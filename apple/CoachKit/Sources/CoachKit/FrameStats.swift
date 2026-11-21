import Foundation

/// Receive-side statistics for the metrics stream, used to verify the data path (spec 14.2).
public struct FrameStats: Sendable, Equatable {
    public private(set) var received = 0
    /// Frames the sender numbered but that never arrived.
    public private(set) var missing = 0
    /// Frames that arrived with a seq at or below one already seen.
    public private(set) var outOfOrder = 0
    /// Mean watch-clock interval between consecutive frames, seconds.
    public private(set) var meanInterval: Double?
    /// Latest phone-minus-watch timestamp difference, milliseconds. Includes clock skew.
    public private(set) var lastDelayMs: Int64?

    private var lastSeq: Int?
    private var lastTs: Int64?
    private var intervalSum = 0.0
    private var intervalCount = 0

    public init() {}

    public mutating func record(_ frame: MetricsFrame) {
        received += 1
        if let phoneTs = frame.phoneTs { lastDelayMs = phoneTs - frame.ts }
        if let lastSeq, frame.seq <= lastSeq {
            outOfOrder += 1
            return
        }
        if let lastSeq { missing += frame.seq - lastSeq - 1 }
        if let lastTs {
            intervalSum += Double(frame.ts - lastTs) / 1000
            intervalCount += 1
            meanInterval = intervalSum / Double(intervalCount)
        }
        lastSeq = frame.seq
        lastTs = frame.ts
    }
}
