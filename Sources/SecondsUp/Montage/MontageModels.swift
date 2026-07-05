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

enum CaptionFormat: String, Codable, CaseIterable, Identifiable {
    case raw
    case iso
    case dayMonth
    case dayMonthPadded
    case dayMonthYearDots
    case slash
    case dayMonthLong
    case dayMonthYearLong
    case weekdayShort
    case weekdayLong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .raw:
            return "jak nazwa pliku"
        case .iso:
            return "2026-06-05"
        case .dayMonth:
            return "5.06"
        case .dayMonthPadded:
            return "05.06"
        case .dayMonthYearDots:
            return "05.06.2026"
        case .slash:
            return "05/06/2026"
        case .dayMonthLong:
            return "5 czerwca"
        case .dayMonthYearLong:
            return "5 czerwca 2026"
        case .weekdayShort:
            return "pt, 5.06"
        case .weekdayLong:
            return "piatek, 5 czerwca"
        }
    }
}

enum CaptionFont: String, Codable, CaseIterable, Identifiable {
    case helvetica
    case helveticaNeue
    case avenir
    case avenirNext
    case menlo
    case georgia
    case times
    case arialRounded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .helvetica:
            return "Helvetica"
        case .helveticaNeue:
            return "Helvetica Neue"
        case .avenir:
            return "Avenir"
        case .avenirNext:
            return "Avenir Next"
        case .menlo:
            return "Menlo"
        case .georgia:
            return "Georgia"
        case .times:
            return "Times"
        case .arialRounded:
            return "Arial Rounded"
        }
    }

    var fontPath: String {
        switch self {
        case .helvetica:
            return "/System/Library/Fonts/Helvetica.ttc"
        case .helveticaNeue:
            return "/System/Library/Fonts/HelveticaNeue.ttc"
        case .avenir:
            return "/System/Library/Fonts/Avenir.ttc"
        case .avenirNext:
            return "/System/Library/Fonts/Avenir Next.ttc"
        case .menlo:
            return "/System/Library/Fonts/Menlo.ttc"
        case .georgia:
            return "/System/Library/Fonts/Supplemental/Georgia.ttf"
        case .times:
            return "/System/Library/Fonts/Times.ttc"
        case .arialRounded:
            return "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"
        }
    }
}

enum MontageRenderMode: String, Codable, CaseIterable, Identifiable {
    case h264
    case proResHQ
    case losslessSmart
    case losslessCopy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264:
            return "H.264"
        case .proResHQ:
            return "ProRes HQ"
        case .losslessSmart:
            return "Bezstratnie smart"
        case .losslessCopy:
            return "Bezstratnie copy"
        }
    }

    var help: String {
        switch self {
        case .h264:
            return "Uniwersalny plik MP4. Obraz jest renderowany ponownie."
        case .proResHQ:
            return "Bardzo wysoka jakosc do archiwum lub dalszego montazu. Pliki beda duze."
        case .losslessSmart:
            return "Klipy zgodne z wiekszoscia sa kopiowane bez rekompresji; "
                + "tylko odstajace (inny kodek/rozdzielczosc/kolor) sa dopasowywane. "
                + "Pomija napisy, plansze, muzyke."
        case .losslessCopy:
            return "Kopiuje klipy bez rekompresji. Wymaga identycznych parametrow wszystkich klipow. "
                + "Pomija napisy, plansze, muzyke, zmiane FPS i rozdzielczosci."
        }
    }

    /// Tryby bezstratne pomijaja napisy/plansze/muzyke.
    var isLossless: Bool {
        self == .losslessSmart || self == .losslessCopy
    }
}

enum RenderQuality: String, Codable, CaseIterable, Identifiable {
    case fast
    case standard
    case best

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast:
            return "Szybka"
        case .standard:
            return "Standard"
        case .best:
            return "Najlepsza"
        }
    }

    var preset: String {
        switch self {
        case .fast:
            return "veryfast"
        case .standard:
            return "medium"
        case .best:
            return "slow"
        }
    }

    var crf: String {
        switch self {
        case .fast:
            return "20"
        case .standard:
            return "18"
        case .best:
            return "16"
        }
    }
}

struct MontageSettings: Codable, Equatable {
    var titleEnabled = false
    var titleText = ""
    var titleDuration = 2.0

    var endCardEnabled = false
    var endCardText = ""
    var endCardDuration = 2.0

    var captionEnabled = true
    var captionPosition: CaptionPosition = .bottomRight
    var captionFormat: CaptionFormat = .raw
    var captionFont: CaptionFont = .helvetica
    var captionFontSize = 36.0
    var captionOpacity = 0.9

