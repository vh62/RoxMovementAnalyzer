import Foundation
@testable import RoxMovementAnalyzer

/// A synthetic rower, built **kinematically**.
///
/// The fixture places the ankle, hip, shoulder and wrist, then solves the knee and elbow by circle
/// intersection, so the angles the analyzer measures emerge from the model rather than being written
/// into it. A fixture that hand-authored the knee angle could only ever confirm the analyzer's own
/// assumptions back to itself.
///
/// It defaults to a genuinely side-on view — near-side leg tracked, far side occluded — which is
/// what exercises `visibleCenter`. The wall-ball fixture makes every landmark visible, which is
/// precisely why it would never have caught the `midpoint` defect.
///
/// Emergent angles on the default geometry, worked through once so a change to the model is visible
/// rather than silent:
///   catch  — hip-to-ankle 0.141 → knee  44.6°, elbow 135.7°
///   finish — hip-to-ankle 0.354 → knee 159.6°, elbow  51.0°
enum RowingFixture {
    static let fps = 30
    static var step: Int { 1000 / fps }

    /// Fixed: the feet are strapped to the footplate.
    static let ankle = (x: 0.62, y: 0.72)
    /// Fixed: the seat rides at a constant height on the rail.
    static let hipY = 0.62

    static let thigh = 0.20
    static let shin = 0.16
    static let torso = 0.25
    static let upperArm = 0.13
    static let forearm = 0.13

    static let finishSeatBack = 0.34
    static let catchLean = 30.0
    static let catchArmReach = 0.24
    static let catchArmDrop = 0.02
    static let finishArmDrop = 0.10

    /// Places the middle joint of a two-link chain by circle intersection. The joint *angle* is
    /// fixed by the link lengths and the end-to-end distance, so `preferSmallerY` only decides which
    /// way the limb is drawn — knees bend up, elbows hang down.
    static func joint(
        from a: (x: Double, y: Double),
        to b: (x: Double, y: Double),
        linkA: Double,
        linkB: Double,
        preferSmallerY: Bool
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

        if preferSmallerY { return one.y <= two.y ? one : two }
        return one.y >= two.y ? one : two
    }

