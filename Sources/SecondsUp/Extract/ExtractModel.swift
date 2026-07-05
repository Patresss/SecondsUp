import AVFoundation
import AppKit
import Foundation

enum AnalysisOutcome: Sendable {
    case success(VideoMetadata, AnalysisResult)
    case failure(String)
    case cancelled
}

@MainActor
final class ExtractModel: ObservableObject {
    @Published var inputFolder: URL?
    @Published var outputFolder: URL?
    @Published var videos: [VideoItem] = []
    @Published var selectedVideoID: URL?
    @Published var selectedStart: Double = 0
    @Published var statusMessage = ""
    @Published var isExporting = false
    @Published var isBatchExporting = false
    @Published var candidateThumbnails: [Double: NSImage] = [:]
    @Published var player = AVPlayer()

    private let service: MediaService
    private var analysisTasks: [URL: Task<AnalysisOutcome, Never>] = [:]
    private var backgroundAnalysisTask: Task<Void, Never>?

    private static let inputFolderKey = "extract.inputFolder"
    private static let outputFolderKey = "extract.outputFolder"

    init(service: MediaService = MediaService()) {
        self.service = service
        player.actionAtItemEnd = .pause
        restoreFolders()
    }

    // MARK: - Stan pochodny

    var ffmpegStatus: String {
        service.tools.statusText
    }

    var canUseTools: Bool {
        service.isReady
    }

    var selectedVideo: VideoItem? {
        guard let selectedVideoID else {
            return nil
        }
        return videos.first { $0.id == selectedVideoID }
    }

    var selectedMetadata: VideoMetadata? {
        selectedVideo?.metadata
    }

    var selectedAnalysis: AnalysisResult? {
        selectedVideo?.analysis
    }

    var isLoadingSelected: Bool {
        guard let video = selectedVideo else {
            return false
        }
        return video.analysis == nil && video.analysisError == nil
    }

    var frameStep: Double {
        selectedMetadata?.frameStep ?? (1.0 / 30.0)
    }

    var maxStart: Double {
        max(0, (selectedMetadata?.duration ?? 1) - 1.0)
    }

    var exportButtonEnabled: Bool {
        canUseTools && !isExporting && !isBatchExporting && selectedMetadata != nil
    }

    var plannedExportMethod: ExportMethod? {
        guard let metadata = selectedMetadata,
              let analysis = selectedAnalysis else {
            return nil
        }
        return MediaService.plannedMethod(
            start: selectedStart,
            keyframes: analysis.keyframes,
            frameStep: metadata.frameStep
        )
    }

    var analyzedCount: Int {
        videos.filter { $0.analysis != nil }.count
    }

    // MARK: - Foldery

    func chooseInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder z filmami"

