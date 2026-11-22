import CoachKit
import SwiftUI

/// Design tokens shared across iOS and watchOS, after the Apple Workout app: a black canvas,
/// system dark-mode colours, rounded numerals, and one colour per kind of metric.
enum Theme {
    static let canvas = Color.black
    /// Grouped-row and tile surface (systemGray6 in dark mode).
    static let surface = Color(hex: 0x1C1C1E)

    /// The single accent: Fitness exercise-ring green.
    static let accent = Color(hex: 0xA6FF00)

    // System dark-mode colours
    static let yellow = Color(hex: 0xFFD60A)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    static let pink = Color(hex: 0xFF375F)
    static let green = Color(hex: 0x30D158)
    static let teal = Color(hex: 0x64D2FF)
    static let blue = Color(hex: 0x0A84FF)

    // Metric colours, as on the Workout app
    static let time = yellow
    static let heart = pink
    static let pace = teal
    static let energy = pink

    static let secondaryText = Color(white: 0.6)
    static let tertiaryText = Color(white: 0.4)

    /// Large rounded numerals used for every live metric.
    static func numeral(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
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

    var badge: String { "\(code) \(title)" }

    var color: Color {
        switch self {
        case .warmup: Theme.blue
        case .fatBurn: Theme.green
        case .aerobic: Theme.yellow
        case .threshold: Theme.orange
        case .maximum: Theme.red
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
}

extension CuePriority {
    var accentColor: Color {
        switch self {
        case .emergency: Theme.red
        case .correction: Theme.orange
        case .milestone: Theme.accent
        case .companion: Theme.teal
        }
    }

    var symbol: String {
        switch self {
        case .emergency: "exclamationmark.triangle.fill"
        case .correction: "waveform.path.ecg"
        case .milestone: "flag.checkered"
        case .companion: "bubble.left.fill"
        }
    }
}

/// One live metric in the Workout-app layout: a big rounded number with a small coloured unit.
struct MetricLine: View {
    let value: String
    let unit: String
    var color: Color = .white
    var unitColor: Color? = nil
    var size: CGFloat = 44
    var hasValue = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(Theme.numeral(size))
                .foregroundStyle(hasValue ? color : Theme.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.system(size: max(11, size * 0.32), weight: .semibold, design: .rounded))
                .foregroundStyle(unitColor ?? color)
                .textCase(.uppercase)
        }
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