    static func makeFrame(
        ms: Int,
        seatBack: Double,
        lean: Double,
        armReach: Double,
        armDrop: Double,
        shoulderLag: Double,
        mirrored: Bool,
        shoulderSpread: Double,
        wristsVisible: Bool,
        tracked: Bool
    ) -> PoseFrame {
        let hip = (x: ankle.x - seatBack, y: hipY)

        // The shoulder is placed by x — normally from the lean, plus any travel it failed to make
        // when the seat shot away — and its y solved to keep the torso rigid.
        let leanOffset = torso * sin(lean * .pi / 180)
        let rawDx = leanOffset + shoulderLag
        let dx = min(max(rawDx, -torso * 0.99), torso * 0.99)
        let shoulder = (x: hip.x + dx, y: hip.y - (torso * torso - dx * dx).squareRoot())

        let wrist = (x: shoulder.x + armReach, y: shoulder.y + armDrop)
        let knee = joint(from: hip, to: ankle, linkA: thigh, linkB: shin, preferSmallerY: true)
        let elbow = joint(from: shoulder, to: wrist, linkA: upperArm, linkB: forearm, preferSmallerY: false)

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

        // Both shoulders read as tracked even side-on: they sit high and clear of the machine, and
        // the narrow apparent spread is what tells `viewpoint` the camera is beside the athlete.
        add(.leftShoulder, (x: shoulder.x - shoulderSpread / 2, y: shoulder.y), visibility: near)
        add(.rightShoulder, (x: shoulder.x + shoulderSpread / 2, y: shoulder.y), visibility: near)

        // The far leg is behind the near one, as it is in any real side-on shot.
        add(.leftHip, hip, visibility: near)
        add(.rightHip, hip, visibility: far)
        add(.leftKnee, knee, visibility: near)
        add(.rightKnee, knee, visibility: far)
        add(.leftAnkle, ankle, visibility: near)
        add(.rightAnkle, ankle, visibility: far)

        let wristVisibility = (tracked && wristsVisible) ? 0.9 : 0.1
        add(.leftElbow, elbow, visibility: wristVisibility)
        add(.rightElbow, elbow, visibility: far)
        add(.leftWrist, wrist, visibility: wristVisibility)
        add(.rightWrist, wrist, visibility: far)

        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    /// 0 before `from`, 1 after `to`, linear between.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    /// One stroke: catch → drive → finish → recovery, ending on the frame before the next catch.
    ///
    /// Defaults model a clean 30 spm stroke — 20 drive frames and 40 recovery frames at 30 fps, a
    /// 2:1 ratio. Each knob injects exactly one fault.
    static func strokeFrames(
        startMs: Int,
        driveFrames: Int = 20,
        recoveryFrames: Int = 40,
        backOpenAtDriveFraction: Double = 0.75,
        armBreakAtDriveFraction: Double = 0.85,
        slideSlipFraction: Double = 0,
        catchSeatBack: Double = 0.10,
        finishLean: Double = -20,
        finishArmReach: Double = 0.05,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        wristsVisible: Bool = true,
        catchHoldFrames: Int = 0,
        gapFrames: Int = 0
    ) -> (frames: [PoseFrame], nextMs: Int) {
        var frames: [PoseFrame] = []
        var ms = startMs
        let slide = finishSeatBack - catchSeatBack

        func emit(seatBack: Double, lean: Double, armReach: Double, armDrop: Double,
                  shoulderLag: Double, tracked: Bool = true) {
            frames.append(
                makeFrame(ms: ms, seatBack: seatBack, lean: lean, armReach: armReach,
                          armDrop: armDrop, shoulderLag: shoulderLag, mirrored: mirrored,
                          shoulderSpread: shoulderSpread, wristsVisible: wristsVisible,
                          tracked: tracked)
            )
            ms += step
        }

        // A pause at the catch, for the test that it does not split the stroke in two.
        for _ in 0..<catchHoldFrames {
            emit(seatBack: catchSeatBack, lean: catchLean,
                 armReach: catchArmReach, armDrop: catchArmDrop, shoulderLag: 0)
        }

        // Drive: legs first, then the body swings open, then the arms draw.
        for i in 0...driveFrames {
            let t = Double(i) / Double(driveFrames)
            let seatBack = catchSeatBack + slide * t
            let armProgress = ramp(t, from: armBreakAtDriveFraction, to: 1)

            let shoulderLag: Double
            if slideSlipFraction > 0 {
                shoulderLag = t <= slideSlipFraction
                    // The seat travels and the upper body does not, so the whole lag accumulates.
                    ? slide * t
                    // Whatever was lost is only recovered gradually across the rest of the drive.
                    : slide * slideSlipFraction * (1 - t) / (1 - slideSlipFraction)
            } else {
                shoulderLag = 0
            }

            emit(
                seatBack: seatBack,
                lean: catchLean + (finishLean - catchLean) * ramp(t, from: backOpenAtDriveFraction, to: 1),
                armReach: catchArmReach + (finishArmReach - catchArmReach) * armProgress,
                armDrop: catchArmDrop + (finishArmDrop - catchArmDrop) * armProgress,
                shoulderLag: shoulderLag
            )
        }

        // Recovery: hands away, body over, then let the seat come. The last frame stops short of
        // the catch, which is the next stroke's opening frame.
        for i in 1..<recoveryFrames {
            let u = Double(i) / Double(recoveryFrames)
            let armProgress = ramp(u, from: 0, to: 0.4)

            emit(
                seatBack: finishSeatBack - slide * ramp(u, from: 0.4, to: 1),
                lean: finishLean + (catchLean - finishLean) * ramp(u, from: 0.2, to: 0.7),
                armReach: finishArmReach + (catchArmReach - finishArmReach) * armProgress,
                armDrop: finishArmDrop + (catchArmDrop - finishArmDrop) * armProgress,
                shoulderLag: 0,
                tracked: !(gapFrames > 0 && i > 2 && i <= 2 + gapFrames)
            )
        }

        return (frames, ms)
    }

    /// A whole piece. Knobs are applied to every stroke in it.
    static func session(
        cycles: Int = 4,
        driveFrames: Int = 20,
        recoveryFrames: Int = 40,
        backOpenAtDriveFraction: Double = 0.75,
        armBreakAtDriveFraction: Double = 0.85,
        slideSlipFraction: Double = 0,
        catchSeatBack: Double = 0.10,
        finishLean: Double = -20,
        finishArmReach: Double = 0.05,
        mirrored: Bool = false,
        shoulderSpread: Double = 0.05,
        wristsVisible: Bool = true,
        catchHoldFrames: Int = 0,
        gapFramesAfterFirstStroke: Int = 0
    ) -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var ms = 0

        for cycle in 0..<cycles {
            let stroke = strokeFrames(
                startMs: ms,
                driveFrames: driveFrames,
                recoveryFrames: recoveryFrames,
                backOpenAtDriveFraction: backOpenAtDriveFraction,
                armBreakAtDriveFraction: armBreakAtDriveFraction,
                slideSlipFraction: slideSlipFraction,
                catchSeatBack: catchSeatBack,
                finishLean: finishLean,
                finishArmReach: finishArmReach,
                mirrored: mirrored,
                shoulderSpread: shoulderSpread,
                wristsVisible: wristsVisible,
                catchHoldFrames: catchHoldFrames,
                gapFrames: cycle == 0 ? 0 : gapFramesAfterFirstStroke
            )
            frames.append(contentsOf: stroke.frames)
            ms = stroke.nextMs
        }

        return frames
    }

    /// An athlete sitting still on the machine — no strokes to find.
    static func stillFrames(count: Int = 90) -> [PoseFrame] {
        (0..<count).map {
            makeFrame(ms: $0 * step, seatBack: 0.22, lean: 10, armReach: 0.15, armDrop: 0.05,
                      shoulderLag: 0, mirrored: false, shoulderSpread: 0.05,
                      wristsVisible: true, tracked: true)
        }
    }

    /// Strokes with the session scale fully established.
    ///
    /// The first emitted stroke is the scale warm-up: `ScaleReference` withholds a value until it
    /// has seen `minScaleSamples` frames, so that stroke's scale-dependent measurements are
    /// deliberately suppressed. Tests that care about the handle work from the rest.
    static func measuredStrokes(_ frames: [PoseFrame]) -> [RowStroke] {
        Array(RowStrokeAnalyzer.analyze(frames: frames).dropFirst())
    }
}
