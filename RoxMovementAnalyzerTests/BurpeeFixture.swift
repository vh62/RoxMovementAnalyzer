import Foundation
@testable import RoxMovementAnalyzer

/// A synthetic athlete performing burpee broad jumps, built **kinematically** — the same discipline as
/// `SkiFixture` and `RowingFixture`.
///
/// Each phase of a rep is a `Pose`: hip, trunk angle, ankle and wrist. The shoulder follows from the
/// hip and the trunk angle so the torso is exactly one link long in every frame, and the knee and
/// elbow are solved by circle intersection. Everything the analyzer measures — chest height above the
/// feet, hand height above the feet, toe against fingertip, wrist against front toe — therefore
/// *emerges* from where the limbs were put, rather than being written in.
///
/// **This is the first fixture to emit fingertips and toes.** `.leftIndex`/`.rightIndex` and
/// `.leftFootIndex`/`.rightFootIndex` are what rules 5 and 6 are judged on, and no other station reads
/// them.
///
/// **The athlete travels.** Every other fixture in this suite keeps the feet at a fixed x, which is
/// true of an erg and of wall balls and false of this station. `base` is the x of the planted hands at
/// a rep's bottom and advances by `jump` each rep, so the whole body walks across the frame the way it
/// does in real footage.
///
/// Side-on by default — near-side limbs tracked, far side occluded. Nose, ears, heels and toes are
/// emitted so `standingFacingVote` is exercised on the anatomy it actually votes on.
///
/// Emergent readings on the default geometry, worked through once so a change to the model is visible
/// rather than silent:
///   bottom — prone, shoulders level with the hips → chest height 0.06, hands down
///   tuck   — hips up, feet in, hands still planted → chest height 0.92, hands down
///   stand  — upright at full extension            → chest height 2.58, hands up
enum BurpeeFixture {
    static let fps = 30
    static var step: Int { 1000 / fps }

    static let floor = 0.90
    static let torso = 0.16
    static let thigh = 0.13
    static let shin = 0.13
    static let upperArm = 0.09
    static let forearm = 0.09
    /// Ankle to toe, and wrist to fingertip. The two segments the corridor rules are measured across.
    static let foot = 0.045
    static let hand = 0.035

    // MARK: - Pose

    /// One instant of the athlete, in the four anchors the model places directly.
    ///
    /// The shoulder is deliberately *not* an anchor: deriving it from the hip and `trunkAngle` is what
    /// holds `sagittalTorsoLength` exactly constant, and every measurement in this station divides by
    /// that. A shoulder placed by hand would let the scale drift between phases and quietly rescale
    /// the thresholds.
    struct Pose {
        var hip: (x: Double, y: Double)
        /// Degrees from vertical, positive with the shoulders ahead of the hips. 10° standing tall,
        /// 90° lying prone.
        var trunkAngle: Double
        var ankle: (x: Double, y: Double)
        var wrist: (x: Double, y: Double)

        var shoulder: (x: Double, y: Double) {
            let radians = trunkAngle * .pi / 180
            return (x: hip.x + torso * sin(radians), y: hip.y - torso * cos(radians))
        }
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func blend(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
        Pose(
            hip: (x: lerp(a.hip.x, b.hip.x, t), y: lerp(a.hip.y, b.hip.y, t)),
            trunkAngle: lerp(a.trunkAngle, b.trunkAngle, t),
            ankle: (x: lerp(a.ankle.x, b.ankle.x, t), y: lerp(a.ankle.y, b.ankle.y, t)),
            wrist: (x: lerp(a.wrist.x, b.wrist.x, t), y: lerp(a.wrist.y, b.wrist.y, t))
        )
    }

    /// Eased so each phase leaves and arrives at zero velocity — the athlete is not a step function,
    /// and a linear phase boundary would put an instantaneous jump into the travel and joint traces.
    static func ease(_ t: Double) -> Double { (1 - cos(min(max(t, 0), 1) * .pi)) / 2 }

    // MARK: - The five phases of a rep

    /// Chest on the deck. `chestGap` lifts the whole trunk off the floor, which is what a hovered rep
    /// looks like — the shoulders and hips rise together rather than the chest alone.
    static func bottom(base: Double, chestGap: Double = 0) -> Pose {
        Pose(
            hip: (x: base - 0.22, y: floor - 0.015 - chestGap),
            trunkAngle: 90,
            ankle: (x: base - 0.48, y: floor - 0.005),
            wrist: (x: base, y: floor - 0.005)
        )
    }

