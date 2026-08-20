import Foundation
@testable import RoxMovementAnalyzer

/// A synthetic skier, built **kinematically** — the same discipline as `RowingFixture`.
///
/// The fixture places the ankle, hip, shoulder and wrist, then solves the knee and elbow by circle
/// intersection, so the shoulder sweep and elbow angles the analyzer measures emerge from the model
/// rather than being written into it. The arm is given in polar form about the shoulder as
/// `(armAngle, armReach)`, which means one knob swings the arm and the other bends the elbow, and
/// neither can be set without the wrist position following.
///
/// Side-on by default — near-side limbs tracked, far side occluded — which is what exercises
/// `visibleCenter`. Nose, ears, heels and toes are emitted so `standingFacingVote` is exercised on
/// the anatomy it actually votes on.
///
/// **The drive is speed-shaped, not linear in time.** A linear drive gives the hands a flat speed
/// profile with no locatable peak, which would make every force-curve reading arbitrary. Progress
/// through the drive is instead the integral of a bump `w(t) = t^α(1−t)^β` whose mode sits at
/// `drivePeakFraction`, so a clean pull front-loads the way a body-driven one does, and `topDwell` and
/// `armSurge` deform that curve into the two faulted shapes. The hands' *speed* is therefore emergent
/// from the shaping, exactly as their angles are emergent from the link lengths.
///
/// Emergent angles on the default geometry, worked through once so a change to the model is visible
/// rather than silent:
///   catch  — arms overhead, torso 5°  → shoulder 164°, elbow 170°, knee 154°
///   finish — hands past hips, torso 50° → shoulder  31°, elbow 170°, knee 123°
enum SkiFixture {
    static let fps = 30
    static var step: Int { 1000 / fps }

    /// Fixed: the athlete stands still on the floor.
    static let ankle = (x: 0.50, y: 0.90)
    /// Hip height with the leg all but straight. `hipDrop` descends from here.
    static let standingHipY = 0.545

    static let thigh = 0.20
    static let shin = 0.16
    static let torso = 0.25
    static let upperArm = 0.13
    static let forearm = 0.13

    /// A straight arm, a hair inside the link sum so the elbow stays solvable.
    static let straightArm = 0.259
    /// The elbow flex carried through the middle of the drive.
    ///
    /// Fixed rather than a knob, because **no check reads the elbow any more**: bending through the
    /// compression and extending at the finish is correct double-poling, not a fault. It is modelled
    /// only so the arm geometry is realistic and the elbow never sits exactly on the shoulder-to-wrist
    /// line.
    static let bentArm = 0.239

    static let catchLean = 5.0
    static let finishLean = 50.0
    static let catchHipBack = 0.02
    static let finishHipBack = 0.10
    static let catchHipDrop = 0.005
    static let finishHipDrop = 0.054
    /// Degrees from straight-up, positive toward the machine: arms overhead at the catch, driven down
    /// and back past the body at the finish.
    static let catchArmAngle = 20.0
    static let finishArmAngle = 200.0

    /// Which side of the straight line between the two ends the middle joint bows to.
    ///
    /// `RowingFixture` picks by y, which is enough there because its limbs never swing far. A ski arm
    /// sweeps through ~180°, and near the bottom of that arc the two circle-intersection solutions sit
    /// at almost the same height — so a y-based choice flips branch mid-swing and puts a ~20°
    /// discontinuity into the shoulder angle, which the analyzer reads as a reversal and segments on.
    /// The elbow has to be picked by the side it actually flares to instead.
    enum Bow {
        /// Smaller y: the knee, drawn in front of the hip-to-ankle line as a standing leg bends.
        case upward
        /// Smaller x: the elbow, which flares behind the shoulder-to-wrist line all the way through
        /// the pull. Chosen in unmirrored coordinates, before `mirrored` flips the frame.
        case backward
    }

    /// Places the middle joint of a two-link chain by circle intersection, as `RowingFixture` does: the
    /// joint *angle* is fixed by the link lengths and the end-to-end distance, so `bow` only decides
    /// which way the limb is drawn — but see `Bow` for why that still matters here.
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

