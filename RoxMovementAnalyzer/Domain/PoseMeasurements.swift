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

    func viewpoint(thresholds: WallBallThresholds = .default) -> CameraViewpoint {
        guard let ratio = shoulderToTorsoRatio else { return .unknown }

        if ratio < thresholds.sideOnRatio { return .sideOn }
        if ratio > thresholds.frontOnRatio { return .frontOn }
        return .angled
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
