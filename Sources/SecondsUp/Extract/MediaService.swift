import Foundation

/// Operacje na plikach wideo przez ffmpeg/ffprobe:
/// skan folderu, metadane, keyframe'y, smart-cut eksport 1 s i walidacja.
struct MediaService: Sendable {
    let tools: ToolSet

    init(tools: ToolSet = .detect()) {
        self.tools = tools
    }

    var isReady: Bool {
        tools.isReady
    }

    static let videoExtensions = Set(["mov", "mp4", "m4v"])

    // MARK: - Skan folderu

    func scanVideos(in folder: URL) -> [VideoItem] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                urls.append(url)
            }
        }

        return urls
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { VideoItem(url: $0) }
    }

    // MARK: - Metadane

    func probeMetadata(for url: URL) throws -> VideoMetadata {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "format=duration:stream=codec_name,width,height,duration,avg_frame_rate,r_frame_rate,nb_frames",
                "-of", "json",
                url.path
            ]
        )

        let probe = try JSONDecoder().decode(StreamProbe.self, from: data)
        guard let stream = probe.streams.first else {
            throw MediaError.noVideoStream
        }

        let streamDuration = stream.duration.flatMap(Double.init)
        let formatDuration = probe.format?.duration.flatMap(Double.init)
        let duration = streamDuration ?? formatDuration ?? 0
        let avgFPS = ratioToDouble(stream.avgFrameRate)
        let realFPS = ratioToDouble(stream.realFrameRate)
        let fps = avgFPS > 0 ? avgFPS : realFPS

        return VideoMetadata(
            duration: duration,
            fps: fps,
            frameCount: stream.frameCount.flatMap(Int.init),
            codec: stream.codecName ?? "",
            width: stream.width,
            height: stream.height
        )
    }

    /// Czasy keyframe'ow ze skanowania pakietow (bez dekodowania — szybkie).
    func keyframes(for url: URL) throws -> [Double] {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "packet=pts_time,dts_time,flags",
                "-of", "json",
                url.path
            ]
        )

        let probe = try JSONDecoder().decode(PacketProbe.self, from: data)
        var times: [Double] = []
        for packet in probe.packets {
            guard packet.flags?.contains("K") == true,
                  let text = packet.ptsTime ?? packet.dtsTime,
                  let time = Double(text),
                  time >= -0.01 else {
                continue
            }
            times.append(max(0, time))
        }

        var cleaned: [Double] = []
        for time in times.sorted() {
            if cleaned.last.map({ abs($0 - time) > 0.01 }) ?? true {
                cleaned.append(time)
            }
        }
        return cleaned.isEmpty ? [0] : cleaned
    }

    // MARK: - Smart cut eksport

    /// Najblizszy keyframe nadajacy sie na bezstratny start dla zadanego czasu.
    static func snapKeyframe(
        near start: Double,
        keyframes: [Double],
        frameStep: Double
    ) -> Double? {
        let tolerance = max(frameStep * 0.6, 0.02)
        return keyframes
            .filter { abs($0 - start) <= tolerance }
            .min { abs($0 - start) < abs($1 - start) }
    }

    static func plannedMethod(
        start: Double,
        keyframes: [Double],
        frameStep: Double
    ) -> ExportMethod {
        snapKeyframe(near: start, keyframes: keyframes, frameStep: frameStep) != nil
            ? .lossless
            : .precise
    }

    /// Eksport 1 s: bezstratny (`-c copy`), gdy start lezy na keyframe;
    /// w przeciwnym razie precyzyjny re-encode z dokladnoscia do klatki.
    func exportSecond(
        source: URL,
        outputFolder: URL,
        start: Double,
        metadata: VideoMetadata,
        keyframes: [Double]
    ) throws -> (url: URL, method: ExportMethod) {
        guard let ffmpegURL = tools.ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }
        let output = try nextOutputURL(for: source, in: outputFolder)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let method: ExportMethod
        let arguments: [String]

        if let keyframe = Self.snapKeyframe(
            near: start,
            keyframes: keyframes,
            frameStep: metadata.frameStep
        ) {
            // Seek wejsciowy (-ss przed -i): ffmpeg zaczyna kopiowanie dokladnie
            // od keyframe'a. Ciecie jest pakietowe, wiec klip moze byc o 1-2
            // klatki dluzszy niz 1 s — walidacja to uwzglednia.
            method = .lossless
            arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-ss", String(format: "%.3f", keyframe),
                "-i", source.path,
                "-t", "1.000",
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-sn",
                "-dn",
                "-c", "copy",
                "-map_metadata", "0",
                "-avoid_negative_ts", "make_zero",
                output.path
            ]
        } else {
            method = .precise
            arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-ss", String(format: "%.3f", start),
                "-i", source.path,
                "-t", "1.000",
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-sn",
                "-dn",
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "16",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "192k",
                "-map_metadata", "0",
                output.path
            ]
        }

        try FFmpegRunner.run(ffmpegURL, arguments)

        let expectedFrames = metadata.fps > 0 ? Int((metadata.fps * 1.0).rounded()) : nil
        let validation = try validateClip(output, expectedFrames: expectedFrames, method: method)
        guard validation.isValid else {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.invalidExport(validation.summary(expectedFrames: expectedFrames))
        }

        return (output, method)
    }

    func nextOutputURL(for source: URL, in outputFolder: URL) throws -> URL {
        guard let date = DateParser.dateString(from: source.lastPathComponent) else {
            throw MediaError.noDateInFileName
        }

        var spaces = 0
        while true {
            let fileName = "\(date)\(String(repeating: " ", count: spaces)).mov"
            let output = outputFolder.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: output.path) {
                return output
            }
            spaces += 1
        }
    }

    func validateClip(
        _ url: URL,
        expectedFrames: Int?,
        method: ExportMethod = .precise
    ) throws -> ExportValidation {
        guard let ffprobeURL = tools.ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try FFmpegRunner.run(
            ffprobeURL,
            [
                "-v", "error",
                "-count_frames",
                "-show_entries", "format=duration:stream=codec_type,duration,nb_read_frames",
                "-of", "json",
                url.path
            ]
        )

        let probe = try JSONDecoder().decode(ValidationProbe.self, from: data)
        let formatDuration = probe.format?.duration.flatMap(Double.init) ?? 0
        let video = probe.streams.first { $0.codecType == "video" }
        let videoDuration = video?.duration.flatMap(Double.init) ?? 0
        let videoFrames = video?.readFrames.flatMap(Int.init)

        // Klip bez strumienia video jest zawsze nieprawidlowy.
        guard video != nil else {
            return ExportValidation(
                formatDuration: formatDuration,
                videoDuration: 0,
                videoFrames: nil,
                isValid: false
            )
        }

        // Ciecie bezstratne jest pakietowe: dopuszczamy 1-2 klatki zapasu.
        // Ciecie precyzyjne (re-encode) musi miec dokladnie ~1.000 s.
        let durationTolerance = method == .lossless ? 0.20 : 0.05
        let extraFramesAllowed = method == .lossless ? 3 : 1

        let durationOK = formatDuration >= 0.90 && formatDuration <= 1.0 + durationTolerance
        let videoDurationOK = videoDuration == 0
            || (videoDuration >= 0.90 && videoDuration <= 1.0 + durationTolerance)
        let framesOK: Bool
        if let expectedFrames, let videoFrames {
            framesOK = videoFrames >= expectedFrames - 1
                && videoFrames <= expectedFrames + extraFramesAllowed
        } else {
            framesOK = true
        }

        return ExportValidation(
            formatDuration: formatDuration,
            videoDuration: videoDuration,
            videoFrames: videoFrames,
            isValid: durationOK && videoDurationOK && framesOK
        )
    }
}

