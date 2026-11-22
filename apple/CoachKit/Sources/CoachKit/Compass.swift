import Foundation

/// "Where is it from here" in the eight Chinese compass words the coach speaks (spec 7.5).
public enum Compass {
    public static let directions = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]

    /// Initial great-circle bearing in degrees, 0 = north, clockwise.
    public static func bearing(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    public static func direction(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> String {
        let bearing = bearing(fromLat: lat1, lon: lon1, toLat: lat2, lon: lon2)
        return directions[Int((bearing + 22.5) / 45) % 8]
    }
}
