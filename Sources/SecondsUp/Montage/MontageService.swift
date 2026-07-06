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
        if ProcessInfo.processInfo.environment["SU_KEEP_INVALID"] != nil {
            let debugURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("secondsup-debug-copy.mov")
            try? FileManager.default.removeItem(at: debugURL)
            try? FileManager.default.copyItem(at: renderedURL, to: debugURL)
        }
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

        // 4. Sklejanie przez AVFoundation passthrough (bez rekompresji).
        // Kazdy segment zachowuje wlasne parametry kodeka (multi-stsd w MOV),
        // wiec granice miedzy klipami z roznych enkoderow dekoduja sie czysto —
        // sklejka ffmpeg -c copy zapisuje jeden globalny naglowek i psuje
        // segmenty z innym SPS/PPS.
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

    /// Bezstratne sklejanie na poziomie PROBEK, w trzech przebiegach:
    ///
    /// 1. Writer #1: sama sciezka VIDEO (jeden input -> zero problemow
    ///    z przeplotem A/V, ktore zakleszczaly writer dwuwejsciowy).
    /// 2. Writer #2: sama sciezka AUDIO do .m4a (budzet per klip wyliczony
    ///    w przebiegu 1 pilnuje globalnej synchronizacji A/V).
    /// 3. Zlaczenie sciezek kompozycja + eksport passthrough — po JEDNYM
    ///    segmencie na sciezke, wiec passthrough nie ma czego zepsuc
    ///    (probki-cienie powstawaly przy wielu segmentach).
    ///
    /// Dlaczego nie AVAssetExportSession na 168 segmentach: eksport
    /// passthrough takiej kompozycji zapisywal zdublowane, nakladajace sie
    /// probki (pakiety-cienie z flaga discard) i niemonotoniczny DTS —
    /// QuickTime dekodowal ~2x wiecej danych i gral w zwolnionym tempie.
    /// Dlaczego nie ffmpeg concat -c copy: jeden globalny naglowek SPS/PPS
    /// psuje segmenty z innego enkodera. Tutaj kazda probka jest kopiowana
    /// bit-w-bit dokladnie raz, z jawnie policzonym czasem: DTS/PTS
    /// monotoniczne i CIAGLE z konstrukcji — zero edit-list w obu sciezkach.
    private func concatenatePassthrough(
        segments: [URL],
        clipDuration: Double,
        to output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecondsUp-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        let firstAsset = AVURLAsset(url: segments[0])
        let includeAudio = firstAsset.tracks(withMediaType: .audio).first != nil
        let clipLimit = CMTime(seconds: clipDuration, preferredTimescale: 600)

        // Przebieg 1: VIDEO. Zapamietujemy faktyczny koniec kazdego klipu —
        // to budzety audio dla przebiegu 2.
        onProgress(RenderProgress(stage: "Sklejanie video", fraction: 0.85))
        let videoURL = workDir.appendingPathComponent("video.mov")
        let clipVideoEnds = try writeVideoTrack(
            segments: segments,
            clipLimit: clipLimit,
            to: videoURL,
            onProgress: onProgress
        )

        // Przebieg 2: AUDIO.
        var audioURL: URL?
        if includeAudio {
            onProgress(RenderProgress(stage: "Sklejanie audio", fraction: 0.93))
            let url = workDir.appendingPathComponent("audio.mov")
            try writeAudioTrack(
                segments: segments,
                clipVideoEnds: clipVideoEnds,
                to: url
            )
            audioURL = url
        }

        if ProcessInfo.processInfo.environment["SU_KEEP_INVALID"] != nil {
            let debugDir = FileManager.default.temporaryDirectory
            try? FileManager.default.removeItem(at: debugDir.appendingPathComponent("su-video.mov"))
            try? FileManager.default.copyItem(
                at: videoURL,
                to: debugDir.appendingPathComponent("su-video.mov")
            )
            if let audioURL {
                try? FileManager.default.removeItem(at: debugDir.appendingPathComponent("su-audio.mov"))
                try? FileManager.default.copyItem(
                    at: audioURL,
                    to: debugDir.appendingPathComponent("su-audio.mov")
                )
            }
        }

        // Przebieg 3: zlaczenie sciezek (po jednym segmencie na sciezke).
        try checkCancelled()
        onProgress(RenderProgress(stage: "Laczenie sciezek", fraction: 0.95))
        try mergeTracks(videoURL: videoURL, audioURL: audioURL, to: output)
    }

    /// Zapisuje sama sciezke video (bit-exact, retiming na wspolna os).
    /// Zwraca globalne konce video kolejnych klipow.
    private func writeVideoTrack(
        segments: [URL],
        clipLimit: CMTime,
        to output: URL,
        onProgress: @escaping @Sendable (RenderProgress) -> Void
    ) throws -> [CMTime] {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        if let firstVideo = AVURLAsset(url: segments[0]).tracks(withMediaType: .video).first,
           firstVideo.naturalTimeScale > 0 {
            input.mediaTimeScale = firstVideo.naturalTimeScale
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaError.invalidExport(
                writer.error?.localizedDescription ?? "nie mozna rozpoczac zapisu video"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let feed = SampleFeed(capacity: 360)
        let errorBox = ErrorBox()
        let done = DispatchSemaphore(value: 0)
        Self.pump(input: input, feed: feed, label: "video", writer: writer, errorBox: errorBox, done: done)

        func fail(_ message: String) -> MediaError {
            feed.finish()
            _ = done.wait(timeout: .now() + 3)
            writer.cancelWriting()
            return MediaError.invalidExport(message)
        }

        var clipVideoEnds: [CMTime] = []
        var videoCursor = CMTime.zero
        var lastVideoDTS = CMTime.invalid

        for (index, segment) in segments.enumerated() {
            if isCancelled {
                _ = fail("przerwane")
                throw MediaError.cancelled
            }
            if let message = errorBox.message {
                throw fail(message)
            }
            onProgress(
                RenderProgress(
                    stage: "Sklejanie video \(index + 1)/\(segments.count)",
                    fraction: 0.85 + 0.08 * Double(index) / Double(segments.count)
                )
            )

            let asset = AVURLAsset(url: segment)
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw fail("brak video w \(segment.lastPathComponent)")
            }
            guard let reader = try? AVAssetReader(asset: asset) else {
                throw fail("nie mozna czytac \(segment.lastPathComponent)")
            }
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            reader.add(readerOutput)
            guard reader.startReading() else {
                throw fail(
                    "blad czytania \(segment.lastPathComponent): "
                        + (reader.error?.localizedDescription ?? "?")
                )
            }

            var clipFirstPTS = CMTime.invalid
            var clipVideoEnd = CMTime.zero
            while let sample = readerOutput.copyNextSampleBuffer() {
                if isCancelled {
                    reader.cancelReading()
                    _ = fail("przerwane")
                    throw MediaError.cancelled
                }
                if let message = errorBox.message {
                    reader.cancelReading()
                    throw fail(message)
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if !clipFirstPTS.isValid {
                    clipFirstPTS = pts
                }
                let rel = CMTimeSubtract(pts, clipFirstPTS)
                // Przyciecie klipu do zadanej dlugosci (granica probki).
                if CMTimeCompare(rel, clipLimit) >= 0 {
                    break
                }
                let delta = CMTimeSubtract(videoCursor, clipFirstPTS)
                guard let retimed = Self.retimed(sample, by: delta, clampDTSAfter: lastVideoDTS) else {
                    reader.cancelReading()
                    throw fail("retiming probki w \(segment.lastPathComponent)")
                }
                lastVideoDTS = CMSampleBufferGetDecodeTimeStamp(retimed).isValid
                    ? CMSampleBufferGetDecodeTimeStamp(retimed)
                    : CMSampleBufferGetPresentationTimeStamp(retimed)
                feed.push(retimed)

                var duration = CMSampleBufferGetDuration(sample)
                if !duration.isValid || duration == .zero {
                    duration = CMTime(value: 1, timescale: track.naturalTimeScale)
                }
                clipVideoEnd = CMTimeAdd(rel, duration)
            }
            reader.cancelReading()

            videoCursor = CMTimeAdd(videoCursor, clipVideoEnd)
            clipVideoEnds.append(videoCursor)
        }

        feed.finish()
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled {
                writer.cancelWriting()
                throw MediaError.cancelled
            }
        }
        if let message = errorBox.message {
            writer.cancelWriting()
            throw MediaError.invalidExport(message)
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw MediaError.invalidExport(
                writer.error?.localizedDescription ?? "zapis video nie powiodl sie"
            )
        }
        return clipVideoEnds
    }

    /// Zapisuje sciezke audio jako JEDEN jednolity strumien AAC: dekoduje
    /// zrodla do PCM i koduje raz. Kopiowanie pakietow AAC bit-w-bit jest
    /// zawodne w praktyce (bufory z zepsutym duration, przeskoki pts,
    /// rozne opisy formatu miedzy klipami -> writer wstawia edit-listy
    /// z dziurami, o ktore wywracaja sie playery). Dekodowanie + enkodowanie
    /// 256k AAC jest niesluszalne, a obraz pozostaje bit-exact.
    ///
    /// Kazdy klip jest dopasowany do konca SWOJEGO video co do sampla:
    /// nadmiar audio przycinamy, niedobor uzupelniamy cisza — synchronizacja
    /// A/V jest dokladna i nigdy sie nie kumuluje.
    private func writeAudioTrack(
        segments: [URL],
        clipVideoEnds: [CMTime],
        to output: URL
    ) throws {
        let sampleRate = 48000
        let channels = 2

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var stereoLayout = AudioChannelLayout()
        stereoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &stereoLayout, count: MemoryLayout<AudioChannelLayout>.size)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 256_000,
                AVChannelLayoutKey: layoutData
            ]
        )
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaError.invalidExport(
                writer.error?.localizedDescription ?? "nie mozna rozpoczac zapisu audio"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let feed = SampleFeed(capacity: 2000)
        let errorBox = ErrorBox()
        let done = DispatchSemaphore(value: 0)
        Self.pump(input: input, feed: feed, label: "audio", writer: writer, errorBox: errorBox, done: done)

        func fail(_ message: String) -> MediaError {
            feed.finish()
            _ = done.wait(timeout: .now() + 3)
            writer.cancelWriting()
            return MediaError.invalidExport(message)
        }

        // Wspolny format PCM: float32 interleaved stereo 48 kHz.
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        guard let pcmFormat = Self.makePCMFormat(sampleRate: sampleRate, channels: channels) else {
            throw fail("nie mozna utworzyc formatu PCM")
        }

        var cursorSamples: Int64 = 0  // pozycja w samplach 48 kHz

        for (index, segment) in segments.enumerated() {
            if isCancelled {
                _ = fail("przerwane")
                throw MediaError.cancelled
            }
            if let message = errorBox.message {
                throw fail(message)
            }
            // Cel: audio konczy sie dokladnie na koncu video tego klipu.
            let targetSamples = Int64((clipVideoEnds[index].seconds * Double(sampleRate)).rounded())

            let asset = AVURLAsset(url: segment)
            if let track = asset.tracks(withMediaType: .audio).first,
               let reader = try? AVAssetReader(asset: asset) {
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
                readerOutput.alwaysCopiesSampleData = false
                reader.add(readerOutput)
                if reader.startReading() {
                    while cursorSamples < targetSamples,
                          let sample = readerOutput.copyNextSampleBuffer() {
                        if isCancelled {
                            reader.cancelReading()
                            _ = fail("przerwane")
                            throw MediaError.cancelled
                        }
                        if let message = errorBox.message {
                            reader.cancelReading()
                            throw fail(message)
                        }
                        var frames = Int64(CMSampleBufferGetNumSamples(sample))
                        guard frames > 0 else {
                            continue
                        }
                        var toAppend = sample
                        if cursorSamples + frames > targetSamples {
                            // Przytnij ostatni bufor co do sampla.
                            let keep = targetSamples - cursorSamples
                            var trimmed: CMSampleBuffer?
                            CMSampleBufferCopySampleBufferForRange(
                                allocator: kCFAllocatorDefault,
                                sampleBuffer: sample,
                                sampleRange: CFRange(location: 0, length: CFIndex(keep)),
                                sampleBufferOut: &trimmed
                            )
                            guard let trimmed else {
                                break
                            }
                            toAppend = trimmed
                            frames = keep
                        }
                        guard let retimed = Self.retimedPCM(
                            toAppend,
                            atSample: cursorSamples,
                            sampleRate: sampleRate
                        ) else {
                            reader.cancelReading()
                            throw fail("retiming audio w \(segment.lastPathComponent)")
                        }
                        feed.push(retimed)
                        cursorSamples += frames
                    }
                    reader.cancelReading()
                }
            }

            // Niedobor uzupelnij cisza — klip konczy sie rowno z video.
            if cursorSamples < targetSamples {
                let missing = targetSamples - cursorSamples
                guard let silence = Self.makeSilence(
                    frames: missing,
                    atSample: cursorSamples,
                    format: pcmFormat,
                    sampleRate: sampleRate,
                    channels: channels
                ) else {
                    throw fail("nie mozna utworzyc ciszy")
                }
                feed.push(silence)
                cursorSamples = targetSamples
            }
        }

        feed.finish()
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled {
                writer.cancelWriting()
                throw MediaError.cancelled
            }
        }
        if let message = errorBox.message {
            writer.cancelWriting()
            throw MediaError.invalidExport(message)
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw MediaError.invalidExport(
                writer.error?.localizedDescription ?? "zapis audio nie powiodl sie"
            )
        }
    }

    private static func makePCMFormat(sampleRate: Int, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return format
    }

    /// Bufor PCM przestemplowany na pozycje `atSample` (contiguous timeline).
    private static func retimedPCM(
        _ sample: CMSampleBuffer,
        atSample position: Int64,
        sampleRate: Int
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        )
        if let result {
            CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        }
        return result
    }

    /// Cichy bufor PCM o zadanej liczbie sampli.
    private static func makeSilence(
        frames: Int64,
        atSample position: Int64,
        format: CMAudioFormatDescription,
        sampleRate: Int,
        channels: Int
    ) -> CMSampleBuffer? {
        let bytesPerFrame = 4 * channels
        let length = Int(frames) * bytesPerFrame
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: length
        )

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &result
        )
        return result
    }

    /// Laczy gotowa sciezke video i audio w jeden plik (passthrough).
    /// Po jednym segmencie na sciezke — nic nie moze sie zdublowac.
    private func mergeTracks(videoURL: URL, audioURL: URL?, to output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw MediaError.invalidExport("brak sciezki video do zlaczenia")
        }
        try videoTrack.insertTimeRange(sourceVideo.timeRange, of: sourceVideo, at: .zero)

        if let audioURL {
            let audioAsset = AVURLAsset(url: audioURL)
            if let sourceAudio = audioAsset.tracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(
                   withMediaType: .audio,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try audioTrack.insertTimeRange(sourceAudio.timeRange, of: sourceAudio, at: .zero)
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

        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled {
                export.cancelExport()
            }
        }

        switch export.status {
        case .completed:
            return
        case .cancelled:
            throw MediaError.cancelled
        default:
            throw MediaError.invalidExport(
                export.error?.localizedDescription ?? "laczenie sciezek nie powiodlo sie"
            )
        }
    }

    /// Blokujaca kolejka probek producent -> pompa writera (backpressure).
    private final class SampleFeed {
        private let condition = NSCondition()
        private var items: [CMSampleBuffer] = []
        private var finished = false
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
        }

        func push(_ sample: CMSampleBuffer) {
            condition.lock()
            while items.count >= capacity && !finished {
                condition.wait()
            }
            if !finished {
                items.append(sample)
            }
            condition.broadcast()
            condition.unlock()
        }

        func finish() {
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }

        /// Blokuje az do probki albo konca strumienia (nil).
        func next() -> CMSampleBuffer? {
            condition.lock()
            defer { condition.unlock() }
            while items.isEmpty && !finished {
                condition.wait()
            }
            guard !items.isEmpty else {
                return nil
            }
            let sample = items.removeFirst()
            condition.broadcast()
            return sample
        }
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var message: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ message: String) {
            lock.lock()
            if stored == nil {
                stored = message
            }
            lock.unlock()
        }
    }

    /// Pompa writera: requestMediaDataWhenReady na wlasnej kolejce,
    /// karmiona z SampleFeed. Sygnalizuje `done` po markAsFinished.
    private static func pump(
        input: AVAssetWriterInput,
        feed: SampleFeed,
        label: String,
        writer: AVAssetWriter,
        errorBox: ErrorBox,
        done: DispatchSemaphore
    ) {
        let queue = DispatchQueue(label: "secondsup.writer.\(label)")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                guard let sample = feed.next() else {
                    input.markAsFinished()
                    done.signal()
                    return
                }
                if !input.append(sample) {
                    errorBox.set(
                        "zapis \(label): "
                            + (writer.error?.localizedDescription ?? "blad writera")
                    )
                    feed.finish()
                    input.markAsFinished()
                    done.signal()
                    return
                }
            }
        }
    }

    /// Kopia bufora audio z pakietami ULOZONYMI SCISLE OD `start`, pakiet po
    /// pakiecie wg ich czasow trwania — kasuje wewnetrzne przeskoki pts
    /// zrodla (writer robilby z nich edit-listy/dziury). Zwraca tez laczny
    /// czas medium bufora (do przesuwania kursora).
    private static func retimedContiguousAudio(
        _ sample: CMSampleBuffer,
        at start: CMTime
    ) -> (buffer: CMSampleBuffer, mediaDuration: CMTime)? {
        var count = 0
        let queryStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        )

        var infos: [CMSampleTimingInfo]
        if queryStatus == noErr, count > 0 {
            infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            guard CMSampleBufferGetSampleTimingInfoArray(
                sample,
                entryCount: count,
                arrayToFill: &infos,
                entriesNeededOut: nil
            ) == noErr else {
                return nil
            }
        } else {
            let sampleCount = max(1, CMSampleBufferGetNumSamples(sample))
            let total = CMSampleBufferGetDuration(sample)
            let perSample = total.isValid && total.value > 0
                ? CMTimeMultiplyByRatio(total, multiplier: 1, divisor: Int32(sampleCount))
                : CMTime(value: 1024, timescale: 48000)
            infos = [
                CMSampleTimingInfo(
                    duration: perSample,
                    presentationTimeStamp: start,
                    decodeTimeStamp: .invalid
                )
            ]
        }

        var running = start
        for index in infos.indices {
            var duration = infos[index].duration
            if !duration.isValid || duration.value <= 0 {
                duration = CMTime(value: 1024, timescale: 48000)
                infos[index].duration = duration
            }
            infos[index].presentationTimeStamp = running
            infos[index].decodeTimeStamp = .invalid
            running = CMTimeAdd(running, duration)
        }

        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: infos.count,
            sampleTimingArray: &infos,
            sampleBufferOut: &result
        )
        guard let result else {
            return nil
        }
        // Trim (priming AAC) honorowany per klip robilby dziure na granicy.
        CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        return (result, CMTimeSubtract(running, start))
    }

    /// Kopia probki z czasami przesunietymi o delte. DTS jest dodatkowo
    /// pilnowany, by byl scisle rosnacy (wymog muxera).
    private static func retimed(
        _ sample: CMSampleBuffer,
        by delta: CMTime,
        clampDTSAfter lastDTS: CMTime
    ) -> CMSampleBuffer? {
        var count = 0
        let queryStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        )

        var infos: [CMSampleTimingInfo]
        if queryStatus == noErr, count > 0 {
            infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            let fillStatus = CMSampleBufferGetSampleTimingInfoArray(
                sample,
                entryCount: count,
                arrayToFill: &infos,
                entriesNeededOut: nil
            )
            guard fillStatus == noErr else {
                return nil
            }
        } else {
            // Bufory audio (wiele pakietow AAC o rownym czasie) czesto nie
            // wystawiaja tablicy timingow — jeden wpis obowiazuje wszystkie
            // probki z sekwencyjnymi PTS co `duration`.
            let sampleCount = max(1, CMSampleBufferGetNumSamples(sample))
            let total = CMSampleBufferGetDuration(sample)
            let perSample = total.isValid && total.value > 0
                ? CMTimeMultiplyByRatio(total, multiplier: 1, divisor: Int32(sampleCount))
                : CMSampleBufferGetDuration(sample)
            infos = [
                CMSampleTimingInfo(
                    duration: perSample,
                    presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                    decodeTimeStamp: .invalid
                )
            ]
        }

        var previousDTS = lastDTS
        for index in infos.indices {
            if infos[index].presentationTimeStamp.isValid {
                infos[index].presentationTimeStamp =
                    CMTimeAdd(infos[index].presentationTimeStamp, delta)
            }
            if infos[index].decodeTimeStamp.isValid {
                var dts = CMTimeAdd(infos[index].decodeTimeStamp, delta)
                // Scisla monotonicznosc DTS; nigdy powyzej PTS.
                if previousDTS.isValid, CMTimeCompare(dts, previousDTS) <= 0 {
                    let bumped = CMTimeAdd(
                        previousDTS,
                        CMTime(value: 1, timescale: previousDTS.timescale)
                    )
                    dts = CMTimeMinimum(bumped, infos[index].presentationTimeStamp)
                }
                infos[index].decodeTimeStamp = dts
                previousDTS = dts
            }
        }

        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: infos.count,
            sampleTimingArray: &infos,
            sampleBufferOut: &result
        )
        if let result {
            // Pierwsze pakiety AAC kazdego klipu niosa trim (priming ~21 ms);
            // honorowany per klip robilby dziure na kazdej granicy.
            CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
            CMRemoveAttachment(result, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        }
        return result
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
    var safeClipDuration: Double {
        min(10.0, max(0.1, clipDuration))
    }

    var segmentExtension: String {
        renderMode == .proResHQ ? "mov" : "mp4"
    }
}
