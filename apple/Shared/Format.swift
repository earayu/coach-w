import Foundation

/// Display formatting for metrics. Missing values show as a dash, never as zero.
enum Format {
    static let dash = "--"

    static func value(_ value: Double?, unit: String, digits: Int = 0) -> String {
        guard let value else { return "\(dash) \(unit)" }
        return "\(number(value, digits: digits)) \(unit)"
    }

    static func number(_ value: Double?, digits: Int = 0) -> String {
        guard let value else { return dash }
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "0:00" }
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func distanceNumber(_ meters: Double?) -> String {
        guard let meters else { return dash }
        return (meters / 1000).formatted(.number.precision(.fractionLength(2)))
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters else { return "\(dash) km" }
        return "\(distanceNumber(meters)) km"
    }

    static func speedNumber(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond else { return dash }
        return (metersPerSecond * 3.6).formatted(.number.precision(.fractionLength(1)))
    }

    static func speed(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond else { return "\(dash) km/h" }
        return "\(speedNumber(metersPerSecond)) km/h"
    }

    /// Minutes and seconds per kilometre (value only), from speed in m/s.
    static func paceNumber(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond, metersPerSecond > 0.3 else { return dash }
        let secondsPerKm = Int((1000 / metersPerSecond).rounded())
        return String(format: "%d'%02d\"", secondsPerKm / 60, secondsPerKm % 60)
    }

    /// Minutes and seconds per kilometre, from speed in m/s.
    static func pace(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond, metersPerSecond > 0.3 else { return "\(dash) /km" }
        return "\(paceNumber(metersPerSecond)) /km"
    }

    static func primarySpeedNumber(_ metersPerSecond: Double?, readsAsPace: Bool) -> String {
        readsAsPace ? paceNumber(metersPerSecond) : speedNumber(metersPerSecond)
    }

    static func primarySpeed(_ metersPerSecond: Double?, readsAsPace: Bool) -> String {
        readsAsPace ? pace(metersPerSecond) : speed(metersPerSecond)
    }
}
