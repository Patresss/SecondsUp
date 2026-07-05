import SwiftUI

struct MontageView: View {
    @ObservedObject var model: MontageModel

    var body: some View {
        HStack(spacing: 0) {
            clipList
                .frame(width: 330)

            Divider()

            settingsPanel
                .frame(minWidth: 720, minHeight: 620)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.chooseFolder) {
                    Label("Folder klipow", systemImage: "folder")
                }

                Button(action: model.sortChronologically) {
                    Label("Sortuj wg daty", systemImage: "arrow.up.arrow.down")
                }
                .disabled(model.clips.isEmpty)

                Spacer()

                Text(model.ffmpegStatus)
                    .font(.caption)
                    .foregroundStyle(model.canUseTools ? .green : .red)
            }
        }
        .onChange(of: model.settings) { _ in
            model.saveProject()
        }
    }

    // MARK: - Lista klipow

    private var clipList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Klipy")
                        .font(.title3.weight(.semibold))
                    Text(model.folder?.lastPathComponent ?? "Nie wybrano folderu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !model.clips.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(model.includedClips.count)/\(model.clips.count)")
                            .font(.caption)
                        Text(model.totalDurationText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)

            Divider()

            if model.clips.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Wybierz folder z sekundami\nz zakladki Wycinanie")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Wybierz folder", action: model.chooseFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.selectedClipID },
                    set: { model.selectedClipID = $0 }
                )) {
                    ForEach(model.clips) { clip in
                        ClipRow(
                            clip: clip,
                            thumbnail: model.thumbnails[clip.url],
                            include: Binding(
                                get: { model.includeBinding(for: clip.id) },
                                set: { model.setInclude(clip.id, include: $0) }
                            )
                        )
                        .tag(clip.id as URL?)
                    }
                    .onMove { source, destination in
                        model.moveClips(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            Text(model.statusMessage)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    // MARK: - Ustawienia i render

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleSection
                    Divider()
                    captionSection
                    Divider()
                    musicSection
                    Divider()
                    outputSection
                }
                .padding(18)
            }

            Divider()

            renderBar
                .padding(14)
        }
    }

    private var preview: some View {
        ZStack {
            if let clip = model.selectedClip ?? model.includedClips.first {
                previewOverlay(
                    thumbnail: model.thumbnails[clip.url],
                    caption: clip.captionText
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Podglad klipu z napisem")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func previewOverlay(thumbnail: NSImage?, caption: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: overlayAlignment) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.settings.captionEnabled {
                    Text(caption)
                        .font(.system(size: max(10, model.settings.captionFontSize * proxy.size.height / 1080)))
                        .foregroundStyle(.white.opacity(model.settings.captionOpacity))
                        .shadow(color: .black.opacity(0.7), radius: 1, x: 1, y: 1)
                        .padding(14)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var overlayAlignment: Alignment {
        switch model.settings.captionPosition {
        case .bottomRight:
            return .bottomTrailing
        case .bottomLeft:
            return .bottomLeading
        case .bottomCenter:
            return .bottom
        case .topRight:
            return .topTrailing
        case .topLeft:
            return .topLeading
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Plansza tytulowa", isOn: $model.settings.titleEnabled)
                .font(.headline)

            if model.settings.titleEnabled {
                TextField("Tytul filmu, np. Rok 2026", text: $model.settings.titleText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)

                HStack {
                    Text("Czas trwania")
                    Slider(value: $model.settings.titleDuration, in: 1...5, step: 0.5)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.1fs", model.settings.titleDuration))
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Napis z data (z nazwy pliku)", isOn: $model.settings.captionEnabled)
                .font(.headline)

            if model.settings.captionEnabled {
                HStack(spacing: 16) {
                    Picker("Pozycja", selection: $model.settings.captionPosition) {
                        ForEach(CaptionPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .frame(maxWidth: 260)

                    HStack {
                        Text("Rozmiar")
                        Slider(value: $model.settings.captionFontSize, in: 18...72, step: 2)
                            .frame(width: 140)
                        Text(String(format: "%.0f", model.settings.captionFontSize))
                            .monospacedDigit()
                    }

                    HStack {
                        Text("Krycie")
                        Slider(value: $model.settings.captionOpacity, in: 0.3...1)
                            .frame(width: 110)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Muzyka")
                .font(.headline)

            HStack(spacing: 10) {
                Button(action: model.chooseMusic) {
                    Label(model.musicFileName ?? "Wybierz plik", systemImage: "music.note")
                }

                if model.settings.musicPath != nil {
                    Button(action: model.clearMusic) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if model.settings.musicPath != nil {
                HStack(spacing: 16) {
                    HStack {
                        Text("Glosnosc")
                        Slider(value: $model.settings.musicVolume, in: 0.1...1.5)
                            .frame(width: 140)
                        Text(String(format: "%.0f%%", model.settings.musicVolume * 100))
                            .monospacedDigit()
                    }

                    Toggle("Fade out", isOn: $model.settings.musicFadeOut)

                    if model.settings.musicFadeOut {
                        HStack {
                            Slider(value: $model.settings.musicFadeDuration, in: 1...5, step: 0.5)
                                .frame(width: 100)
                            Text(String(format: "%.1fs", model.settings.musicFadeDuration))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }

            Toggle("Zachowaj dzwiek klipow", isOn: $model.settings.keepClipAudio)
                .font(.callout)
                .help("Bez muzyki i bez tej opcji film bedzie niemy")
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wyjscie")
                .font(.headline)

            HStack(spacing: 16) {
                Picker("Rozdzielczosc", selection: $model.settings.resolution) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .frame(maxWidth: 300)

                Picker("FPS", selection: $model.settings.fps) {
                    ForEach([24, 25, 30, 60], id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .frame(maxWidth: 120)
            }
            .font(.callout)
        }
    }

    private var renderBar: some View {
        HStack(spacing: 14) {
            if model.isRendering {
                ProgressView(value: model.progress?.fraction ?? 0)
                    .frame(maxWidth: 320)
                Text(model.progress?.stage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Przerwij", action: model.cancelRender)

                Spacer()
            } else {
                Text("\(model.includedClips.count) klipow · ~\(model.totalDurationText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                if model.lastOutput != nil {
                    Button(action: model.revealLastOutput) {
                        Label("Pokaz w Finderze", systemImage: "magnifyingglass")
                    }
                }

                Button(action: model.render) {
                    Label("Renderuj film", systemImage: "film")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canUseTools || model.includedClips.isEmpty)
            }
        }
    }
}

// MARK: - Wiersz klipu

private struct ClipRow: View {
    let clip: MontageClip
    let thumbnail: NSImage?
    @Binding var include: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $include)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 52, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(include ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.captionText)
                    .lineLimit(1)
                    .foregroundStyle(include ? .primary : .secondary)
                Text(clip.fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
