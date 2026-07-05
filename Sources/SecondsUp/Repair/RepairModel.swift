import AppKit
import Foundation

struct RepairClip: Identifiable {
    enum State: Equatable {
        case pending
        case analyzing
        case compatible
        case needsRepair
        case repairing
        case repaired
        case failed(String)
    }

    let url: URL
    var summary = ""
    var state: State = .pending

    var id: URL { url }

    var fileName: String {
        url.lastPathComponent
    }
}

/// Zakladka Naprawa: analizuje klipy w folderze, wyznacza wzorzec
/// (najczestsza kombinacja parametrow) i dopasowuje odstajace klipy
/// w miejscu, z kopia oryginalow w podfolderze.
@MainActor
final class RepairModel: ObservableObject {
    static let backupFolderName = "_oryginaly"

    @Published var folder: URL?
    @Published var clips: [RepairClip] = []
    @Published var targetSummary: String?
    @Published var isAnalyzing = false
    @Published var isRepairing = false
    @Published var progressFraction: Double = 0
    @Published var statusMessage = ""

    private let tools: ToolSet
    private var conformer: ClipConformer?
    private var infos: [URL: ClipConformer.ClipInfo] = [:]
    private var target: ClipConformer.ClipInfo?
    private var analysisTask: Task<Void, Never>?

    private static let folderKey = "repair.folder"

    init(tools: ToolSet = .detect()) {
        self.tools = tools
        if let path = UserDefaults.standard.string(forKey: Self.folderKey),
           FileManager.default.fileExists(atPath: path) {
            loadFolder(URL(fileURLWithPath: path))
        }
    }

    var canUseTools: Bool {
        tools.isReady
    }

    var ffmpegStatus: String {
        tools.statusText
    }

    var needsRepairCount: Int {
        clips.filter { $0.state == .needsRepair }.count
    }

    var compatibleCount: Int {
        clips.filter { $0.state == .compatible || $0.state == .repaired }.count
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder z klipami do sprawdzenia"

        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        analysisTask?.cancel()
        conformer?.cancel()
        folder = url
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)

