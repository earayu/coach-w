import CoachKit
import SwiftUI

/// Pulse W design tokens shared across iOS and watchOS (aligned with `docs/assets/logo.svg`).
enum PulseTheme {
    // Deep athletic obsidian canvas
    static let obsidianTop = Color(hex: 0x0C1419)
    static let obsidianMid = Color(hex: 0x091015)
    static let obsidianBottom = Color(hex: 0x111D24)
    static let watchCanvas = Color(hex: 0x04080B)

    // Layered obsidian glass surfaces
    static let surface = Color(hex: 0x121E26)
    static let surfaceElevated = Color(hex: 0x172630)
    static let surfaceMuted = Color(hex: 0x0E181F)
    static let surfaceStroke = Color.white.opacity(0.085)
    static let surfaceHighlight = Color.white.opacity(0.15)

    // Pulse W signature Volt-to-Mint spectrum
    static let volt = Color(hex: 0xDCFF38)
    static let lime = Color(hex: 0x8EFF52)
    static let mint = Color(hex: 0x1FE08B)
    static let auraVolt = Color(hex: 0xC8FF2E)

    // Semantic status & heart rate zone accents
    static let sky = Color(hex: 0x38BDF8)
    static let yellow = Color(hex: 0xFACC15)
    static let amber = Color(hex: 0xFFB020)
    static let orange = Color(hex: 0xFB923C)
    static let coral = Color(hex: 0xFF4D6D)

    // High-contrast dark-mode typography
    static let textPrimary = Color(hex: 0xF4F8FA)
    static let textSecondary = Color(hex: 0x90A4AE)
    static let textTertiary = Color(hex: 0x5B717D)