    /// Feet tucked up under the body, hands still planted — where rule 5 is judged. `toeLead` is how
    /// far ahead of the planted hands the toe lands.
    static func tuck(base: Double, toeLead: Double) -> Pose {
        Pose(
            hip: (x: base - 0.20, y: 0.79),
            trunkAngle: 75,
            ankle: (x: base + toeLead - foot, y: floor - 0.005),
            wrist: (x: base, y: floor - 0.005)
        )
    }

    /// Upright at full extension — the take-off. The feet do not move between the tuck and here, which
    /// is what keeps the stand-up out of the travel trace.
    static func stand(footX: Double) -> Pose {
        Pose(
            hip: (x: footX, y: 0.645),
            trunkAngle: 10,
            ankle: (x: footX, y: floor),
            wrist: (x: footX + 0.02, y: 0.657)
        )
    }

    /// Hands planted to start the next burpee — where rule 6 is judged. `handsAhead` is wrist to front
    /// toe, the quantity the rulebook caps at 30 cm.
    static func plant(nextBase: Double, handsAhead: Double) -> Pose {
        let ankleX = nextBase - handsAhead - foot
        return Pose(
            hip: (x: ankleX - 0.10, y: 0.79),
            trunkAngle: 75,
            ankle: (x: ankleX, y: floor),
            wrist: (x: nextBase, y: floor - 0.005)
        )
    }

    // MARK: - Frame construction

    static func makeFrame(
        ms: Int,
        pose: Pose,
        mirrored: Bool,
        shoulderSpread: Double,
        handsVisible: Bool,
        tracked: Bool
    ) -> PoseFrame {
        let hip = pose.hip
        let shoulder = pose.shoulder
        let ankle = pose.ankle
        let wrist = pose.wrist

        let knee = joint(from: hip, to: ankle, linkA: thigh, linkB: shin, bow: .upward)
        let elbow = joint(from: shoulder, to: wrist, linkA: upperArm, linkB: forearm, bow: .backward)

        // The head rides on the trunk line and the face points the way the athlete travels — true
        // standing and true lying prone, which is what makes the facing vote survive a rep.
        let radians = pose.trunkAngle * .pi / 180
        let ear = (
            x: shoulder.x + torso * 0.35 * sin(radians),
            y: shoulder.y - torso * 0.35 * cos(radians)
        )
        let nose = (x: ear.x + 0.03, y: ear.y + 0.004)

        // Fingers point the way the athlete travels, which is how a planted hand sits. Only ever read
        // while the hands are on the deck, so the standing case does not need modelling.
        let fingertip = (x: wrist.x + hand, y: wrist.y)
        let toe = (x: ankle.x + foot, y: ankle.y + 0.004)
        let heel = (x: ankle.x - 0.02, y: ankle.y + 0.004)

        var landmarks: [PoseLandmark] = []

        func add(_ name: PoseLandmarkName, _ point: (x: Double, y: Double), visibility: Double) {
            let x = mirrored ? 1 - point.x : point.x
            landmarks.append(
                PoseLandmark(name: name, x: x, y: point.y, z: 0,
                             visibility: visibility, presence: visibility)
            )
        }

        let near = tracked ? 0.9 : 0.1
        let far = 0.1

        add(.nose, nose, visibility: near)
        add(.leftEar, ear, visibility: near)
        add(.rightEar, ear, visibility: far)

        // Both shoulders read as tracked even side-on: the narrow apparent spread is what tells
        // `viewpoint` the camera is beside the athlete.
        add(.leftShoulder, (x: shoulder.x - shoulderSpread / 2, y: shoulder.y), visibility: near)
        add(.rightShoulder, (x: shoulder.x + shoulderSpread / 2, y: shoulder.y), visibility: near)

        add(.leftHip, hip, visibility: near)
        add(.rightHip, hip, visibility: far)
        add(.leftKnee, knee, visibility: near)
        add(.rightKnee, knee, visibility: far)
        add(.leftAnkle, ankle, visibility: near)
        add(.rightAnkle, ankle, visibility: far)
        add(.leftHeel, heel, visibility: near)
        add(.rightHeel, heel, visibility: far)
        add(.leftFootIndex, toe, visibility: near)
        add(.rightFootIndex, toe, visibility: far)

        add(.leftElbow, elbow, visibility: near)
        add(.rightElbow, elbow, visibility: far)
        add(.leftWrist, wrist, visibility: (tracked && handsVisible) ? 0.9 : 0.1)
        add(.rightWrist, wrist, visibility: far)
        add(.leftIndex, fingertip, visibility: (tracked && handsVisible) ? 0.9 : 0.1)
        add(.rightIndex, fingertip, visibility: far)

        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    enum Bow {
        /// Smaller y: the knee, drawn ahead of the hip-to-ankle line as a bending leg does.
        case upward
        /// Smaller x: the elbow, which flares behind the shoulder-to-wrist line.
        case backward
    }

    /// Places the middle joint of a two-link chain by circle intersection, as `SkiFixture.joint` does.
    static func joint(
        from a: (x: Double, y: Double),
        to b: (x: Double, y: Double),
        linkA: Double,
        linkB: Double,
        bow: Bow
    ) -> (x: Double, y: Double) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard distance > 0.0001 else { return a }

        let reach = min(distance, linkA + linkB - 0.0001)
        let along = (reach * reach + linkA * linkA - linkB * linkB) / (2 * reach)
        let height = max(0, linkA * linkA - along * along).squareRoot()

        let ux = dx / distance
        let uy = dy / distance
        let base = (x: a.x + ux * along, y: a.y + uy * along)
        let one = (x: base.x - uy * height, y: base.y + ux * height)
        let two = (x: base.x + uy * height, y: base.y - ux * height)

        switch bow {
        case .upward: return one.y <= two.y ? one : two
        case .backward: return one.x <= two.x ? one : two
        }
    }

