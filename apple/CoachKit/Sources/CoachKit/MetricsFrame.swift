import Foundation

/// Workout state carried by every metrics frame (docs/spec.md 6.3).
public enum WorkoutState: String, Codable, Sendable {
    case running
    case paused
    case ended
}

/// One frame of live workout metrics, wire protocol v1 (docs/spec.md 6.3).
///
/// Optional fields mean "not measured this time", never zero.
public struct MetricsFrame: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public var v: Int
    public var seq: Int
    /// Watch time, Unix milliseconds.
    public var ts: Int64
    /// Set by the iPhone when it forwards the frame, Unix milliseconds.
    public var phoneTs: Int64?
    /// HealthKit activity type name, e.g. "running".
    public var activity: String
    public var state: WorkoutState
    public var elapsedS: Double

    public var hrBpm: Double?
    public var distanceM: Double?
    public var speedMps: Double?
    public var cadenceSpm: Double?
    public var powerW: Double?
    public var strideM: Double?
    public var gctMs: Double?
    public var voCm: Double?
    public var energyKcal: Double?
    public var lat: Double?
    public var lon: Double?
    public var altM: Double?

    public init(
        seq: Int,
        ts: Int64,
        activity: String,
        state: WorkoutState,
        elapsedS: Double,
        phoneTs: Int64? = nil,
        hrBpm: Double? = nil,
        distanceM: Double? = nil,
        speedMps: Double? = nil,
        cadenceSpm: Double? = nil,
        powerW: Double? = nil,
        strideM: Double? = nil,
        gctMs: Double? = nil,
        voCm: Double? = nil,
        energyKcal: Double? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        altM: Double? = nil
    ) {
        self.v = Self.protocolVersion
        self.seq = seq
        self.ts = ts
        self.phoneTs = phoneTs
        self.activity = activity
        self.state = state
        self.elapsedS = elapsedS
        self.hrBpm = hrBpm
        self.distanceM = distanceM
        self.speedMps = speedMps
        self.cadenceSpm = cadenceSpm
        self.powerW = powerW
        self.strideM = strideM
        self.gctMs = gctMs
        self.voCm = voCm
        self.energyKcal = energyKcal
        self.lat = lat
        self.lon = lon
        self.altM = altM
    }

    enum CodingKeys: String, CodingKey {
        case v, seq, ts, activity, state, lat, lon
        case phoneTs = "phone_ts"
        case elapsedS = "elapsed_s"
        case hrBpm = "hr_bpm"
        case distanceM = "distance_m"
        case speedMps = "speed_mps"
        case cadenceSpm = "cadence_spm"
        case powerW = "power_w"
        case strideM = "stride_m"
        case gctMs = "gct_ms"
        case voCm = "vo_cm"
        case energyKcal = "energy_kcal"
        case altM = "alt_m"
    }
}

public enum ProtocolError: Error, Equatable {
    case unsupportedVersion(Int)
}

extension MetricsFrame {
    /// Decodes a frame and rejects versions this build does not understand.
    public static func decode(_ data: Data) throws -> MetricsFrame {
        let frame = try JSONDecoder().decode(MetricsFrame.self, from: data)
        guard frame.v == protocolVersion else { throw ProtocolError.unsupportedVersion(frame.v) }
        return frame
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
