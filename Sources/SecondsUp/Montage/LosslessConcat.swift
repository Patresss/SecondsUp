import AVFoundation
import Foundation

/// Maszyneria bezstratnego sklejania na poziomie probek.
/// Wydzielona z MontageService — patrz koncatenatePassthrough
/// dla pelnego opisu architektury trzech przebiegow.
extension MontageRenderer {
    /// Bezstratne sklejanie na poziomie PROBEK, w trzech przebiegach:
    ///
    /// 1. Writer #1: sama sciezka VIDEO (jeden input -> zero problemow
    ///    z przeplotem A/V, ktore zakleszczaly writer dwuwejsciowy).
    /// 2. Writer #2: sama sciezka AUDIO — dekodowana do PCM i kodowana RAZ
    ///    jako jednolity strumien AAC (kopiowanie pakietow AAC jest zawodne:
    ///    zepsute duration buforow, przeskoki pts, rozne opisy formatu
    ///    miedzy klipami -> writer wstawia edit-listy z dziurami, o ktore
    ///    wywracaja sie playery). Budzet per klip z przebiegu 1 + docinanie
    ///    i cisza daja synchronizacje A/V co do sampla.
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
    func concatenatePassthrough(
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
}
