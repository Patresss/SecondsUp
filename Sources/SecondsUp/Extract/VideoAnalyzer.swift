import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Algorytm v2 rekomendacji najlepszej sekundy.
///
/// Fazy:
/// 1. Gesty skan calego filmu (AVAssetImageGenerator, ~320 px):
///    metryki techniczne + detekcja twarzy (Vision).
/// 2. Scoring okien 1 s na siatce co 0.2 s oraz osobno scoring okien
///    startujacych na keyframe'ach dla trybu bezstratnego.
/// 3. Doprecyzowanie top-N (NMS) na gestszych probkach + saliency (Vision).
enum VideoAnalyzer {
    struct Weights {
        var image = 0.32
        var faces = 0.20
        var saliency = 0.12
        var motion = 0.20
        var audio = 0.16
    }

    static let maxCandidates = 5
    private static let coarseStep = 0.4
    private static let windowStep = 0.2
    private static let sceneCutThreshold = 0.30

    // MARK: - Publiczne API

    static func analyze(
        url: URL,
        metadata: VideoMetadata,
        keyframes: [Double]
    ) throws -> AnalysisResult {
        let duration = metadata.duration
        let waveform = AudioWaveform.compute(url: url)

        guard duration > 0 else {
            throw MediaError.noVideoStream
        }

        // Filmy krotsze niz ~1 s: jedyny kandydat to start 0.
        guard duration > 1.05 else {
            let candidate = Candidate(start: 0, score: 1, reason: "film ma okolo 1 s")
            return AnalysisResult(
                candidates: [candidate],
                losslessCandidates: [candidate],
                keyframes: keyframes,
                waveform: waveform,
                sampleCount: 1
            )
        }

        // Faza 1: gesty skan.
        let samples = coarseSamples(url: url, duration: duration)
        guard !samples.isEmpty else {
            throw MediaError.cannotCreateImage
        }

        let stats = VideoStats(samples: samples)
        let maxStart = max(0, duration - 1.0)

        // Faza 2a: scoring okien precyzyjnych.
        var starts: [Double] = Array(stride(from: 0.0, through: maxStart, by: windowStep))
        if let last = starts.last, maxStart - last > 0.01 {
            starts.append(maxStart)
        }

        let windows = scoreWindows(
            starts: starts,
            samples: samples,
            stats: stats,
            waveform: waveform,
            duration: duration
        )

        // NMS: top-N okien precyzyjnych z minimalnym odstepem.
        let separation = duration < 4 ? 0.6 : 1.5
        let selected = nonMaxSuppression(windows: windows, separation: separation, limit: maxCandidates)

        let weights = Weights()
        var candidates = refineCandidates(
            starts: selected,
            url: url,
            duration: duration,
            stats: stats,
            waveform: waveform,
            weights: weights
        )

        if candidates.isEmpty {
            candidates = [Candidate(start: 0, score: 0, reason: "analiza nie znalazla kandydatow")]
        }

        // Faza 2b/3b: osobna lista kandydatow bezstratnych. Te starty sa
        // ograniczone do keyframe'ow, wiec podglad i eksport pokazuja to samo.
        let losslessStarts = exportableKeyframes(
            keyframes,
            maxStart: maxStart,
            frameStep: metadata.frameStep
        )
        let losslessWindows = scoreWindows(
            starts: losslessStarts,
            samples: samples,
            stats: stats,
            waveform: waveform,
            duration: duration
        )
        let selectedLossless = nonMaxSuppression(
            windows: losslessWindows,
            separation: separation,
            limit: maxCandidates
        )
        var losslessCandidates = refineCandidates(
            starts: selectedLossless,
            url: url,
            duration: duration,
            stats: stats,
            waveform: waveform,
            weights: weights
        )
        losslessCandidates = losslessCandidates.map { candidate in
            Candidate(
                start: candidate.start,
                score: candidate.score,
                reason: "keyframe · \(candidate.reason)"
            )
        }

        if losslessCandidates.isEmpty, let first = losslessStarts.first {
            losslessCandidates = [
                Candidate(
                    start: first,
                    score: 0,
                    reason: "keyframe · analiza nie znalazla kandydatow"
                )
            ]
        }

        return AnalysisResult(
            candidates: candidates,
            losslessCandidates: losslessCandidates,
            keyframes: keyframes,
            waveform: waveform,
            sampleCount: samples.count
        )
    }

