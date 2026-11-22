import CoachKit
import Testing

@Suite struct CompassTests {
    // the Bund (31.2400, 121.4900) as "here"
    @Test(arguments: [
        (31.2500, 121.4900, "北"),
        (31.2400, 121.5000, "东"),
        (31.2300, 121.4900, "南"),
        (31.2400, 121.4800, "西"),
        (31.2470, 121.4980, "东北"),
        (31.2330, 121.4820, "西南"),
    ])
    func eightWayDirection(lat: Double, lon: Double, expected: String) {
        #expect(Compass.direction(fromLat: 31.24, lon: 121.49, toLat: lat, lon: lon) == expected)
    }

    @Test func bearingIsClockwiseFromNorth() {
        #expect(abs(Compass.bearing(fromLat: 0, lon: 0, toLat: 0, lon: 1) - 90) < 0.01)
    }
}
