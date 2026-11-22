import CoachKit
import CoreLocation
import Foundation
import MapKit
import os

private let log = Logger(subsystem: "com.earayu.coachw", category: "places")

/// Answers the coach's `look_around` tool on the phone with Apple Maps (spec 7.5).
///
/// The lookup runs here: the coach gets place names, distances and directions, not coordinates.
/// Apple Maps in mainland China uses AutoNavi (Gaode) data, so no map key or second vendor is
/// needed. Never logs coordinates or place names.
@MainActor
final class PlaceFinder: NSObject {
    static let shared = PlaceFinder()

    /// The watch's latest GPS fix (WGS-84), if any; preferred over the phone's own location.
    var watchFix: (@MainActor () -> CLLocation?)?

    private let manager = CLLocationManager()
    private var pending: [CheckedContinuation<CLLocation?, Never>] = []

    nonisolated static let searchRadius: CLLocationDistance = 1500
    nonisolated static let maxResults = 5
    /// A watch fix older than this is not where the athlete is any more.
    static let fixMaxAge: TimeInterval = 120

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Asks once at launch; without permission the coach just cannot look around.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// JSON for the coach: `{available, here?, places: [{name, category?, distance_m, direction}], reason?}`.
    func lookAround(query: String) async -> String {
        guard let here = await currentLocation() else {
            return Self.json(["available": false, "reason": "no location (no GPS fix or no permission)"])
        }
        async let address = Self.address(of: here)
        async let found = Self.places(near: here, query: query)
        var result: [String: Any] = ["available": true, "places": await found.map(\.json)]
        if let address = await address { result["here"] = address }
        if !query.isEmpty { result["query"] = query }
        return Self.json(result)
    }

    private func currentLocation() async -> CLLocation? {
        if let fix = watchFix?(), -fix.timestamp.timeIntervalSinceNow < Self.fixMaxAge { return fix }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return nil
        }
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            if pending.count == 1 { manager.requestLocation() }
        }
    }

    private func resolve(_ location: CLLocation?) {
        let waiting = pending
        pending = []
        for continuation in waiting { continuation.resume(returning: location) }
    }

    private nonisolated static func address(of location: CLLocation) async -> String? {
        do {
            guard let mark = try await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            let parts = [mark.locality, mark.subLocality, mark.thoroughfare, mark.name]
            var seen: [String] = []
            for part in parts.compactMap({ $0 }) where !part.isEmpty && !seen.contains(part) { seen.append(part) }
            return seen.isEmpty ? nil : seen.joined(separator: " ")
        } catch {
            log.info("reverse geocoding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func places(near location: CLLocation, query: String) async -> [Place] {
        let region = MKCoordinateRegion(
            center: location.coordinate, latitudinalMeters: searchRadius * 2, longitudinalMeters: searchRadius * 2
        )
        do {
            let response: MKLocalSearch.Response
            if query.isEmpty {
                let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: searchRadius)
                response = try await MKLocalSearch(request: request).start()
            } else {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = region
                request.resultTypes = .pointOfInterest
                response = try await MKLocalSearch(request: request).start()
            }
            return response.mapItems
                .compactMap { item -> Place? in
                    guard let name = item.name, let spot = item.placemark.location else { return nil }
                    return Place(
                        name: name,
                        category: item.pointOfInterestCategory?.rawValue,
                        distanceM: Int(location.distance(from: spot).rounded()),
                        direction: Compass.direction(
                            fromLat: location.coordinate.latitude, lon: location.coordinate.longitude,
                            toLat: spot.coordinate.latitude, lon: spot.coordinate.longitude
                        )
                    )
                }
                .sorted { $0.distanceM < $1.distanceM }
                .prefix(maxResults)
                .map { $0 }
        } catch {
            log.info("place search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"available":false,"reason":"encoding failed"}"# }
        return text
    }
}

extension PlaceFinder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.resolve(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.info("phone location failed: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in self.resolve(nil) }
    }
}

struct Place: Sendable {
    let name: String
    let category: String?
    let distanceM: Int
    let direction: String

    var json: [String: Any] {
        var out: [String: Any] = ["name": name, "distance_m": distanceM, "direction": direction]
        if let category { out["category"] = category }
        return out
    }
}

extension MetricsFrame {
    /// The watch's GPS fix in this frame, timed by the watch.
    var location: CLLocation? {
        guard let lat, let lon else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altM ?? 0,
            horizontalAccuracy: 10,
            verticalAccuracy: altM == nil ? -1 : 10,
            timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        )
    }
}
