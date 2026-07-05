import AVFoundation
import Foundation

/// Liczy waveform (slupki RMS 0...1) dla sciezki audio filmu.
/// Natywnie przez AVAssetReader, bez ffmpeg. Pusty wynik = brak audio.
enum AudioWaveform {
    static let defaultBucketCount = 800
    private static let sampleRate = 22050.0

    static func compute(url: URL, bucketCount: Int = defaultBucketCount) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return []
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return []
        }
        reader.add(output)
        guard reader.startReading() else {
            return []
        }

        let duration = asset.duration.seconds
        guard duration > 0 else {
            return []
        }
        let totalSamples = max(1, Int(duration * sampleRate))
        let samplesPerBucket = max(1, totalSamples / bucketCount)

        var sums = [Double](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        var sampleIndex = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else {
                continue
            }
            let length = CMBlockBufferGetDataLength(block)
            let floatCount = length / MemoryLayout<Float>.size
            guard floatCount > 0 else {
                continue
            }
            var samples = [Float](repeating: 0, count: floatCount)
            let status = samples.withUnsafeMutableBytes { pointer -> OSStatus in
                guard let base = pointer.baseAddress else {
                    return -1
                }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: base
                )
            }
            guard status == noErr else {
                continue
            }
            for value in samples {
                let bucket = min(bucketCount - 1, sampleIndex / samplesPerBucket)
                sums[bucket] += Double(value) * Double(value)
                counts[bucket] += 1
                sampleIndex += 1
            }
        }

        var rms = [Float](repeating: 0, count: bucketCount)
        for index in 0..<bucketCount where counts[index] > 0 {
            rms[index] = Float((sums[index] / Double(counts[index])).squareRoot())
        }

        guard let maxValue = rms.max(), maxValue > 0.0005 else {
            return []
        }
        return rms.map { min(1, $0 / maxValue) }
    }

    /// Srednia energia (0...1) w oknie czasowym na podstawie policzonych slupkow.
    static func windowEnergy(waveform: [Float], duration: Double, start: Double, length: Double) -> Double {
        guard !waveform.isEmpty, duration > 0 else {
            return 0
        }
        let count = waveform.count
        let lower = max(0, min(count - 1, Int(start / duration * Double(count))))
        let upper = max(lower, min(count - 1, Int((start + length) / duration * Double(count))))
        var total = 0.0
        for index in lower...upper {
            total += Double(waveform[index])
        }
        return total / Double(upper - lower + 1)
    }
}
