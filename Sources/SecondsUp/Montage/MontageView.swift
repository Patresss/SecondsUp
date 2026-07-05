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
        .folderDrop { url in
            model.loadFolder(url)
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
        .onChange(of: model.settings.titleEnabled) { enabled in
            if enabled {
                model.suggestTitleIfEmpty()
            }
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

            if let coverage = model.coverage {
                CoverageBar(coverage: coverage)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

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
                    set: { model.selectClip($0) }
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
                        .contextMenu {
                            Button("Pokaz w Finderze") {
                                model.revealClip(clip.url)
                            }
                            Button(clip.include ? "Wyklucz z montazu" : "Wlacz do montazu") {
                                model.setInclude(clip.id, include: !clip.include)
                            }
                        }
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
                        .disabled(effectsDisabled)
                        .opacity(effectsDisabled ? 0.55 : 1)
                    Divider()
                    captionSection
                        .disabled(effectsDisabled)
                        .opacity(effectsDisabled ? 0.55 : 1)
                    Divider()
                    musicSection
                        .disabled(effectsDisabled)
                        .opacity(effectsDisabled ? 0.55 : 1)
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

    private var effectsDisabled: Bool {
        model.settings.renderMode.isLossless
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: model.startSelectedClipPreview) {
                    Label("Klip", systemImage: "play.rectangle")
                }
                .disabled(model.selectedClip == nil)

                Button(action: model.startMoviePreview) {
                    Label("Caly film", systemImage: "film.stack")
                }
                .disabled(model.includedClips.isEmpty)

                Button(action: model.restartPreview) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Uruchom podglad od poczatku")

                Spacer()

                Text(model.previewMode.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            ZStack {
                if model.previewMode == .movie || model.selectedClip != nil {
                    previewOverlay(caption: model.previewCaption)
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
    }

    private func previewOverlay(caption: String) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: overlayAlignment) {
                PlayerView(player: model.previewPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if model.settings.captionEnabled {
                    let fontSize = max(10, model.settings.captionFontSize * proxy.size.height / 1080)
                    Text(caption)
                        .font(.custom(model.settings.captionFont.label, size: fontSize))
                        .foregroundStyle(.white.opacity(model.settings.captionOpacity))
                        .shadow(color: .black.opacity(0.7), radius: 1, x: 1, y: 1)
                        .padding(14)
                        .allowsHitTesting(false)
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

            Toggle("Plansza koncowa", isOn: $model.settings.endCardEnabled)
                .font(.headline)
                .padding(.top, model.settings.titleEnabled ? 6 : 0)

            if model.settings.endCardEnabled {
                TextField("Tekst koncowy, np. Koniec", text: $model.settings.endCardText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)

                HStack {
                    Text("Czas trwania")
                    Slider(value: $model.settings.endCardDuration, in: 1...5, step: 0.5)
                        .frame(maxWidth: 220)
                    Text(String(format: "%.1fs", model.settings.endCardDuration))
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
                    Picker("Format", selection: $model.settings.captionFormat) {
                        ForEach(CaptionFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .frame(maxWidth: 280)

                    Picker("Pozycja", selection: $model.settings.captionPosition) {
                        ForEach(CaptionPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .frame(maxWidth: 240)

                    Picker("Font", selection: $model.settings.captionFont) {
                        ForEach(CaptionFont.allCases) { font in
                            Text(font.label).tag(font)
                        }
                    }
                    .frame(maxWidth: 220)
                }
                .font(.callout)

                HStack(spacing: 16) {
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

            HStack(spacing: 16) {
                Toggle("Zachowaj dzwiek klipow", isOn: $model.settings.keepClipAudio)
                    .help("Bez muzyki i bez tej opcji film bedzie niemy")

                if model.settings.keepClipAudio {
                    HStack {
                        Text("Glosnosc klipow")
                        Slider(value: $model.settings.clipAudioVolume, in: 0.1...1.5)
                            .frame(width: 140)
                        Text(String(format: "%.0f%%", model.settings.clipAudioVolume * 100))
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wyjscie")
                .font(.headline)

            HStack(spacing: 16) {
                Picker("Tryb", selection: $model.settings.renderMode) {
                    ForEach(MontageRenderMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .frame(maxWidth: 230)
                .help(model.settings.renderMode.help)

                Picker("Rozdzielczosc", selection: $model.settings.resolution) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .frame(maxWidth: 300)
                .disabled(model.settings.renderMode.isLossless)

                Picker("FPS", selection: $model.settings.fps) {
                    ForEach([24, 25, 30, 60], id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .frame(maxWidth: 120)
                .disabled(model.settings.renderMode.isLossless)

                if model.settings.renderMode == .h264 {
                    Picker("Jakosc", selection: $model.settings.renderQuality) {
                        ForEach(RenderQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .frame(maxWidth: 200)
                    .help("Szybka: krotszy czas renderu. Najlepsza: mniejsze artefakty, wolniejszy render.")
                }
            }
            .font(.callout)

            Text(model.settings.renderMode.help)
                .font(.caption)
                .foregroundStyle(model.settings.renderMode.isLossless ? .orange : .secondary)
                .lineLimit(3)

            if model.settings.renderMode.isLossless {
                Label("Napisy, plansze i muzyka wymagaja renderowania obrazu. Uzyj ProRes HQ, jesli chcesz zachowac bardzo wysoka jakosc z tymi dodatkami.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

// MARK: - Pokrycie dni

private struct CoverageBar: View {
    let coverage: DayCoverage
    @State private var showMissing = false

    private var isComplete: Bool {
        coverage.missing.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isComplete ? "checkmark.seal.fill" : "calendar.badge.exclamationmark")
                    .foregroundStyle(isComplete ? .green : .orange)

                Text("\(coverage.daysCovered)/\(coverage.daysTotal) dni")
                    .font(.caption.weight(.semibold))

                Text("\(coverage.firstDate) – \(coverage.lastDate)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if !isComplete {
                    Button("brakuje \(coverage.missing.count)") {
                        showMissing.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .popover(isPresented: $showMissing) {
                        missingList
                    }
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isComplete ? Color.green : Color.orange)
                        .frame(
                            width: proxy.size.width
                                * CGFloat(coverage.daysCovered)
                                / CGFloat(max(1, coverage.daysTotal))
                        )
                }
            }
            .frame(height: 4)
        }
    }

    private var missingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dni bez sekundy")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(coverage.missing, id: \.self) { date in
                        Text(date)
                            .font(.callout.monospacedDigit())
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 180)
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