    // MARK: - Reps

    /// One rep, bottom to just before the next bottom.
    ///
    /// Runs bottom → tuck → stand → jump → plant → back down, which is the order the athlete performs
    /// it. Every knob injects exactly one fault, and the two `step` knobs inject **legal** technique
    /// that a careless implementation would fault.
    static func repFrames(
        startMs: Int,
        base: Double,
        jump: Double = 0.30,
        toeLead: Double = 0.01,
        handsAhead: Double = 0.05,
        chestGap: Double = 0,
        stepOut: Bool = false,
        stepBack: Bool = false,
        phaseFrames: Int = 12,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        handsVisible: Bool = true,
        gapFrames: Int = 0,
        frameRate: Int = fps
    ) -> (frames: [PoseFrame], nextMs: Int) {
        var frames: [PoseFrame] = []
        var ms = startMs
        var emitted = 0
        let step = 1000 / frameRate

        func emit(_ pose: Pose) {
            let inGap = gapFrames > 0 && emitted >= 6 && emitted < 6 + gapFrames
            frames.append(
                makeFrame(ms: ms, pose: pose, mirrored: mirrored,
                          shoulderSpread: shoulderSpread, handsVisible: handsVisible,
                          tracked: !inGap)
            )
            ms += step
            emitted += 1
        }

        /// A phase: `count` eased frames from `a` to `b`, excluding `a` itself so phases join without
        /// a duplicated frame.
        func phase(_ a: Pose, _ b: Pose, count: Int) {
            for i in 1...max(count, 1) {
                emit(blend(a, b, ease(Double(i) / Double(count))))
            }
        }

        func hold(_ pose: Pose, count: Int) {
            for _ in 0..<count { emit(pose) }
        }

        let nextBase = base + jump
        let bottomPose = bottom(base: base, chestGap: chestGap)
        let tuckPose = tuck(base: base, toeLead: toeLead)
        let standPose = stand(footX: tuckPose.ankle.x)
        let plantPose = plant(nextBase: nextBase, handsAhead: handsAhead)
        let landedPose = stand(footX: plantPose.ankle.x)

        emit(bottomPose)

        // Bottom → tuck: the feet come forward while the hands stay planted. Rule 5's window.
        //
        // `stepOut` brings them up one foot at a time — two translations with a dwell between, which
        // rules 3 and 7 explicitly permit. It is here so the tests can prove a legal rep taken
        // entirely in steps still segments cleanly and still reads both corridor rules correctly.
        if stepOut {
            let half = tuck(base: base, toeLead: toeLead - 0.12)
            phase(bottomPose, half, count: phaseFrames / 2)
            hold(half, count: 4)
            phase(half, tuckPose, count: phaseFrames / 2)
        } else {
            phase(bottomPose, tuckPose, count: phaseFrames)
        }

        // Tuck → stand: the hands leave the deck. The feet do not move, so nothing enters the travel
        // trace here.
        phase(tuckPose, standPose, count: phaseFrames)

        // The broad jump, taken with the hands off the deck — the window `jumpDistance` measures.
        phase(standPose, landedPose, count: phaseFrames)

        // Landed → hands planted. The hand reaches its final x before its final y, which is how a
        // reach to the floor actually goes, and it is what makes rule 6 read the placement rather
        // than a frame mid-reach.
        for i in 1...phaseFrames {
            let t = Double(i) / Double(phaseFrames)
            var pose = blend(landedPose, plantPose, ease(t))
            pose.wrist.x = lerp(landedPose.wrist.x, plantPose.wrist.x, ease(min(t * 1.8, 1)))
            emit(pose)
        }

        // Plant → next bottom: the feet travel a long way backward, but the hands are already down,
        // so rules 3 and 7 permit it whether it is a jump or a step.
        let nextBottom = bottom(base: nextBase, chestGap: chestGap)
        if stepBack {
            var half = blend(plantPose, nextBottom, 0.5)
            half.wrist = plantPose.wrist
            phase(plantPose, half, count: phaseFrames / 2)
            hold(half, count: 4)
            phase(half, nextBottom, count: phaseFrames / 2)
        } else {
            phase(plantPose, nextBottom, count: phaseFrames)
        }

        // The closing bottom belongs to the next rep, so stop one frame short of it.
        frames.removeLast()
        ms -= step

        return (frames, ms)
    }

