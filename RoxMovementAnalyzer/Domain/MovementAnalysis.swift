import Foundation

/// What the shared surfaces — the live cue, the replay banner, the burned-in overlay, the scorecard
/// — need from a fault, flattened off whichever station's enum produced it.
///
/// A flat value type rather than a protocol. The station enums stay concrete and exhaustively
/// switchable inside the domain, which is where that earns its keep, and nothing downstream has to
/// reason about existentials in order to draw a red banner.
struct FaultCallout: Equatable {
    let title: String
    let liveMessage: String
    let coachingDetail: String
    let severity: AlertSeverity
    /// Stable per fault kind, so alerts can be aggregated one-per-kind without knowing the station.
    let kindIdentifier: String
}

/// One counted movement — a wall-ball rep or a rowing stroke — reduced to what the replay scrubber
/// and the fault banner need.
///
/// The concrete record stays reachable through `StationAnalysis` for the per-station tuning
/// readouts, which are deliberately station-specific.
struct CountedMovement: Equatable, Identifiable {
    let id: Int
    let index: Int
    let startSeconds: Double
    let endSeconds: Double
    /// Whether it counted toward the tally.
    ///
    /// Always true for both ergs: every stroke and every pull counts, and the machine logs the metres
    /// either way. The two judged stations are where this can be false, and they fail differently:
    /// a wall ball has exactly one rule — the hips break parallel or they do not — while a burpee
    /// broad jump has four, so `BurpeeRep.isValid` is simply whether any fault fired.
    let counted: Bool
    /// Every fault on this movement, in the station's own priority order.
    let faults: [FaultCallout]
    /// The moment worth jumping the replay to. The station picks it: for a wall ball that is the
    /// release, for a stroke or a pull the finish — in every case where the error is visible, which is
    /// not necessarily where the record ends.
    let calloutSeconds: Double

    /// The fault worth showing, already prioritised by the station's own ordering.
    var fault: FaultCallout? { faults.first }
}

/// A session's movement analysis, as produced by whichever station was recorded.
enum StationAnalysis: Equatable {
    case wallBalls([WallBallRep])
    case rowing([RowStroke])
    case skiErg([SkiPull])
    case burpees([BurpeeRep])
    /// No analyzer exists for this station yet. The session still has frames and tracking coverage;
    /// nothing is counted and nothing is faulted.
    case unsupported

    static func analyze(station: HyroxStation, frames: [PoseFrame]) -> StationAnalysis {
        switch station {
        case .wallBalls: .wallBalls(WallBallRepAnalyzer.analyze(frames: frames))
        case .rowing: .rowing(RowStrokeAnalyzer.analyze(frames: frames))
        case .skiErg: .skiErg(SkiPullAnalyzer.analyze(frames: frames))
        case .burpeeBroadJumps: .burpees(BurpeeRepAnalyzer.analyze(frames: frames))
        default: .unsupported
        }
    }

    var countedMovements: [CountedMovement] {
        switch self {
        case .wallBalls(let reps):
            reps.map {
                CountedMovement(
                    id: $0.index, index: $0.index,
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    counted: $0.reachedDepth,
                    faults: $0.faults.map(\.callout),
                    calloutSeconds: $0.releaseSeconds ?? $0.endSeconds
                )
            }
        case .rowing(let strokes):
            strokes.map {
                CountedMovement(
                    id: $0.index, index: $0.index,
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    counted: true,
                    faults: $0.faults.map(\.callout),
                    calloutSeconds: $0.finishSeconds
                )
            }
        case .skiErg(let pulls):
            pulls.map {
                CountedMovement(
                    id: $0.index, index: $0.index,
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    counted: true,
                    faults: $0.faults.map(\.callout),
                    calloutSeconds: $0.finishSeconds
                )
            }
        case .burpees(let reps):
            reps.map {
                CountedMovement(
                    id: $0.index, index: $0.index,
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    counted: $0.isValid,
                    faults: $0.faults.map(\.callout),
                    // The take-off. Chest height above the feet peaks at full extension, which for a
                    // burpee broad jump is the moment the athlete leaves the ground — and it sits
                    // between the two corridor moments, so it is the frame worth jumping to whichever
                    // rule fired.
                    calloutSeconds: $0.topSeconds
                )
            }
        case .unsupported:
            []
        }
    }
}

