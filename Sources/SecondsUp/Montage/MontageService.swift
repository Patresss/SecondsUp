import AVFoundation
import Foundation

/// Renderer montazu: normalizacja klipow + napis daty -> plansza tytulowa ->
/// concat -> muzyka -> walidacja. Kazdy etap raportuje postep; render mozna przerwac.
final class MontageRenderer: @unchecked Sendable {
    private let tools: ToolSet
    private let lock = NSLock()
    private var cancelled = false
    private var currentProcess: Process?
    var currentExport: AVAssetExportSession?
    private let conformer: ClipConformer

    init(tools: ToolSet) {
        self.tools = tools
        self.conformer = ClipConformer(tools: tools)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        let export = currentExport
        lock.unlock()
        process?.terminate()
        export?.cancelExport()
        conformer.cancel()
    }

    private var isCancelled: Bool {
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
    ) throws -> URL {
        guard let ffmpegURL = tools.ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }
        guard !clips.isEmpty else {
            throw MediaError.emptyRender
        }

        if settings.renderMode == .losslessCopy {
            return try renderLosslessCopy(
                ffmpegURL: ffmpegURL,
                clips: clips.map(\.url),
                output: output,
                onProgress: onProgress
            )
        }

        if settings.renderMode == .losslessSmart {
            return try renderLosslessSmart(
                ffmpegURL: ffmpegURL,
                clips: clips.map(\.url),
                output: output,
                onProgress: onProgress
            )
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
        var expectedClipsDuration = 0.0
        for (index, clip) in clips.enumerated() {
            try checkCancelled()
            onProgress(
                RenderProgress(
                    stage: "Klip \(index + 1)/\(clips.count): \(clip.url.lastPathComponent)",
                    fraction: 0.03 + 0.69 * Double(index) / Double(clips.count)
                )
            )
            expectedClipsDuration += (try? probeDuration(of: clip.url)) ?? 1.0
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
        let tolerance = max(1.0, expected * 0.03)
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
        return output
    }

    // MARK: - Etapy

    private func renderLosslessCopy(
        ffmpegURL: URL,
        clips: [URL],
        output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> URL {
        // Rozne kodeki/rozdzielczosci/fps daja zepsute odtwarzanie
        // na granicach klipow — sprawdzamy to przed renderem.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sprawdzam zgodnosc klipow", fraction: 0.05))
        try verifyCopyCompatibility(of: clips)

        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie bezstratne", fraction: 0.4))
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try concatenatePassthrough(segments: clips, to: output, onProgress: onProgress)

        try checkCancelled()
        onProgress(RenderProgress(stage: "Walidacja", fraction: 0.97))
        let expected = clips.reduce(0.0) { total, clip in
            total + ((try? probeDuration(of: clip)) ?? 1.0)
        }
        let actual = try probeDuration(of: output)
        let tolerance = max(1.0, expected * 0.05)
        guard abs(actual - expected) <= tolerance else {
            throw MediaError.invalidExport(
                String(format: "czas %.1fs, oczekiwano ~%.1fs", actual, expected)
            )
        }

        onProgress(RenderProgress(stage: "Gotowe", fraction: 1.0))
        return output
    }

    /// Smart concat: klipy zgodne z najczestsza sygnatura sa kopiowane
    /// bez rekompresji, tylko odstajace sa dopasowywane re-encode'em.
    private func renderLosslessSmart(
        ffmpegURL: URL,
        clips: [URL],
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
            try conformer.conform(source: info, target: target, to: conformedURL)
            segments.append(conformedURL)
        }

        // 4. Sklejanie przez AVFoundation passthrough (bez rekompresji).
        // Kazdy segment zachowuje wlasne parametry kodeka (multi-stsd w MOV),
        // wiec granice miedzy klipami z roznych enkoderow dekoduja sie czysto —
        // sklejka ffmpeg -c copy zapisuje jeden globalny naglowek i psuje
        // segmenty z innym SPS/PPS.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie bezstratne", fraction: 0.85))
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try concatenatePassthrough(segments: segments, to: output, onProgress: onProgress)

        try checkCancelled()
        onProgress(RenderProgress(stage: "Walidacja", fraction: 0.97))
        let expected = clips.reduce(0.0) { total, clip in
            total + ((try? probeDuration(of: clip)) ?? 1.0)
        }
        let actual = try probeDuration(of: output)
        let tolerance = max(1.0, expected * 0.05)
        guard abs(actual - expected) <= tolerance else {
            throw MediaError.invalidExport(
                String(format: "czas %.1fs, oczekiwano ~%.1fs", actual, expected)
            )
        }

        onProgress(RenderProgress(stage: "Gotowe", fraction: 1.0))
        return output
    }

    /// Bezstratne sklejanie przez AVMutableComposition + eksport passthrough.
    private func concatenatePassthrough(
        segments: [URL],
        to output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MediaError.invalidExport("nie mozna utworzyc sciezki video")
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        for segment in segments {
            try checkCancelled()
            let asset = AVURLAsset(url: segment)
            guard let sourceVideo = asset.tracks(withMediaType: .video).first else {
                throw MediaError.invalidExport("brak video w \(segment.lastPathComponent)")
            }

            // KRYTYCZNE: kursor idzie po dlugosci sciezki VIDEO, nie asset.duration.
            // asset.duration to maksimum ze sciezek — audio (padding AAC) bywa
            // 20-90 ms dluzsze od video. Wstawianie wg asset.duration tworzy
            // puste edity (media time -1) w sciezce video, a QuickTime zamraza
            // wtedy ostatnia klatke na kazdej granicy klipu — wyglada to jak
            // zwolnione tempo / przyciecia.
            let videoRange = sourceVideo.timeRange
            do {
                try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: cursor)
            } catch {
                throw MediaError.invalidExport(
                    "nie mozna dolaczyc \(segment.lastPathComponent): \(error.localizedDescription)"
                )
            }

            // Kursor = faktyczny koniec sciezki po wstawieniu. Zrodlowy track
            // moze wstawic odrobine mniej, niz deklaruje timeRange — liczenie
            // kursora z deklaracji zostawialoby pusty edit (zamrozona klatka).
            let segmentStart = cursor
            cursor = videoTrack.timeRange.end
            let segmentDuration = CMTimeSubtract(cursor, segmentStart)

            if let audioTrack {
                if let sourceAudio = asset.tracks(withMediaType: .audio).first {
                    // Audio przyciete do dlugosci video — ewentualna luka
                    // w dzwieku na granicy jest niezauwazalna, luka w obrazie nie.
                    let audioRange = CMTimeRange(
                        start: sourceAudio.timeRange.start,
                        duration: CMTimeMinimum(sourceAudio.timeRange.duration, segmentDuration)
                    )
                    try? audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: segmentStart)
                } else {
                    // Cisza zamiast dzwieku, zeby audio nie rozjechalo sie z obrazem.
                    audioTrack.insertEmptyTimeRange(
                        CMTimeRange(start: segmentStart, duration: segmentDuration)
                    )
                }
            }
        }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MediaError.invalidExport("passthrough eksport niedostepny")
        }
        export.outputURL = output
        export.outputFileType = .mov

        lock.lock()
        currentExport = export
        lock.unlock()
        defer {
            lock.lock()
            currentExport = nil
            lock.unlock()
        }

        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously {
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            onProgress(
                RenderProgress(
                    stage: "Sklejanie bezstratne",
                    fraction: 0.85 + 0.11 * Double(export.progress)
                )
            )
        }

        switch export.status {
        case .completed:
            return
        case .cancelled:
            throw MediaError.cancelled
        default:
            throw MediaError.invalidExport(
                export.error?.localizedDescription ?? "eksport passthrough nie powiodl sie"
            )
        }
    }

    /// Re-encode pojedynczego klipu do parametrow wzorca (kodek, rozdzielczosc,
    /// pix_fmt, kolor, audio), zeby dal sie bezpiecznie skleic -c copy.
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
        if settings.captionEnabled && !caption.isEmpty {
            filters.append(captionFilter(text: caption, settings: settings))
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
                if abs(settings.clipAudioVolume - 1.0) > 0.01 {
                    arguments += ["-af", String(format: "volume=%.2f", settings.clipAudioVolume)]
                }
            } else {
                arguments += ["-map", "1:a:0", "-shortest"]
            }
            arguments += ["-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k"]
        } else {
            arguments += ["-an"]
        }

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
        arguments += [
            "-t", String(format: "%.2f", duration),
            "-vf", drawtext,
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

    private func checkCancelled() throws {
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
    var segmentExtension: String {
        renderMode == .proResHQ ? "mov" : "mp4"
    }
}