// MARK: - Struktury ffprobe

private struct StreamProbe: Decodable {
    let streams: [VideoStream]
    let format: FormatInfo?
}

private struct VideoStream: Decodable {
    let codecName: String?
    let width: Int?
    let height: Int?
    let duration: String?
    let avgFrameRate: String?
    let realFrameRate: String?
    let frameCount: String?

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case width
        case height
        case duration
        case avgFrameRate = "avg_frame_rate"
        case realFrameRate = "r_frame_rate"
        case frameCount = "nb_frames"
    }
}

private struct FormatInfo: Decodable {
    let duration: String?
}

private struct PacketProbe: Decodable {
    let packets: [PacketInfo]
}

private struct PacketInfo: Decodable {
    let ptsTime: String?
    let dtsTime: String?
    let flags: String?

    enum CodingKeys: String, CodingKey {
        case ptsTime = "pts_time"
        case dtsTime = "dts_time"
        case flags
    }
}

private struct ValidationProbe: Decodable {
    let streams: [ValidationStream]
    let format: FormatInfo?
}

private struct ValidationStream: Decodable {
    let codecType: String?
    let duration: String?
    let readFrames: String?

    enum CodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case duration
        case readFrames = "nb_read_frames"
    }
}

func ratioToDouble(_ value: String?) -> Double {
    guard let value, value != "0/0" else {
        return 0
    }
    if !value.contains("/") {
        return Double(value) ?? 0
    }

    let parts = value.split(separator: "/", maxSplits: 1)
    guard parts.count == 2,
          let numerator = Double(parts[0]),
          let denominator = Double(parts[1]),
          denominator != 0 else {
        return 0
    }
    return numerator / denominator
}
