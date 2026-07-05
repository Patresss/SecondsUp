import Foundation

/// Renderer montazu: normalizacja klipow + napis daty -> plansza tytulowa ->
/// concat -> muzyka -> walidacja. Kazdy etap raportuje postep; render mozna przerwac.
final class MontageRenderer: @unchecked Sendable {
    private let tools: ToolSet
    private let lock = NSLock()
    private var cancelled = false
    private var currentProcess: Process?

    private static let fontPath = "/System/Library/Fonts/Helvetica.ttc"

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
            let titleURL = workDir.appendingPathComponent("title.mp4")
            try renderTitleCard(
                ffmpegURL: ffmpegURL,
                to: titleURL,
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
            let segmentURL = workDir.appendingPathComponent(String(format: "seg_%04d.mp4", index))
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

        // Concat.
        try checkCancelled()
        onProgress(RenderProgress(stage: "Sklejanie klipow", fraction: 0.75))
        let concatURL = workDir.appendingPathComponent("concat.mp4")
        try concatenate(ffmpegURL: ffmpegURL, segments: segments, to: concatURL, workDir: workDir)

        // Muzyka.
        try checkCancelled()
        let renderedURL: URL
        if let musicPath = settings.musicPath,
           FileManager.default.fileExists(atPath: musicPath) {
            onProgress(RenderProgress(stage: "Dodaje muzyke", fraction: 0.88))
            let musicURL = workDir.appendingPathComponent("final.mp4")
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
            } else {
                arguments += ["-map", "1:a:0", "-shortest"]
            }
            arguments += ["-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k"]
        } else {
            arguments += ["-an"]
        }

        arguments += [
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            output.path
        ]

        try run(ffmpegURL, arguments)
    }

    private func renderTitleCard(
        ffmpegURL: URL,
        to output: URL,
        settings: MontageSettings,
        width: Int,
        height: Int
    ) throws {
        let fontSize = min(width, height) / 12
        let title = Self.escapeDrawtext(settings.titleText)
        let drawtext = "drawtext=fontfile=\(Self.fontPath):text='\(title)'"
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
            "-t", String(format: "%.2f", settings.titleDuration),
            "-vf", drawtext,
            "-map", "0:v"
        ]
        if settings.keepClipAudio {
            arguments += ["-map", "1:a", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "192k"]
        }
        arguments += [
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "18",
            "-pix_fmt", "yuv420p",
            output.path
        ]

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
        return "drawtext=fontfile=\(Self.fontPath):text='\(escaped)'"
            + String(format: ":fontsize=%.0f", settings.captionFontSize)
            + String(format: ":fontcolor=white@%.2f", settings.captionOpacity)
            + ":borderw=2:bordercolor=black@0.6"
            + ":x=\(position.x):y=\(position.y)"
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
