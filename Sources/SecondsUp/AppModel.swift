import AVFoundation
import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var inputFolder: URL?
    @Published var outputFolder: URL?
    @Published var videos: [VideoItem] = []
    @Published var selectedVideoID: URL?
    @Published var selectedStart: Double = 0
    @Published var statusMessage = ""
    @Published var isLoadingRecommendation = false
    @Published var isExporting = false
    @Published var player = AVPlayer()

    private let service: MediaService
    private var recommendationTask: Task<Void, Never>?

    init(service: MediaService = .detect()) {
        self.service = service
        player.actionAtItemEnd = .pause
    }

    var ffmpegStatus: String {
        if service.isReady {
            return "ffmpeg OK"
        }
        if service.ffmpegURL == nil && service.ffprobeURL == nil {
            return "Brak ffmpeg i ffprobe"
        }
        if service.ffmpegURL == nil {
            return "Brak ffmpeg"
        }
        return "Brak ffprobe"
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

    var selectedRecommendation: Recommendation? {
        selectedVideo?.recommendation
    }

    var frameStep: Double {
        selectedMetadata?.frameStep ?? (1.0 / 30.0)
    }

    var maxStart: Double {
        max(0, (selectedMetadata?.duration ?? 1) - 1.0)
    }

    var exportButtonEnabled: Bool {
        canUseTools && !isExporting && !isLoadingRecommendation && selectedVideo != nil
    }

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
            statusMessage = "Folder eksportu: \(url.path)"
        }
    }

    func loadInputFolder(_ url: URL) {
        recommendationTask?.cancel()
        inputFolder = url
        videos = service.scanVideos(in: url)
        selectedVideoID = nil
        selectedStart = 0
        player.replaceCurrentItem(with: nil)
        statusMessage = "Znaleziono \(videos.count) filmow"

        if let first = videos.first {
            selectVideo(first.id)
        }
    }

    func selectVideo(_ id: URL?) {
        recommendationTask?.cancel()
        selectedVideoID = id
        selectedStart = 0
        isLoadingRecommendation = false

        guard let id else {
            player.replaceCurrentItem(with: nil)
            return
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: id))
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        loadMetadataAndRecommendation(for: id)
    }

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

    func useRecommendation() {
        guard let recommendation = selectedRecommendation else {
            return
        }
        setStart(recommendation.start)
    }

    func playSelectedSecond() {
        let startTime = CMTime(seconds: selectedStart, preferredTimescale: 600)
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player.play()
                let startToken = self.selectedStart
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if abs(self.selectedStart - startToken) < 0.0001 {
                    self.player.pause()
                }
            }
        }
    }

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
        Task {
            do {
                let output = try await Task.detached {
                    try service.exportLosslessSecond(
                        source: video.url,
                        outputFolder: outputFolder,
                        start: start,
                        metadata: metadata
                    )
                }.value

                updateVideo(video.id) { $0.exportState = .exported(output) }
                statusMessage = "Zapisano: \(output.lastPathComponent)"
            } catch {
                updateVideo(video.id) { $0.exportState = .failed(error.localizedDescription) }
                statusMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func loadMetadataAndRecommendation(for url: URL) {
        guard canUseTools else {
            statusMessage = ffmpegStatus
            return
        }

        isLoadingRecommendation = true
        statusMessage = "Laduje metadane \(url.lastPathComponent)..."

        let service = self.service
        recommendationTask = Task {
            let startedAt = Date()
            defer {
                if selectedVideoID == url {
                    isLoadingRecommendation = false
                }
            }

            do {
                let metadata = try await Task.detached {
                    try service.probeMetadata(for: url)
                }.value

                guard !Task.isCancelled, selectedVideoID == url else {
                    return
                }

                updateVideo(url) { $0.metadata = metadata }
                statusMessage = "Licze rekomendacje dla \(url.lastPathComponent)..."

                let recommendation = try await Task.detached {
                    try service.recommendStart(for: url, metadata: metadata)
                }.value

                guard !Task.isCancelled, selectedVideoID == url else {
                    return
                }

                updateVideo(url) { $0.recommendation = recommendation }
                selectedStart = min(max(0, recommendation.start), maxStart)
                seekToSelectedStart()
                let elapsed = Date().timeIntervalSince(startedAt)
                statusMessage = String(
                    format: "Rekomendacja gotowa: %.3fs, score %.3f, %.1fs",
                    recommendation.start,
                    recommendation.score,
                    elapsed
                )
            } catch {
                guard !Task.isCancelled, selectedVideoID == url else {
                    return
                }
                updateVideo(url) { $0.exportState = .failed(error.localizedDescription) }
                statusMessage = error.localizedDescription
            }

        }
    }

    private func updateVideo(_ id: URL, _ update: (inout VideoItem) -> Void) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else {
            return
        }
        update(&videos[index])
    }
}