        if panel.runModal() == .OK, let url = panel.url {
            loadInputFolder(url)
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Wybierz folder zapisu sekund"

        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            UserDefaults.standard.set(url.path, forKey: Self.outputFolderKey)
            statusMessage = "Folder eksportu: \(url.path)"
        }
    }

    func loadInputFolder(_ url: URL) {
        cancelAnalysisTasks()
        inputFolder = url
        UserDefaults.standard.set(url.path, forKey: Self.inputFolderKey)
        videos = service.scanVideos(in: url)
        selectedVideoID = nil
        selectedStart = 0
        candidateThumbnails = [:]
        player.replaceCurrentItem(with: nil)
        statusMessage = "Znaleziono \(videos.count) filmow"

        if let first = videos.first {
            selectVideo(first.id)
        }
        startBackgroundAnalysis()
    }

    private func restoreFolders() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Self.outputFolderKey),
           FileManager.default.fileExists(atPath: path) {
            outputFolder = URL(fileURLWithPath: path)
        }
        if let path = defaults.string(forKey: Self.inputFolderKey),
           FileManager.default.fileExists(atPath: path) {
            loadInputFolder(URL(fileURLWithPath: path))
        }
    }

    // MARK: - Wybor filmu

    func selectVideo(_ id: URL?) {
        selectedVideoID = id
        selectedStart = 0
        candidateThumbnails = [:]

        guard let id else {
            player.replaceCurrentItem(with: nil)
            return
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: id))
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

        Task { [weak self] in
            guard let self else {
                return
            }
            let outcome = await self.ensureAnalysis(for: id).value
            guard self.selectedVideoID == id else {
                return
            }
            switch outcome {
            case .success(_, let analysis):
                if let top = analysis.candidates.first {
                    self.setStart(top.start)
                }
                self.statusMessage = String(
                    format: "Rekomendacja gotowa: %d kandydatow, %d probek",
                    analysis.candidates.count,
                    analysis.sampleCount
                )
                await self.loadThumbnails(for: id, analysis: analysis)
            case .failure(let message):
                self.statusMessage = message
            case .cancelled:
                break
            }
        }
    }

    private func loadThumbnails(for url: URL, analysis: AnalysisResult) async {
        let starts = analysis.candidates.map(\.start)
        let images = await Task.detached(priority: .utility) {
            VideoAnalyzer.thumbnails(url: url, times: starts)
        }.value
        guard selectedVideoID == url else {
            return
        }
        candidateThumbnails = images.mapValues { NSImage(cgImage: $0, size: .zero) }
    }

    // MARK: - Analiza

    @discardableResult
    func ensureAnalysis(for url: URL) -> Task<AnalysisOutcome, Never> {
        if let existing = analysisTasks[url] {
            return existing
        }
        if let item = videos.first(where: { $0.id == url }),
           let metadata = item.metadata,
           let analysis = item.analysis {
            return Task { .success(metadata, analysis) }
        }

        let service = self.service
        let task = Task { [weak self] () -> AnalysisOutcome in
            let outcome = await Task.detached(priority: .userInitiated) { () -> AnalysisOutcome in
                if let cached = AnalysisCache.load(for: url) {
                    return .success(cached.metadata, cached.analysis)
                }
                do {
                    if Task.isCancelled {
                        return .cancelled
                    }
                    let metadata = try service.probeMetadata(for: url)
                    let keyframes = (try? service.keyframes(for: url)) ?? [0]
                    let analysis = try VideoAnalyzer.analyze(
                        url: url,
                        metadata: metadata,
                        keyframes: keyframes
                    )
                    AnalysisCache.store(metadata: metadata, analysis: analysis, for: url)
                    return .success(metadata, analysis)
                } catch MediaError.cancelled {
                    return .cancelled
                } catch {
                    return .failure(error.localizedDescription)
                }
            }.value

            await MainActor.run { [weak self] in
                guard let self else {
                    return
                }
                self.analysisTasks[url] = nil
                switch outcome {
                case .success(let metadata, let analysis):
                    self.updateVideo(url) {
                        $0.metadata = metadata
                        $0.analysis = analysis
                        $0.analysisError = nil
                    }
                case .failure(let message):
                    self.updateVideo(url) { $0.analysisError = message }
                case .cancelled:
                    break
                }
            }
            return outcome
        }
        analysisTasks[url] = task
        return task
    }

    private func startBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel()
        let urls = videos.map(\.id)
        backgroundAnalysisTask = Task { [weak self] in
            for url in urls {
                if Task.isCancelled {
                    return
                }
                guard let self else {
                    return
                }
                _ = await self.ensureAnalysis(for: url).value
            }
        }
    }

    private func cancelAnalysisTasks() {
        backgroundAnalysisTask?.cancel()
        backgroundAnalysisTask = nil
        for task in analysisTasks.values {
            task.cancel()
        }
        analysisTasks = [:]
    }

    // MARK: - Nawigacja czasowa

    func seekToSelectedStart() {
        let time = CMTime(seconds: selectedStart, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStart(_ start: Double) {
        selectedStart = min(max(0, start), maxStart)
        seekToSelectedStart()
    }

    func stepBackward() {
        setStart(selectedStart - frameStep)
    }

    func stepForward() {
        setStart(selectedStart + frameStep)
    }

    func jumpBackward() {
        setStart(selectedStart - 0.5)
    }

    func jumpForward() {
        setStart(selectedStart + 0.5)
    }

    func useRecommendation() {
        guard let top = selectedVideo?.topCandidate else {
            return
        }
        setStart(top.start)
    }

    func playSelectedSecond() {
        let startTime = CMTime(seconds: selectedStart, preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.player.play()
                let startToken = self.selectedStart
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if abs(self.selectedStart - startToken) < 0.0001 {
                    self.player.pause()
                }
            }
        }
    }

    // MARK: - Eksport

    func exportSelectedSecond() {
        guard let video = selectedVideo,
              let metadata = video.metadata else {
            return
        }

        if outputFolder == nil {
            chooseOutputFolder()
        }

        guard let outputFolder else {
            statusMessage = "Wybierz folder eksportu."
            return
        }

        isExporting = true
        updateVideo(video.id) { $0.exportState = .exporting }
        statusMessage = "Eksportuje \(video.fileName)..."

        let service = self.service
        let start = selectedStart
        let keyframes = video.analysis?.keyframes ?? []
        Task {
            do {
                let result = try await Task.detached {
                    try service.exportSecond(
                        source: video.url,
                        outputFolder: outputFolder,
                        start: start,
                        metadata: metadata,
                        keyframes: keyframes
                    )
                }.value

                updateVideo(video.id) { $0.exportState = .exported(result.url) }
                statusMessage = "Zapisano: \(result.url.lastPathComponent) (\(result.method.label))"
            } catch {
                updateVideo(video.id) { $0.exportState = .failed(error.localizedDescription) }
                statusMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    /// Eksport wsadowy: kazdy film wg najlepszego kandydata.
    func exportAllRecommended() {
        guard canUseTools, !isBatchExporting else {
            return
        }
        if outputFolder == nil {
            chooseOutputFolder()
        }
        guard let outputFolder else {
            statusMessage = "Wybierz folder eksportu."
            return
        }

        isBatchExporting = true
        let service = self.service
        Task { [weak self] in
            guard let self else {
                return
            }
            var exported = 0
            var skipped = 0
            var failures: [String] = []

            for url in self.videos.map(\.id) {
                guard let item = self.videos.first(where: { $0.id == url }) else {
                    continue
                }
                if case .exported = item.exportState {
                    skipped += 1
                    continue
                }

                let outcome = await self.ensureAnalysis(for: url).value
                guard case .success(let metadata, let analysis) = outcome,
                      let top = analysis.candidates.first else {
                    failures.append(url.lastPathComponent)
                    continue
                }

                self.updateVideo(url) { $0.exportState = .exporting }
                self.statusMessage = "Eksportuje \(url.lastPathComponent)..."
                do {
                    let keyframes = analysis.keyframes
                    let start = top.start
                    let result = try await Task.detached {
                        try service.exportSecond(
                            source: url,
                            outputFolder: outputFolder,
                            start: start,
                            metadata: metadata,
                            keyframes: keyframes
                        )
                    }.value
                    self.updateVideo(url) { $0.exportState = .exported(result.url) }
                    exported += 1
                } catch {
                    self.updateVideo(url) { $0.exportState = .failed(error.localizedDescription) }
                    failures.append(url.lastPathComponent)
                }
            }

            var report = "Eksport wsadowy: \(exported) zapisanych"
            if skipped > 0 {
                report += ", \(skipped) pominietych"
            }
            if !failures.isEmpty {
                report += ", bledy: \(failures.joined(separator: ", "))"
            }
            self.statusMessage = report
            self.isBatchExporting = false
        }
    }

    // MARK: - Pomocnicze

    private func updateVideo(_ id: URL, _ update: (inout VideoItem) -> Void) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&videos[index])
    }
}
