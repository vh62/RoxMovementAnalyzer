import Foundation

/// Which way the camera is facing the athlete, inferred from how wide the shoulders appear
/// relative to the torso.
///
/// Horizontal measurements (how far in front of the body the hands are) only mean anything from
/// a side-on view, so analysis uses this to suppress measurements it cannot make honestly rather
/// than reporting a number that looks precise and is wrong.
enum CameraViewpoint: String, Equatable {
    case sideOn = "Side-on"
    case angled = "Angled"
    case frontOn = "Front-on"
    case unknown = "Unknown"

    /// Whether horizontal reach can be measured meaningfully from this viewpoint.
    var supportsReachMeasurement: Bool {
        self == .sideOn || self == .angled
    }
}

/// Where the shoulder-width-to-torso ratio divides one viewpoint from the next.
///
/// Extracted from `WallBallThresholds` so that classifying the camera angle — which every station
/// needs, for the same reason — does not require passing another station's configuration.
struct ViewpointThresholds: Equatable {
    static let `default` = ViewpointThresholds()

    /// Shoulder width ÷ torso length below this reads as a side-on view.
    var sideOnRatio: Double = 0.5
    /// Shoulder width ÷ torso length above this reads as a front-on view.
    var frontOnRatio: Double = 0.8
}

/// Which side of the body a measurement was taken from.
///
/// Side-on, the far limb is behind the near one and MediaPipe estimates rather than tracks it, so
/// measurements that need a real joint position have to say which side they mean.
enum BodySide: CaseIterable {
    case left
    case right

    var shoulder: PoseLandmarkName { self == .left ? .leftShoulder : .rightShoulder }
    var hip: PoseLandmarkName { self == .left ? .leftHip : .rightHip }
    var knee: PoseLandmarkName { self == .left ? .leftKnee : .rightKnee }
    var ankle: PoseLandmarkName { self == .left ? .leftAnkle : .rightAnkle }
    var elbow: PoseLandmarkName { self == .left ? .leftElbow : .rightElbow }
    var wrist: PoseLandmarkName { self == .left ? .leftWrist : .rightWrist }
}

/// Scale-invariant measurements derived from a single pose frame.
///
/// Everything is normalized by torso length, so a value means the same thing whether the athlete
/// is two metres or five metres from the camera.
extension PoseFrame {
    /// Shoulder-centre to hip-centre distance in normalized image units — the scale reference for
    /// every other measurement. Nil when the torso is not tracked, or degenerate.
    var torsoLength: Double? {
        guard let shoulder = midpoint(.leftShoulder, .rightShoulder),
              let hip = midpoint(.leftHip, .rightHip) else { return nil }

        let length = hypot(shoulder.x - hip.x, shoulder.y - hip.y)
        return length > 0.01 ? length : nil
    }

    /// Apparent shoulder width relative to torso length. Wide means the athlete is facing the
    /// camera; narrow means they are side-on and one shoulder is hiding the other.
    var shoulderToTorsoRatio: Double? {
        guard let left = landmark(.leftShoulder), let right = landmark(.rightShoulder),
              left.isVisible, right.isVisible,
              let torsoLength else { return nil }

        return hypot(left.x - right.x, left.y - right.y) / torsoLength
    }

    func viewpoint(thresholds: ViewpointThresholds = .default) -> CameraViewpoint {
        guard let ratio = shoulderToTorsoRatio else { return .unknown }

        if ratio < thresholds.sideOnRatio { return .sideOn }
        if ratio > thresholds.frontOnRatio { return .frontOn }
        return .angled
    }

    /// Centre of a left/right pair using only the confidently tracked side(s).
    ///
    /// Unlike `midpoint(_:_:)` this never averages in an occluded far joint — precisely the joint
    /// MediaPipe estimates rather than tracks in a side-on view. It returns a plain coordinate pair
    /// rather than a `PoseLandmark` on purpose: `midpoint` synthesises a landmark with no
    /// visibility, and `isVisible` treats a missing value as visible, so two occluded joints come
    /// back as one confident-looking one. A tuple cannot be laundered that way.
    func visibleCenter(
        _ first: PoseLandmarkName,
        _ second: PoseLandmarkName
    ) -> (x: Double, y: Double)? {
        let points = [first, second].compactMap { landmark($0) }.filter(\.isVisible)
        guard !points.isEmpty else { return nil }

        let count = Double(points.count)
        return (
            x: points.map(\.x).reduce(0, +) / count,
            y: points.map(\.y).reduce(0, +) / count
        )
    }