        var found: [RepairClip] = []
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in contents
            where MediaService.videoExtensions.contains(fileURL.pathExtension.lowercased()) {
                found.append(RepairClip(url: fileURL))
            }
        }
        found.sort {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }

        clips = found
        infos = [:]
        target = nil
        targetSummary = nil
        statusMessage = "Znaleziono \(found.count) klipow"
        analyze()
    }

    /// Podpowiedz folderu z innych zakladek.
    func suggestFolderIfEmpty(_ url: URL?) {
        guard folder == nil, let url else {
            return
        }
        loadFolder(url)
    }

    // MARK: - Analiza

    func analyze() {
        guard canUseTools, !clips.isEmpty, !isRepairing else {
            return
        }
        analysisTask?.cancel()
        isAnalyzing = true
        progressFraction = 0

        let conformer = ClipConformer(tools: tools)
        self.conformer = conformer
        let urls = clips.map(\.url)

        analysisTask = Task { [weak self] in
            var collected: [URL: ClipConformer.ClipInfo] = [:]
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    return
                }
                await MainActor.run { [weak self] in
                    self?.updateClip(url) { $0.state = .analyzing }
                    self?.progressFraction = Double(index) / Double(urls.count)
                }
                let info = await Task.detached(priority: .userInitiated) {
                    try? conformer.inspect(url)
                }.value
                await MainActor.run { [weak self] in
                    guard let self else {
                        return
                    }
                    if let info {
                        collected[url] = info
                        self.infos[url] = info
                        self.updateClip(url) {
                            $0.summary = info.summary
                            $0.state = .pending
                        }
                    } else {
                        self.updateClip(url) { $0.state = .failed("nie mozna odczytac parametrow") }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else {
                    return
                }
                self.finishAnalysis(with: collected)
            }
        }
    }

    private func finishAnalysis(with collected: [URL: ClipConformer.ClipInfo]) {
        isAnalyzing = false
        progressFraction = 1

        let infosList = clips.compactMap { collected[$0.url] }
        guard let target = ClipConformer.majorityTarget(of: infosList) else {
            statusMessage = "Nie udalo sie ustalic wzorca."
            return
        }
        self.target = target
        targetSummary = target.summary

        for clip in clips {
            guard let info = collected[clip.url] else {
                continue
            }
            updateClip(clip.url) {
                $0.state = info.matchKey == target.matchKey ? .compatible : .needsRepair
            }
        }

        let broken = needsRepairCount
        statusMessage = broken == 0
            ? "Wszystkie klipy sa zgodne — mozna sklejac bezstratnie."
            : "\(broken) klipow odstaje od wzorca. Kliknij Napraw."
    }

    // MARK: - Naprawa

    func repairAll() {
        guard let folder, let target, !isRepairing, !isAnalyzing else {
            return
        }
        let toRepair = clips.filter { $0.state == .needsRepair }.compactMap { infos[$0.url] }
        guard !toRepair.isEmpty else {
            return
        }

        isRepairing = true
        progressFraction = 0
        let conformer = ClipConformer(tools: tools)
        self.conformer = conformer
        let backupDir = folder.appendingPathComponent(Self.backupFolderName, isDirectory: true)

        Task { [weak self] in
            var repaired = 0
            var failures = 0
            for (index, info) in toRepair.enumerated() {
                if conformer.isCancelled {
                    break
                }
                await MainActor.run { [weak self] in
                    self?.updateClip(info.url) { $0.state = .repairing }
                    self?.progressFraction = Double(index) / Double(toRepair.count)
                    self?.statusMessage = "Naprawiam \(info.url.lastPathComponent)..."
                }

                let result = await Task.detached(priority: .userInitiated) { () -> String? in
                    do {
                        try FileManager.default.createDirectory(
                            at: backupDir,
                            withIntermediateDirectories: true
                        )
                        let temp = info.url.deletingLastPathComponent()
                            .appendingPathComponent(".conform-\(UUID().uuidString).mov")
                        try conformer.conform(source: info, target: target, to: temp)

                        // Oryginal do kopii zapasowej, naprawiony na jego miejsce.
                        let backupURL = Self.availableURL(
                            for: info.url.lastPathComponent,
                            in: backupDir
                        )
                        try FileManager.default.moveItem(at: info.url, to: backupURL)
                        try FileManager.default.moveItem(at: temp, to: info.url)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value

                await MainActor.run { [weak self] in
                    if let message = result {
                        failures += 1
                        self?.updateClip(info.url) { $0.state = .failed(message) }
                    } else {
                        repaired += 1
                        self?.updateClip(info.url) { $0.state = .repaired }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }
                self.isRepairing = false
                self.progressFraction = 1
                if conformer.isCancelled {
                    self.statusMessage = "Naprawa przerwana. Naprawiono \(repaired) klipow."
                } else if failures > 0 {
                    self.statusMessage = "Naprawiono \(repaired), bledy: \(failures). Oryginaly w \(Self.backupFolderName)/."
                } else {
                    self.statusMessage = "Naprawiono \(repaired) klipow. Oryginaly w \(Self.backupFolderName)/."
                }
            }
        }
    }

    func cancelRepair() {
        conformer?.cancel()
    }

    func revealBackup() {
        guard let folder else {
            return
        }
        let backup = folder.appendingPathComponent(Self.backupFolderName)
        NSWorkspace.shared.activateFileViewerSelecting([backup])
    }

    func revealClip(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Pomocnicze

    nonisolated static func availableURL(for fileName: String, in folder: URL) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func updateClip(_ url: URL, _ update: (inout RepairClip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.url == url }) else {
            return
        }
        update(&clips[index])
    }
}
