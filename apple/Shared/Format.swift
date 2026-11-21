import Foundation

/// Display formatting for metrics. Missing values show as a dash, never as zero.
enum Format {
    static let dash = "--"

    static func value(_ value: Double?, unit: String, digits: Int = 0) -> String {
        guard let value else { return "\(dash) \(unit)" }
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(unit)"
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters else { return "\(dash) km" }
        return "\((meters / 1000).formatted(.number.precision(.fractionLength(2)))) km"
    }

    /// Minutes and seconds per kilometre, from speed in m/s.
    static func pace(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond, metersPerSecond > 0.3 else { return "\(dash) /km" }
        let secondsPerKm = Int((1000 / metersPerSecond).rounded())
        return String(format: "%d'%02d\" /km", secondsPerKm / 60, secondsPerKm % 60)
    }
}
