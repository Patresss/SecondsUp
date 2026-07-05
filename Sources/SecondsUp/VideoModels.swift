import Foundation

struct VideoItem: Identifiable, Hashable {
    let url: URL
    var metadata: VideoMetadata?
    var recommendation: Recommendation?
    var exportState: ExportState = .idle

    var id: URL { url }

    var fileName: String {
        url.lastPathComponent
    }

    var dateString: String? {
        DateParser.dateString(from: fileName)
    }
}

struct VideoMetadata: Sendable, Hashable {
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

struct Recommendation: Sendable, Hashable {
    let start: Double
    let score: Double
    let reason: String
    let candidateCount: Int
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

enum DateParser {
    static func dateString(from text: String) -> String? {
        let pattern = #"(20\d{2}-\d{2}-\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let dateRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[dateRange])
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