    /// Miniaturki dla podanych czasow (do paska kandydatow w UI).
    static func thumbnails(url: URL, times: [Double]) -> [Double: CGImage] {
        let generator = makeGenerator(url: url, maxSize: 240, tolerance: 0.05)
        var result: [Double: CGImage] = [:]
        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                result[time] = image
            }
        }
        return result
    }

    // MARK: - Faza 1: skan

    private struct CoarseSample {
        let time: Double
        let metrics: FrameMetrics
        let faceCount: Int
        let faceArea: Double
    }

    private static func coarseSamples(url: URL, duration: Double) -> [CoarseSample] {
        // Cap liczby probek dla bardzo dlugich nagran.
        let step = max(coarseStep, duration / 600.0)
        let generator = makeGenerator(url: url, maxSize: 320, tolerance: 0.15)

        var samples: [CoarseSample] = []
        var time = min(0.1, duration / 2)
        while time < duration - 0.04 {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: cmTime, actualTime: nil),
               let metrics = FrameMetrics.compute(from: image) {
                let faces = detectFaces(in: image)
                samples.append(
                    CoarseSample(
                        time: time,
                        metrics: metrics,
                        faceCount: faces.count,
                        faceArea: faces.area
                    )
                )
            }
            time += step
        }
        return samples
    }

    private static func makeGenerator(url: URL, maxSize: CGFloat, tolerance: Double) -> AVAssetImageGenerator {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let cmTolerance = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = cmTolerance
        generator.requestedTimeToleranceAfter = cmTolerance
        return generator
    }

    // MARK: - Vision

    private static func detectFaces(in image: CGImage) -> (count: Int, area: Double) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let faces = request.results ?? []
        let area = faces.reduce(0.0) {
            $0 + Double($1.boundingBox.width * $1.boundingBox.height)
        }
        return (faces.count, area)
    }

    private static func saliencyQuality(of image: CGImage) -> Double {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNSaliencyImageObservation else {
            return 0.4
        }
        let objects = observation.salientObjects ?? []
        guard !objects.isEmpty else {
            return 0.3
        }
        let area = objects.reduce(0.0) {
            $0 + Double($1.boundingBox.width * $1.boundingBox.height)
        }
        return min(1.0, 0.45 + area * 2.2)
    }

    // MARK: - Faza 2: scoring okien

    private struct VideoStats {
        let sharpness: Percentiler
        let contrast: Percentiler
        let saturation: Percentiler
        let medianLuma: Double

        init(samples: [CoarseSample]) {
            sharpness = Percentiler(values: samples.map(\.metrics.sharpness))
            contrast = Percentiler(values: samples.map(\.metrics.contrast))
            saturation = Percentiler(values: samples.map(\.metrics.saturation))
            let lumas = samples.map(\.metrics.meanLuma).sorted()
            medianLuma = lumas.isEmpty ? 118 : lumas[lumas.count / 2]
        }
    }

    private static func imageQuality(of metrics: FrameMetrics, stats: VideoStats) -> Double {
        let sharpP = stats.sharpness.rank(metrics.sharpness)
        let contrastP = stats.contrast.rank(metrics.contrast)
        let satP = stats.saturation.rank(metrics.saturation)
        // Ekspozycja: glownie wzgledem mediany tego filmu (film nocny tez ma
        // swoja najlepsza sekunde), z lekka preferencja srodka skali.
        let relative = max(0, 1.0 - abs(metrics.meanLuma - stats.medianLuma) / 96.0)
        let absolute = max(0, 1.0 - abs(metrics.meanLuma - 118.0) / 118.0)
        let exposure = 0.7 * relative + 0.3 * absolute
        let clipPenalty = min(0.35, metrics.clippedFraction * 1.8)
        let quality = 0.45 * sharpP + 0.20 * exposure + 0.20 * contrastP + 0.15 * satP - clipPenalty
        return min(1, max(0, quality))
    }

    private static func averageImageQuality(of samples: [CoarseSample], stats: VideoStats) -> Double {
        let values = samples.map { imageQuality(of: $0.metrics, stats: stats) }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func faceQuality(of samples: [CoarseSample]) -> Double {
        let bestArea = samples.map(\.faceArea).max() ?? 0
        let bestCount = samples.map(\.faceCount).max() ?? 0
        guard bestCount > 0 else {
            return 0
        }
        return min(1.0, bestArea * 5.0 + 0.15 * Double(min(bestCount, 3)))
    }

    private static func motionQuality(
        of samples: [CoarseSample]
    ) -> (quality: Double, sceneCut: Bool) {
        guard samples.count >= 2 else {
            return (0.6, false)
        }
        var diffs: [Double] = []
        for index in 1..<samples.count {
            diffs.append(FrameMetrics.gridDifference(samples[index - 1].metrics, samples[index].metrics))
        }
        let sceneCut = diffs.contains { $0 > sceneCutThreshold }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        // Preferuj lekki, plynny ruch; karz stopklatke i szarpanie.
        let quality = max(0, 1.0 - abs(mean - 0.055) / 0.16)
        return (quality, sceneCut)
    }

    private static func scoreWindows(
        starts: [Double],
        samples: [CoarseSample],
        stats: VideoStats,
        waveform: [Float],
        duration: Double
    ) -> [(start: Double, score: Double)] {
        let audioEnergies = starts.map {
            AudioWaveform.windowEnergy(waveform: waveform, duration: duration, start: $0, length: 1.0)
        }
        let audioRank = Percentiler(values: audioEnergies)

        var windows: [(start: Double, score: Double)] = []
        for (index, start) in starts.enumerated() {
            let inWindow = samples.filter { $0.time >= start - 0.02 && $0.time <= start + 1.02 }
            guard !inWindow.isEmpty else {
                continue
            }
            let imageQ = averageImageQuality(of: inWindow, stats: stats)
            let faceQ = faceQuality(of: inWindow)
            let motion = motionQuality(of: inWindow)
            let audioQ = waveform.isEmpty ? 0.5 : audioRank.rank(audioEnergies[index])
            var score = 0.38 * imageQ + 0.20 * faceQ + 0.22 * motion.quality + 0.20 * audioQ
            if motion.sceneCut {
                score *= 0.25
            }
            windows.append((start, score))
        }
        return windows
    }

    private static func exportableKeyframes(
        _ keyframes: [Double],
        maxStart: Double,
        frameStep: Double
    ) -> [Double] {
        let tolerance = max(frameStep * 0.5, 0.005)
        var starts = keyframes
            .map { max(0, ($0 * 1000).rounded() / 1000) }
            .filter { $0 <= maxStart + tolerance }
            .sorted()

        if starts.first.map({ $0 > tolerance }) ?? true {
            starts.insert(0, at: 0)
        }

        var cleaned: [Double] = []
        for start in starts {
            if cleaned.last.map({ abs($0 - start) > 0.01 }) ?? true {
                cleaned.append(start)
            }
        }
        return cleaned
    }

    private static func nonMaxSuppression(
        windows: [(start: Double, score: Double)],
        separation: Double,
        limit: Int
    ) -> [Double] {
        let sorted = windows.sorted { $0.score > $1.score }
        var picked: [Double] = []
        for window in sorted {
            guard picked.count < limit else {
                break
            }
            if picked.allSatisfy({ abs($0 - window.start) >= separation }) {
                picked.append(window.start)
            }
        }
        return picked
    }

    // MARK: - Faza 3: doprecyzowanie

    private static func refineCandidates(
        starts: [Double],
        url: URL,
        duration: Double,
        stats: VideoStats,
        waveform: [Float],
        weights: Weights
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for start in starts {
            if let candidate = refine(
                url: url,
                start: start,
                duration: duration,
                stats: stats,
                waveform: waveform,
                weights: weights
            ) {
                candidates.append(candidate)
            }
        }
        candidates.sort { $0.score > $1.score }
        return candidates
    }

    private static func refine(
        url: URL,
        start: Double,
        duration: Double,
        stats: VideoStats,
        waveform: [Float],
        weights: Weights
    ) -> Candidate? {
        let generator = makeGenerator(url: url, maxSize: 320, tolerance: 0.05)
        let offsets = [0.1, 0.3, 0.5, 0.7, 0.9]

        var metrics: [FrameMetrics] = []
        var faceCounts: [Int] = []
        var faceAreas: [Double] = []
        var middleImage: CGImage?

        for (index, offset) in offsets.enumerated() {
            let time = min(duration - 0.03, start + offset)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let image = try? generator.copyCGImage(at: cmTime, actualTime: nil),
                  let frame = FrameMetrics.compute(from: image) else {
                continue
            }
            metrics.append(frame)
            let faces = detectFaces(in: image)
            faceCounts.append(faces.count)
            faceAreas.append(faces.area)
            if index == 2 {
                middleImage = image
            }
        }

        guard !metrics.isEmpty else {
            return nil
        }

        let imageQ = metrics
            .map { imageQuality(of: $0, stats: stats) }
            .reduce(0, +) / Double(metrics.count)

        let bestFaceArea = faceAreas.max() ?? 0
        let bestFaceCount = faceCounts.max() ?? 0
        let faceQ = bestFaceCount > 0
            ? min(1.0, bestFaceArea * 5.0 + 0.15 * Double(min(bestFaceCount, 3)))
            : 0.0

        var diffs: [Double] = []
        for index in 1..<metrics.count {
            diffs.append(FrameMetrics.gridDifference(metrics[index - 1], metrics[index]))
        }
        let sceneCut = diffs.contains { $0 > 0.28 }
        let meanDiff = diffs.isEmpty ? 0.045 : diffs.reduce(0, +) / Double(diffs.count)
        let motionQ = max(0, 1.0 - abs(meanDiff - 0.045) / 0.13)

        let saliencyQ = middleImage.map(saliencyQuality) ?? 0.4
        let audioQ = waveform.isEmpty
            ? 0.5
            : AudioWaveform.windowEnergy(waveform: waveform, duration: duration, start: start, length: 1.0)

        var score = weights.image * imageQ
            + weights.faces * faceQ
            + weights.saliency * saliencyQ
            + weights.motion * motionQ
            + weights.audio * audioQ
        if sceneCut {
            score *= 0.25
        }

        var parts: [String] = [
            String(format: "obraz %.0f%%", imageQ * 100)
        ]
        if bestFaceCount > 0 {
            parts.append(bestFaceCount == 1 ? "1 twarz" : "\(bestFaceCount) twarze")
        }
        parts.append(sceneCut ? "ciecie sceny!" : String(format: "ruch %.0f%%", motionQ * 100))
        if !waveform.isEmpty {
            parts.append(String(format: "dzwiek %.0f%%", audioQ * 100))
        }

        return Candidate(
            start: (start * 1000).rounded() / 1000,
            score: min(1, max(0, score)),
            reason: parts.joined(separator: " · ")
        )
    }
}

