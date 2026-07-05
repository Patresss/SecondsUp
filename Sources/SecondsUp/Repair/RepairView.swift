import SwiftUI

struct RepairView: View {
    @ObservedObject var model: RepairModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)

            Divider()

            if model.clips.isEmpty {
                emptyState
            } else {
                clipList
            }

            Divider()

            footer
                .padding(14)
        }
        .folderDrop { url in
            model.loadFolder(url)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.chooseFolder) {
                    Label("Folder klipow", systemImage: "folder")
                }

                Button(action: model.analyze) {
                    Label("Analizuj ponownie", systemImage: "arrow.clockwise")
                }
                .disabled(model.clips.isEmpty || model.isAnalyzing || model.isRepairing)

                Spacer()

                Text(model.ffmpegStatus)
                    .font(.caption)
                    .foregroundStyle(model.canUseTools ? .green : .red)
            }
        }
    }

    // MARK: - Naglowek

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Naprawa klipow")
                        .font(.title3.weight(.semibold))
                    Text(model.folder?.path ?? "Wybierz folder z 1-sekundowymi klipami")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !model.clips.isEmpty {
                    HStack(spacing: 14) {
                        StatBadge(
                            value: model.compatibleCount,
                            label: "zgodne",
                            color: .green
                        )
                        StatBadge(
                            value: model.needsRepairCount,
                            label: "do naprawy",
                            color: model.needsRepairCount > 0 ? .orange : .secondary
                        )
                    }
                }
            }

            if let target = model.targetSummary {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .foregroundStyle(.blue)
                    Text("Wzorzec (najczestszy format): \(target)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Klipy odstajace od wzorca (inny kodek, rozdzielczosc, fps, kolor lub audio) "
                + "psuja bezstratne sklejanie — np. zwolnione tempo albo przyciecia na granicach. "
                + "Naprawa dopasowuje je wysoka jakoscia (CRF 14); oryginaly laduja w podfolderze "
                + "\(RepairModel.backupFolderName)/.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Wybierz folder z sekundami,\nzeby sprawdzic ich zgodnosc")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Wybierz folder", action: model.chooseFolder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lista

    private var clipList: some View {
        List {
            ForEach(model.clips) { clip in
                RepairRow(clip: clip)
                    .contextMenu {
                        Button("Pokaz w Finderze") {
                            model.revealClip(clip.url)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Stopka

    private var footer: some View {
        HStack(spacing: 14) {
            if model.isAnalyzing || model.isRepairing {
                ProgressView(value: model.progressFraction)
                    .frame(maxWidth: 320)
                Text(model.isAnalyzing ? "Analizuje..." : model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if model.isRepairing {
                    Button("Przerwij", action: model.cancelRepair)
                }

                Spacer()
            } else {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                if model.clips.contains(where: { $0.state == .repaired }) {
                    Button(action: model.revealBackup) {
                        Label("Oryginaly", systemImage: "archivebox")
                    }
                }

                Button(action: model.repairAll) {
                    Label(
                        model.needsRepairCount > 0
                            ? "Napraw \(model.needsRepairCount) klipow"
                            : "Wszystko zgodne",
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canUseTools || model.needsRepairCount == 0)
            }
        }
    }
}

// MARK: - Komponenty

private struct StatBadge: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RepairRow: View {
    let clip: RepairClip

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.fileName)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !clip.summary.isEmpty {
                        Text(clip.summary)
                    }
                    if case .failed(let message) = clip.state {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch clip.state {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        case .analyzing, .repairing:
            ProgressView()
                .controlSize(.small)
        case .compatible:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsRepair:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .repaired:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch clip.state {
        case .pending:
            return ""
        case .analyzing:
            return "analiza"
        case .compatible:
            return "zgodny"
        case .needsRepair:
            return "do naprawy"
        case .repairing:
            return "naprawiam"
        case .repaired:
            return "naprawiony"
        case .failed:
            return "blad"
        }
    }

    private var statusColor: Color {
        switch clip.state {
        case .pending, .analyzing:
            return .secondary
        case .compatible:
            return .green
        case .needsRepair, .repairing:
            return .orange
        case .repaired:
            return .blue
        case .failed:
            return .red
        }
    }
}
