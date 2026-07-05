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
    /// Podglad 1 s w petli — sekunda odtwarza sie w kolko az do zatrzymania.
    @Published var loopPreview = false
    @Published var cutMode: CutMode = .losslessOnly {
        didSet {
            UserDefaults.standard.set(cutMode.rawValue, forKey: Self.cutModeKey)
            if oldValue != cutMode {
                applyTopRecommendationForCurrentMode()
            }
        }
    }

    private let service: MediaService
    private var analysisTasks: [URL: Task<AnalysisOutcome, Never>] = [:]
    private var backgroundAnalysisTask: Task<Void, Never>?
    private var previewToken = UUID()

    private static let inputFolderKey = "extract.inputFolder"
    private static let outputFolderKey = "extract.outputFolder"
    private static let cutModeKey = "extract.cutMode"

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

    var selectedCandidates: [Candidate] {
        selectedAnalysis?.candidates(for: cutMode) ?? []
    }

    var selectedTopCandidate: Candidate? {
        selectedCandidates.first
    }

    var selectedLosslessExportStart: Double? {
        guard let metadata = selectedMetadata,
              let analysis = selectedAnalysis else {
            return nil
        }
        return MediaService.losslessStart(
            near: selectedStart,
            keyframes: analysis.keyframes,
            frameStep: metadata.frameStep
        )
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
            frameStep: metadata.frameStep,
            cutMode: cutMode
        )
    }

    var plannedExportText: String? {
        guard let metadata = selectedMetadata,
              let analysis = selectedAnalysis else {
            return nil
        }
        switch cutMode {
        case .autoPrecise:
            return MediaService.plannedMethod(
                start: selectedStart,
                keyframes: analysis.keyframes,
                frameStep: metadata.frameStep,
                cutMode: cutMode
            ).label
        case .losslessOnly:
            if let start = selectedLosslessExportStart {
                let delta = start - selectedStart
                let codec = codecCopyLabel(for: metadata)
                if abs(delta) <= max(metadata.frameStep * 0.6, 0.02) {
                    return String(format: "%.3f-%.3fs, %@", start, start + 1.0, codec)
                }
                return String(
                    format: "Najbliższe bezstratne: %.3f-%.3fs (%+.3fs), %@",
                    start,
                    start + 1.0,
                    delta,
                    codec
                )
            }
            return "bezstratnie"
        }
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
        if let raw = defaults.string(forKey: Self.cutModeKey),
           let restored = CutMode(rawValue: raw) {
            cutMode = restored
        }
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
        previewToken = UUID()
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
                let candidates = analysis.candidates(for: self.cutMode)
                if let top = candidates.first {
                    self.setStart(top.start)
                }
                self.statusMessage = String(
                    format: "Rekomendacja gotowa: %d kandydatow, %d probek",
                    candidates.count,
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
        var seen = Set<Double>()
        let starts = (analysis.losslessCandidates + analysis.candidates)
            .map(\.start)
            .filter { seen.insert($0).inserted }
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

    func setStart(_ start: Double, snapToLossless: Bool = false) {
        previewToken = UUID()
        player.pause()
        var resolvedStart = start
        if snapToLossless,
           cutMode == .losslessOnly,
           let metadata = selectedMetadata,
           let analysis = selectedAnalysis,
           let keyframe = MediaService.losslessStart(
            near: start,
            keyframes: analysis.keyframes,
            frameStep: metadata.frameStep
           ) {
            resolvedStart = keyframe
        }
        selectedStart = min(max(0, resolvedStart), maxStart)
        seekToSelectedStart()
    }

    func stepBackward() {
        if cutMode == .losslessOnly, let previous = adjacentLosslessStart(direction: -1) {
            setStart(previous)
            return
        }
        setStart(selectedStart - frameStep)
    }

    func stepForward() {
        if cutMode == .losslessOnly, let next = adjacentLosslessStart(direction: 1) {
            setStart(next)
            return
        }
        setStart(selectedStart + frameStep)
    }

    func jumpBackward() {
        setStart(selectedStart - 0.5, snapToLossless: true)
    }

    func jumpForward() {
        setStart(selectedStart + 0.5, snapToLossless: true)
    }

    func useRecommendation() {
        guard let top = selectedTopCandidate else {
            return
        }
        setStart(top.start)
    }

    /// Odtwarza zaznaczona sekunde; drugie wywolanie w trakcie zatrzymuje.
    /// Przy wlaczonej petli sekunda powtarza sie do zatrzymania.
    func playSelectedSecond() {
        if player.rate > 0 {
            previewToken = UUID()
            player.pause()
            return
        }
        let token = UUID()
        previewToken = token
        playOnce(token: token)
    }

    private func playOnce(token: UUID) {
        let startTime = CMTime(seconds: selectedStart, preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewToken == token else {
                    return
                }
                self.player.play()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.previewToken == token else {
                    return
                }
                if self.loopPreview {
                    self.playOnce(token: token)
                } else {
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

        guard let dateText = video.effectiveDate else {
            statusMessage = "Brak daty: ani w nazwie pliku, ani w metadanych nagrania."
            return
        }

        isExporting = true
        updateVideo(video.id) { $0.exportState = .exporting }
        statusMessage = "Eksportuje \(video.fileName)..."

        let service = self.service
        let start = resolvedExportStart(for: video, metadata: metadata)
        let keyframes = video.analysis?.keyframes ?? []
        let selectedCutMode = cutMode
        Task {
            do {
                let result = try await Task.detached {
                    try service.exportSecond(
                        source: video.url,
                        outputFolder: outputFolder,
                        start: start,
                        metadata: metadata,
                        keyframes: keyframes,
                        dateText: dateText,
                        cutMode: selectedCutMode
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
        let selectedCutMode = cutMode
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
                      let top = analysis.candidates(for: selectedCutMode).first else {
                    failures.append(url.lastPathComponent)
                    continue
                }
                guard let dateText = DateParser.dateString(from: url.lastPathComponent)
                        ?? metadata.recordedDate else {
                    failures.append("\(url.lastPathComponent) (brak daty)")
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
                            keyframes: keyframes,
                            dateText: dateText,
                            cutMode: selectedCutMode
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

    // MARK: - Akcje kontekstowe

    /// Czysci cache i liczy rekomendacje od nowa dla danego pliku.
    func reanalyze(_ url: URL) {
        analysisTasks[url]?.cancel()
        analysisTasks[url] = nil
        AnalysisCache.remove(for: url)
        updateVideo(url) {
            $0.metadata = nil
            $0.analysis = nil
            $0.analysisError = nil
        }
        if selectedVideoID == url {
            selectVideo(url)
        } else {
            ensureAnalysis(for: url)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealExportedClip(for item: VideoItem) {
        if case .exported(let url) = item.exportState {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Pomocnicze

    private func updateVideo(_ id: URL, _ update: (inout VideoItem) -> Void) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&videos[index])
    }

    private func applyTopRecommendationForCurrentMode() {
        guard let top = selectedTopCandidate else {
            return
        }
        setStart(top.start)
        if let selectedVideoID,
           let analysis = selectedAnalysis {
            Task {
                await loadThumbnails(for: selectedVideoID, analysis: analysis)
            }
        }
    }

    private func resolvedExportStart(for video: VideoItem, metadata: VideoMetadata) -> Double {
        guard cutMode == .losslessOnly,
              let analysis = video.analysis,
              let start = MediaService.losslessStart(
                near: selectedStart,
                keyframes: analysis.keyframes,
                frameStep: metadata.frameStep
              ) else {
            return selectedStart
        }
        return start
    }

    private func adjacentLosslessStart(direction: Int) -> Double? {
        guard let metadata = selectedMetadata,
              let analysis = selectedAnalysis else {
            return nil
        }
        let starts = losslessStarts(analysis: analysis, metadata: metadata)
        guard !starts.isEmpty else {
            return nil
        }

        let tolerance = max(metadata.frameStep * 0.6, 0.02)
        if direction < 0 {
            return starts.last { $0 < selectedStart - tolerance } ?? starts.first
        }
        return starts.first { $0 > selectedStart + tolerance } ?? starts.last
    }

    private func losslessStarts(analysis: AnalysisResult, metadata: VideoMetadata) -> [Double] {
        let maxStart = max(0, metadata.duration - 1.0)
        let tolerance = max(metadata.frameStep * 0.5, 0.005)
        var starts = analysis.keyframes
            .map { max(0, ($0 * 1000).rounded() / 1000) }
            .filter { $0 <= maxStart + tolerance }
            .sorted()
        if starts.first.map({ $0 > tolerance }) ?? true {
            starts.insert(0, at: 0)
        }

        var cleaned: [Double] = []
        for start in starts {
            if cleaned.last.map({ abs($0 - start) > 0.01 }) ?? true {
                cleaned.append(start)
            }
        }
        return cleaned
    }

    private func codecCopyLabel(for metadata: VideoMetadata) -> String {
        switch metadata.codec.lowercased() {
        case "hevc", "h265":
            return "HEVC copy"
        case "h264":
            return "H.264 copy"
        case "":
            return "copy"
        default:
            return "\(metadata.codec.uppercased()) copy"
        }
    }
}
