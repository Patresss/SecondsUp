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

    /// Data uzywana do nazwania eksportu: z nazwy pliku,
    /// a gdy jej brak — z metadanych nagrania.
    var effectiveDate: String? {
        dateString ?? metadata?.recordedDate
    }

    /// Czy data pochodzi z metadanych (a nie z nazwy pliku).
    var dateFromMetadata: Bool {
        dateString == nil && metadata?.recordedDate != nil
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
    /// Data nagrania (yyyy-mm-dd) z metadanych pliku — fallback,
    /// gdy nazwa pliku nie zawiera daty.
    var recordedDate: String?

    var frameStep: Double {
        fps > 0 ? 1.0 / fps : 1.0 / 30.0
    }
}

/// Wynik pelnej analizy filmu: kandydaci top-N, keyframe'y i waveform audio.
struct AnalysisResult: Sendable, Hashable, Codable {
    /// Kandydaci precyzyjni — moga zaczynac sie w dowolnym miejscu filmu.
    let candidates: [Candidate]
    /// Kandydaci bezstratni — zawsze zaczynaja sie na keyframe, wiec da sie
    /// ich wyeksportowac przez `-c copy` bez przesuwania startu.
    let losslessCandidates: [Candidate]
    let keyframes: [Double]
    let waveform: [Float]
    let sampleCount: Int

    func candidates(for cutMode: CutMode) -> [Candidate] {
        switch cutMode {
        case .losslessOnly:
            return losslessCandidates.isEmpty ? candidates : losslessCandidates
        case .autoPrecise:
            return candidates
        }
    }
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

enum CutMode: String, Codable, CaseIterable, Identifiable {
    case losslessOnly
    case autoPrecise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .losslessOnly:
            return "Tylko bezstratnie"
        case .autoPrecise:
            return "Auto precyzyjnie"
        }
    }

    var help: String {
        switch self {
        case .losslessOnly:
            return "Rekomenduje i eksportuje tylko sekundy zaczynajace sie na keyframe, bez rekompresji."
        case .autoPrecise:
            return "Na keyframe eksportuje bezstratnie, poza keyframe robi krotki re-encode dla dokladnego startu."
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