    var musicPath: String?
    var musicVolume = 0.8
    var musicFadeOut = true
    var musicFadeDuration = 2.0
    var keepClipAudio = false
    var clipAudioVolume = 1.0

    var resolution: ResolutionPreset = .p1080
    var fps = 30
    var renderQuality: RenderQuality = .standard
    var renderMode: MontageRenderMode = .h264

    /// Kolejnosc (nazwy plikow) i wykluczenia zapisane w projekcie.
    var order: [String] = []
    var excluded: [String] = []

    init() {}

    // Odporne dekodowanie: brakujace pola (starsze wersje projektu)
    // dostaja wartosci domyslne zamiast psuc caly plik.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MontageSettings()
        titleEnabled = try container.decodeIfPresent(Bool.self, forKey: .titleEnabled) ?? defaults.titleEnabled
        titleText = try container.decodeIfPresent(String.self, forKey: .titleText) ?? defaults.titleText
        titleDuration = try container.decodeIfPresent(Double.self, forKey: .titleDuration) ?? defaults.titleDuration
        endCardEnabled = try container.decodeIfPresent(Bool.self, forKey: .endCardEnabled) ?? defaults.endCardEnabled
        endCardText = try container.decodeIfPresent(String.self, forKey: .endCardText) ?? defaults.endCardText
        endCardDuration = try container.decodeIfPresent(Double.self, forKey: .endCardDuration) ?? defaults.endCardDuration
        captionEnabled = try container.decodeIfPresent(Bool.self, forKey: .captionEnabled) ?? defaults.captionEnabled
        captionPosition = try container.decodeIfPresent(CaptionPosition.self, forKey: .captionPosition) ?? defaults.captionPosition
        captionFormat = try container.decodeIfPresent(CaptionFormat.self, forKey: .captionFormat) ?? defaults.captionFormat
        captionFont = try container.decodeIfPresent(CaptionFont.self, forKey: .captionFont) ?? defaults.captionFont
        captionFontSize = try container.decodeIfPresent(Double.self, forKey: .captionFontSize) ?? defaults.captionFontSize
        captionOpacity = try container.decodeIfPresent(Double.self, forKey: .captionOpacity) ?? defaults.captionOpacity
        musicPath = try container.decodeIfPresent(String.self, forKey: .musicPath)
        musicVolume = try container.decodeIfPresent(Double.self, forKey: .musicVolume) ?? defaults.musicVolume
        musicFadeOut = try container.decodeIfPresent(Bool.self, forKey: .musicFadeOut) ?? defaults.musicFadeOut
        musicFadeDuration = try container.decodeIfPresent(Double.self, forKey: .musicFadeDuration) ?? defaults.musicFadeDuration
        keepClipAudio = try container.decodeIfPresent(Bool.self, forKey: .keepClipAudio) ?? defaults.keepClipAudio
        clipAudioVolume = try container.decodeIfPresent(Double.self, forKey: .clipAudioVolume) ?? defaults.clipAudioVolume
        resolution = try container.decodeIfPresent(ResolutionPreset.self, forKey: .resolution) ?? defaults.resolution
        fps = try container.decodeIfPresent(Int.self, forKey: .fps) ?? defaults.fps
        renderQuality = try container.decodeIfPresent(RenderQuality.self, forKey: .renderQuality) ?? defaults.renderQuality
        renderMode = try container.decodeIfPresent(MontageRenderMode.self, forKey: .renderMode) ?? defaults.renderMode
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        excluded = try container.decodeIfPresent([String].self, forKey: .excluded) ?? []
    }
}

/// Pokrycie dni w projekcie 1SE: ktore daty maja sekunde, ktorych brakuje.
struct DayCoverage {
    let firstDate: String
    let lastDate: String
    let daysTotal: Int
    let daysCovered: Int
    let missing: [String]

    static func compute(dates rawDates: [String]) -> DayCoverage? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        let covered = Set(rawDates.compactMap { DateParser.dateString(from: $0) })
        guard !covered.isEmpty,
              let first = covered.min(),
              let last = covered.max(),
              let firstDate = formatter.date(from: first),
              let lastDate = formatter.date(from: last) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current

        var missing: [String] = []
        var total = 0
        var current = firstDate
        // Bezpiecznik na absurdalnie szerokie zakresy dat.
        let maxDays = 5000
        while current <= lastDate && total < maxDays {
            total += 1
            let text = formatter.string(from: current)
            if !covered.contains(text) {
                missing.append(text)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else {
                break
            }
            current = next
        }

        return DayCoverage(
            firstDate: first,
            lastDate: last,
            daysTotal: total,
            daysCovered: total - missing.count,
            missing: missing
        )
    }
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