    static func makeFrame(
        ms: Int,
        hipBack: Double,
        hipDrop: Double,
        lean: Double,
        armAngle: Double,
        armReach: Double,
        mirrored: Bool,
        shoulderSpread: Double,
        wristsVisible: Bool,
        tracked: Bool
    ) -> PoseFrame {
        let hip = (x: ankle.x - hipBack, y: standingHipY + hipDrop)

        let leanRadians = lean * .pi / 180
        let shoulder = (
            x: hip.x + torso * sin(leanRadians),
            y: hip.y - torso * cos(leanRadians)
        )

        let armRadians = armAngle * .pi / 180
        let wrist = (
            x: shoulder.x + armReach * sin(armRadians),
            y: shoulder.y - armReach * cos(armRadians)
        )

        // The head rides on the torso line, and the face points at the machine.
        let ear = (
            x: shoulder.x + torso * 0.35 * sin(leanRadians),
            y: shoulder.y - torso * 0.35 * cos(leanRadians)
        )
        let nose = (x: ear.x + 0.035, y: ear.y + 0.005)

        let knee = joint(from: hip, to: ankle, linkA: thigh, linkB: shin, bow: .upward)
        let elbow = joint(from: shoulder, to: wrist, linkA: upperArm, linkB: forearm, bow: .backward)

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

        // The far limbs are behind the near ones, as in any real side-on shot.
        add(.leftHip, hip, visibility: near)
        add(.rightHip, hip, visibility: far)
        add(.leftKnee, knee, visibility: near)
        add(.rightKnee, knee, visibility: far)
        add(.leftAnkle, ankle, visibility: near)
        add(.rightAnkle, ankle, visibility: far)
        add(.leftHeel, (x: ankle.x - 0.02, y: ankle.y + 0.02), visibility: near)
        add(.rightHeel, (x: ankle.x - 0.02, y: ankle.y + 0.02), visibility: far)
        add(.leftFootIndex, (x: ankle.x + 0.06, y: ankle.y + 0.03), visibility: near)
        add(.rightFootIndex, (x: ankle.x + 0.06, y: ankle.y + 0.03), visibility: far)

        // The elbow stays tracked when the wrist does not, which is the whole reason segmentation runs
        // on the shoulder angle: an overhead reach loses the hands long before it loses the elbows.
        add(.leftElbow, elbow, visibility: near)
        add(.rightElbow, elbow, visibility: far)
        add(.leftWrist, wrist, visibility: (tracked && wristsVisible) ? 0.9 : 0.1)
        add(.rightWrist, wrist, visibility: far)

        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    /// Progress through the drive, sample by sample: the normalised integral of a speed bump.
    ///
    /// `w(t) = t^α(1−t)^β` with `α = 2` and `β = α(1−f)/f`, which puts the bump's mode exactly at `f`.
    /// `topDwell` scales the opening down so the hands drift through the top of the range before
    /// loading; `armSurge` adds a second bump late, so the drive arrives as two efforts with a lull
    /// between them.
    static func driveProgress(
        frames: Int,
        peakFraction: Double,
        topDwell: Double,
        armSurge: Double
    ) -> [Double] {
        let alpha = 2.0
        let beta = alpha * (1 - peakFraction) / peakFraction

        var weights: [Double] = (0...frames).map { i in
            let t = Double(i) / Double(frames)
            let bump = pow(t, alpha) * pow(max(0, 1 - t), beta)
            let dwell = topDwell > 0 ? pow(ramp(t, from: 0, to: topDwell), 2) : 1
            return bump * dwell
        }

        if armSurge > 0, let peak = weights.max(), peak > 0 {
            for i in weights.indices {
                let t = Double(i) / Double(frames)
                let offset = (t - 0.8) / 0.1
                weights[i] += armSurge * peak * exp(-offset * offset)
            }
        }

        let total = weights.reduce(0, +)
        guard total > 0 else { return (0...frames).map { Double($0) / Double(frames) } }

        var running = 0.0
        return weights.map { weight in
            running += weight
            return running / total
        }
    }

    /// 0 before `from`, 1 after `to`, linear between.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    /// `ramp`, eased so it leaves and arrives at zero velocity.
    ///
    /// The recovery needs this and the drive does not. The hands genuinely come to rest at the top
    /// before reversing into the next pull, and a linear return would instead carry full recovery speed
    /// straight across the catch. The analyzer locates the catch on a *smoothed* signal, so it can land
    /// a frame either side of the true reversal — and a linear recovery would then hand the opening of
    /// the drive a speed spike an order of magnitude above the pull's real peak, which is force that
    /// never happened.
    static func easedRamp(_ value: Double, from: Double, to: Double) -> Double {
        (1 - cos(ramp(value, from: from, to: to) * .pi)) / 2
    }

    /// One pull: catch → drive → finish → recovery, ending on the frame before the next catch.
    ///
    /// Defaults model a clean 45-a-minute pull — 16 drive frames and 24 recovery frames at 30 fps, a
    /// 1.5:1 ratio. Each knob injects exactly one fault.
    static func pullFrames(
        startMs: Int,
        driveFrames: Int = 16,
        recoveryFrames: Int = 24,
        drivePeakFraction: Double = 0.3,
        topDwell: Double = 0,
        armSurge: Double = 0,
        catchArmAngle: Double = catchArmAngle,
        finishArmAngle: Double = finishArmAngle,
        finishLean: Double = finishLean,
        finishHipBack: Double = finishHipBack,
        finishHipDrop: Double = finishHipDrop,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        wristsVisible: Bool = true,
        catchHoldFrames: Int = 0,
        gapFrames: Int = 0
    ) -> (frames: [PoseFrame], nextMs: Int) {
        var frames: [PoseFrame] = []
        var ms = startMs

        func emit(hipBack: Double, hipDrop: Double, lean: Double, armAngle: Double,
                  armReach: Double, tracked: Bool = true) {
            frames.append(
                makeFrame(ms: ms, hipBack: hipBack, hipDrop: hipDrop, lean: lean,
                          armAngle: armAngle, armReach: armReach, mirrored: mirrored,
                          shoulderSpread: shoulderSpread, wristsVisible: wristsVisible,
                          tracked: tracked)
            )
            ms += step
        }

        // A pause at the top, for the test that it does not split the pull in two.
        for _ in 0..<catchHoldFrames {
            emit(hipBack: catchHipBack, hipDrop: catchHipDrop, lean: catchLean,
                 armAngle: catchArmAngle, armReach: straightArm)
        }

        // Drive: the hips hinge back and the torso folds onto the handles, then the arms draw through.
        // Every parameter advances by `p`, the speed-shaped progress, so the hands' speed profile — and
        // with it the whole force curve — falls out of the shaping rather than being asserted.
        let progress = driveProgress(
            frames: driveFrames,
            peakFraction: drivePeakFraction,
            topDwell: topDwell,
            armSurge: armSurge
        )
        for i in 0...driveFrames {
            let p = progress[i]
            emit(
                hipBack: catchHipBack + (finishHipBack - catchHipBack) * p,
                hipDrop: catchHipDrop + (finishHipDrop - catchHipDrop) * p,
                lean: catchLean + (finishLean - catchLean) * p,
                armAngle: catchArmAngle + (finishArmAngle - catchArmAngle) * p,
                // Elbows flex through the compression and extend again at the finish: correct double
                // poling, and nothing measures it.
                armReach: straightArm - (straightArm - bentArm) * sin(p * .pi)
            )
        }

        // Recovery: the hands come away and rise immediately while the body stands up under them. The
        // last frame stops short of the catch, which is the next pull's opening frame.
        //
        // The arms have to start rising from the *first* recovery frame. Delaying them puts the minimum
        // of the shoulder angle several frames into the recovery — the elbow straightening alone keeps
        // driving the angle down — and the analyzer would then place the finish there, inflating the
        // drive and deflating the recovery until a clean pull reported a rushed one.
        for i in 1..<recoveryFrames {
            let u = Double(i) / Double(recoveryFrames)
            let stand = easedRamp(u, from: 0.05, to: 0.65)
            let hips = easedRamp(u, from: 0.1, to: 0.75)

            emit(
                hipBack: finishHipBack + (catchHipBack - finishHipBack) * hips,
                hipDrop: finishHipDrop + (catchHipDrop - finishHipDrop) * hips,
                lean: finishLean + (catchLean - finishLean) * stand,
                armAngle: finishArmAngle
                    + (catchArmAngle - finishArmAngle) * easedRamp(u, from: 0, to: 1),
                armReach: straightArm,
                tracked: !(gapFrames > 0 && i > 2 && i <= 2 + gapFrames)
            )
        }

        return (frames, ms)
    }

    /// A whole piece. Knobs are applied to every pull in it.
    static func session(
        cycles: Int = 4,
        driveFrames: Int = 16,
        recoveryFrames: Int = 24,
        drivePeakFraction: Double = 0.3,
        topDwell: Double = 0,
        armSurge: Double = 0,
        catchArmAngle: Double = catchArmAngle,
        finishArmAngle: Double = finishArmAngle,
        finishLean: Double = finishLean,
        finishHipBack: Double = finishHipBack,
        finishHipDrop: Double = finishHipDrop,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        wristsVisible: Bool = true,
        catchHoldFrames: Int = 0,
        gapFramesAfterFirstPull: Int = 0
    ) -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var ms = 0

        for cycle in 0..<cycles {
            let pull = pullFrames(
                startMs: ms,
                driveFrames: driveFrames,
                recoveryFrames: recoveryFrames,
                drivePeakFraction: drivePeakFraction,
                topDwell: topDwell,
                armSurge: armSurge,
                catchArmAngle: catchArmAngle,
                finishArmAngle: finishArmAngle,
                finishLean: finishLean,
                finishHipBack: finishHipBack,
                finishHipDrop: finishHipDrop,
                mirrored: mirrored,
                shoulderSpread: shoulderSpread,
                wristsVisible: wristsVisible,
                catchHoldFrames: catchHoldFrames,
                gapFrames: cycle == 0 ? 0 : gapFramesAfterFirstPull
            )
            frames.append(contentsOf: pull.frames)
            ms = pull.nextMs
        }

        return frames
    }

    /// An athlete standing at the machine doing nothing — no pulls to find.
    static func stillFrames(count: Int = 90) -> [PoseFrame] {
        (0..<count).map {
            makeFrame(ms: $0 * step, hipBack: 0.03, hipDrop: 0.01, lean: 10,
                      armAngle: 60, armReach: straightArm, mirrored: false,
                      shoulderSpread: 0.05, wristsVisible: true, tracked: true)
        }
    }

    /// Pulls with the session scale fully established.
    ///
    /// The first emitted pull is the scale warm-up: `ScaleReference` withholds a value until it has
    /// seen `minScaleSamples` frames, so that pull's scale-dependent measurements are deliberately
    /// suppressed. Tests that care about the hands work from the rest.
    static func measuredPulls(_ frames: [PoseFrame]) -> [SkiPull] {
        Array(SkiPullAnalyzer.analyze(frames: frames).dropFirst())
    }
}
