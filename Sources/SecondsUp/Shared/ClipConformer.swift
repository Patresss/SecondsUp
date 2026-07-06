import Foundation

/// Analiza parametrow klipow i dopasowywanie (conform) odstajacych do wzorca.
/// Uzywane przez zakladke Naprawa i tryb "Bezstratnie smart" w Montazu.
///
/// Kluczowe: sygnatura obejmuje TAKZE fps. Mieszanie kadencji klatek w jednej
/// sciezce (np. 30 fps wsrod 120 fps) psuje odtwarzanie w QuickTime — player
/// po przelaczeniu opisu probek potrafi zostac w zlym tempie.
final class ClipConformer: @unchecked Sendable {
    struct VideoSignature: Equatable {
        let codec: String
        let width: Int
        let height: Int
        let pixelFormat: String
        let colorTransfer: String
        let colorPrimaries: String
        let colorSpace: String
        let fps: Double
        /// Timescale sciezki w kontenerze (mianownik time_base), np. 19200.
        /// Konformowane klipy dostaja timescale wzorca — rozne timescale
        /// powoduja artefakty zaokraglen edit-list przy sklejaniu passthrough.
        let trackTimescale: Int
        /// start_time strumienia. Niezerowy (przesuniecie CTS od B-klatek)
        /// zostawia pusty edit (zamrozona klatke) przy sklejaniu passthrough.
        let startTime: Double

        var startsCleanly: Bool {
            abs(startTime) < 0.001
        }

        var fpsBucket: Int {
            ClipConformer.fpsBucket(fps)
        }

        var summary: String {
            var text = "\(codec) \(width)x\(height)"
            if fpsBucket > 0 {
                text += " \(fpsBucket)fps"
            }
            if !pixelFormat.isEmpty {
                text += " \(pixelFormat)"
            }
            if !colorTransfer.isEmpty {
                text += " \(colorTransfer)"
            }
            if !startsCleanly {
                text += " · przesuniety start"
            }
            return text
        }
    }

    struct AudioSignature: Equatable {
        let codec: String
        let sampleRate: Int
        let channels: Int

        static let none = AudioSignature(codec: "brak", sampleRate: 0, channels: 0)

        var hasAudio: Bool {
            self != .none
        }

        var summary: String {
            hasAudio ? "\(codec) \(sampleRate)Hz \(channels)ch" : "brak audio"
        }
    }

    struct ClipInfo {
        let url: URL
        let video: VideoSignature
        let audio: AudioSignature

        var matchKey: String {
            "\(video.summary)|\(audio.summary)"
        }

        var summary: String {
            "\(video.summary) · \(audio.summary)"
        }
    }

    private let tools: ToolSet
    private let lock = NSLock()
    private var cancelled = false
    private var currentProcess: Process?

