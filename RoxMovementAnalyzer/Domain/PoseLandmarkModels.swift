import Foundation

struct PoseFrame: Equatable {
    let timestampInMilliseconds: Int
    let sourceAspectRatio: Double
    let landmarks: [PoseLandmark]

    func landmark(_ name: PoseLandmarkName) -> PoseLandmark? {
        landmarks.first { $0.name == name }
    }

    func areVisible(_ names: PoseLandmarkName...) -> Bool {
        names.allSatisfy { landmark($0)?.isVisible ?? false }
    }

    /// Whether at least one of a left/right pair is tracked.
    ///
    /// Filmed from the side, the far limb is hidden behind the near one and comes back at low
    /// confidence, so requiring both sides of a joint is a test no side-on footage can pass.
    func isEitherVisible(_ first: PoseLandmarkName, _ second: PoseLandmarkName) -> Bool {
        (landmark(first)?.isVisible ?? false) || (landmark(second)?.isVisible ?? false)
    }

    /// Whether the whole athlete is in frame: shoulders, hips, knees and ankles each tracked on
    /// at least one side.
    ///
    /// A body region counts as trackable when either side of it is visible — the same rule the
    /// depth measurement uses. Individual occluded joints are still filtered out when drawing, so
    /// the far limb simply does not appear rather than blocking the whole skeleton.
    var hasFullBody: Bool {
        isEitherVisible(.leftShoulder, .rightShoulder)
            && isEitherVisible(.leftHip, .rightHip)
            && isEitherVisible(.leftKnee, .rightKnee)
            && isEitherVisible(.leftAnkle, .rightAnkle)
    }

    /// Average normalized y of whichever of the given landmarks are confidently tracked (one or more).
    /// Returns nil only if none are visible. Lets depth checks work from a side view where only the
    /// near-side joint is reliable.
    func visibleAverageY(_ names: PoseLandmarkName...) -> Double? {
        let ys = names.compactMap { landmark($0) }.filter(\.isVisible).map(\.y)
        guard !ys.isEmpty else { return nil }
        return ys.reduce(0, +) / Double(ys.count)
    }

    func midpoint(_ firstName: PoseLandmarkName, _ secondName: PoseLandmarkName) -> PoseLandmark? {
        guard let first = landmark(firstName), let second = landmark(secondName) else { return nil }
        return PoseLandmark(
            name: firstName,
            x: (first.x + second.x) / 2,
            y: (first.y + second.y) / 2,
            z: (first.z + second.z) / 2,
            visibility: nil,
            presence: nil
        )
    }

    func angle(at vertexName: PoseLandmarkName, from firstName: PoseLandmarkName, to secondName: PoseLandmarkName) -> Double? {
        guard let vertex = landmark(vertexName), let first = landmark(firstName), let second = landmark(secondName) else { return nil }
        return PoseGeometry.angle(at: vertex, from: first, to: second)
    }

    func torsoLeanAngle() -> Double? {
        guard let shoulderCenter = midpoint(.leftShoulder, .rightShoulder), let hipCenter = midpoint(.leftHip, .rightHip) else { return nil }
        return PoseGeometry.angleFromVertical(from: hipCenter, to: shoulderCenter)
    }

    func hipHingeAngle() -> Double? {
        guard let shoulderCenter = midpoint(.leftShoulder, .rightShoulder), let hipCenter = midpoint(.leftHip, .rightHip), let kneeCenter = midpoint(.leftKnee, .rightKnee) else { return nil }
        return PoseGeometry.angle(at: hipCenter, from: shoulderCenter, to: kneeCenter)
    }
}

struct PoseLandmark: Equatable {
    static let visibilityThreshold = 0.5

    let name: PoseLandmarkName
    let x: Double
    let y: Double
    let z: Double
    let visibility: Double?
    let presence: Double?

    /// Whether the joint is confidently in frame. Landmarks below the threshold are MediaPipe's
    /// estimates of occluded or off-screen joints and should not be drawn. A missing value is
    /// treated as visible so nothing is hidden when the model does not report confidence.
    var isVisible: Bool {
        (visibility ?? 1) >= Self.visibilityThreshold
    }
}

