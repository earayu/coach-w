import Foundation

/// How the phone reads the latest frame between frames, and when the stream has stalled.
extension MetricsFrame {
    /// The watch sends a frame every second while running; silence longer than this is a broken link.
    public static let staleAfter: TimeInterval = 5

    /// Seconds since this frame reached the phone; nil when the phone did not stamp it.
    public func silence(at now: Date) -> TimeInterval? {
        phoneTs.map { max(0, now.timeIntervalSince1970 - Double($0) / 1000) }
    }

    /// Workout time to show at `now`. While running it keeps counting from when the frame arrived,
    /// so the clock does not freeze between frames or when the stream stalls: the watch session keeps
    /// timing either way.
    public func elapsed(at now: Date) -> Double {
        guard state == .running, let silence = silence(at: now) else { return elapsedS }
        return elapsedS + silence
    }

    /// The workout is running but no frame has arrived for longer than `staleAfter`.
    public func isStale(at now: Date) -> Bool {
        state == .running && (silence(at: now) ?? 0) > Self.staleAfter
    }

    /// Whether this frame is newer than `other`. Compares watch time rather than `seq`: a watch app
    /// that relaunches and recovers its workout numbers frames from 1 again.
    public func isNewer(than other: MetricsFrame?) -> Bool {
        guard let other else { return true }
        return ts > other.ts
    }
}
