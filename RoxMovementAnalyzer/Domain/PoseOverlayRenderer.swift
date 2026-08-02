import CoreGraphics
import CoreText
import Foundation

/// Draws the pose overlay into a `CGContext` for burning into an exported video.
///
/// The SwiftUI `PoseOverlayView` renders the same thing for on-screen use; both take their
/// geometry and depth rules from `PoseOverlayGeometry` so the two cannot drift apart.
///
/// Expects a context in image coordinates with the origin at the top-left (as set up by
/// `OverlayVideoExporter`), matching the normalized landmark space where y increases downward.
struct PoseOverlayRenderer {
    /// Scales stroke widths and text relative to a reference height, so a 1080p export looks like
    /// the on-screen overlay rather than hairline-thin.
    private static let referenceHeight: CGFloat = 800

    struct Frame {
        let pose: PoseFrame
        let validReps: Int
        /// Set on the frames where a rep was just counted, driving the "REP N — COUNTED" callout.
        let justCountedRep: Bool
        /// An inefficiency detected on the rep just finished, called out instead of the count.
        var fault: WallBallFault?
    }

    let showsDepthGuide: Bool
    let requiresFullBody: Bool

    func draw(_ frame: Frame, in context: CGContext, size: CGSize) {
        let scale = max(size.height / Self.referenceHeight, 1)
        let pose = frame.pose

        if requiresFullBody && !pose.hasFullBody {
            return
        }

        if showsDepthGuide, let guide = PoseOverlayGeometry.depthGuide(for: pose) {
            drawDepthGuide(guide, pose: pose, in: context, size: size, scale: scale)
        }

        drawConnections(pose, in: context, size: size, scale: scale)
        drawLandmarks(pose, in: context, size: size, scale: scale)
        drawRepBadge(frame, in: context, size: size, scale: scale)

        if showsDepthGuide {
            if let fault = frame.fault {
                drawFaultCallout(fault, in: context, size: size, scale: scale)
            } else if frame.justCountedRep, let guide = PoseOverlayGeometry.depthGuide(for: pose) {
                drawRepCallout(frame, guide: guide, in: context, size: size, scale: scale)
            }
        }
    }

    // MARK: - Layers

    private func drawDepthGuide(
        _ guide: PoseOverlayGeometry.DepthGuide,
        pose: PoseFrame,
        in context: CGContext,
        size: CGSize,
        scale: CGFloat
    ) {
        let kneeY = PoseOverlayGeometry.point(
            forNormalizedX: 0.5,
            y: guide.kneeLevel,
            in: size,
            sourceAspectRatio: pose.sourceAspectRatio
        ).y

        let reached = guide.hasReachedDepth
        let color: CGColor = reached
            ? CGColor(red: 0.19, green: 0.82, blue: 0.48, alpha: 1)
            : CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)

        context.saveGState()
        context.setLineDash(phase: 0, lengths: [12 * scale, 7 * scale])

        context.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
        context.setLineWidth(5 * scale)
        context.move(to: CGPoint(x: 0, y: kneeY))
        context.addLine(to: CGPoint(x: size.width, y: kneeY))
        context.strokePath()

        context.setStrokeColor(color)
        context.setLineWidth(3 * scale)
        context.move(to: CGPoint(x: 0, y: kneeY))
        context.addLine(to: CGPoint(x: size.width, y: kneeY))
        context.strokePath()
        context.restoreGState()

