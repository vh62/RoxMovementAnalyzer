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
        (.rightKnee, .rightAnkle)
        // Twelve bones: shoulders, arms, torso, hips, legs — and nothing past the wrist or ankle.
        // See `PoseLandmarkName.isDrawnInOverlay` for why the face, fingers and feet are left out.
    ]

    /// The bones to draw for a profile view of one side.
    ///
    /// Five links rather than twelve. The two cross-body bones are gone because side-on they collapse
    /// to a near-zero-length stub, and the far arm and leg are gone because MediaPipe *estimates* them
    /// from behind the near ones — drawing them shows the athlete a limb that was guessed.
    static func connections(for side: BodySide?) -> [(PoseLandmarkName, PoseLandmarkName)] {
        guard let side else { return connections }
        return [
            (side.shoulder, side.elbow),
            (side.elbow, side.wrist),
            (side.shoulder, side.hip),
            (side.hip, side.knee),
            (side.knee, side.ankle)
        ]
    }

    /// The joints to draw for a profile view of one side.
    static func landmarks(for side: BodySide) -> Set<PoseLandmarkName> {
        [side.shoulder, side.elbow, side.wrist, side.hip, side.knee, side.ankle]
    }

    /// How the video is fitted into its container — and therefore how landmarks map onto it.
    ///
    /// The overlay and the video it sits on must agree, or the skeleton drifts off the body, which
    /// is why this lives here rather than in either view.
    enum ScalingMode {
        /// Fill the container and crop the overflow. Right when the source and the container share
        /// an orientation: a portrait clip on a portrait phone loses only a sliver off the sides.
        case aspectFill
        /// Fit the whole frame in and letterbox the rest. Required when they disagree —
        /// aspect-filling a landscape RowErg clip onto a portrait phone keeps about a quarter of
        /// the frame width and throws away most of the machine along with it.
        case aspectFit

        /// Fill when the source and container agree on orientation, fit when they do not.
        ///
        /// Wall balls is filmed portrait and rowing landscape, so this picks itself from the footage
        /// rather than needing the station to be threaded through every view.
        static func forSource(aspectRatio: Double, in size: CGSize) -> ScalingMode {
            guard size.height > 0 else { return .aspectFill }
            let sourceIsLandscape = aspectRatio > 1
            let containerIsLandscape = (size.width / size.height) > 1
            return sourceIsLandscape == containerIsLandscape ? .aspectFill : .aspectFit
        }
    }

    /// Maps a landmark's normalized coordinates into view/pixel space, matching how the preview
    /// layer fits the same video.
    static func point(
        forNormalizedX x: Double,
        y: Double,
        in size: CGSize,
        sourceAspectRatio: Double,
        scalingMode: ScalingMode = .aspectFill
    ) -> CGPoint {
        let containerAspectRatio = size.width / max(size.height, 1)

        // Which dimension the scaled frame is pinned to. Filling pins the one that overflows;
        // fitting pins the one that runs out first.
        let matchesHeight = switch scalingMode {
        case .aspectFill: sourceAspectRatio > containerAspectRatio
        case .aspectFit: sourceAspectRatio < containerAspectRatio
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
    static func mediaRect(
        in size: CGSize,
        sourceAspectRatio: Double,
        scalingMode: ScalingMode = .aspectFill
    ) -> CGRect {
        let topLeft = point(
            forNormalizedX: 0, y: 0, in: size,
            sourceAspectRatio: sourceAspectRatio, scalingMode: scalingMode
        )
        let bottomRight = point(
            forNormalizedX: 1, y: 1, in: size,
            sourceAspectRatio: sourceAspectRatio, scalingMode: scalingMode
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
        scalingMode: ScalingMode = .aspectFill
    ) -> CGPoint {
        point(
            forNormalizedX: landmark.x, y: landmark.y, in: size,
            sourceAspectRatio: sourceAspectRatio, scalingMode: scalingMode
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

    // MARK: - Power trail

    /// One drawable leg of the SkiErg hand path, with the effort it was travelling under.
    struct TrailSegment {
        let from: CGPoint
        let to: CGPoint
        /// The larger of the two endpoints' intensities, so a segment is drawn at the effort it
        /// represents rather than fading toward whichever end happens to come second.
        let intensity: Double
    }

    /// Maps a pull's hand path into view space, pairing consecutive points into drawable legs.
    ///
    /// Goes through `point(forNormalizedX:y:...)`, the same mapping every landmark uses, so the trail
    /// lands on the hands rather than near them.
    static func trailSegments(
        _ trail: [SkiPull.PowerSample],
        in size: CGSize,
        sourceAspectRatio: Double,
        scalingMode: ScalingMode = .aspectFill
    ) -> [TrailSegment] {
        guard trail.count >= 2 else { return [] }

        let points = trail.map {
            point(
                forNormalizedX: $0.x, y: $0.y, in: size,
                sourceAspectRatio: sourceAspectRatio, scalingMode: scalingMode
            )
        }

        return (0..<(points.count - 1)).map { index in
            TrailSegment(
                from: points[index],
                to: points[index + 1],
                intensity: max(trail[index].intensity, trail[index + 1].intensity)
            )
        }
    }

    /// How hard a segment is drawn, given its intensity.
    ///
    /// **Effort by width and opacity on a single hue, never by colour.** Green and red already mean
    /// depth-reached and fault everywhere else on this overlay, so a colour ramp would collide with a
    /// vocabulary the athlete has already learned. Ramping the weight instead keeps the trail reading
    /// as one quantity, and keeps faith with the rule that the overlay is a reference for the
    /// athlete's form rather than the subject of the frame.
    ///
    /// Lives here so the SwiftUI `Canvas` and the `CGContext` exporter cannot draw the same pull two
    /// different ways.
    static func trailShading(intensity: Double) -> (width: CGFloat, alpha: Double) {
        let clamped = min(max(intensity, 0), 1)
        return (width: 2 + 6 * clamped, alpha: 0.15 + 0.75 * clamped)
    }
}