// MARK: - Metryki pojedynczej klatki

struct FrameMetrics {
    /// log1p wariancji Laplace'a — ostrosc.
    let sharpness: Double
    let meanLuma: Double
    let contrast: Double
    let saturation: Double
    let clippedFraction: Double
    /// Luma zredukowana do siatki (do porownywania ruchu miedzy klatkami).
    let gridLuma: [Double]

    static let gridWidth = 32
    static let gridHeight = 18

    static func compute(from image: CGImage) -> FrameMetrics? {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else {
            return nil
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
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Double](repeating: 0, count: width * height)
        var lumaSum = 0.0
        var saturationSum = 0.0
        var clipped = 0

        var gridSums = [Double](repeating: 0, count: gridWidth * gridHeight)
        var gridCounts = [Int](repeating: 0, count: gridWidth * gridHeight)

        for y in 0..<height {
            let gy = min(gridHeight - 1, y * gridHeight / height)
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let r = Double(pixels[pixelIndex])
                let g = Double(pixels[pixelIndex + 1])
                let b = Double(pixels[pixelIndex + 2])
                let yValue = 0.2126 * r + 0.7152 * g + 0.0722 * b
                luma[y * width + x] = yValue
                lumaSum += yValue

                let rgbMean = (r + g + b) / 3.0
                let rgbVariance = ((r - rgbMean) * (r - rgbMean)
                    + (g - rgbMean) * (g - rgbMean)
                    + (b - rgbMean) * (b - rgbMean)) / 3.0
                saturationSum += rgbVariance.squareRoot()

                if yValue < 8 || yValue > 247 {
                    clipped += 1
                }

                let gx = min(gridWidth - 1, x * gridWidth / width)
                let gridIndex = gy * gridWidth + gx
                gridSums[gridIndex] += yValue
                gridCounts[gridIndex] += 1
            }
        }

