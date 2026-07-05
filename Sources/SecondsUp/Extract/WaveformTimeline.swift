import SwiftUI

/// Os czasu z waveformem audio: glowny sposob nawigacji po filmie.
/// Klik/przeciagniecie ustawia poczatek 1-sekundowego okna.
/// Pokazuje: slupki RMS, zaznaczone okno 1 s, keyframe'y i kandydatow.
struct WaveformTimeline: View {
    let waveform: [Float]
    let duration: Double
    let start: Double
    let keyframes: [Double]
    let candidates: [Candidate]
    let onScrub: (Double) -> Void

    private let cornerRadius: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let safeDuration = max(duration, 0.001)

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBackground(in: &context, size: size)
                    drawWaveform(in: &context, size: size)
                    drawKeyframes(in: &context, size: size, duration: safeDuration)
                    drawSelection(in: &context, size: size, duration: safeDuration)
                    drawCandidates(in: &context, size: size, duration: safeDuration)
                }

                if waveform.isEmpty {
                    Text("brak dzwieku")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(at: value.location.x, width: width, duration: safeDuration)
                    }
            )
            .frame(width: width, height: height)
        }
    }

    private func scrub(at x: CGFloat, width: CGFloat, duration: Double) {
        guard width > 0 else {
            return
        }
        let fraction = min(max(0, x / width), 1)
        let time = Double(fraction) * duration
        onScrub(min(max(0, time - 0.0), max(0, duration - 1.0)))
    }

    // MARK: - Rysowanie

    private func drawBackground(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(
            Path(roundedRect: rect, cornerRadius: cornerRadius),
            with: .color(Color.secondary.opacity(0.10))
        )
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        guard !waveform.isEmpty else {
            let midY = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 4, y: midY))
            path.addLine(to: CGPoint(x: size.width - 4, y: midY))
            context.stroke(path, with: .color(Color.secondary.opacity(0.35)), lineWidth: 1)
            return
        }

        let count = waveform.count
        let midY = size.height / 2
        let maxBarHeight = (size.height - 10) / 2
        var path = Path()

        let columns = Int(size.width)
        guard columns > 0 else {
            return
        }
        for column in 0..<columns {
            let bucket = min(count - 1, column * count / columns)
            let amplitude = CGFloat(waveform[bucket])
            let barHeight = max(1, amplitude * maxBarHeight)
            let x = CGFloat(column) + 0.5
            path.move(to: CGPoint(x: x, y: midY - barHeight))
            path.addLine(to: CGPoint(x: x, y: midY + barHeight))
        }

        context.stroke(path, with: .color(Color.accentColor.opacity(0.45)), lineWidth: 1)
    }

    private func drawKeyframes(in context: inout GraphicsContext, size: CGSize, duration: Double) {
        guard !keyframes.isEmpty else {
            return
        }
        var path = Path()
        for keyframe in keyframes {
            let x = CGFloat(keyframe / duration) * size.width
            path.move(to: CGPoint(x: x, y: size.height - 6))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(Color.secondary.opacity(0.6)), lineWidth: 1)
    }

    private func drawSelection(in context: inout GraphicsContext, size: CGSize, duration: Double) {
        let x = CGFloat(start / duration) * size.width
        let width = max(4, CGFloat(1.0 / duration) * size.width)
        let clampedX = min(max(0, x), max(0, size.width - width))
        let rect = CGRect(x: clampedX, y: 2, width: width, height: size.height - 4)

        context.fill(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(Color.accentColor.opacity(0.22))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(Color.accentColor),
            lineWidth: 1.5
        )
    }

    private func drawCandidates(in context: inout GraphicsContext, size: CGSize, duration: Double) {
        for (index, candidate) in candidates.enumerated() {
            let x = CGFloat(candidate.start / duration) * size.width
            let isTop = index == 0
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: 8))
            context.stroke(
                path,
                with: .color(isTop ? Color.orange : Color.orange.opacity(0.5)),
                lineWidth: isTop ? 2.5 : 1.5
            )
        }
    }
}
