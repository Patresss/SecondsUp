import SwiftUI

struct ExtractView: View {
    @ObservedObject var model: ExtractModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)

            Divider()

            mainPanel
                .frame(minWidth: 720, minHeight: 620)
        }
        .folderDrop { url in
            model.loadInputFolder(url)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.chooseInputFolder) {
                    Label("Folder filmow", systemImage: "folder")
                }

                Button(action: model.chooseOutputFolder) {
                    Label("Folder eksportu", systemImage: "square.and.arrow.down")
                }

                Button(action: model.exportAllRecommended) {
                    Label("Eksportuj wszystkie", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!model.canUseTools || model.isBatchExporting || model.videos.isEmpty)
                .help("Eksportuje najlepsza sekunde z kazdego filmu wg rekomendacji")

                Spacer()

                Text(model.ffmpegStatus)
                    .font(.caption)
                    .foregroundStyle(model.canUseTools ? .green : .red)
            }
        }
    }

    // MARK: - Sidebar

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
                if !model.videos.isEmpty {
                    Text("\(model.analyzedCount)/\(model.videos.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Przeanalizowane filmy")
                }
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
                            isLoading: video.analysis == nil && video.analysisError == nil
                        )
                        .tag(video.id as URL?)
                        .contextMenu {
                            Button("Pokaz w Finderze") {
                                model.revealInFinder(video.url)
                            }
                            if case .exported = video.exportState {
                                Button("Pokaz wyeksportowana sekunde") {
                                    model.revealExportedClip(for: video)
                                }
                            }
                            Divider()
                            Button("Przelicz rekomendacje") {
                                model.reanalyze(video.url)
                            }
                        }
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

    // MARK: - Panel glowny

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

                if model.isLoadingSelected {
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
        VStack(spacing: 12) {
            if video.analysis != nil, !model.selectedCandidates.isEmpty {
                candidateStrip(candidates: model.selectedCandidates)
            } else if let error = video.analysisError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                    Spacer()
                }
            }

            WaveformTimeline(
                waveform: video.analysis?.waveform ?? [],
                duration: video.metadata?.duration ?? 1,
                start: model.selectedStart,
                keyframes: video.analysis?.keyframes ?? [],
                candidates: model.selectedCandidates,
                onScrub: { model.setStart($0, snapToLossless: true) }
            )
            .frame(height: 64)

            HStack(spacing: 10) {
                Button(action: model.stepBackward) {
                    Label("Klatka", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(video.metadata == nil)
                .help("Poprzednia klatka (←), −0.5 s (⇧←)")

                Button(action: model.stepForward) {
                    Label("Klatka", systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(video.metadata == nil)
                .help("Nastepna klatka (→), +0.5 s (⇧→)")

                Button(action: model.jumpBackward) {
                    Image(systemName: "gobackward.5")
                }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(video.metadata == nil)
                .labelStyle(.iconOnly)
                .help("−0.5 s (⇧←)")

                Button(action: model.jumpForward) {
                    Image(systemName: "goforward.5")
                }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(video.metadata == nil)
                .labelStyle(.iconOnly)
                .help("+0.5 s (⇧→)")

                Button(action: model.useRecommendation) {
                    Label("Rekomendacja", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedTopCandidate == nil)
                .help("Najlepszy kandydat (⌘R)")

                Button(action: model.playSelectedSecond) {
                    Label("Podglad 1s", systemImage: "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(video.metadata == nil)
                .help("Odtworz/zatrzymaj zaznaczona sekunde (spacja)")

                Toggle(isOn: $model.loopPreview) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .help("Podglad w petli")

                Spacer()

                Button(action: model.exportSelectedSecond) {
                    Label(exportButtonTitle, systemImage: "scissors")
                }
                .keyboardShortcut("e", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.exportButtonEnabled || video.metadata == nil)
                .help("Eksportuj 1 s (⌘E)")
            }

            HStack(spacing: 14) {
                Picker("Tryb cięcia", selection: $model.cutMode) {
                    ForEach(CutMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .frame(width: 220)
                .help(model.cutMode.help)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3fs", model.selectedStart))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Zakres")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.3fs - %.3fs", model.selectedStart, model.selectedStart + 1.0))
                        .monospacedDigit()
                }

                if let method = model.plannedExportMethod {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Eksport")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.plannedExportText ?? method.label)
                            .foregroundStyle(method == .lossless ? Color.green : Color.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 310, alignment: .leading)
                }

                Spacer()

                if let top = model.selectedTopCandidate {
                    Text(top.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
    }

    private func candidateStrip(candidates: [Candidate]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    CandidateChip(
                        candidate: candidate,
                        rank: index + 1,
                        thumbnail: model.candidateThumbnails[candidate.start],
                        isSelected: abs(model.selectedStart - candidate.start) < 0.021
                    )
                    .onTapGesture {
                        model.setStart(candidate.start)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func metadataLine(_ metadata: VideoMetadata) -> String {
        let fps = metadata.fps > 0 ? String(format: "%.2f fps", metadata.fps) : "? fps"
        let frames = metadata.frameCount.map { "\($0) kl." } ?? "? kl."
        return String(format: "%.2fs  %@  %@  %@", metadata.duration, fps, frames, metadata.codec)
    }

    private var exportButtonTitle: String {
        if model.outputFolder == nil {
            return "Wybierz folder i eksportuj"
        }
        return "Eksportuj 1s"
    }
}

// MARK: - Komponenty

private struct CandidateChip: View {
    let candidate: Candidate
    let rank: Int
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                ProgressView()
                                    .controlSize(.small)
                            )
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                Text("\(rank)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        rank == 1 ? Color.orange : Color.black.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .padding(3)
            }

            Text(String(format: "%.2fs · %.0f%%", candidate.start, candidate.score * 100))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .help(candidate.reason)
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
                    if let date = video.effectiveDate {
                        HStack(spacing: 3) {
                            Text(date)
                            if video.dateFromMetadata {
                                Image(systemName: "info.circle")
                                    .help("Data z metadanych nagrania (nazwa pliku nie zawiera daty)")
                            }
                        }
                    } else {
                        Text("bez daty")
                            .foregroundStyle(.red)
                    }
                    if let metadata = video.metadata {
                        Text(String(format: "%.0f fps", metadata.fps))
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
            return video.analysis == nil ? "film" : "sparkles"
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
            return video.analysis == nil ? .secondary : .accentColor
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
                Text("Kandydaci pojawia sie automatycznie")
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