extension HyroxStation {
    /// Whether a movement analyzer exists for this station. Everything else here follows from it.
    var hasMovementAnalysis: Bool {
        switch self {
        case .wallBalls, .rowing, .skiErg, .burpeeBroadJumps: true
        default: false
        }
    }

    /// Whether analysis needs the whole athlete in frame, gating whether the skeleton is drawn.
    /// Every analysed station measures joint relationships that a partial body cannot support.
    var requiresFullBody: Bool { hasMovementAnalysis }

    /// The depth guide draws the hip-versus-knee parallel line. That is a wall-ball judging device
    /// and means nothing on an erg, where the athlete is seated throughout.
    var showsDepthGuide: Bool { self == .wallBalls }

    /// Whether the overlay labels joint angles — back, hinge, knees, elbows.
    ///
    /// Off for burpee broad jumps, and that follows from what §8.4 actually judges. Every other
    /// analysed station has faults phrased in joints: the hinge and the knee carry both erg's power,
    /// and the squat is judged on hip versus knee. A burpee is judged on **where the hands and feet
    /// are relative to each other**, and not one of its three rules reads a joint angle. Labelling
    /// six of them would put the app's most prominent numbers on the only quantities that cannot
    /// change the verdict.
    var showsJointAngles: Bool { self != .burpeeBroadJumps }

    /// What the running tally is counting, or **nil for a station that should not show one**.
    ///
    /// Wall balls and burpee broad jumps count because the tally is the judged quantity: a rep is
    /// valid or it is a no-rep, and nothing else in the athlete's view is keeping score.
    ///
    /// Both ergs are nil, and the reason is the machine. A RowErg or SkiErg monitor is a foot from the
    /// athlete's face already showing strokes, split and metres — from its own sensor on its own
    /// flywheel, which is a far better counter than pose estimation will ever be. Putting a second,
    /// worse number next to it invites the athlete to notice when the two disagree, and the app would
    /// be the one that was wrong. The ergs' analysis is about *how* each stroke was made, which is the
    /// thing the monitor cannot tell them.
    var countNoun: String? {
        switch self {
        case .wallBalls, .burpeeBroadJumps: "VALID REPS"
        default: nil
        }
    }

    /// Whether a movement can fail to count, and so whether a no-rep is called aloud.
    ///
    /// Neither erg has a judging concept to import — the machine logs the metres either way. Wall
    /// balls and burpee broad jumps both do, which is why both speak.
    var hasNoRepRule: Bool { self == .wallBalls || self == .burpeeBroadJumps }

    /// What is said aloud when a rep does not count.
    ///
    /// A correction where there is only one thing to correct, and a plain verdict where there is not:
    /// a wall ball fails one way, so "squat lower" is always the right instruction, while a burpee
    /// broad jump can fail four different rules and naming the wrong one mid-set would be worse than
    /// naming none. Which rule it was is on screen. Short on purpose either way — this lands while the
    /// athlete is already moving into the next rep.
    var noRepPhrase: String {
        switch self {
        case .wallBalls: "Squat lower"
        default: "No rep"
        }
    }
}

extension WallBallFault {
    var callout: FaultCallout {
        FaultCallout(
            title: title,
            liveMessage: liveMessage,
            coachingDetail: coachingDetail,
            severity: severity,
            kindIdentifier: kind.rawValue
        )
    }
}

extension SkiFault {
    var callout: FaultCallout {
        FaultCallout(
            title: title,
            liveMessage: liveMessage,
            coachingDetail: coachingDetail,
            severity: severity,
            kindIdentifier: kind.rawValue
        )
    }
}

extension BurpeeFault {
    var callout: FaultCallout {
        FaultCallout(
            title: title,
            liveMessage: liveMessage,
            coachingDetail: coachingDetail,
            severity: severity,
            kindIdentifier: kind.rawValue
        )
    }
}

extension RowingFault {
    var callout: FaultCallout {
        FaultCallout(
            title: title,
            liveMessage: liveMessage,
            coachingDetail: coachingDetail,
            severity: severity,
            kindIdentifier: kind.rawValue
        )
    }
}

