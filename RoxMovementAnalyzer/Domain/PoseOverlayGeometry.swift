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

    /// How the video is fitted into its container — and therefore how landmarks map onto it.
    ///
    /// The overlay and the video it sits on must agree, or the skeleton drifts off the body, which
    /// is why this lives here rather than in either view.
    enum ContentMode {
        /// Fill the container and crop the overflow. Right when the source and the container share
        /// an orientation: a portrait clip on a portrait phone loses only a sliver off the sides.
        case fill
        /// Fit the whole frame in and letterbox the rest. Required when they disagree —
        /// aspect-filling a landscape RowErg clip onto a portrait phone keeps about a quarter of
        /// the frame width and throws away most of the machine along with it.
        case fit

        /// Fill when the source and container agree on orientation, fit when they do not.
        ///
        /// Wall balls is filmed portrait and rowing landscape, so this picks itself from the footage
        /// rather than needing the station to be threaded through every view.
        static func forSource(aspectRatio: Double, in size: CGSize) -> ContentMode {
            guard size.height > 0 else { return .fill }
            let sourceIsLandscape = aspectRatio > 1
            let containerIsLandscape = (size.width / size.height) > 1
            return sourceIsLandscape == containerIsLandscape ? .fill : .fit
        }
    }

    /// Maps a landmark's normalized coordinates into view/pixel space, matching how the preview
    /// layer fits the same video.
    static func point(
        forNormalizedX x: Double,
        y: Double,
        in size: CGSize,
        sourceAspectRatio: Double,
        contentMode: ContentMode = .fill
    ) -> CGPoint {
        let containerAspectRatio = size.width / max(size.height, 1)

        // Which dimension the scaled frame is pinned to. Filling pins the one that overflows;
        // fitting pins the one that runs out first.
        let matchesHeight = switch contentMode {
        case .fill: sourceAspectRatio > containerAspectRatio
        case .fit: sourceAspectRatio < containerAspectRatio
        }

        let scaledSize = matchesHeight
            ? CGSize(width: size.height * sourceAspectRatio, height: size.height)
            : CGSize(width: size.width, height: size.width / max(sourceAspectRatio, 0.001))

        // Centred either way: negative offsets crop, positive ones letterbox.
        let offset = CGPoint(
            x: (size.width - scaledSize.width) / 2,
            y: (size.height - scaledSize.height) / 2
        )

        return CGPoint(
            x: offset.x + CGFloat(x) * scaledSize.width,
            y: offset.y + CGFloat(y) * scaledSize.height
        )
    }

    /// Where the video itself sits inside the container, in view coordinates.
    ///
    /// Guides that span "the whole frame" — the squat parallel line especially — must span *this*,
    /// not the container. Drawn edge to edge they run out over the letterbox bars and read as a
    /// measurement of something that is not there.
    static func videoRect(
        in size: CGSize,
        sourceAspectRatio: Double,
        contentMode: ContentMode = .fill
    ) -> CGRect {
        let topLeft = point(
            forNormalizedX: 0, y: 0, in: size,
            sourceAspectRatio: sourceAspectRatio, contentMode: contentMode
        )
        let bottomRight = point(
            forNormalizedX: 1, y: 1, in: size,
            sourceAspectRatio: sourceAspectRatio, contentMode: contentMode
        )

        return CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        ).intersection(CGRect(origin: .zero, size: size))
    }

    static func point(
        for landmark: PoseLandmark,
        in size: CGSize,
        sourceAspectRatio: Double,
        contentMode: ContentMode = .fill
    ) -> CGPoint {
        point(
            forNormalizedX: landmark.x, y: landmark.y, in: size,
            sourceAspectRatio: sourceAspectRatio, contentMode: contentMode
        )
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
