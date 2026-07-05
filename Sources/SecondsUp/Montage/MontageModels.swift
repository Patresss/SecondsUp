import Foundation

struct MontageClip: Identifiable, Hashable {
    let url: URL
    var include = true

    var id: URL { url }

    var fileName: String {
        url.lastPathComponent
    }

    /// Tekst napisu: nazwa pliku bez rozszerzenia i sufiksu spacji.
    var captionText: String {
        DateParser.captionText(for: fileName)
    }
}

enum CaptionPosition: String, Codable, CaseIterable, Identifiable {
    case bottomRight
    case bottomLeft
    case bottomCenter
    case topRight
    case topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight:
            return "prawy dolny"
        case .bottomLeft:
            return "lewy dolny"
        case .bottomCenter:
            return "dol, srodek"
        case .topRight:
            return "prawy gorny"
        case .topLeft:
            return "lewy gorny"
        }
    }

    /// Wyrazenia x/y dla filtra drawtext.
    var drawtextXY: (x: String, y: String) {
        switch self {
        case .bottomRight:
            return ("w-tw-32", "h-th-28")
        case .bottomLeft:
            return ("32", "h-th-28")
        case .bottomCenter:
            return ("(w-tw)/2", "h-th-28")
        case .topRight:
            return ("w-tw-32", "28")
        case .topLeft:
            return ("32", "28")
        }
    }
}

enum ResolutionPreset: String, Codable, CaseIterable, Identifiable {
    case p2160
    case p1080
    case p720
    case square1080
    case vertical1080

    var id: String { rawValue }

    var label: String {
        switch self {
        case .p2160:
            return "4K (3840x2160)"
        case .p1080:
            return "1080p (1920x1080)"
        case .p720:
            return "720p (1280x720)"
        case .square1080:
            return "Kwadrat (1080x1080)"
        case .vertical1080:
            return "Pion (1080x1920)"
        }
    }

    var size: (width: Int, height: Int) {
        switch self {
        case .p2160:
            return (3840, 2160)
        case .p1080:
            return (1920, 1080)
        case .p720:
            return (1280, 720)
        case .square1080:
            return (1080, 1080)
        case .vertical1080:
            return (1080, 1920)
        }
    }
}

struct MontageSettings: Codable, Equatable {
    var titleEnabled = false
    var titleText = ""
    var titleDuration = 2.0

    var captionEnabled = true
    var captionPosition: CaptionPosition = .bottomRight
    var captionFontSize = 36.0
    var captionOpacity = 0.9

    var musicPath: String?
    var musicVolume = 0.8
    var musicFadeOut = true
    var musicFadeDuration = 2.0
    var keepClipAudio = false

    var resolution: ResolutionPreset = .p1080
    var fps = 30

    /// Kolejnosc (nazwy plikow) i wykluczenia zapisane w projekcie.
    var order: [String] = []
    var excluded: [String] = []
}

/// Plik projektu zapisywany w folderze klipow.
enum MontageProject {
    static let fileName = ".secondsup-project.json"

    static func load(from folder: URL) -> MontageSettings? {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(MontageSettings.self, from: data)
    }

    static func save(_ settings: MontageSettings, to folder: URL) {
        let url = folder.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

struct RenderProgress: Sendable {
    let stage: String
    let fraction: Double
}
