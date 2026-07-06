import AVFoundation
import Foundation

/// Renderer montazu: normalizacja klipow + napis daty -> plansza tytulowa ->
/// concat -> muzyka -> walidacja. Kazdy etap raportuje postep; render mozna przerwac.
final class MontageRenderer: @unchecked Sendable {
    private let tools: ToolSet
    private let lock = NSLock()
    private var cancelled = false
    private var currentProcess: Process?
    private let conformer: ClipConformer

    init(tools: ToolSet) {
        self.tools = tools
        self.conformer = ClipConformer(tools: tools)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
        conformer.cancel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Render

    func render(
        clips: [(url: URL, caption: String)],
        settings: MontageSettings,
        output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> MontageRenderResult {
        guard let ffmpegURL = tools.ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }
        guard !clips.isEmpty else {
            throw MediaError.emptyRender
        }

        if settings.renderMode == .losslessCopy {
            do {
                let url = try renderLosslessCopy(
                    ffmpegURL: ffmpegURL,
                    clips: clips.map(\.url),
                    clipDuration: settings.safeClipDuration,
                    output: output,
                    onProgress: onProgress
                )
                return MontageRenderResult(url: url, renderMode: settings.renderMode, fallbackReason: nil)
            } catch {
                guard shouldFallbackFromLossless(error, settings: settings) else {
                    throw error
                }
                return try renderProResFallback(
                    clips: clips,
                    settings: settings,
                    output: output,
                    originalError: error,
                    onProgress: onProgress
                )
            }
        }

        if settings.renderMode == .losslessSmart {
            do {
                let url = try renderLosslessSmart(
                    ffmpegURL: ffmpegURL,
                    clips: clips.map(\.url),
                    clipDuration: settings.safeClipDuration,
                    output: output,
                    onProgress: onProgress
                )
                return MontageRenderResult(url: url, renderMode: settings.renderMode, fallbackReason: nil)
            } catch {
                guard shouldFallbackFromLossless(error, settings: settings) else {
                    throw error
                }
                return try renderProResFallback(
                    clips: clips,
                    settings: settings,
                    output: output,
                    originalError: error,
                    onProgress: onProgress
                )
            }
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondsUp-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        let (width, height) = settings.resolution.size
        var segments: [URL] = []

        // Plansza tytulowa.
        if settings.titleEnabled && !settings.titleText.isEmpty {
            onProgress(RenderProgress(stage: "Plansza tytulowa", fraction: 0.02))
            let titleURL = workDir.appendingPathComponent("title.\(settings.segmentExtension)")
            try renderCard(
                ffmpegURL: ffmpegURL,
                to: titleURL,
                text: settings.titleText,
                duration: settings.titleDuration,
                settings: settings,
                width: width,
                height: height
            )
            segments.append(titleURL)
        }

        // Normalizacja klipow + napisy.
        let expectedClipsDuration = Double(clips.count) * settings.safeClipDuration
        for (index, clip) in clips.enumerated() {
            try checkCancelled()
            onProgress(
                RenderProgress(
                    stage: "Klip \(index + 1)/\(clips.count): \(clip.url.lastPathComponent)",
                    fraction: 0.03 + 0.69 * Double(index) / Double(clips.count)
                )
            )
            let segmentURL = workDir.appendingPathComponent(
                String(format: "seg_%04d.%@", index, settings.segmentExtension)
            )
            try normalizeClip(
                ffmpegURL: ffmpegURL,
                source: clip.url,
                caption: clip.caption,
                to: segmentURL,
                settings: settings,
                width: width,
                height: height
            )
            segments.append(segmentURL)
        }

        if settings.endCardEnabled && !settings.endCardText.isEmpty {
            try checkCancelled()
            onProgress(RenderProgress(stage: "Plansza koncowa", fraction: 0.73))
            let endURL = workDir.appendingPathComponent("end.\(settings.segmentExtension)")
            try renderCard(
                ffmpegURL: ffmpegURL,
                to: endURL,
                text: settings.endCardText,
                duration: settings.endCardDuration,
                settings: settings,
                width: width,
                height: height
            )
            segments.append(endURL)
        }

        // Concat.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie klipow", fraction: 0.75))
        let concatURL = workDir.appendingPathComponent("concat.\(settings.segmentExtension)")
        try concatenate(ffmpegURL: ffmpegURL, segments: segments, to: concatURL, workDir: workDir)

        // Muzyka.
        try checkCancelled()
        let renderedURL: URL
        if let musicPath = settings.musicPath,
           FileManager.default.fileExists(atPath: musicPath) {
            onProgress(RenderProgress(stage: "Dodaje muzyke", fraction: 0.88))
            let musicURL = workDir.appendingPathComponent("final.\(settings.segmentExtension)")
            try addMusic(
                ffmpegURL: ffmpegURL,
                video: concatURL,
                music: URL(fileURLWithPath: musicPath),
                to: musicURL,
                settings: settings
            )
            renderedURL = musicURL
        } else {
            renderedURL = concatURL
        }

        // Walidacja i przeniesienie na miejsce docelowe.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Walidacja", fraction: 0.96))
        var expected = expectedClipsDuration
        if settings.titleEnabled && !settings.titleText.isEmpty {
            expected += settings.titleDuration
        }
        if settings.endCardEnabled && !settings.endCardText.isEmpty {
            expected += settings.endCardDuration
        }
        let actual = try probeDuration(of: renderedURL)
        let tolerance = validationTolerance(for: expected)
        guard abs(actual - expected) <= tolerance else {
            throw MediaError.invalidExport(
                String(format: "czas %.1fs, oczekiwano ~%.1fs", actual, expected)
            )
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: renderedURL, to: output)
        onProgress(RenderProgress(stage: "Gotowe", fraction: 1.0))
        return MontageRenderResult(url: output, renderMode: settings.renderMode, fallbackReason: nil)
    }

    // MARK: - Etapy

    private func renderProResFallback(
        clips: [(url: URL, caption: String)],
        settings: MontageSettings,
        output: URL,
        originalError: Error,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> MontageRenderResult {
        try checkCancelled()
        onProgress(
            RenderProgress(
                stage: "Copy nie przeszlo walidacji, renderuje ProRes HQ",
                fraction: 0.01
            )
        )
        var fallbackSettings = settings
        fallbackSettings.renderMode = .proResHQ
        let result = try render(
            clips: clips,
            settings: fallbackSettings,
            output: output,
            onProgress: onProgress
        )
        return MontageRenderResult(
            url: result.url,
            renderMode: .proResHQ,
            fallbackReason: originalError.localizedDescription
        )
    }

    private func shouldFallbackFromLossless(_ error: Error, settings: MontageSettings) -> Bool {
        guard settings.autoFallbackToProRes else {
            return false
        }
        switch error {
        case MediaError.invalidExport, MediaError.incompatibleClips, MediaError.commandFailed:
            return true
        default:
            return false
        }
    }

    private func renderLosslessCopy(
        ffmpegURL: URL,
        clips: [URL],
        clipDuration: Double,
        output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> URL {
        // Rozne kodeki/rozdzielczosci/fps daja zepsute odtwarzanie
        // na granicach klipow — sprawdzamy to przed renderem.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sprawdzam zgodnosc klipow", fraction: 0.05))
        try verifyCopyCompatibility(of: clips)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondsUp-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }
        let renderedURL = workDir.appendingPathComponent("lossless-copy.mov")

        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie bezstratne", fraction: 0.4))
        try concatenatePassthrough(
            segments: clips,
            clipDuration: clipDuration,
            to: renderedURL,
            onProgress: onProgress
        )

        try checkCancelled()
        onProgress(RenderProgress(stage: "Walidacja", fraction: 0.97))
        let expected = Double(clips.count) * clipDuration
        let actual = try probeDuration(of: renderedURL)
        let tolerance = validationTolerance(for: expected)
        guard abs(actual - expected) <= tolerance else {
            throw MediaError.invalidExport(
                String(format: "czas %.1fs, oczekiwano ~%.1fs", actual, expected)
            )
        }
        try validateDecodable(renderedURL, onProgress: onProgress)

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: renderedURL, to: output)
        onProgress(RenderProgress(stage: "Gotowe", fraction: 1.0))
        return output
    }

    /// Smart concat: klipy zgodne z najczestsza sygnatura sa kopiowane
    /// bez rekompresji, tylko odstajace sa dopasowywane re-encode'em.
    private func renderLosslessSmart(
        ffmpegURL: URL,
        clips: [URL],
        clipDuration: Double,
        output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondsUp-smart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        // 1. Sygnatury wszystkich klipow (kodek/rozdzielczosc/fps/kolor/audio).
        onProgress(RenderProgress(stage: "Analiza parametrow klipow", fraction: 0.02))
        var infos: [ClipConformer.ClipInfo] = []
        for clip in clips {
            try checkCancelled()
            infos.append(try conformer.inspect(clip))
        }

        // 2. Najczestsza kombinacja jako wzorzec.
        guard let target = ClipConformer.majorityTarget(of: infos) else {
            throw MediaError.emptyRender
        }

        // 3. Odstajace klipy dopasowujemy do wzorca, reszta idzie bez zmian.
        var segments: [URL] = []
        let outlierCount = infos.filter { $0.matchKey != target.matchKey }.count
        var conformedCount = 0
        for (index, info) in infos.enumerated() {
            try checkCancelled()
            if info.matchKey == target.matchKey {
                segments.append(info.url)
                continue
            }
            conformedCount += 1
            onProgress(
                RenderProgress(
                    stage: "Dopasowuje \(conformedCount)/\(outlierCount): \(info.url.lastPathComponent)",
                    fraction: 0.05 + 0.75 * Double(conformedCount) / Double(max(1, outlierCount))
                )
            )
            let conformedURL = workDir.appendingPathComponent(String(format: "conf_%04d.mov", index))
            try conformer.conform(
                source: info,
                target: target,
                to: conformedURL,
                duration: clipDuration
            )
            segments.append(conformedURL)
        }

        // 4. Bezstratne sklejanie na poziomie probek (LosslessConcat.swift):
        // kazdy segment zachowuje wlasne parametry kodeka, wiec granice
        // miedzy klipami z roznych enkoderow dekoduja sie czysto — sklejka
        // ffmpeg -c copy zapisuje jeden globalny naglowek SPS/PPS i psuje
        // segmenty z innego enkodera.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie bezstratne", fraction: 0.85))
        let renderedURL = workDir.appendingPathComponent("lossless-smart.mov")
        try concatenatePassthrough(
            segments: segments,
            clipDuration: clipDuration,
            to: renderedURL,
            onProgress: onProgress
        )

        try checkCancelled()
        onProgress(RenderProgress(stage: "Walidacja", fraction: 0.97))
        let expected = Double(clips.count) * clipDuration
        let actual = try probeDuration(of: renderedURL)
        let tolerance = validationTolerance(for: expected)
        guard abs(actual - expected) <= tolerance else {
            throw MediaError.invalidExport(
                String(format: "czas %.1fs, oczekiwano ~%.1fs", actual, expected)
            )
        }
        try validateDecodable(renderedURL, onProgress: onProgress)

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: renderedURL, to: output)
        onProgress(RenderProgress(stage: "Gotowe", fraction: 1.0))
        return output
    }


    /// Rzuca `incompatibleClips`, jesli klipy nie maja identycznych parametrow
    /// (kodek, rozdzielczosc, fps, kolor, audio). Za wzorzec przyjmujemy
    /// najczestsza sygnature, w bledzie wypisujemy odstajace pliki.
    private func verifyCopyCompatibility(of clips: [URL]) throws {
        var infos: [ClipConformer.ClipInfo] = []
        for clip in clips {
            try checkCancelled()
            infos.append(try conformer.inspect(clip))
        }
        guard let target = ClipConformer.majorityTarget(of: infos) else {
            return
        }
        let outliers = infos.filter { $0.matchKey != target.matchKey }
        guard !outliers.isEmpty else {
            return
        }
        let maxListed = 6
        var names = outliers.prefix(maxListed).map {
            "\($0.url.lastPathComponent) (\($0.summary))"
        }
        if outliers.count > maxListed {
            names.append("… i \(outliers.count - maxListed) innych")
        }
        throw MediaError.incompatibleClips(names.joined(separator: ", "))
    }

    private func normalizeClip(
        ffmpegURL: URL,
        source: URL,
        caption: String,
        to output: URL,
        settings: MontageSettings,
        width: Int,
        height: Int
    ) throws {
        var filters = [
            "scale=\(width):\(height):force_original_aspect_ratio=decrease",
            "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2",
            "setsar=1",
            "fps=\(settings.fps)"
        ]
        if settings.renderMode == .hdrPremium {
            // Zrodla spoza HLG (np. stare klipy SDR) konwertujemy do
            // przestrzeni wyjscia, zeby kolory byly spojne w calym filmie.
            if let signature = try? conformer.probeVideoSignature(of: source),
               signature.colorTransfer != "arib-std-b67",
               let zscale = ClipConformer.zscaleFilter(from: signature, to: Self.hlgTarget) {
                filters.append(zscale)
            }
        }
        if settings.captionEnabled && !caption.isEmpty {
            filters.append(captionFilter(text: caption, settings: settings))
        }
        if settings.renderMode == .hdrPremium {
            // Znakowanie klatek charakterystyka HLG — bez tego videotoolbox
            // i concat gubia tagi kolorow (color_transfer=unknown).
            filters.append(
                "setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc"
            )
            // 10 bitow do samego enkodera (videotoolbox przyjmuje p010).
            filters.append("format=p010le")
        }

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-i", source.path
        ]

        let hasAudio = (try? probeHasAudio(of: source)) ?? false
        let needsSilence = settings.keepClipAudio && !hasAudio
        if needsSilence {
            arguments += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        }

        arguments += [
            "-vf", filters.joined(separator: ","),
            "-map", "0:v:0"
        ]

        if settings.keepClipAudio {
            if hasAudio {
                arguments += ["-map", "0:a:0"]
                var audioFilters: [String] = []
                if settings.normalizeLoudness {
                    // EBU R128: dwuprzebiegowo, gdy udalo sie zmierzyc klip;
                    // inaczej jednoprzebiegowo. loudnorm upsampluje do 192 kHz,
                    // wiec wracamy do 48 kHz.
                    audioFilters.append(
                        loudnormFilter(ffmpegURL: ffmpegURL, source: source)
                    )
                    audioFilters.append("aresample=48000")
                }
                if abs(settings.clipAudioVolume - 1.0) > 0.01 {
                    audioFilters.append(String(format: "volume=%.2f", settings.clipAudioVolume))
                }
                if !audioFilters.isEmpty {
                    arguments += ["-af", audioFilters.joined(separator: ",")]
                }
            } else {
                arguments += ["-map", "1:a:0", "-shortest"]
            }
            arguments += ["-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k"]
        } else {
            arguments += ["-an"]
        }

        arguments += ["-t", String(format: "%.3f", settings.safeClipDuration)]
        arguments += videoEncodingArguments(settings: settings)
        arguments += [output.path]

        try run(ffmpegURL, arguments)
    }

