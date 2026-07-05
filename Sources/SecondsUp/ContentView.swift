import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)

            Divider()

            mainPanel
                .frame(minWidth: 720, minHeight: 620)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.chooseInputFolder) {
                    Label("Folder filmow", systemImage: "folder")
                }

                Button(action: model.chooseOutputFolder) {
                    Label("Folder eksportu", systemImage: "square.and.arrow.down")
                }

                Spacer()

                Text(model.ffmpegStatus)
                    .font(.caption)
                    .foregroundStyle(model.canUseTools ? .green : .red)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Filmy")
                        .font(.title3.weight(.semibold))
                    Text(model.inputFolder?.lastPathComponent ?? "Nie wybrano folderu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            if model.videos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Button("Wybierz folder", action: model.chooseInputFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedVideoID },
                    set: { model.selectVideo($0) }
                )) {
                    ForEach(model.videos) { video in
                        VideoRow(
                            video: video,
                            isLoading: model.isLoadingRecommendation && model.selectedVideoID == video.id
                        )
                            .tag(video.id as URL?)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(model.outputFolder?.path ?? "Folder eksportu nie wybrany")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(model.statusMessage)
                    .font(.caption)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if let video = model.selectedVideo {
                playerArea(video: video)
                Divider()
                controls(video: video)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "movieclapper")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Wybierz film")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func playerArea(video: VideoItem) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                PlayerView(player: model.player)
                    .background(Color.black)

                if model.isLoadingRecommendation {
                    LoadingBadge()
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Text(video.fileName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if model.isLoadingRecommendation {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Licze rekomendacje")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if let metadata = video.metadata {
                    Text(metadataLine(metadata))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func controls(video: VideoItem) -> some View {
        VStack(spacing: 14) {
            if model.isLoadingRecommendation {
                RecommendationStatusBanner(kind: .loading)
            } else if video.recommendation != nil {
                RecommendationStatusBanner(kind: .ready)
            }

            RangeTimeline(
                duration: video.metadata?.duration ?? 1,
                start: model.selectedStart,
                recommendedStart: video.recommendation?.start
            )
            .frame(height: 34)

            HStack(spacing: 10) {
                Button(action: model.stepBackward) {
                    Label("Klatka wstecz", systemImage: "chevron.left")
                }
                .disabled(video.metadata == nil)

                Button(action: model.stepForward) {
                    Label("Klatka dalej", systemImage: "chevron.right")
                }
                .disabled(video.metadata == nil)

                Button(action: model.useRecommendation) {
                    Label("Rekomendacja", systemImage: "wand.and.stars")
                }
                .disabled(video.recommendation == nil)

                Button(action: model.playSelectedSecond) {
                    Label("Podglad 1s", systemImage: "play.fill")
                }
                .disabled(video.metadata == nil)

                Spacer()

                Button(action: model.exportSelectedSecond) {
                    Label(
                        exportButtonTitle,
                        systemImage: "scissors"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.exportButtonEnabled || video.metadata == nil)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3fs", model.selectedStart))
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { model.selectedStart },
                        set: { model.setStart($0) }
                    ),
                    in: 0...max(0.001, model.maxStart)
                )
                .disabled(video.metadata == nil)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Zakres")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3fs-%.3fs", model.selectedStart, model.selectedStart + 1.0))
                        .monospacedDigit()
                }
            }

            if let recommendation = video.recommendation {
                HStack {
                    Text(String(format: "Rekomendacja %.3fs", recommendation.start))
                    Text(String(format: "score %.3f", recommendation.score))
                    Text("\(recommendation.candidateCount) kandydatow")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func metadataLine(_ metadata: VideoMetadata) -> String {
        let fps = metadata.fps > 0 ? String(format: "%.2f fps", metadata.fps) : "? fps"
        let frames = metadata.frameCount.map { "\($0) kl." } ?? "? kl."
        return String(format: "%.2fs  %@  %@  %@", metadata.duration, fps, frames, metadata.codec)
    }

    private var exportButtonTitle: String {
        if model.isLoadingRecommendation {
            return "Czekam na rekomendacje"
        }
        if model.outputFolder == nil {
            return "Wybierz folder i eksportuj"
        }
        return "Eksportuj 1s"
    }
}

private struct VideoRow: View {
    let video: VideoItem
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(video.fileName)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(video.dateString ?? "bez daty")
                    if let metadata = video.metadata {
                        Text(String(format: "%.0f fps", metadata.fps))
                    }
                    if isLoading {
                        Text("licze")
                    }
                    if !video.exportState.shortText.isEmpty {
                        Text(video.exportState.shortText)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch video.exportState {
        case .idle:
            return video.recommendation == nil ? "film" : "sparkles"
        case .exporting:
            return "arrow.triangle.2.circlepath"
        case .exported:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch video.exportState {
        case .idle:
            return video.recommendation == nil ? .secondary : .accentColor
        case .exporting:
            return .orange
        case .exported:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct LoadingBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Licze rekomendacje")
                    .font(.caption.weight(.semibold))
                Text("Start zostanie ustawiony automatycznie")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)
        )
    }
}

private enum RecommendationStatusKind: Equatable {
    case loading
    case ready
}

private struct RecommendationStatusBanner: View {
    let kind: RecommendationStatusKind

    var body: some View {
        HStack(spacing: 10) {
            if kind == .loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(kind == .loading ? "Aplikacja liczy rekomendowany poczatek sekundy" : "Rekomendowany poczatek jest ustawiony")
                .font(.caption.weight(.semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (kind == .loading ? Color.orange : Color.green)
                .opacity(0.13),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }
}

private struct RangeTimeline: View {
    let duration: Double
    let start: Double
    let recommendedStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let safeDuration = max(duration, 1.0)
            let selectionX = CGFloat(start / safeDuration) * width
            let selectionWidth = max(4, CGFloat(1.0 / safeDuration) * width)
            let recommendationX = CGFloat((recommendedStart ?? start) / safeDuration) * width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 10)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: selectionWidth, height: 14)
                    .offset(x: min(max(0, selectionX), max(0, width - selectionWidth)))

                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: 26)
                    .offset(x: min(max(0, recommendationX), max(0, width - 2)))
            }
            .frame(maxHeight: .infinity)
        }
    }
}
