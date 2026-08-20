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
        /// The station's running tally at this moment — valid reps, or strokes. What it counts is
        /// station-specific, which is why it is not named for either one.
        let count: Int
        /// Movements begun by this moment, counted or not. Equal to `count` where nothing can fail.
        let attempts: Int
        /// When the most recent movement was counted, used to hold the callout on screen for a
        /// readable moment rather than a single frame.
        let lastCountedAt: Double?

        /// Whether a movement was counted recently enough to still be worth calling out.
        func isCelebratingRep(at seconds: Double, window: Double = 0.8) -> Bool {
            guard let lastCountedAt else { return false }
            return seconds - lastCountedAt <= window
        }
    }

    /// How far playback may run past a frame before it is considered stale. Beyond this the overlay
    /// hides rather than freezing on a pose the athlete has already left.
    static let stalenessWindow: Double = 0.25

    /// How long a rep's fault stays called out on the overlay after the rep finishes.
    static let faultCalloutWindow: Double = 1.6

    private(set) var entries: [Entry]
    /// The session's movement analysis, `.unsupported` for stations without an analyzer.
    private(set) var analysis: StationAnalysis
    /// Station-neutral view of the analysis, for the scrubber and the fault banner.
    private(set) var movements: [CountedMovement]
    /// The side of the skeleton to draw, or nil to draw both. A session property, not a per-frame one:
    /// see `NearSideVote`.
    private(set) var profileSide: BodySide?

    var isEmpty: Bool { entries.isEmpty }

    /// Movements where at least one fault was detected.
    var faultedMovements: [CountedMovement] { movements.filter { $0.fault != nil } }

    /// Length of the tracked portion of the session, in seconds.
    var duration: Double { entries.last?.seconds ?? 0 }

    /// The station's total count across the whole session.
    var totalCount: Int { entries.last?.count ?? 0 }

    /// Builds a timeline from frames captured in chronological order.
    ///
    /// - Parameters:
    ///   - frames: pose frames in capture order.
    ///   - station: selects the analyzer, if the station has one.
    init(frames: [PoseFrame], station: HyroxStation) {
        guard let firstTimestamp = frames.first?.timestampInMilliseconds else {
            self.entries = []
            self.analysis = .unsupported
            self.movements = []
            self.profileSide = nil
            return
        }

        // The analyzers anchor on the same first frame, so their seconds share this timeline's origin.
        self.analysis = StationAnalysis.analyze(station: station, frames: frames)
        self.movements = analysis.countedMovements

        var counter = LiveMovementCounter(station: station)
        var previousCount = 0
        var lastCountedAt: Double?

        self.entries = frames.map { frame in
            let seconds = Double(frame.timestampInMilliseconds - firstTimestamp) / 1000

            counter.process(frame)
            if counter.count > previousCount {
                previousCount = counter.count
                lastCountedAt = seconds
            }

            return Entry(
                frame: frame,
                seconds: seconds,
                count: counter.count,
                attempts: counter.attempts,
                lastCountedAt: lastCountedAt
            )
        }

        // Read after the pass, not during it: the vote needs the whole session to settle, and a
        // half-formed answer would have the skeleton change sides partway through a replay.
        self.profileSide = counter.profileSide
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

    /// Movements begun by `seconds`, counted or not.
    func attempts(at seconds: Double) -> Int {
        guard let index = indexOfEntry(at: seconds) else { return 0 }
        return entries[index].attempts
    }

    /// The station's tally at `seconds`. Unlike `frame(at:)` this ignores the staleness window — a
    /// tracking dropout should not make the running count fall back to zero.
    func count(at seconds: Double) -> Int {
        guard let index = indexOfEntry(at: seconds) else { return 0 }
        return entries[index].count
    }

    /// The fault worth calling out at `seconds` — the most recently finished faulted movement, held
    /// on screen briefly so it is readable rather than flashing for a single frame.
    func activeFault(at seconds: Double) -> FaultCallout? {
        activeFaultedMovement(at: seconds)?.fault
    }

    func activeFaultedMovement(at seconds: Double) -> CountedMovement? {
        faultedMovements.last {
            seconds >= $0.endSeconds && seconds - $0.endSeconds <= Self.faultCalloutWindow
        }
    }

    /// The hand path to draw at `seconds`, tinted by how hard the athlete was pulling — empty for
    /// every station but the SkiErg, and for a pull whose wrists were not tracked.
    ///
    /// The station switch lives here rather than in the two renderers, the same seam `activeFault(at:)`
    /// uses to flatten each station's fault enum into a `FaultCallout`: a view should not have to know
    /// which station it is drawing.
    func powerTrail(at seconds: Double) -> [SkiPull.PowerSample] {
        guard case .skiErg(let pulls) = analysis, let movement = movement(at: seconds) else { return [] }
        return pulls.first { $0.index == movement.index }?.powerTrail ?? []
    }

    /// The movement in progress at `seconds`, for the tuning readout. Its `index` addresses the
    /// matching record in `analysis` when the readout needs the station's own measurements.
    func movement(at seconds: Double) -> CountedMovement? {
        movements.last { seconds >= $0.startSeconds && seconds <= $0.endSeconds + Self.faultCalloutWindow }
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
