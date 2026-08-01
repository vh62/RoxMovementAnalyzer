import Foundation

/// Maps a recorded session's pose frames onto video playback time so the overlay can be replayed
/// in sync with the recording.
///
/// Pose timestamps come from the capture session clock and do not share an origin with the movie
/// file's timeline (which starts at its first written sample). Rather than assume they line up,
/// the timeline anchors on the first pose frame captured after recording started and stores every
/// frame as an offset from it.
struct SessionTimeline: Equatable {
    /// A frame paired with its position in the recording, and the valid-rep tally as of that moment.
    struct Entry: Equatable {
        let frame: PoseFrame
        let seconds: Double
        let validReps: Int
        /// When the most recent rep was counted, used to hold the "rep counted" callout on screen
        /// for a readable moment rather than a single frame.
        let lastRepCountedAt: Double?

        /// Whether a rep was counted recently enough to still be worth calling out.
        func isCelebratingRep(at seconds: Double, window: Double = 0.8) -> Bool {
            guard let lastRepCountedAt else { return false }
            return seconds - lastRepCountedAt <= window
        }
    }

    /// How far playback may run past a frame before it is considered stale. Beyond this the overlay
    /// hides rather than freezing on a pose the athlete has already left.
    static let stalenessWindow: Double = 0.25

    private(set) var entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    /// Length of the tracked portion of the session, in seconds.
    var duration: Double { entries.last?.seconds ?? 0 }

    /// Total valid reps counted across the whole session.
    var totalValidReps: Int { entries.last?.validReps ?? 0 }

    /// Builds a timeline from frames captured in chronological order.
    ///
    /// - Parameters:
    ///   - frames: pose frames in capture order.
    ///   - station: drives whether rep counting applies (currently Wall Balls only).
    init(frames: [PoseFrame], station: HyroxStation) {
        guard let firstTimestamp = frames.first?.timestampInMilliseconds else {
            self.entries = []
            return
        }

        let countsReps = station == .wallBalls
        var counter = WallBallRepCounter()
        var previousReps = 0
        var lastRepCountedAt: Double?

        self.entries = frames.map { frame in
            let seconds = Double(frame.timestampInMilliseconds - firstTimestamp) / 1000

            if countsReps {
                counter.process(frame)
                if counter.result.validReps > previousReps {
                    previousReps = counter.result.validReps
                    lastRepCountedAt = seconds
                }
            }

            return Entry(
                frame: frame,
                seconds: seconds,
                validReps: counter.result.validReps,
                lastRepCountedAt: lastRepCountedAt
            )
        }
    }

    /// The entry in effect at `seconds` — the nearest preceding frame, or nil when playback is
    /// before the first frame or has run past the last one by more than `stalenessWindow`.
    func entry(at seconds: Double) -> Entry? {
        guard let index = indexOfEntry(at: seconds) else { return nil }
        let entry = entries[index]
        guard seconds - entry.seconds <= Self.stalenessWindow else { return nil }
        return entry
    }

    /// The pose to draw at `seconds`, if any.
    func frame(at seconds: Double) -> PoseFrame? {
        entry(at: seconds)?.frame
    }

    /// Valid reps counted so far at `seconds`. Unlike `frame(at:)` this ignores the staleness
    /// window — a tracking dropout should not make the running count fall back to zero.
    func validReps(at seconds: Double) -> Int {
        guard let index = indexOfEntry(at: seconds) else { return 0 }
        return entries[index].validReps
    }

    /// Index of the last entry at or before `seconds`, via binary search over the sorted entries.
    private func indexOfEntry(at seconds: Double) -> Int? {
        guard !entries.isEmpty, seconds >= entries[0].seconds else { return nil }

        var low = 0
        var high = entries.count - 1

        while low < high {
            let mid = (low + high + 1) / 2
            if entries[mid].seconds <= seconds {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return low
    }
}
