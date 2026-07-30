import Foundation

/// Counts wall-ball squat reps from pose frames and flags which reached legal depth.
///
/// It is stateful: feed frames one at a time with `process(_:)` for live counting, or use
/// `evaluate(frames:)` for a one-shot pass over a recorded session. Both share the same logic, so a
/// live count and an end-of-session count agree.
///
/// Each descent from standing is an attempt; the attempt becomes a *valid* rep the moment the hip
/// drops below the knee (proper HYROX wall-ball depth), so the count reflects depth as it happens
/// rather than waiting for the stand-up. Standing back up simply arms the next rep.
///
/// Depth is judged with `delta = hipCenter.y - kneeCenter.y` in normalized image coordinates
/// (y increases downward), so:
///   - standing  → hips above knees → delta clearly negative
///   - at depth  → hip at/below knee → delta >= 0
///
/// Thresholds are approximate and framing-dependent; keep the full body in view. A side or front-on
/// angle both work as long as both hips and both knees stay tracked.
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
    var standingDelta = -0.12
    /// Hips dropped past this (delta above this) counts as having started a squat attempt.
    var descentDelta = -0.06
    /// Hip at or below the knee — legal depth.
    var validDepthDelta = 0.0

    private enum Phase { case up, down }

    private var phase: Phase = .up
    private var reachedDepthThisRep = false
    private var validReps = 0
    private var attempts = 0
    private var deepestDelta: Double?

    var result: Result {
        Result(validReps: validReps, attempts: attempts, deepestDelta: deepestDelta)
    }

    /// Updates the running counts from a single frame. Frames without at least one hip and one knee
    /// tracked are ignored so a dropped landmark does not register as movement. Using whichever side
    /// is visible keeps counting working from a side view.
    mutating func process(_ frame: PoseFrame) {
        guard let hipY = frame.visibleAverageY(.leftHip, .rightHip),
              let kneeY = frame.visibleAverageY(.leftKnee, .rightKnee) else { return }

        let delta = hipY - kneeY
        deepestDelta = max(deepestDelta ?? delta, delta)

        switch phase {
        case .up:
            if delta > descentDelta {
                phase = .down
                attempts += 1
                reachedDepthThisRep = false
            }
        case .down:
            // Count the rep the instant legal depth is reached, not on the way back up. Guarded so a
            // single squat counts once even if the hips hover around the line.
            if delta >= validDepthDelta, !reachedDepthThisRep {
                reachedDepthThisRep = true
                validReps += 1
            }
            if delta < standingDelta {
                phase = .up
            }
        }
    }

    /// One-shot evaluation over a full recording, independent of any prior state.
    func evaluate(frames: [PoseFrame]) -> Result {
        var counter = WallBallRepCounter()
        counter.standingDelta = standingDelta
        counter.descentDelta = descentDelta
        counter.validDepthDelta = validDepthDelta
        for frame in frames {
            counter.process(frame)
        }
        return counter.result
    }
}
