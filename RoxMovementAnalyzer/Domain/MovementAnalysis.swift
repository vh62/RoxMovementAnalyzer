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
    /// Always true for rowing: every stroke counts and the erg logs the metres either way. Wall
    /// balls is the station with a rule a movement can fail — the hips break parallel or the rep is
    /// a no-rep — so this is the only station where it can be false.
    let counted: Bool
    /// Every fault on this movement, in the station's own priority order.
    let faults: [FaultCallout]
    /// The moment worth jumping the replay to. The station picks it: for a wall ball that is the
    /// release, for a stroke the finish — in both cases where the error is visible, which is not
    /// necessarily where the record ends.
    let calloutSeconds: Double

    /// The fault worth showing, already prioritised by the station's own ordering.
    var fault: FaultCallout? { faults.first }
}

/// A session's movement analysis, as produced by whichever station was recorded.
enum StationAnalysis: Equatable {
    case wallBalls([WallBallRep])
    case rowing([RowStroke])
    /// No analyzer exists for this station yet. The session still has frames and tracking coverage;
    /// nothing is counted and nothing is faulted.
    case unsupported

    static func analyze(station: HyroxStation, frames: [PoseFrame]) -> StationAnalysis {
        switch station {
        case .wallBalls: .wallBalls(WallBallRepAnalyzer.analyze(frames: frames))
        case .rowing: .rowing(RowStrokeAnalyzer.analyze(frames: frames))
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
        case .unsupported:
            []
        }
    }
}

extension HyroxStation {
    /// Whether a movement analyzer exists for this station. Everything else here follows from it.
    var hasMovementAnalysis: Bool {
        self == .wallBalls || self == .rowing
    }

    /// Whether analysis needs the whole athlete in frame, gating whether the skeleton is drawn.
    /// Both analysed stations measure joint relationships that a partial body cannot support.
    var requiresFullBody: Bool { hasMovementAnalysis }

    /// The depth guide draws the hip-versus-knee parallel line. That is a wall-ball judging device
    /// and means nothing on an erg, where the athlete is seated throughout.
    var showsDepthGuide: Bool { self == .wallBalls }

    /// What the running tally is counting.
    ///
    /// Deliberately not one shared word. A wall-ball rep is *valid* or it is a no-rep — the hips
    /// broke parallel or they did not — whereas every rowing stroke counts and the erg logs the
    /// metres either way. Calling a stroke a "valid rep" would import a judging concept that rowing
    /// does not have.
    var countNoun: String {
        switch self {
        case .wallBalls: "VALID REPS"
        case .rowing: "STROKES"
        default: "TRACKED"
        }
    }

    /// Whether a movement can fail to count. Only wall balls has a no-rep, which is why it is the
    /// only station that calls one aloud.
    var hasNoRepRule: Bool { self == .wallBalls }
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
    case unsupported

    init(station: HyroxStation) {
        switch station {
        case .wallBalls: self = .wallBalls(WallBallRepAnalyzer())
        case .rowing: self = .rowing(RowStrokeAnalyzer())
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
        case .unsupported:
            break
        }
    }

    /// The tally as of right now — valid reps, or strokes.
    var count: Int {
        switch self {
        case .wallBalls(let analyzer): analyzer.validRepsSoFar
        case .rowing(let analyzer): analyzer.strokesSoFar
        case .unsupported: 0
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
        case .unsupported:
            0
        }
    }

    /// Records finished so far. Wall balls closes a rep at the catch that follows the throw; rowing
    /// closes a stroke at the following catch, so both lag the tally.
    var completedMovements: [CountedMovement] {
        analysis.countedMovements
    }

    var analysis: StationAnalysis {
        switch self {
        case .wallBalls(let analyzer): .wallBalls(analyzer.completedReps)
        case .rowing(let analyzer): .rowing(analyzer.completedStrokes)
        case .unsupported: .unsupported
        }
    }
}
