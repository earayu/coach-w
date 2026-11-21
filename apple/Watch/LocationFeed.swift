import CoreLocation
import os

private let log = Logger(subsystem: "com.earayu.coachw.watch", category: "location")

/// GPS fixes during an outdoor workout, for the HealthKit route and the metrics frames.
///
/// Coordinates are health and privacy data (docs/spec.md 11): never logged, kept only in memory
/// on their way to the route builder and the next frame.
@MainActor
final class LocationFeed: NSObject, CLLocationManagerDelegate {
    /// Fixes less accurate than this are dropped: they would bend the route.
    nonisolated static let maxHorizontalAccuracy: CLLocationAccuracy = 50

    private let manager = CLLocationManager()
    private var onLocations: (@MainActor ([CLLocation]) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start(_ onLocations: @escaping @MainActor ([CLLocation]) -> Void) {
        self.onLocations = onLocations
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: log.info("location not authorised: workout runs without a route")
        default: break
        }
        // the running workout session keeps updates flowing in the background
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        onLocations = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let usable = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Self.maxHorizontalAccuracy
        }
        guard !usable.isEmpty else { return }
        Task { @MainActor in self.onLocations?(usable) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location failed: \(error.localizedDescription, privacy: .public)")
    }
}