    /// Mean reported confidence of hip, knee and ankle on one side. Side-on the near side scores
    /// higher, which is how the analyzer picks which leg to measure.
    func sagittalConfidence(_ side: BodySide) -> Double {
        let confidences = [side.hip, side.knee, side.ankle]
            .compactMap { landmark($0) }
            .map { $0.visibility ?? 1 }

        guard !confidences.isEmpty else { return 0 }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    /// Hip-knee-ankle angle on one side. 180° is a fully extended leg.
    func kneeAngle(_ side: BodySide) -> Double? {
        trackedAngle(at: side.knee, from: side.hip, to: side.ankle)
    }

    /// Shoulder-elbow-wrist angle on one side. 180° is a straight arm.
    func elbowAngle(_ side: BodySide) -> Double? {
        trackedAngle(at: side.elbow, from: side.shoulder, to: side.wrist)
    }

    /// Shoulder-hip-knee angle on one side — how closed the athlete is at the hip.
    func hipAngle(_ side: BodySide) -> Double? {
        trackedAngle(at: side.hip, from: side.shoulder, to: side.knee)
    }

    /// An angle only if all three joints are actually tracked.
    ///
    /// `angle(at:from:to:)` will happily compute from MediaPipe's estimate of an occluded joint,
    /// which is right for drawing and wrong for measuring — an elbow angle taken from a guessed
    /// wrist reads as a real measurement and is not one. Analysis that would rather report nothing
    /// than report a fabricated number goes through here.
    private func trackedAngle(
        at vertex: PoseLandmarkName,
        from first: PoseLandmarkName,
        to second: PoseLandmarkName
    ) -> Double? {
        guard areVisible(vertex, first, second) else { return nil }
        return angle(at: vertex, from: first, to: second)
    }

    /// How far the hands are raised above the shoulders, in torso lengths. Rises through the
    /// throw and peaks at full extension, which is when the ball leaves the hands.
    ///
    /// Uses whichever wrist is tracked so a side-on view still works.
    var armHeightAboveShoulders: Double? {
        guard let wristY = visibleAverageY(.leftWrist, .rightWrist),
              let shoulderY = visibleAverageY(.leftShoulder, .rightShoulder),
              let torsoLength else { return nil }

        // y increases downward, so a wrist above the shoulder gives a positive value.
        return (shoulderY - wristY) / torsoLength
    }

    /// Horizontal distance from the shoulders to the hands, in torso lengths — how far out in
    /// front of the body the ball is being held. Only meaningful side-on.
    var handReachFromShoulders: Double? {
        guard let wristX = visibleAverageX(.leftWrist, .rightWrist),
              let shoulderX = visibleAverageX(.leftShoulder, .rightShoulder),
              let torsoLength else { return nil }

        return abs(wristX - shoulderX) / torsoLength
    }

    /// How straight the legs are, as the larger of the two hip-knee-ankle angles. 180° is fully
    /// extended. Takes the maximum so a partly occluded far leg does not drag the reading down.
    var legExtensionAngle: Double? {
        let angles = [
            angle(at: .leftKnee, from: .leftHip, to: .leftAnkle),
            angle(at: .rightKnee, from: .rightHip, to: .rightAnkle)
        ].compactMap { $0 }

        return angles.max()
    }

    /// Whether the hands are tracked — required to measure release and catch. At full extension a
    /// tightly framed shot pushes the wrists out of frame, which is exactly when we need them.
    var hasTrackedHands: Bool {
        (landmark(.leftWrist)?.isVisible ?? false) || (landmark(.rightWrist)?.isVisible ?? false)
    }

    /// Average normalized x of whichever of the given landmarks are confidently tracked.
    /// Mirrors `visibleAverageY` for horizontal measurements.
    func visibleAverageX(_ names: PoseLandmarkName...) -> Double? {
        let xs = names.compactMap { landmark($0) }.filter(\.isVisible).map(\.x)
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }
}
