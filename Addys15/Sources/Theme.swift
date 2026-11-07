import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

enum Theme {
    static let purple = Color(hex: 0x5B3FE0)
    static let purpleDark = Color(hex: 0x3E27A8)
    static let purpleText = Color(hex: 0x432CB0)
    static let lavender = Color(hex: 0xE6E0F7)
    static let lavenderLight = Color(hex: 0xF1ECFF)
    static let lavenderText = Color(hex: 0xE3DBFF)
    static let yellow = Color(hex: 0xFFC94D)
    static let yellowDark = Color(hex: 0xD9A22B)
    static let yellowLight = Color(hex: 0xFFF3D1)
    static let goldText = Color(hex: 0x5A4310)
    static let cream = Color(hex: 0xFFF8EF)
    static let ink = Color(hex: 0x1F1A2E)
    static let muted = Color(hex: 0x4A4460)
    static let green = Color(hex: 0x2F7A57)
    static let greenDark = Color(hex: 0x1F5A3E)
    static let greenLight = Color(hex: 0xE4F5EC)
    static let line = Color(hex: 0xEDE6DA)
    static let pink = Color(hex: 0xFF8FB1)
}

extension Font {
    static func kid(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Size multiplier: Addy's screens are drawn for the iPad and shrink on a phone.
struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var k: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}
struct ScaledForDevice: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hsc
    func body(content: Content) -> some View { content.environment(\.k, hsc == .regular ? 1 : 0.62) }
}

/// Big pressable button with a solid "shadow" underneath, like the mockup.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color
    var shadow: Color
    var text: Color = .white
    var height: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        ChunkyBody(configuration: configuration, style: self)
    }
    private struct ChunkyBody: View {
        let configuration: ButtonStyleConfiguration
        let style: ChunkyButtonStyle
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let r = style.height * 0.29
            let down: CGFloat = configuration.isPressed ? 5 : 0
            ZStack {
                RoundedRectangle(cornerRadius: r).fill(enabled ? style.shadow : Theme.lavender).offset(y: 6)
                RoundedRectangle(cornerRadius: r).fill(enabled ? style.fill : Theme.lavenderLight).offset(y: down)
                configuration.label
                    .font(.kid(style.height * 0.32, .heavy))
                    .foregroundStyle(enabled ? style.text : Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .offset(y: down)
            }
            .frame(maxWidth: .infinity, minHeight: style.height, maxHeight: style.height)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
    }
}

/// A tappable answer: purple when picked, white with a soft border when not.
struct ChoiceChip<Label: View>: View {
    let selected: Bool
    var height: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .background(RoundedRectangle(cornerRadius: height * 0.26).fill(selected ? Theme.purple : Color.white))
                .overlay(RoundedRectangle(cornerRadius: height * 0.26).strokeBorder(selected ? Theme.purple : Theme.lavender, lineWidth: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct ProgressDots: View {
    let step: Int
    @Environment(\.k) private var k
    var body: some View {
        HStack(spacing: 12 * k) {
            ForEach(1...3, id: \.self) { i in
                Capsule().fill(i <= step ? Theme.purple : Theme.lavender).frame(height: 14 * k)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step) of 3")
    }
}

struct ItemThumb: View {
    let image: UIImage?
    var side: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.16).fill(Theme.lavenderLight)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.16))
            } else {
                Image(systemName: "tshirt").font(.system(size: side * 0.4)).foregroundStyle(Theme.purple)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var radius: CGFloat = 26
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.white).shadow(color: Theme.line, radius: 0, y: 3))
    }
}

/// A short burst of confetti; draws nothing after about 3 seconds.
struct Confetti: View {
    private struct Piece {
        let x = Double.random(in: 0...1)
        let delay = Double.random(in: 0...0.5)
        let speed = Double.random(in: 0.6...1.1)
        let spin = Double.random(in: -7...7)
        let size = Double.random(in: 9...17)
        let drift = Double.random(in: -0.12...0.12)
        let color = [Theme.purple, Theme.yellow, Theme.green, Theme.pink].randomElement()!
    }
    @State private var start = Date()
    @State private var finished = false
    @State private var pieces = (0..<80).map { _ in Piece() }

    var body: some View {
        Group {
            if !finished {
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        let t = tl.date.timeIntervalSince(start)
                        for p in pieces {
                            let tt = t - p.delay
                            guard tt > 0 else { continue }
                            let y = -20 + (tt * p.speed * 0.8 + 0.45 * tt * tt) * size.height * 0.5
                            let x = (p.x + p.drift * tt) * size.width
                            let opacity = max(0, min(1, 3.0 - tt))
                            var c = ctx
                            c.translateBy(x: x, y: y)
                            c.rotate(by: .radians(p.spin * tt))
                            c.fill(Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2), cornerRadius: 2),
                                   with: .color(p.color.opacity(opacity)))
                        }
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(3.6))
                    finished = true
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.kid(16, .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Capsule().fill(Theme.ink.opacity(0.9)))
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
