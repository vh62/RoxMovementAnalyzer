import CoreGraphics
import Foundation

/// Geometry and rules shared by every pose overlay renderer.
///
/// The overlay is drawn twice in the app — as a SwiftUI `Canvas` (live camera and playback) and
/// into a `CGContext` (burned-in video export). Those use different drawing APIs, but the maths
/// and the depth rules must stay identical, so they live here.
enum PoseOverlayGeometry {
    /// Skeleton bones, as pairs of landmarks to connect.
    static let connections: [(PoseLandmarkName, PoseLandmarkName)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel),
        (.leftHeel, .leftFootIndex),
        (.leftAnkle, .leftFootIndex),
        (.rightAnkle, .rightHeel),
        (.rightHeel, .rightFootIndex),
        (.rightAnkle, .rightFootIndex),
        (.leftWrist, .leftThumb),
        (.leftWrist, .leftIndex),
        (.leftWrist, .leftPinky),
        (.leftIndex, .leftPinky),
        (.rightWrist, .rightThumb),
        (.rightWrist, .rightIndex),
        (.rightWrist, .rightPinky),
        (.rightIndex, .rightPinky),
        (.nose, .leftEyeInner),
        (.leftEyeInner, .leftEye),
        (.leftEye, .leftEyeOuter),
        (.nose, .rightEyeInner),
        (.rightEyeInner, .rightEye),
        (.rightEye, .rightEyeOuter),
        (.mouthLeft, .mouthRight)
    ]

    /// Maps a landmark's normalized coordinates into view/pixel space using aspect-FILL, matching
    /// how the camera preview and the player layer letterbox their video.
    static func point(
        forNormalizedX x: Double,
        y: Double,
        in size: CGSize,
        sourceAspectRatio: Double
    ) -> CGPoint {
        let containerAspectRatio = size.width / max(size.height, 1)
        let scaledSize: CGSize
        let offset: CGPoint

        if sourceAspectRatio > containerAspectRatio {
            scaledSize = CGSize(width: size.height * sourceAspectRatio, height: size.height)
            offset = CGPoint(x: (size.width - scaledSize.width) / 2, y: 0)
        } else {
            scaledSize = CGSize(width: size.width, height: size.width / max(sourceAspectRatio, 0.001))
            offset = CGPoint(x: 0, y: (size.height - scaledSize.height) / 2)
        }

        return CGPoint(
            x: offset.x + CGFloat(x) * scaledSize.width,
            y: offset.y + CGFloat(y) * scaledSize.height
        )
    }

    static func point(
        for landmark: PoseLandmark,
        in size: CGSize,
        sourceAspectRatio: Double
    ) -> CGPoint {
        point(forNormalizedX: landmark.x, y: landmark.y, in: size, sourceAspectRatio: sourceAspectRatio)
    }

    /// Squat-depth state for a frame, used for the knee-height parallel line and the depth callout.
    struct DepthGuide {
        /// Normalized y of the knee line (the "parallel" reference).
        let kneeLevel: Double
        /// Normalized y of the hips, when tracked.
        let hipLevel: Double?

        /// Whether the hip has broken below the knee — the legal wall-ball depth rule.
        var hasReachedDepth: Bool {
            guard let hipLevel else { return false }
            return hipLevel >= kneeLevel
        }

        /// How far below parallel the hips are, as a percentage of frame height. Negative while
        /// the athlete is still above parallel.
        var percentBelowParallel: Double {
            guard let hipLevel else { return 0 }
            return (hipLevel - kneeLevel) * 100
        }
    }

    /// Depth state for a frame, or nil when the knees are not tracked.
    static func depthGuide(for frame: PoseFrame) -> DepthGuide? {
        guard let kneeLevel = frame.visibleAverageY(.leftKnee, .rightKnee) else { return nil }
        return DepthGuide(
            kneeLevel: kneeLevel,
            hipLevel: frame.visibleAverageY(.leftHip, .rightHip)
        )
    }
}