/// Runs a station's analyzer incrementally to keep a live tally.
///
/// The running count cannot be derived from the completed records: a wall-ball rep is counted the
/// instant the hips break parallel, roughly a second before its record closes at the catch, and a
/// rowing stroke is counted at its opening catch while its record is not complete until the next
/// one. Both are what a judge or a coach would count at the moment they see it, so both need the
/// stateful analyzer rather than a tally of finished records.
enum LiveMovementCounter {
    case wallBalls(WallBallRepAnalyzer)
    case rowing(RowStrokeAnalyzer)
    case skiErg(SkiPullAnalyzer)
    case burpees(BurpeeRepAnalyzer)
    case unsupported

    init(station: HyroxStation) {
        switch station {
        case .wallBalls: self = .wallBalls(WallBallRepAnalyzer())
        case .rowing: self = .rowing(RowStrokeAnalyzer())
        case .skiErg: self = .skiErg(SkiPullAnalyzer())
        case .burpeeBroadJumps: self = .burpees(BurpeeRepAnalyzer())
        default: self = .unsupported
        }
    }

    mutating func process(_ frame: PoseFrame) {
        switch self {
        case .wallBalls(var analyzer):
            analyzer.process(frame)
            self = .wallBalls(analyzer)
        case .rowing(var analyzer):
            analyzer.process(frame)
            self = .rowing(analyzer)
        case .skiErg(var analyzer):
            analyzer.process(frame)
            self = .skiErg(analyzer)
        case .burpees(var analyzer):
            analyzer.process(frame)
            self = .burpees(analyzer)
        case .unsupported:
            break
        }
    }

    /// The tally as of right now — valid reps, strokes, or pulls.
    var count: Int {
        switch self {
        case .wallBalls(let analyzer): analyzer.validRepsSoFar
        case .rowing(let analyzer): analyzer.strokesSoFar
        case .skiErg(let analyzer): analyzer.pullsSoFar
        case .burpees(let analyzer): analyzer.validRepsSoFar
        case .unsupported: 0
        }
    }

    /// The side the overlay should draw, or nil to draw both.
    ///
    /// Every analysed station is filmed in profile and every one of them answers this the same way;
    /// burpees have no side vote yet, so they draw both sides as before.
    var profileSide: BodySide? {
        switch self {
        case .wallBalls(let analyzer): analyzer.profileSide
        case .rowing(let analyzer): analyzer.profileSide
        case .skiErg(let analyzer): analyzer.profileSide
        default: nil
        }
    }

    /// Movements that have been **resolved** — counted, or finished without counting.
    ///
    /// Deliberately not the analyzer's raw attempt tally. That increments the instant a descent
    /// begins, so a squat still on the way down would sit in the denominator as though it had
    /// already been missed: 0/1 during the first rep, 1/2 during the second. The athlete has not
    /// missed anything yet, and the badge should not say they have.
    ///
    /// A rep joins the denominator when it is counted (at depth, where a judge would call it) or
    /// when it closes having never reached depth. So a set with one missed rep reads 5/6, and a
    /// rep in progress does not move the number at all.
    var attempts: Int {
        switch self {
        case .wallBalls(let analyzer):
            analyzer.validRepsSoFar + analyzer.completedReps.filter { !$0.reachedDepth }.count
        case .rowing(let analyzer):
            analyzer.strokesSoFar
        case .skiErg(let analyzer):
            analyzer.pullsSoFar
        case .burpees(let analyzer):
            // Every closed rep, valid or not. Unlike wall balls there is no mid-rep moment where a
            // burpee becomes valid — rule 6 is read at the very end — so a rep joins the numerator
            // and the denominator together, when it closes. The badge lags by one rep and never
            // shows a rep as missed while it is still being performed.
            analyzer.completedReps.count
        case .unsupported:
            0
        }
    }

    /// Records finished so far. Wall balls closes a rep at the catch that follows the throw; both ergs
    /// close a movement at the following catch, so all three lag the tally.
    var completedMovements: [CountedMovement] {
        analysis.countedMovements
    }

    var analysis: StationAnalysis {
        switch self {
        case .wallBalls(let analyzer): .wallBalls(analyzer.completedReps)
        case .rowing(let analyzer): .rowing(analyzer.completedStrokes)
        case .skiErg(let analyzer): .skiErg(analyzer.completedPulls)
        case .burpees(let analyzer): .burpees(analyzer.completedReps)
        case .unsupported: .unsupported
        }
    }
}
