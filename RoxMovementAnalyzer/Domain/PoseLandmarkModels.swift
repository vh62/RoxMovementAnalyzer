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

    /// Whether the core full-body joints — shoulders, hips, knees, and ankles on both sides — are
    /// all confidently tracked, i.e. the whole athlete is in frame.
    var hasFullBody: Bool {
        areVisible(
            .leftShoulder, .rightShoulder,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle
        )
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

    static func angleFromVertical(from lower: PoseLandmark, to upper: PoseLandmark) -> Double? {
        let deltaX = upper.x - lower.x
        let deltaY = lower.y - upper.y
        guard deltaX != 0 || deltaY != 0 else { return nil }
        return abs(atan2(deltaX, deltaY) * 180 / .pi)
    }
}