    init(tools: ToolSet) {
        self.tools = tools
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = currentProcess
        lock.unlock()
        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancelled() throws {
        if isCancelled {
            throw MediaError.cancelled
        }
    }

    // MARK: - Analiza

    /// Zaokragla fps do najblizszej typowej wartosci (119.95 -> 120).
    static func fpsBucket(_ fps: Double) -> Int {
        guard fps > 0 else {
            return 0
        }
        let common: [Int] = [24, 25, 30, 50, 60, 100, 120, 240]
        return common.min { abs(Double($0) - fps) < abs(Double($1) - fps) } ?? Int(fps.rounded())
    }

    func inspect(_ url: URL) throws -> ClipInfo {
        try checkCancelled()
        return ClipInfo(
            url: url,
            video: try probeVideoSignature(of: url),
            audio: (try? probeAudioSignature(of: url)) ?? .none
        )
    }

    /// Najczestsza kombinacja parametrow jako wzorzec dla folderu.
    /// Wzorzec wybieramy sposrod klipow z czystym startem (start_time 0) —
    /// konformacja zawsze daje czysty start, wiec wzorzec z przesunieciem
    /// prowadzilby do wiecznego "do naprawy".
    static func majorityTarget(of infos: [ClipInfo]) -> ClipInfo? {
        let clean = infos.filter { $0.video.startsCleanly }
        let candidates = clean.isEmpty ? infos : clean
        guard !candidates.isEmpty else {
            return nil
        }
        var counts: [String: Int] = [:]
        for info in candidates {
            counts[info.matchKey, default: 0] += 1
        }
        guard let majorityKey = counts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        return candidates.first { $0.matchKey == majorityKey }
    }

    func probeVideoSignature(of url: URL) throws -> VideoSignature {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }
        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries",
                "stream=codec_name,width,height,pix_fmt,color_transfer,color_primaries,color_space,avg_frame_rate,r_frame_rate,time_base,start_time",
                "-of", "json",
                url.path
            ]
        )
        struct Probe: Decodable {
            struct Stream: Decodable {
                let codecName: String?
                let width: Int?
                let height: Int?
                let pixFmt: String?
                let colorTransfer: String?
                let colorPrimaries: String?
                let colorSpace: String?
                let avgFrameRate: String?
                let realFrameRate: String?
                let timeBase: String?
                let startTime: String?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case width
                    case height
                    case pixFmt = "pix_fmt"
                    case colorTransfer = "color_transfer"
                    case colorPrimaries = "color_primaries"
                    case colorSpace = "color_space"
                    case avgFrameRate = "avg_frame_rate"
                    case realFrameRate = "r_frame_rate"
                    case timeBase = "time_base"
                    case startTime = "start_time"
                }
            }
            let streams: [Stream]
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let stream = probe.streams.first else {
            throw MediaError.noVideoStream
        }
        let avgFPS = ratioToDouble(stream.avgFrameRate)
        let realFPS = ratioToDouble(stream.realFrameRate)
        let timescale = stream.timeBase
            .flatMap { $0.split(separator: "/").last }
            .flatMap { Int($0) } ?? 0
        return VideoSignature(
            codec: stream.codecName ?? "?",
            width: stream.width ?? 0,
            height: stream.height ?? 0,
            pixelFormat: stream.pixFmt ?? "",
            colorTransfer: stream.colorTransfer ?? "",
            colorPrimaries: stream.colorPrimaries ?? "",
            colorSpace: stream.colorSpace ?? "",
            fps: avgFPS > 0 ? avgFPS : realFPS,
            trackTimescale: timescale,
            startTime: stream.startTime.flatMap(Double.init) ?? 0
        )
    }

    func probeAudioSignature(of url: URL) throws -> AudioSignature {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }
        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "a:0",
                "-show_entries", "stream=codec_name,sample_rate,channels",
                "-of", "json",
                url.path
            ]
        )
        struct Probe: Decodable {
            struct Stream: Decodable {
                let codecName: String?
                let sampleRate: String?
                let channels: Int?

                enum CodingKeys: String, CodingKey {
                    case codecName = "codec_name"
                    case sampleRate = "sample_rate"
                    case channels
                }
            }
            let streams: [Stream]
        }
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        guard let stream = probe.streams.first else {
            return .none
        }
        return AudioSignature(
            codec: stream.codecName ?? "?",
            sampleRate: stream.sampleRate.flatMap(Int.init) ?? 0,
            channels: stream.channels ?? 0
        )
    }

    // MARK: - Conform

    /// Re-encode klipu do parametrow wzorca: kodek, rozdzielczosc, fps,
    /// pix_fmt, kolor i audio — tak, zeby dal sie czysto skleic z reszta.
    func conform(
        source: ClipInfo,
        target: ClipInfo,
        to output: URL,
        duration: Double? = nil
    ) throws {
        guard let ffmpegURL = tools.ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }

        var filters = [
            "scale=\(target.video.width):\(target.video.height):force_original_aspect_ratio=decrease",
            "pad=\(target.video.width):\(target.video.height):(ow-iw)/2:(oh-ih)/2",
            "setsar=1"
        ]

        // Ujednolicenie kadencji klatek (np. 30 -> 120 przez duplikacje).
        if target.video.fpsBucket > 0, source.video.fpsBucket != target.video.fpsBucket {
            filters.append("fps=\(target.video.fpsBucket)")
        }

        // Konwersja przestrzeni barw (np. SDR bt709 -> HDR HLG bt2020).
        if !target.video.colorTransfer.isEmpty,
           source.video.colorTransfer != target.video.colorTransfer,
           let zscale = Self.zscaleFilter(from: source.video, to: target.video) {
            filters.append(zscale)
        }
        if !target.video.pixelFormat.isEmpty {
            filters.append("format=\(target.video.pixelFormat)")
        }
        // Start dokladnie od zera — ffmpeg inaczej przenosi wejsciowe
        // przesuniecie timestampow do wyniku (przesuniety start psuje
        // sklejanie passthrough pusta klatka na granicy).
        filters.append("setpts=PTS-STARTPTS")

        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-i", source.url.path
        ]

        let needsSilence = target.audio.hasAudio && !source.audio.hasAudio
        if needsSilence {
            let layout = target.audio.channels >= 2 ? "stereo" : "mono"
            arguments += [
                "-f", "lavfi",
                "-i", "anullsrc=r=\(target.audio.sampleRate):cl=\(layout)"
            ]
        }

        arguments += [
            "-vf", filters.joined(separator: ","),
            "-map", "0:v:0"
        ]

        if target.audio.hasAudio {
            if source.audio.hasAudio {
                arguments += ["-map", "0:a:0"]
            } else {
                arguments += ["-map", "1:a:0", "-shortest"]
            }
            arguments += [
                "-af", "asetpts=PTS-STARTPTS",
                "-c:a", "aac",
                "-ar", "\(target.audio.sampleRate)",
                "-ac", "\(target.audio.channels)",
                "-b:a", "256k"
            ]
        } else {
            arguments += ["-an"]
        }

        if let duration {
            arguments += ["-t", String(format: "%.3f", min(10.0, max(0.1, duration)))]
        }

        // bframes=0: bez reorderingu klatek pierwsze pts = 0 i klip nie ma
        // edit-listy — wstawia sie do kompozycji bez pustych editow
        // (zamrozonych klatek na granicach).
        if target.video.codec == "hevc" {
            arguments += [
                "-c:v", "libx265",
                "-preset", "medium",
                "-crf", "14",
                "-x265-params", "bframes=0",
                "-tag:v", "hvc1"
            ]
        } else {
            arguments += [
                "-c:v", "libx264",
                "-preset", "medium",
                "-crf", "14",
                "-bf", "0"
            ]
        }

        if !target.video.colorPrimaries.isEmpty {
            arguments += ["-color_primaries", target.video.colorPrimaries]
        }
        if !target.video.colorTransfer.isEmpty {
            arguments += ["-color_trc", target.video.colorTransfer]
        }
        if !target.video.colorSpace.isEmpty {
            arguments += ["-colorspace", target.video.colorSpace]
        }
        if target.video.trackTimescale > 0 {
            arguments += ["-video_track_timescale", "\(target.video.trackTimescale)"]
        }

        arguments.append(output.path)
        try run(ffmpegURL, arguments)
    }

    /// Filtr zscale konwertujacy kolory zrodla do wzorca. Zwraca nil,
    /// gdy nie umiemy zmapowac nazw — wtedy zostaje samo przetagowanie.
    static func zscaleFilter(from source: VideoSignature, to target: VideoSignature) -> String? {
        func transferName(_ value: String) -> String? {
            switch value {
            case "bt709": return "709"
            case "arib-std-b67": return "arib-std-b67"
            case "smpte2084": return "smpte2084"
            case "smpte170m", "bt601": return "601"
            default: return nil
            }
        }
        func primariesName(_ value: String) -> String? {
            switch value {
            case "bt709": return "709"
            case "bt2020": return "2020"
            case "smpte170m": return "170m"
            default: return nil
            }
        }
        func matrixName(_ value: String) -> String? {
            switch value {
            case "bt709": return "709"
            case "bt2020nc": return "2020_ncl"
            case "smpte170m": return "170m"
            case "bt470bg": return "470bg"
            default: return nil
            }
        }

        guard let targetTransfer = transferName(target.colorTransfer),
              let targetPrimaries = primariesName(target.colorPrimaries),
              let targetMatrix = matrixName(target.colorSpace) else {
            return nil
        }

        var filter = "zscale=t=\(targetTransfer):p=\(targetPrimaries):m=\(targetMatrix)"
        if let sourceTransfer = transferName(source.colorTransfer),
           let sourcePrimaries = primariesName(source.colorPrimaries),
           let sourceMatrix = matrixName(source.colorSpace) {
            filter += ":tin=\(sourceTransfer):pin=\(sourcePrimaries):min=\(sourceMatrix)"
        }
        return filter
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
