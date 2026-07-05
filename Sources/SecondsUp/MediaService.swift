import AppKit
import Foundation

enum MediaError: LocalizedError {
    case toolMissing(String)
    case commandFailed(String, String)
    case invalidJSON
    case noVideoStream
    case noDateInFileName
    case invalidExport(String)
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name):
            return "\(name) nie zostal znaleziony."
        case .commandFailed(let command, let stderr):
            return stderr.isEmpty ? "Polecenie nie powiodlo sie: \(command)" : stderr
        case .invalidJSON:
            return "Nie udalo sie odczytac danych ffprobe."
        case .noVideoStream:
            return "Plik nie ma strumienia video."
        case .noDateInFileName:
            return "Nazwa pliku nie zawiera daty yyyy-mm-dd."
        case .invalidExport(let details):
            return "Eksport nie przeszedl walidacji: \(details)"
        case .cannotCreateImage:
            return "Nie udalo sie odczytac klatki podgladu."
        }
    }
}

struct MediaService: Sendable {
    let ffmpegURL: URL?
    let ffprobeURL: URL?

    var isReady: Bool {
        ffmpegURL != nil && ffprobeURL != nil
    }

    static func detect() -> MediaService {
        MediaService(
            ffmpegURL: findExecutable("ffmpeg"),
            ffprobeURL: findExecutable("ffprobe")
        )
    }

