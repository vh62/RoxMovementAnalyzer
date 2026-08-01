import Foundation

/// Counts wall-ball squat reps and flags which reached legal depth.
///
/// This is a thin wrapper over `WallBallRepAnalyzer` so there is exactly one rep state machine in
/// the app — the counter is the "how many reps" view of it, while the analyzer additionally
/// segments each rep and measures movement inefficiencies.
///
/// It stays stateful and incremental: feed frames one at a time with `process(_:)` for live
/// counting, or use `evaluate(frames:)` for a one-shot pass over a recording. Each descent from
/// standing is an attempt; the attempt becomes a *valid* rep the moment the hip drops below the
/// knee, so the count reflects depth as it happens rather than waiting for the stand-up.
struct WallBallRepCounter {
    struct Result: Equatable {
        let validReps: Int
        let attempts: Int
        /// Deepest squat observed as `hip.y - knee.y` (higher = deeper). Nil if never tracked.
        let deepestDelta: Double?

        var depthAccuracy: Double {
            guard attempts > 0 else { return 0 }
            return Double(validReps) / Double(attempts)
        }
    }

    /// Hips this far above knees (delta below this) counts as standing/top of the rep.
    var standingDelta: Double {
        get { analyzer.thresholds.standingDelta }
        set { analyzer.thresholds.standingDelta = newValue }
    }

    /// Hips dropped past this (delta above this) counts as having started a squat attempt.
    var descentDelta: Double {
        get { analyzer.thresholds.descentDelta }
        set { analyzer.thresholds.descentDelta = newValue }
    }

    /// Hip at or below the knee — legal depth.
    var validDepthDelta: Double {
        get { analyzer.thresholds.validDepthDelta }
        set { analyzer.thresholds.validDepthDelta = newValue }
    }

    private var analyzer = WallBallRepAnalyzer()

    var result: Result {
        Result(
            validReps: analyzer.validRepsSoFar,
            attempts: analyzer.attempts,
            deepestDelta: analyzer.deepestDelta
        )
    }

    /// Updates the running counts from a single frame. Frames without at least one hip and one knee
    /// tracked are ignored so a dropped landmark does not register as movement.
    mutating func process(_ frame: PoseFrame) {
        analyzer.process(frame)
    }

    /// One-shot evaluation over a full recording, independent of any prior state.
    func evaluate(frames: [PoseFrame]) -> Result {
        var counter = WallBallRepCounter()
        counter.analyzer.thresholds = analyzer.thresholds
        for frame in frames {
            counter.process(frame)
        }
        return counter.result
    }
}
