import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

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

    private let tools: ToolSet
    private var renderer: MontageRenderer?
    private var thumbnailTask: Task<Void, Never>?
    private var suppressProjectSave = false

    private static let folderKey = "montage.folder"

    init(tools: ToolSet = .detect()) {
        self.tools = tools
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
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
        selectedClipID = found.first?.id
        thumbnails = [:]
        statusMessage = "Znaleziono \(found.count) klipow"
        loadThumbnails(for: found.map(\.url))
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
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "OneSecondEveryday.mp4"
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

        let payload = included.map { (url: $0.url, caption: $0.captionText) }
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
}