    static func findExecutable(_ name: String) -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in pathValue.split(separator: ":") {
            let path = String(folder) + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    func scanVideos(in folder: URL) -> [VideoItem] {
        let extensions = Set(["mov", "mp4", "m4v"])
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else {
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

    func probeMetadata(for url: URL) throws -> VideoMetadata {
        guard let ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try run(
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

    func recommendStart(for url: URL, metadata: VideoMetadata) throws -> Recommendation {
        let candidates = limitedCandidates(
            try keyframeTimes(for: url, duration: metadata.duration),
            maxCount: 8
        )

        var quick: [(score: Double, start: Double, reason: String)] = []
        let quickTimestamps = candidates.map {
            sampleTimestamp(start: $0, offset: 0.50, duration: metadata.duration)
        }
        let quickSamples = try frameSamples(url: url, timestamps: quickTimestamps, fps: metadata.fps)

        for (index, start) in candidates.enumerated() {
            if index < quickSamples.count {
                let scored = scoreSamples([quickSamples[index]])
                quick.append((scored.score, start, scored.reason))
            } else {
                quick.append((-1, start, "missing preview frame"))
            }
        }
        quick.sort { $0.score > $1.score }

        var best = (score: -1.0, start: 0.0, reason: "fallback")
        for candidate in quick.prefix(1) {
            let timestamps = [0.20, 0.50, 0.80].map {
                sampleTimestamp(start: candidate.start, offset: $0, duration: metadata.duration)
            }
            let scored = scoreSamples(try frameSamples(url: url, timestamps: timestamps, fps: metadata.fps))
            if scored.score > best.score {
                best = (scored.score, candidate.start, scored.reason)
            }
        }

        return Recommendation(
            start: best.start,
            score: best.score,
            reason: best.reason,
            candidateCount: candidates.count
        )
    }

    func exportLosslessSecond(
        source: URL,
        outputFolder: URL,
        start: Double,
        metadata: VideoMetadata
    ) throws -> URL {
        guard let ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }
        let output = try nextOutputURL(for: source, in: outputFolder)

        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        try run(
            ffmpegURL,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-nostdin",
                "-i", source.path,
                "-ss", String(format: "%.3f", start),
                "-t", "1.000",
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-sn",
                "-dn",
                "-c",
                "copy",
                "-map_metadata",
                "0",
                "-avoid_negative_ts",
                "make_zero",
                output.path
            ]
        )

        let expectedFrames = metadata.fps > 0 ? Int((metadata.fps * 1.0).rounded()) : nil
        let validation = try validateClip(output, expectedFrames: expectedFrames)
        guard validation.isValid else {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.invalidExport(validation.summary(expectedFrames: expectedFrames))
        }

        return output
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

    func validateClip(_ url: URL, expectedFrames: Int?) throws -> ExportValidation {
        guard let ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try run(
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

        let durationOK = abs(formatDuration - 1.0) <= 0.05
        let videoDurationOK = videoDuration == 0 || abs(videoDuration - 1.0) <= 0.05
        let framesOK: Bool
        if let expectedFrames, let videoFrames {
            framesOK = abs(videoFrames - expectedFrames) <= 1
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

    private func keyframeTimes(for url: URL, duration: Double) throws -> [Double] {
        guard let ffprobeURL else {
            throw MediaError.toolMissing("ffprobe")
        }

        let data = try run(
            ffprobeURL,
            [
                "-v", "error",
                "-select_streams", "v:0",
                "-skip_frame", "nokey",
                "-show_entries", "frame=best_effort_timestamp_time,pkt_pts_time,pts_time",
                "-of", "json",
                url.path
            ]
        )

        let probe = try JSONDecoder().decode(FrameProbe.self, from: data)
        let maxStart = max(0, duration - 1.0)
        var times = [0.0]
        for frame in probe.frames {
            if let value = frame.bestEffortTimestamp ?? frame.ptsTime ?? frame.packetPtsTime,
               let time = Double(value) {
                times.append(time)
            }
        }

        var cleaned: [Double] = []
        for time in times.sorted() {
            guard time >= -0.01, time <= maxStart + 0.05 else {
                continue
            }
            let clamped = min(maxStart, max(0, time))
            if cleaned.last.map({ abs($0 - clamped) > 0.05 }) ?? true {
                cleaned.append(clamped)
            }
        }

        return cleaned.isEmpty ? [0] : cleaned
    }

    private func limitedCandidates(_ candidates: [Double], maxCount: Int) -> [Double] {
        guard candidates.count > maxCount else {
            return candidates
        }
        guard maxCount > 1 else {
            return [candidates[0]]
        }

        let indexes = Set((0..<maxCount).map {
            Int((Double($0) * Double(candidates.count - 1) / Double(maxCount - 1)).rounded())
        })

        return indexes.sorted().map { candidates[$0] }
    }

    private func scoreCandidate(url: URL, start: Double, duration: Double, full: Bool) throws -> RecommendationScore {
        let offsets = full ? [0.20, 0.50, 0.80] : [0.50]
        var samples: [FrameSample] = []

        for offset in offsets {
            let timestamp = sampleTimestamp(start: start, offset: offset, duration: duration)
            if let sample = try? frameSample(url: url, timestamp: timestamp) {
                samples.append(sample)
            }
        }

        guard !samples.isEmpty else {
            return RecommendationScore(score: -1, reason: "no readable preview frames")
        }

        return scoreSamples(samples)
    }

    private func scoreSamples(_ samples: [FrameSample]) -> RecommendationScore {
        guard !samples.isEmpty else {
            return RecommendationScore(score: -1, reason: "no readable preview frames")
        }

        let imageScore = samples.map(\.metrics.score).reduce(0, +) / Double(samples.count)
        var motionScore = 0.75
        if samples.count >= 2 {
            var diffs: [Double] = []
            for index in 1..<samples.count {
                diffs.append(lumaDifference(samples[index - 1], samples[index]))
            }
            let motion = diffs.reduce(0, +) / Double(diffs.count)
            motionScore = max(0, 1.0 - abs(motion - 0.08) / 0.18)
        }

        let finalScore = 0.88 * imageScore + 0.12 * motionScore
        let avgSharp = average(samples.map(\.metrics.sharpness))
        let avgExposure = average(samples.map(\.metrics.exposure))
        let avgContrast = average(samples.map(\.metrics.contrast))
        let reason = String(
            format: "sharp=%.2f; exposure=%.2f; contrast=%.2f; stable_motion=%.2f",
            avgSharp,
            avgExposure,
            avgContrast,
            motionScore
        )
        return RecommendationScore(score: finalScore, reason: reason)
    }

    private func sampleTimestamp(start: Double, offset: Double, duration: Double) -> Double {
        min(max(0, duration - 0.05), start + min(offset, max(0, duration / 2)))
    }

    private func frameSamples(url: URL, timestamps: [Double], fps: Double) throws -> [FrameSample] {
        guard !timestamps.isEmpty else {
            return []
        }
        guard fps > 0 else {
            var samples: [FrameSample] = []
            for timestamp in timestamps {
                samples.append(try frameSample(url: url, timestamp: timestamp))
            }
            return samples
        }
        guard let ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }

        let frameNumbers = timestamps.map { max(0, Int(($0 * fps).rounded())) }
        let selector = frameNumbers
            .map { "eq(n\\,\($0))" }
            .joined(separator: "+")
        let filter = "select='\(selector)',scale=426:-1"
        let data = try run(
            ffmpegURL,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-i", url.path,
                "-vf", filter,
                "-vsync", "0",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-"
            ]
        )

        let images = splitPNGStream(data)
        var samples: [FrameSample] = []
        for imageData in images {
            guard let image = NSImage(data: imageData) else {
                continue
            }
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                continue
            }
            if let sample = try? FrameAnalyzer.sample(from: cgImage) {
                samples.append(sample)
            }
        }

        if samples.isEmpty {
            throw MediaError.cannotCreateImage
        }
        return samples
    }

    private func frameSample(url: URL, timestamp: Double) throws -> FrameSample {
        guard let ffmpegURL else {
            throw MediaError.toolMissing("ffmpeg")
        }

        let data = try run(
            ffmpegURL,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-ss", String(format: "%.3f", max(0, timestamp)),
                "-i", url.path,
                "-frames:v", "1",
                "-vf", "scale=426:-1",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-"
            ]
        )

        guard let image = NSImage(data: data) else {
            throw MediaError.cannotCreateImage
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw MediaError.cannotCreateImage
        }

        return try FrameAnalyzer.sample(from: cgImage)
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let command = ([executable.path] + arguments).joined(separator: " ")
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            throw MediaError.commandFailed(command, stderr)
        }

        return outputData
    }
}

private struct RecommendationScore {
    let score: Double
    let reason: String
}

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

private struct FrameProbe: Decodable {
    let frames: [FrameInfo]
}

private struct FrameInfo: Decodable {
    let bestEffortTimestamp: String?
    let packetPtsTime: String?
    let ptsTime: String?

    enum CodingKeys: String, CodingKey {
        case bestEffortTimestamp = "best_effort_timestamp_time"
        case packetPtsTime = "pkt_pts_time"
        case ptsTime = "pts_time"
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

private func ratioToDouble(_ value: String?) -> Double {
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

private func average(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private func splitPNGStream(_ data: Data) -> [Data] {
    let bytes = [UInt8](data)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var images: [Data] = []
    var index = 0

    while index + signature.count <= bytes.count {
        guard bytes[index..<(index + signature.count)].elementsEqual(signature) else {
            index += 1
            continue
        }

        let start = index
        index += signature.count
        var end: Int?

        while index + 12 <= bytes.count {
            let length = Int(bytes[index]) << 24
                | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8
                | Int(bytes[index + 3])
            let typeStart = index + 4
            let dataEnd = typeStart + 4 + length
            let chunkEnd = dataEnd + 4

            guard chunkEnd <= bytes.count else {
                index = bytes.count
                break
            }

            let chunkType = String(bytes: bytes[typeStart..<(typeStart + 4)], encoding: .ascii)
            index = chunkEnd

            if chunkType == "IEND" {
                end = chunkEnd
                break
            }
        }

        if let end {
            images.append(data.subdata(in: start..<end))
            index = end
        } else {
            break
        }
    }

    return images
}

private func lumaDifference(_ left: FrameSample, _ right: FrameSample) -> Double {
    guard left.width == right.width, left.height == right.height else {
        return 0.75
    }
    let count = min(left.luma.count, right.luma.count)
    guard count > 0 else {
        return 0
    }

    var total = 0.0
    for index in 0..<count {
        total += abs(left.luma[index] - right.luma[index])
    }
    return total / Double(count) / 255.0
}

private struct FrameSample {
    let width: Int
    let height: Int
    let luma: [Double]
    let metrics: ImageMetrics
}

private struct ImageMetrics {
    let score: Double
    let sharpness: Double
    let exposure: Double
    let contrast: Double
}

private enum FrameAnalyzer {
    static func sample(from image: CGImage) throws -> FrameSample {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else {
            throw MediaError.cannotCreateImage
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw MediaError.cannotCreateImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var lumaSum = 0.0
        var lumaSqSum = 0.0
        var saturationSum = 0.0
        var clipped = 0

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let r = Double(pixels[pixelIndex])
                let g = Double(pixels[pixelIndex + 1])
                let b = Double(pixels[pixelIndex + 2])
                let yValue = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let lumaIndex = y * width + x
                luma[lumaIndex] = yValue
                lumaSum += yValue
                lumaSqSum += yValue * yValue

                let rgbMean = (r + g + b) / 3.0
                let rgbVariance = ((r - rgbMean) * (r - rgbMean)
                    + (g - rgbMean) * (g - rgbMean)
                    + (b - rgbMean) * (b - rgbMean)) / 3.0
                saturationSum += sqrt(rgbVariance)

                if yValue < 8 || yValue > 247 {
                    clipped += 1
                }
            }
        }

        let pixelCount = Double(width * height)
        let mean = lumaSum / pixelCount
        let variance = max(0, lumaSqSum / pixelCount - mean * mean)
        let contrast = sqrt(variance)
        let saturation = saturationSum / pixelCount
        let clippedFraction = Double(clipped) / pixelCount

        var laplacianEnergy = 0.0
        var laplacianCount = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let laplacian = luma[index - 1]
                    + luma[index + 1]
                    + luma[index - width]
                    + luma[index + width]
                    - 4.0 * luma[index]
                laplacianEnergy += laplacian * laplacian
                laplacianCount += 1
            }
        }

        let sharpnessVariance = laplacianCount > 0 ? laplacianEnergy / laplacianCount : 0
        let exposureScore = max(0, 1.0 - abs(mean - 118.0) / 118.0)
        let contrastScore = min(1, contrast / 64.0)
        let saturationScore = min(1, saturation / 42.0)
        let sharpnessScore = min(1, log1p(sharpnessVariance) / 8.0)
        let clippingPenalty = min(0.35, clippedFraction * 1.8)
        let score = max(
            0,
            0.46 * sharpnessScore
                + 0.24 * exposureScore
                + 0.20 * contrastScore
                + 0.10 * saturationScore
                - clippingPenalty
        )

        return FrameSample(
            width: width,
            height: height,
            luma: luma,
            metrics: ImageMetrics(
                score: score,
                sharpness: sharpnessScore,
                exposure: exposureScore,
                contrast: contrastScore
            )
        )
    }
}
