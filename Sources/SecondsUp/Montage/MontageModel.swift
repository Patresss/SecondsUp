import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MontagePreviewMode: String, CaseIterable, Identifiable {
    case clip
    case movie

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clip:
            return "Klip"
        case .movie:
            return "Caly film"
        }
    }
}

@MainActor
final class MontageModel: ObservableObject {
    @Published var folder: URL?
    @Published var clips: [MontageClip] = []
    @Published var settings = MontageSettings()
    @Published var thumbnails: [URL: NSImage] = [:]
    @Published var selectedClipID: URL?
    @Published var isRendering = false
    @Published var progress: RenderProgress?
    @Published var statusMessage = ""
    @Published var lastOutput: URL?
    @Published var previewMode: MontagePreviewMode = .clip
    @Published var previewCaption = ""

    /// Podglad wybranego klipu odtwarzany w petli.
    let previewPlayer = AVQueuePlayer()
    private var previewLooper: AVPlayerLooper?
    private var previewTimeObserver: Any?

    private let tools: ToolSet
    private var renderer: MontageRenderer?
    private var thumbnailTask: Task<Void, Never>?
    private var suppressProjectSave = false

    private static let folderKey = "montage.folder"
    private static let quickTimeMovieType = UTType(filenameExtension: "mov") ?? .movie

    init(tools: ToolSet = .detect()) {
        self.tools = tools
        previewPlayer.isMuted = true
        restoreFolder()
    }

    var canUseTools: Bool {
        tools.isReady
    }

    var ffmpegStatus: String {
        tools.statusText
    }

    var includedClips: [MontageClip] {
        clips.filter(\.include)
    }

    var selectedClip: MontageClip? {
        guard let selectedClipID else {
            return nil
        }
        return clips.first { $0.id == selectedClipID }
    }

    var totalDurationText: String {
        var total = Double(includedClips.count)
        if settings.titleEnabled && !settings.titleText.isEmpty {
            total += settings.titleDuration
        }
        if settings.endCardEnabled && !settings.endCardText.isEmpty {
            total += settings.endCardDuration
        }
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Pokrycie dni: ile dni w zakresie ma swoja sekunde, ktorych brakuje.
    var coverage: DayCoverage? {
        DayCoverage.compute(dates: clips.map(\.captionText))
    }

    /// Napis dla klipu wg wybranego formatu daty.
    func formattedCaption(for clip: MontageClip) -> String {
        Self.formatCaption(clip.captionText, format: settings.captionFormat)
    }

    static func formatCaption(_ raw: String, format: CaptionFormat) -> String {
        guard format != .raw,
              let dateText = DateParser.dateString(from: raw),
              let date = isoDateFormatter.date(from: dateText) else {
            return raw
        }
        switch format {
        case .raw:
            return raw
        case .iso:
            return dateText
        case .dayMonth:
            return displayFormatter(template: "d.MM").string(from: date)
        case .dayMonthPadded:
            return displayFormatter(template: "dd.MM").string(from: date)
        case .dayMonthYearDots:
            return displayFormatter(template: "dd.MM.yyyy").string(from: date)
        case .slash:
            return displayFormatter(template: "dd/MM/yyyy").string(from: date)
        case .dayMonthLong:
            return displayFormatter(template: "d MMMM").string(from: date)
        case .dayMonthYearLong:
            return displayFormatter(template: "d MMMM yyyy").string(from: date)
        case .weekdayShort:
            return displayFormatter(template: "E, d.MM").string(from: date)
        case .weekdayLong:
            return displayFormatter(template: "EEEE, d MMMM").string(from: date)
        }
    }

    private static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func displayFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = template
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// Proponuje tytul na podstawie zakresu dat klipow, np. "Czerwiec 2026".
    func suggestTitleIfEmpty() {
        guard settings.titleText.isEmpty, let coverage else {
            return
        }
        guard let first = Self.isoDateFormatter.date(from: coverage.firstDate),
              let last = Self.isoDateFormatter.date(from: coverage.lastDate) else {
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let firstParts = calendar.dateComponents([.year, .month], from: first)
        let lastParts = calendar.dateComponents([.year, .month], from: last)

        if firstParts.year == lastParts.year, firstParts.month == lastParts.month {
            let text = Self.displayFormatter(template: "LLLL yyyy").string(from: first)
            settings.titleText = text.prefix(1).uppercased() + text.dropFirst()
        } else if firstParts.year == lastParts.year, let year = firstParts.year {
            settings.titleText = "\(year)"
        } else if let firstYear = firstParts.year, let lastYear = lastParts.year {
            settings.titleText = "\(firstYear)-\(lastYear)"
        }
    }

    // MARK: - Folder i klipy

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder z 1-sekundowymi klipami"

        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)

        var found: [MontageClip] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in contents
            where MediaService.videoExtensions.contains(fileURL.pathExtension.lowercased()) {
                found.append(MontageClip(url: fileURL))
            }
        }
        found.sort {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }

        suppressProjectSave = true
        if let saved = MontageProject.load(from: url) {
            settings = saved
            applySavedOrder(to: &found, order: saved.order, excluded: saved.excluded)
        } else {
            settings.order = []
            settings.excluded = []
        }
        suppressProjectSave = false

        clips = found
        thumbnails = [:]
        statusMessage = "Znaleziono \(found.count) klipow"
        selectClip(found.first?.id)
        loadThumbnails(for: found.map(\.url))
    }

    /// Wybiera klip i odtwarza go w petli w podgladzie.
    func selectClip(_ id: URL?) {
        selectedClipID = id
        guard previewMode == .clip else {
            return
        }
        startSelectedClipPreview()
    }

    func startSelectedClipPreview() {
        previewMode = .clip
        removePreviewObserver()
        previewLooper = nil
        previewPlayer.removeAllItems()
        guard let selectedClip else {
            return
        }
        previewCaption = formattedCaption(for: selectedClip)
        let item = AVPlayerItem(url: selectedClip.url)
        previewLooper = AVPlayerLooper(player: previewPlayer, templateItem: item)
        previewPlayer.play()
    }

    func startMoviePreview() {
        let included = includedClips
        guard !included.isEmpty else {
            statusMessage = "Brak zaznaczonych klipow do podgladu."
            return
        }

        previewMode = .movie
        previewLooper = nil
        removePreviewObserver()
        previewPlayer.removeAllItems()
        for clip in included {
            previewPlayer.insert(AVPlayerItem(url: clip.url), after: nil)
        }
        previewCaption = formattedCaption(for: included[0])
        startPreviewObserver()
        previewPlayer.play()
        statusMessage = "Podglad calego filmu: \(included.count) klipow"
    }

    func restartPreview() {
        switch previewMode {
        case .clip:
            startSelectedClipPreview()
        case .movie:
            startMoviePreview()
        }
    }

    private func applySavedOrder(to clips: inout [MontageClip], order: [String], excluded: [String]) {
        let excludedSet = Set(excluded)
        for index in clips.indices where excludedSet.contains(clips[index].fileName) {
            clips[index].include = false
        }
        guard !order.isEmpty else {
            return
        }
        let position = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        clips.sort { left, right in
            let leftIndex = position[left.fileName] ?? Int.max
            let rightIndex = position[right.fileName] ?? Int.max
            if leftIndex != rightIndex {
                return leftIndex < rightIndex
            }
            return left.fileName.localizedStandardCompare(right.fileName) == .orderedAscending
        }
    }

    private func restoreFolder() {
        if let path = UserDefaults.standard.string(forKey: Self.folderKey),
           FileManager.default.fileExists(atPath: path) {
            loadFolder(URL(fileURLWithPath: path))
        }
    }

    /// Sugeruje folder eksportu z zakladki Wycinanie, jesli nie wybrano zadnego.
    func suggestFolderIfEmpty(_ url: URL?) {
        guard folder == nil, let url else {
            return
        }
        loadFolder(url)
    }

    private func loadThumbnails(for urls: [URL]) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            for url in urls {
                if Task.isCancelled {
                    return
                }
                let image = await Task.detached(priority: .utility) { () -> CGImage? in
                    VideoAnalyzer.thumbnails(url: url, times: [0.3]).values.first
                }.value
                guard let self, !Task.isCancelled else {
                    return
                }
                if let image {
                    self.thumbnails[url] = NSImage(cgImage: image, size: .zero)
                }
            }
        }
    }

    // MARK: - Edycja listy

    func moveClips(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
        saveProject()
    }

    func setInclude(_ id: URL, include: Bool) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else {
            return
        }
        clips[index].include = include
        saveProject()
    }

    func includeBinding(for id: URL) -> Bool {
        clips.first { $0.id == id }?.include ?? false
    }

    func sortChronologically() {
        clips.sort {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
        saveProject()
    }

    func saveProject() {
        guard !suppressProjectSave, let folder else {
            return
        }
        settings.order = clips.map(\.fileName)
        settings.excluded = clips.filter { !$0.include }.map(\.fileName)
        MontageProject.save(settings, to: folder)
    }

    // MARK: - Muzyka

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Wybierz"
        panel.message = "Wybierz plik z muzyka"

        if panel.runModal() == .OK, let url = panel.url {
            settings.musicPath = url.path
            saveProject()
        }
    }

    func clearMusic() {
        settings.musicPath = nil
        saveProject()
    }

    var musicFileName: String? {
        settings.musicPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    // MARK: - Render

    func render() {
        guard !isRendering else {
            return
        }
        let included = includedClips
        guard !included.isEmpty else {
            statusMessage = "Brak zaznaczonych klipow."
            return
        }
        guard canUseTools else {
            statusMessage = ffmpegStatus
            return
        }

        let panel = NSSavePanel()
        if settings.renderMode == .losslessCopy || settings.renderMode == .proResHQ {
            panel.allowedContentTypes = [Self.quickTimeMovieType]
            panel.nameFieldStringValue = "OneSecondEveryday.mov"
        } else {
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "OneSecondEveryday.mp4"
        }
        if let folder {
            panel.directoryURL = folder.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let output = panel.url else {
            return
        }

        saveProject()
        let renderer = MontageRenderer(tools: tools)
        self.renderer = renderer
        isRendering = true
        progress = RenderProgress(stage: "Start", fraction: 0)
        statusMessage = "Renderuje..."

        let payload = included.map { (url: $0.url, caption: formattedCaption(for: $0)) }
        let settings = self.settings
        let applyProgress: @MainActor (RenderProgress) -> Void = { [weak self] update in
            self?.progress = update
        }
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try renderer.render(
                        clips: payload,
                        settings: settings,
                        output: output,
                        onProgress: { update in
                            Task { @MainActor in
                                applyProgress(update)
                            }
                        }
                    )
                }.value
                guard let self else {
                    return
                }
                self.lastOutput = result
                self.statusMessage = "Zapisano: \(result.path)"
            } catch MediaError.cancelled {
                self?.statusMessage = "Render przerwany."
            } catch {
                self?.statusMessage = error.localizedDescription
            }
            self?.isRendering = false
            self?.progress = nil
            self?.renderer = nil
        }
    }

    func cancelRender() {
        renderer?.cancel()
    }

    func revealLastOutput() {
        guard let lastOutput else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
    }

    func revealClip(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startPreviewObserver() {
        previewTimeObserver = previewPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.previewMode == .movie,
                      let currentURL = self.currentPreviewURL(),
                      let clip = self.clips.first(where: { $0.url == currentURL }) else {
                    return
                }
                self.previewCaption = self.formattedCaption(for: clip)
            }
        }
    }

    private func removePreviewObserver() {
        if let previewTimeObserver {
            previewPlayer.removeTimeObserver(previewTimeObserver)
            self.previewTimeObserver = nil
        }
    }

    private func currentPreviewURL() -> URL? {
        guard let asset = previewPlayer.currentItem?.asset as? AVURLAsset else {
            return nil
        }
        return asset.url
    }
}