        let pixelCount = Double(width * height)
        let mean = lumaSum / pixelCount

        var varianceSum = 0.0
        var laplacianEnergy = 0.0
        var laplacianCount = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let value = luma[index]
                varianceSum += (value - mean) * (value - mean)
                let laplacian = luma[index - 1]
                    + luma[index + 1]
                    + luma[index - width]
                    + luma[index + width]
                    - 4.0 * value
                laplacianEnergy += laplacian * laplacian
                laplacianCount += 1
            }
        }

        var grid = [Double](repeating: 0, count: gridWidth * gridHeight)
        for index in 0..<grid.count where gridCounts[index] > 0 {
            grid[index] = gridSums[index] / Double(gridCounts[index])
        }

        let contrast = (varianceSum / max(1, laplacianCount)).squareRoot()
        let sharpnessVariance = laplacianCount > 0 ? laplacianEnergy / laplacianCount : 0

        return FrameMetrics(
            sharpness: log1p(sharpnessVariance),
            meanLuma: mean,
            contrast: contrast,
            saturation: saturationSum / pixelCount,
            clippedFraction: Double(clipped) / pixelCount,
            gridLuma: grid
        )
    }

    /// Srednia roznica lumy siatek dwoch klatek, 0...1.
    static func gridDifference(_ left: FrameMetrics, _ right: FrameMetrics) -> Double {
        let count = min(left.gridLuma.count, right.gridLuma.count)
        guard count > 0 else {
            return 0
        }
        var total = 0.0
        for index in 0..<count {
            total += abs(left.gridLuma[index] - right.gridLuma[index])
        }
        return total / Double(count) / 255.0
    }
}

// MARK: - Percentyle

/// Normalizacja percentylowa w obrebie filmu: rank(v) = odsetek probek <= v.
struct Percentiler {
    private let sorted: [Double]

    init(values: [Double]) {
        sorted = values.sorted()
    }

    func rank(_ value: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0.5
        }
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return Double(low) / Double(sorted.count)
    }
}