extension PoseLandmarkName {
    /// Whether the overlay draws this landmark.
    ///
    /// MediaPipe returns all 33 because BlazePose always does. Two groups are excluded because
    /// nothing in the app reads them — not squat depth, not the rowing stroke sequence, not the
    /// viewpoint check — and each one covers part of the athlete the overlay has no reason to hide:
    ///
    /// - **The face**: nose, eyes, ears, mouth. Eleven dots on the head, which is what makes a
    ///   side-on athlete hardest to recognise in their own footage.
    /// - **Finger and foot detail**: thumb, index, pinky, heel, foot index. A fan at the end of
    ///   each hand and foot, right where an athlete looks to check their stance.
    ///
    /// **Burpee broad jumps break the "nothing reads them" half of that.** Rules 5 and 6 are judged on
    /// the fingertip and the toe — `.leftIndex`/`.rightIndex` against `.leftFootIndex`/`.rightFootIndex`
    /// — so for that one station they are the two most load-bearing landmarks on the athlete, and
    /// arguably the ones most worth drawing. They stay hidden for now because this property has no
    /// station to switch on: making it station-aware means threading one through `PoseOverlayRenderer`
    /// and the burn-in export path, which is its own change rather than a line here.
    ///
    /// The **wrist** and **ankle** are kept, because both are load-bearing rather than decorative.
    /// The wrist stands in for the ball and the handle; the ankle carries rowing's knee angle, its
    /// facing check and every horizontal offset, and gates `hasFullBody` for both stations.
    var isDrawnInOverlay: Bool {
        switch self {
        case .nose, .leftEyeInner, .leftEye, .leftEyeOuter,
             .rightEyeInner, .rightEye, .rightEyeOuter,
             .leftEar, .rightEar, .mouthLeft, .mouthRight,
             .leftThumb, .rightThumb, .leftIndex, .rightIndex,
             .leftPinky, .rightPinky,
             .leftHeel, .rightHeel, .leftFootIndex, .rightFootIndex:
            false
        default:
            true
        }
    }
}

enum PoseLandmarkName: Int, CaseIterable {
    case nose = 0
    case leftEyeInner = 1
    case leftEye = 2
    case leftEyeOuter = 3
    case rightEyeInner = 4
    case rightEye = 5
    case rightEyeOuter = 6
    case leftEar = 7
    case rightEar = 8
    case mouthLeft = 9
    case mouthRight = 10
    case leftShoulder = 11
    case rightShoulder = 12
    case leftElbow = 13
    case rightElbow = 14
    case leftWrist = 15
    case rightWrist = 16
    case leftPinky = 17
    case rightPinky = 18
    case leftIndex = 19
    case rightIndex = 20
    case leftThumb = 21
    case rightThumb = 22
    case leftHip = 23
    case rightHip = 24
    case leftKnee = 25
    case rightKnee = 26
    case leftAnkle = 27
    case rightAnkle = 28
    case leftHeel = 29
    case rightHeel = 30
    case leftFootIndex = 31
    case rightFootIndex = 32
}

enum PoseGeometry {
    static func angle(at vertex: PoseLandmark, from first: PoseLandmark, to second: PoseLandmark) -> Double? {
        let firstVector = (x: first.x - vertex.x, y: first.y - vertex.y)
        let secondVector = (x: second.x - vertex.x, y: second.y - vertex.y)
        let dotProduct = firstVector.x * secondVector.x + firstVector.y * secondVector.y
        let firstMagnitude = hypot(firstVector.x, firstVector.y)
        let secondMagnitude = hypot(secondVector.x, secondVector.y)

        guard firstMagnitude > 0, secondMagnitude > 0 else { return nil }

        let cosine = max(-1, min(1, dotProduct / (firstMagnitude * secondMagnitude)))
        return acos(cosine) * 180 / .pi
    }

    /// Angle from vertical in degrees, **signed**: positive when `upper` sits at a greater x than
    /// `lower` in image coordinates.
    ///
    /// Image-relative, not athlete-relative. Which direction counts as "forward" depends on which
    /// way the athlete faces, so callers apply the facing sign themselves and this stays a dumb
    /// primitive — see `PoseFrame.forwardTorsoLean(facing:)`.
    static func signedAngleFromVertical(
        fromX: Double, fromY: Double, toX: Double, toY: Double
    ) -> Double? {
        let deltaX = toX - fromX
        let deltaY = fromY - toY
        guard deltaX != 0 || deltaY != 0 else { return nil }
        return atan2(deltaX, deltaY) * 180 / .pi
    }

    static func signedAngleFromVertical(from lower: PoseLandmark, to upper: PoseLandmark) -> Double? {
        signedAngleFromVertical(fromX: lower.x, fromY: lower.y, toX: upper.x, toY: upper.y)
    }

    /// Magnitude of the lean, direction discarded — the right primitive when only "how far from
    /// upright" matters. Defined in terms of the signed form so the two cannot drift apart.
    static func angleFromVertical(from lower: PoseLandmark, to upper: PoseLandmark) -> Double? {
        signedAngleFromVertical(from: lower, to: upper).map(abs)
    }
}