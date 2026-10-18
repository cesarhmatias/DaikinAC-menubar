import SwiftUI

// The top of the Control tab: a drawn indoor unit with airflow in the mode's color,
// the target temperature with − and +, and a slider over the mode's range.

struct ACUnitIllustration: View {
    let accent: Color
    let running: Bool
    let display: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                // Top highlight and the louver slot.
                VStack(spacing: 0) {
                    Capsule().fill(Color.white.opacity(0.9)).frame(height: 1.5).padding(.horizontal, 18).padding(.top, 5)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.28)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 7).padding(.horizontal, 34).padding(.bottom, 9)
                }
                // Small front display.
                HStack {
                    Spacer()
                    Text(display).font(.system(size: 8, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(running ? accent : Color(white: 0.55))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.16).opacity(running ? 0.9 : 0.25)))
                        .padding(.trailing, 14).padding(.top, 12)
                }.frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 210, height: 50)
            Airflow(accent: accent, running: running).frame(width: 186, height: 38)
        }
        .opacity(running ? 1 : 0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running ? "Air conditioner running" : "Air conditioner off")
    }
}

// Streaks that fall from the louver and fade out; still and faint while the unit is off.
struct Airflow: View {
    let accent: Color
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { timeline in
            Canvas { context, size in
                let time = running ? timeline.date.timeIntervalSinceReferenceDate : 0
                let streaks = 11
                if !running {
                    // A still, faint hint of the airflow while the unit is off.
                    for index in 0..<streaks {
                        let fraction = Double(index) / Double(streaks - 1)
                        let startX = size.width * (0.12 + 0.76 * fraction), drift = (fraction - 0.5) * size.width * 0.35
                        var path = Path()
                        path.move(to: CGPoint(x: startX, y: 0))
                        path.addLine(to: CGPoint(x: startX + drift * 0.45, y: size.height * 0.45))
                        context.stroke(path, with: .color(Color.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    }
                    return
                }
                for index in 0..<streaks {
                    let fraction = Double(index) / Double(streaks - 1)
                    let startX = size.width * (0.12 + 0.76 * fraction)
                    // Spread outward like air leaving an angled louver.
                    let drift = (fraction - 0.5) * size.width * 0.35
                    let phase = (time * 0.55 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1)
                    let length = size.height * (0.35 + 0.25 * sin(Double(index) * 1.7).magnitude)
                    let headY = phase * (size.height + length)
                    let tailY = max(0, headY - length)
                    guard tailY < size.height else { continue }
                    var path = Path()
                    let steps = 8
                    for step in 0...steps {
                        let y = tailY + (min(headY, size.height) - tailY) * Double(step) / Double(steps)
                        let progress = y / size.height
                        let x = startX + drift * progress + sin(progress * 5 + time * 2 + Double(index)) * 2.2
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    let fade = 1 - min(1, headY / (size.height + length))
                    context.stroke(path, with: .color(accent.opacity(0.25 + 0.55 * fade)),
                                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct TemperatureControl: View {
    let value: Int?
    let range: ClosedRange<Int>
    let enabled: Bool
    let accent: Color
    let onCommit: (Int) -> Void
    @State private var draft: Int?

    private var shown: Int? { draft ?? value }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                roundButton("minus", target: shown.map { $0 - 1 })
                Spacer()
                HStack(alignment: .top, spacing: 2) {
                    Text(shown.map(String.init) ?? "--")
                        .font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(shown == nil ? Theme.faintInk : Theme.ink)
                        .contentTransition(.numericText())
                    Text("°C").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.mutedInk).padding(.top, 8)
                }
                Spacer()
                roundButton("plus", target: shown.map { $0 + 1 })
            }
            TemperatureSlider(value: shown, range: range, enabled: enabled, accent: accent,
                              onChange: { draft = $0 }, onEnd: { commit($0) })
            HStack {
                Text("\(range.lowerBound)°"); Spacer(); Text("\((range.lowerBound + range.upperBound) / 2)°"); Spacer(); Text("\(range.upperBound)°")
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.mutedInk).monospacedDigit()
        }
        .onChange(of: value) { _, _ in draft = nil }
        .animation(.easeOut(duration: 0.15), value: shown)
    }

    private func commit(_ target: Int) {
        let clamped = min(range.upperBound, max(range.lowerBound, target))
        guard clamped != value else { draft = nil; return }
        draft = clamped
        onCommit(clamped)
    }

    private func roundButton(_ symbol: String, target: Int?) -> some View {
        let allowed = enabled && target.map(range.contains) == true
        return Button { if let target { commit(target) } } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(allowed ? Theme.ink : Theme.faintInk)
                .background(Circle().fill(Theme.buttonFill))
                .overlay(Circle().strokeBorder(Theme.cardBorder, lineWidth: Theme.borderWidth))
                .contentShape(Circle())
        }.buttonStyle(.plain).disabled(!allowed)
            .help(symbol == "plus" ? "Raise the target" : "Lower the target")
    }
}

struct TemperatureSlider: View {
    let value: Int?
    let range: ClosedRange<Int>
    let enabled: Bool
    let accent: Color
    let onChange: (Int) -> Void
    let onEnd: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = Double(range.upperBound - range.lowerBound)
            let fraction = value.map { Double(min(range.upperBound, max(range.lowerBound, $0)) - range.lowerBound) / span } ?? 0
            let knobX = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.buttonPressedFill).frame(height: 3)
                Capsule().fill(enabled ? accent : Theme.mutedInk).frame(width: max(0, knobX), height: 3)
                // One tick per degree.
                ForEach(range.lowerBound...range.upperBound, id: \.self) { degree in
                    let x = width * Double(degree - range.lowerBound) / span
                    Circle().fill(Theme.faintInk).frame(width: 2, height: 2).offset(x: x - 1, y: 9)
                }
                if value != nil {
                    Circle().fill(Color(white: 0.92)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(enabled ? accent : Theme.mutedInk, lineWidth: 4))
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: knobX - 9)
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in if enabled { onChange(degree(at: drag.location.x, width: width)) } }
                .onEnded { drag in if enabled { onEnd(degree(at: drag.location.x, width: width)) } })
        }
        .frame(height: 24)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement()
        .accessibilityLabel("Target temperature")
        .accessibilityValue(value.map { "\($0) degrees" } ?? "Unknown")
    }

    private func degree(at x: CGFloat, width: CGFloat) -> Int {
        let fraction = min(1, max(0, x / max(1, width)))
        return range.lowerBound + Int((fraction * Double(range.upperBound - range.lowerBound)).rounded())
    }
}