    private func renderCard(
        ffmpegURL: URL,
        to output: URL,
        text: String,
        duration: Double,
        settings: MontageSettings,
        width: Int,
        height: Int
    ) throws {
        let fontSize = min(width, height) / 12
        let title = Self.escapeDrawtext(text)
        let drawtext = "drawtext=fontfile=\(settings.captionFont.fontPath):text='\(title)'"
            + ":fontsize=\(fontSize):fontcolor=white:x=(w-tw)/2:y=(h-th)/2"

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-f", "lavfi",
            "-i", "color=c=black:s=\(width)x\(height):r=\(settings.fps)"
        ]
        if settings.keepClipAudio {
            arguments += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        }
        var cardFilter = drawtext
        if settings.renderMode == .hdrPremium {
            cardFilter += ",setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc"
            cardFilter += ",format=p010le"
        }
        arguments += [
            "-t", String(format: "%.2f", duration),
            "-vf", cardFilter,
            "-map", "0:v"
        ]
        if settings.keepClipAudio {
            arguments += ["-map", "1:a", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k"]
        }
        arguments += videoEncodingArguments(settings: settings)
        arguments += [output.path]

        try run(ffmpegURL, arguments)
    }

    private func concatenate(
        ffmpegURL: URL,
        segments: [URL],
        to output: URL,
        workDir: URL
    ) throws {
        let listURL = workDir.appendingPathComponent("concat.txt")
        let lines = segments.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
        try lines.joined(separator: "\n").write(to: listURL, atomically: true, encoding: .utf8)

        try run(
            ffmpegURL,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-f", "concat",
                "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                "-movflags", "write_colr",
                output.path
            ]
        )
    }

    private func addMusic(
        ffmpegURL: URL,
        video: URL,
        music: URL,
        to output: URL,
        settings: MontageSettings
    ) throws {
        let duration = try probeDuration(of: video)
        var musicChain = String(format: "volume=%.2f,apad", settings.musicVolume)
        if settings.musicFadeOut {
            let fadeStart = max(0, duration - settings.musicFadeDuration)
            musicChain += String(
                format: ",afade=t=out:st=%.2f:d=%.2f",
                fadeStart,
                settings.musicFadeDuration
            )
        }

        let hasClipAudio = settings.keepClipAudio && ((try? probeHasAudio(of: video)) ?? false)
        let filterComplex: String
        let audioMap: String
        if hasClipAudio {
            filterComplex = "[1:a]\(musicChain)[mu];[0:a][mu]amix=inputs=2:duration=first:normalize=0[m]"
            audioMap = "[m]"
        } else {
            filterComplex = "[1:a]\(musicChain)[m]"
            audioMap = "[m]"
        }

        try run(
            ffmpegURL,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-i", video.path,
                "-i", music.path,
                "-filter_complex", filterComplex,
                "-map", "0:v",
                "-map", audioMap,
                "-c:v", "copy",
                "-movflags", "write_colr",
                "-c:a", "aac",
                "-b:a", "192k",
                "-t", String(format: "%.3f", duration),
                output.path
            ]
        )
    }

    // MARK: - Pomocnicze

    private func captionFilter(text: String, settings: MontageSettings) -> String {
        let escaped = Self.escapeDrawtext(text)
        let position = settings.captionPosition.drawtextXY
        return "drawtext=fontfile=\(settings.captionFont.fontPath):text='\(escaped)'"
            + String(format: ":fontsize=%.0f", settings.captionFontSize)
            + String(format: ":fontcolor=white@%.2f", settings.captionOpacity)
            + ":borderw=2:bordercolor=black@0.6"
            + ":x=\(position.x):y=\(position.y)"
    }

    private func videoEncodingArguments(settings: MontageSettings) -> [String] {
        switch settings.renderMode {
        case .hdrPremium:
            // HEVC 10-bit z zachowanym HLG — jakosc wizualnie jak oryginal,
            // hvc1 + jeden opis formatu, wiec QuickTime/TV graja bez zarzutu.
            let (width, height) = settings.resolution.size
            return [
                "-c:v", "hevc_videotoolbox",
                "-b:v", Self.premiumBitrate(width: width, height: height),
                "-profile:v", "main10",
                "-tag:v", "hvc1",
                "-color_primaries", "bt2020",
                "-color_trc", "arib-std-b67",
                "-colorspace", "bt2020nc",
                "-movflags", "write_colr"
            ]
        case .h264, .losslessSmart, .losslessCopy:
            return [
                "-c:v", "libx264",
                "-preset", settings.renderQuality.preset,
                "-crf", settings.renderQuality.crf,
                "-pix_fmt", "yuv420p"
            ]
        case .proResHQ:
            return [
                "-c:v", "prores_ks",
                "-profile:v", "3",
                "-pix_fmt", "yuv422p10le"
            ]
        }
    }

    /// Docelowa charakterystyka kolorow Premium HDR (jak nagrania iPhone'a).
    static let hlgTarget = ClipConformer.VideoSignature(
        codec: "hevc",
        width: 0,
        height: 0,
        pixelFormat: "yuv420p10le",
        colorTransfer: "arib-std-b67",
        colorPrimaries: "bt2020",
        colorSpace: "bt2020nc",
        fps: 0,
        trackTimescale: 0,
        startTime: 0
    )

    /// Filtr loudnorm: mierzy klip (pierwszy przebieg) i zwraca filtr
    /// drugiego przebiegu; gdy pomiar sie nie uda — jednoprzebiegowy.
    private func loudnormFilter(ffmpegURL: URL, source: URL) -> String {
        let base = "loudnorm=I=-16:TP=-1.5:LRA=11"
        guard let measured = try? measureLoudness(ffmpegURL: ffmpegURL, source: source) else {
            return base
        }
        return base
            + ":measured_I=\(measured.i)"
            + ":measured_TP=\(measured.tp)"
            + ":measured_LRA=\(measured.lra)"
            + ":measured_thresh=\(measured.thresh)"
            + ":offset=\(measured.offset)"
            + ":linear=true"
    }

    private func measureLoudness(
        ffmpegURL: URL,
        source: URL
    ) throws -> (i: String, tp: String, lra: String, thresh: String, offset: String) {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-nostdin",
            "-i", source.path,
            "-vn",
            "-af", "loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json",
            "-f", "null",
            "-"
        ]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        // JSON loudnorm to ostatni blok { ... } na stderr.
        guard let open = text.range(of: "{", options: .backwards),
              let close = text.range(of: "}", options: .backwards),
              open.lowerBound < close.lowerBound,
              let json = try? JSONSerialization.jsonObject(
                  with: Data(text[open.lowerBound...close.lowerBound].utf8)
              ) as? [String: Any],
              let i = json["input_i"] as? String,
              let tp = json["input_tp"] as? String,
              let lra = json["input_lra"] as? String,
              let thresh = json["input_thresh"] as? String,
              let offset = json["target_offset"] as? String else {
            throw MediaError.invalidJSON
        }
        return (i, tp, lra, thresh, offset)
    }

    /// Bitrate Premium HDR wg rozdzielczosci (HEVC 10-bit).
    static func premiumBitrate(width: Int, height: Int) -> String {
        let pixels = width * height
        if pixels >= 3840 * 2160 * 9 / 10 {
            return "70M"
        }
        if pixels >= 1920 * 1080 {
            return "30M"
        }
        return "15M"
    }

    static func escapeDrawtext(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        // Apostrof zamieniamy na typograficzny — unika pieklo escapowania w filtrze.
        escaped = escaped.replacingOccurrences(of: "'", with: "\u{2019}")
        escaped = escaped.replacingOccurrences(of: ":", with: "\\:")
        escaped = escaped.replacingOccurrences(of: ",", with: "\\,")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        return escaped
    }

    func probeDuration(of url: URL) throws -> Double {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }
        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "json",
                url.path
            ]
        )
        struct Probe: Decodable {
            struct Format: Decodable {
                let duration: String?
            }
            let format: Format?
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        return probe.format?.duration.flatMap(Double.init) ?? 0
    }

    func probeHasAudio(of url: URL) throws -> Bool {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }
        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "a",
                "-show_entries", "stream=codec_type",
                "-of", "json",
                url.path
            ]
        )
        struct Probe: Decodable {
            struct Stream: Decodable {
                let codecType: String?

                enum CodingKeys: String, CodingKey {
                    case codecType = "codec_type"
                }
            }
            let streams: [Stream]
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        return !probe.streams.isEmpty
    }

    private func validationTolerance(for expected: Double) -> Double {
        max(0.35, expected * 0.01)
    }

    /// Walidacja przez PELNE natywne dekodowanie (AVAssetReader/VideoToolbox —
    /// dokladnie ten sam stack, ktorym gra QuickTime). ffmpeg nie nadaje sie
    /// do walidacji plikow multi-stsd (zglasza pozorne bledy SPS mimo
    /// poprawnego odtwarzania w QuickTime).
    private func validateDecodable(
        _ url: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws {
        try checkCancelled()
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw MediaError.invalidExport("wynik nie ma sciezki video")
        }
        let expectedDuration = asset.duration.seconds
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw MediaError.invalidExport("wyniku nie da sie otworzyc do dekodowania")
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MediaError.invalidExport(
                "dekodowanie wyniku nie startuje: "
                    + (reader.error?.localizedDescription ?? "?")
            )
        }

        var decodedFrames = 0
        var lastPTS = CMTime.zero
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled {
                reader.cancelReading()
                throw MediaError.cancelled
            }
            if CMSampleBufferGetNumSamples(sample) > 0 {
                decodedFrames += 1
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isValid {
                    lastPTS = pts
                }
            }
            if decodedFrames % 600 == 0, expectedDuration > 0 {
                onProgress(
                    RenderProgress(
                        stage: "Walidacja dekodowania",
                        fraction: 0.97 + 0.025 * min(1, lastPTS.seconds / expectedDuration)
                    )
                )
            }
        }

        if reader.status == .failed {
            throw MediaError.invalidExport(
                "wynik nie dekoduje sie czysto: "
                    + (reader.error?.localizedDescription ?? "blad dekodera")
            )
        }
        guard decodedFrames > 0, lastPTS.seconds > expectedDuration - 1.0 else {
            throw MediaError.invalidExport(
                String(
                    format: "dekodowanie urwalo sie na %.1fs z %.1fs (%d klatek)",
                    lastPTS.seconds,
                    expectedDuration,
                    decodedFrames
                )
            )
        }
    }

    func checkCancelled() throws {
        if isCancelled {
            throw MediaError.cancelled
        }
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        try checkCancelled()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        lock.lock()
        currentProcess = process
        lock.unlock()
        defer {
            lock.lock()
            currentProcess = nil
            lock.unlock()
        }

        do {
            return try FFmpegRunner.execute(process)
        } catch {
            if isCancelled {
                throw MediaError.cancelled
            }
            throw error
        }
    }
}

private extension MontageSettings {
    var safeClipDuration: Double {
        min(10.0, max(0.1, clipDuration))
    }

    var segmentExtension: String {
        renderMode == .proResHQ || renderMode == .hdrPremium ? "mov" : "mp4"
    }
}