    /// A whole set. Knobs are applied to every rep in it.
    static func session(
        cycles: Int = 5,
        jump: Double = 0.30,
        toeLead: Double = 0.01,
        handsAhead: Double = 0.05,
        chestGap: Double = 0,
        stepOut: Bool = false,
        stepBack: Bool = false,
        phaseFrames: Int = 12,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        handsVisible: Bool = true,
        gapFramesInSecondRep: Int = 0,
        startBase: Double = 0.20,
        frameRate: Int = fps
    ) -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var ms = 0
        var base = startBase

        for cycle in 0..<cycles {
            let rep = repFrames(
                startMs: ms,
                base: base,
                jump: jump,
                toeLead: toeLead,
                handsAhead: handsAhead,
                chestGap: chestGap,
                stepOut: stepOut,
                stepBack: stepBack,
                phaseFrames: phaseFrames,
                mirrored: mirrored,
                shoulderSpread: shoulderSpread,
                handsVisible: handsVisible,
                gapFrames: cycle == 1 ? gapFramesInSecondRep : 0,
                frameRate: frameRate
            )
            frames.append(contentsOf: rep.frames)
            ms = rep.nextMs
            base += jump
        }

        // Close the last rep so it is emitted rather than left open.
        frames.append(
            makeFrame(ms: ms, pose: bottom(base: base, chestGap: chestGap), mirrored: mirrored,
                      shoulderSpread: shoulderSpread, handsVisible: handsVisible, tracked: true)
        )

        return frames
    }

    /// An athlete standing still — no reps to find.
    static func stillFrames(count: Int = 120) -> [PoseFrame] {
        (0..<count).map {
            makeFrame(ms: $0 * step, pose: stand(footX: 0.50), mirrored: false,
                      shoulderSpread: 0.05, handsVisible: true, tracked: true)
        }
    }

    /// A bob at the top that never goes near the floor — below `minChestRange`, so not a rep.
    static func shallowBobs(cycles: Int = 4, phaseFrames: Int = 12) -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var ms = 0
        let tall = stand(footX: 0.50)
        var dipped = tall
        dipped.hip.y += 0.09

        for _ in 0..<cycles {
            for i in 1...phaseFrames {
                frames.append(makeFrame(ms: ms, pose: blend(tall, dipped, ease(Double(i) / Double(phaseFrames))),
                                        mirrored: false, shoulderSpread: 0.05,
                                        handsVisible: true, tracked: true))
                ms += step
            }
            for i in 1...phaseFrames {
                frames.append(makeFrame(ms: ms, pose: blend(dipped, tall, ease(Double(i) / Double(phaseFrames))),
                                        mirrored: false, shoulderSpread: 0.05,
                                        handsVisible: true, tracked: true))
                ms += step
            }
        }
        return frames
    }

    /// Reps with the session scale fully established.
    ///
    /// The first emitted rep is the scale warm-up: `ScaleReference` withholds a value until it has seen
    /// `minScaleSamples` frames, so that rep's corridor and travel measurements are deliberately
    /// suppressed. Tests that care about the rules work from the rest.
    static func measuredReps(_ frames: [PoseFrame]) -> [BurpeeRep] {
        Array(BurpeeRepAnalyzer.analyze(frames: frames).dropFirst())
    }
}