        drawText(
            "PARALLEL",
            at: CGPoint(x: 12 * scale, y: kneeY - 20 * scale),
            fontSize: 13 * scale,
            color: color,
            in: context,
            background: CGColor(gray: 0, alpha: 0.55)
        )
    }

    private func drawConnections(_ pose: PoseFrame, in context: CGContext, size: CGSize, scale: CGFloat) {
        for connection in PoseOverlayGeometry.connections {
            guard let start = pose.landmark(connection.0), let end = pose.landmark(connection.1),
                  start.isVisible, end.isVisible else { continue }

            let a = PoseOverlayGeometry.point(for: start, in: size, sourceAspectRatio: pose.sourceAspectRatio)
            let b = PoseOverlayGeometry.point(for: end, in: size, sourceAspectRatio: pose.sourceAspectRatio)

            context.setStrokeColor(CGColor(gray: 0, alpha: 0.72))
            context.setLineWidth(6 * scale)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()

            context.setStrokeColor(CGColor(red: 1, green: 0.84, blue: 0.04, alpha: 1))
            context.setLineWidth(4 * scale)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        }
    }

    private func drawLandmarks(_ pose: PoseFrame, in context: CGContext, size: CGSize, scale: CGFloat) {
        for landmark in pose.landmarks where landmark.isVisible {
            let position = PoseOverlayGeometry.point(
                for: landmark, in: size, sourceAspectRatio: pose.sourceAspectRatio
            )
            let radius = 4 * scale
            let rect = CGRect(
                x: position.x - radius, y: position.y - radius,
                width: radius * 2, height: radius * 2
            )

            context.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1))
            context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(1.5 * scale)
            context.strokeEllipse(in: rect)
        }
    }

    private func drawRepBadge(_ frame: Frame, in context: CGContext, size: CGSize, scale: CGFloat) {
        let origin = CGPoint(x: 16 * scale, y: 16 * scale)
        let badgeSize = CGSize(width: 132 * scale, height: 64 * scale)
        let rect = CGRect(origin: origin, size: badgeSize)

        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
        context.fillPath()

        drawText(
            "\(frame.validReps)",
            at: CGPoint(x: origin.x + 14 * scale, y: origin.y + 8 * scale),
            fontSize: 34 * scale,
            color: CGColor(gray: 1, alpha: 1),
            in: context
        )
        drawText(
            "VALID REPS",
            at: CGPoint(x: origin.x + 14 * scale, y: origin.y + 46 * scale),
            fontSize: 11 * scale,
            color: CGColor(gray: 1, alpha: 0.85),
            in: context
        )
    }

    private func drawRepCallout(
        _ frame: Frame,
        guide: PoseOverlayGeometry.DepthGuide,
        in context: CGContext,
        size: CGSize,
        scale: CGFloat
    ) {
        let text = String(
            format: "REP %d — COUNTED  ·  %.1f%% BELOW PARALLEL",
            frame.validReps,
            max(guide.percentBelowParallel, 0)
        )

        drawText(
            text,
            at: CGPoint(x: 16 * scale, y: size.height - 44 * scale),
            fontSize: 14 * scale,
            color: CGColor(red: 0.19, green: 0.82, blue: 0.48, alpha: 1),
            in: context,
            background: CGColor(gray: 0, alpha: 0.6)
        )
    }

    private func drawFaultCallout(
        _ fault: WallBallFault,
        in context: CGContext,
        size: CGSize,
        scale: CGFloat
    ) {
        drawText(
            fault.title.uppercased() + "  ·  " + fault.liveMessage,
            at: CGPoint(x: 16 * scale, y: size.height - 44 * scale),
            fontSize: 14 * scale,
            color: CGColor(red: 1, green: 0.42, blue: 0.35, alpha: 1),
            in: context,
            background: CGColor(gray: 0, alpha: 0.6)
        )
    }

    // MARK: - Text

    private func drawText(
        _ string: String,
        at origin: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        in context: CGContext,
        background: CGColor? = nil
    ) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        let attributed = NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )

        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        if let background {
            let padding = fontSize * 0.35
            let box = CGRect(
                x: origin.x - padding,
                y: origin.y - padding,
                width: bounds.width + padding * 2,
                height: bounds.height + padding * 2
            )
            context.setFillColor(background)
            context.addPath(CGPath(
                roundedRect: box, cornerWidth: padding, cornerHeight: padding, transform: nil
            ))
            context.fillPath()
        }

        // Flip for CoreText, which draws with the origin at the baseline in a y-up space.
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
