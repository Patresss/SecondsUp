import Foundation

struct VideoItem: Identifiable, Hashable {
    let url: URL
    var metadata: VideoMetadata?
    var analysis: AnalysisResult?
    var analysisError: String?
    var exportState: ExportState = .idle

    var id: URL { url }

    var fileName: String {
        url.lastPathComponent
    }

    var dateString: String? {
        DateParser.dateString(from: fileName)
    }

    var topCandidate: Candidate? {
        analysis?.candidates.first
    }
}

struct VideoMetadata: Sendable, Hashable, Codable {
    let duration: Double
    let fps: Double
    let frameCount: Int?
    let codec: String
    let width: Int?
    let height: Int?

    var frameStep: Double {
        fps > 0 ? 1.0 / fps : 1.0 / 30.0
    }
}

/// Wynik pelnej analizy filmu: kandydaci top-N, keyframe'y i waveform audio.
struct AnalysisResult: Sendable, Hashable, Codable {
    let candidates: [Candidate]
    let keyframes: [Double]
    let waveform: [Float]
    let sampleCount: Int
}

struct Candidate: Sendable, Hashable, Codable, Identifiable {
    let start: Double
    let score: Double
    let reason: String

    var id: Double { start }
}

enum ExportMethod: String, Sendable {
    case lossless
    case precise

    var label: String {
        switch self {
        case .lossless:
            return "bezstratnie"
        case .precise:
            return "precyzyjnie (re-encode)"
        }
    }
}

enum ExportState: Hashable {
    case idle
    case exporting
    case exported(URL)
    case failed(String)

    var shortText: String {
        switch self {
        case .idle:
            return ""
        case .exporting:
            return "Eksport..."
        case .exported:
            return "Gotowe"
        case .failed:
            return "Blad"
        }
    }
}

struct ExportValidation: Sendable {
    let formatDuration: Double
    let videoDuration: Double
    let videoFrames: Int?
    let isValid: Bool

    func summary(expectedFrames: Int?) -> String {
        let framesText = videoFrames.map(String.init) ?? "?"
        if let expectedFrames {
            return String(
                format: "duration %.3fs, video %.3fs, frames %@/%d",
                formatDuration,
                videoDuration,
                framesText,
                expectedFrames
            )
        }
        return String(
            format: "duration %.3fs, video %.3fs, frames %@",
            formatDuration,
            videoDuration,
            framesText
        )
    }
}