    static let pulseGradient = LinearGradient(
        colors: [volt, lime, mint],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pulseHorizontal = LinearGradient(
        colors: [volt, lime, mint],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let obsidianGradient = LinearGradient(
        colors: [obsidianTop, obsidianMid, obsidianBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [Color(hex: 0x16252F).opacity(0.92), Color(hex: 0x101B23).opacity(0.96)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let mutedCardGradient = LinearGradient(
        colors: [Color(hex: 0x111B22).opacity(0.62), Color(hex: 0x0C141A).opacity(0.68)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Display-only heart rate zone bands based on default max HR 190 bpm (docs/spec.md 5.3).
enum HeartRateZone: Int, CaseIterable, Sendable {
    case warmup = 1
    case fatBurn = 2
    case aerobic = 3
    case threshold = 4
    case maximum = 5

    var code: String { "Z\(rawValue)" }

    var title: String {
        switch self {
        case .warmup: "热身"
        case .fatBurn: "燃脂"
        case .aerobic: "有氧"
        case .threshold: "阈值"
        case .maximum: "极限"
        }
    }

    var badge: String { "\(code) · \(title)" }

    var color: Color {
        switch self {
        case .warmup: PulseTheme.sky
        case .fatBurn: PulseTheme.mint
        case .aerobic: PulseTheme.yellow
        case .threshold: PulseTheme.orange
        case .maximum: PulseTheme.coral
        }
    }

    static func zone(for bpm: Double?, maxHR: Double = 190) -> HeartRateZone? {
        guard let bpm, bpm > 30 else { return nil }
        let ratio = bpm / maxHR
        switch ratio {
        case ..<0.60: return .warmup
        case ..<0.70: return .fatBurn
        case ..<0.80: return .aerobic
        case ..<0.90: return .threshold
        default: return .maximum
        }
    }

    /// Normalized 0...1 indicator across typical workout range (95...195 bpm).
    static func progress(for bpm: Double?, maxHR: Double = 190) -> Double {
        guard let bpm, bpm > 30 else { return 0 }
        let lower = maxHR * 0.50
        let upper = maxHR * 1.02
        return min(max((bpm - lower) / (upper - lower), 0.03), 1.0)
    }
}

extension CuePriority {
    var accentColor: Color {
        switch self {
        case .emergency: PulseTheme.coral
        case .correction: PulseTheme.amber
        case .milestone: PulseTheme.volt
        case .companion: PulseTheme.sky
        }
    }

    var symbol: String {
        switch self {
        case .emergency: "exclamationmark.triangle.fill"
        case .correction: "waveform.path.ecg"
        case .milestone: "flag.checkered"
        case .companion: "bubble.left.and.text.bubble.right.fill"
        }
    }
}

/// Full-bleed Pulse W obsidian background with subtle top volt radial aura.
struct PulseBackground: View {
    var auraOpacity: Double = 0.16

    var body: some View {
        ZStack {
            PulseTheme.obsidianGradient
            RadialGradient(
                colors: [
                    PulseTheme.auraVolt.opacity(auraOpacity),
                    PulseTheme.mint.opacity(auraOpacity * 0.35),
                    .clear,
                ],
                center: UnitPoint(x: 0.5, y: 0.08),
                startRadius: 16,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }
}

/// Native SwiftUI vector rendering of the Pulse W brand mark (`docs/assets/logo.svg`).
struct PulseWMark: View {
    var size: CGFloat = 72
    var showRings: Bool = true
    var breathing: Bool = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            if showRings {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                PulseTheme.auraVolt.opacity(breathing && pulse ? 0.28 : 0.16),
                                PulseTheme.mint.opacity(0.06),
                                .clear,
                            ],
                            center: .center,
                            startRadius: size * 0.08,
                            endRadius: size * 0.65
                        )
                    )
                    .frame(width: size * 1.32, height: size * 1.32)
                    .scaleEffect(breathing && pulse ? 1.06 : 0.96)

                Circle()
                    .stroke(PulseTheme.auraVolt.opacity(0.14), lineWidth: 1)
                    .frame(width: size * 0.96, height: size * 0.96)

                Circle()
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    .frame(width: size * 0.74, height: size * 0.74)
            }

            PulseWVector(size: size)
                .shadow(color: PulseTheme.lime.opacity(0.32), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard breathing else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Normalized vector strokes matching `docs/assets/logo.svg` (1024x1024 viewBox, -4 deg stride lean).
private struct PulseWVector: View {
    let size: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 1024.0
            let ox = (canvasSize.width - 1024 * s) / 2
            let oy = (canvasSize.height - 1024 * s) / 2

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                // -4 deg horizontal shear around (512, 512) matching SVG skewX(-4)
                let dx = x - 512
                let dy = y - 512
                let leanedX = dx + dy * (-0.0699) + 512
                return CGPoint(x: ox + leanedX * s, y: oy + y * s)
            }

            // Echo trace
            var echo = Path()
            echo.move(to: point(244, 434))
            echo.addLine(to: point(378, 700))
            echo.addLine(to: point(512, 356))
            echo.addLine(to: point(646, 700))
            echo.addLine(to: point(780, 434))
            context.stroke(
                echo,
                with: .color(PulseTheme.mint.opacity(0.24)),
                style: StrokeStyle(lineWidth: 26 * s, lineCap: .round, lineJoin: .round)
            )

            // Primary bold Pulse-W
            var primary = Path()
            primary.move(to: point(244, 402))
            primary.addLine(to: point(378, 698))
            primary.addLine(to: point(512, 318))
            primary.addLine(to: point(646, 698))
            primary.addLine(to: point(780, 402))
            context.stroke(
                primary,
                with: .linearGradient(
                    Gradient(colors: [PulseTheme.volt, PulseTheme.lime, PulseTheme.mint]),
                    startPoint: point(200, 300),
                    endPoint: point(824, 720)
                ),
                style: StrokeStyle(lineWidth: 84 * s, lineCap: .round, lineJoin: .round)
            )

            // Flanking voice-pulse ticks
            var leftTick = Path()
            leftTick.move(to: point(176, 482))
            leftTick.addLine(to: point(176, 548))
            context.stroke(
                leftTick,
                with: .color(PulseTheme.volt.opacity(0.78)),
                style: StrokeStyle(lineWidth: 34 * s, lineCap: .round)
            )

            var rightTick = Path()
            rightTick.move(to: point(848, 482))
            rightTick.addLine(to: point(848, 548))
            context.stroke(
                rightTick,
                with: .color(PulseTheme.mint.opacity(0.78)),
                style: StrokeStyle(lineWidth: 34 * s, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

/// Reusable obsidian glass card surface with optional volt-to-mint highlight border.
struct PulseCardModifier: ViewModifier {
    var highlighted: Bool = false
    var muted: Bool = false
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(muted ? PulseTheme.mutedCardGradient : PulseTheme.cardGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                highlighted
                                    ? AnyShapeStyle(PulseTheme.pulseGradient)
                                    : AnyShapeStyle(PulseTheme.surfaceStroke),
                                lineWidth: highlighted ? 1.5 : 1
                            )
                    }
                    .shadow(
                        color: highlighted ? PulseTheme.volt.opacity(0.14) : Color.black.opacity(0.28),
                        radius: highlighted ? 16 : 10,
                        y: highlighted ? 4 : 6
                    )
            }
    }
}

extension View {
    func pulseCard(highlighted: Bool = false, muted: Bool = false, cornerRadius: CGFloat = 20) -> some View {
        modifier(PulseCardModifier(highlighted: highlighted, muted: muted, cornerRadius: cornerRadius))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
