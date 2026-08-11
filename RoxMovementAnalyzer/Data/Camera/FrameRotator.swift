import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Rotates decoded video frames upright, once, at the source.
///
/// A portrait phone clip is stored as a landscape buffer plus a `preferredTransform`, and something
/// has to apply that rotation. Two alternatives were tried and rejected:
///
/// - An `AVVideoComposition` re-renders the frame onto its own canvas, and the canvas size and the
///   layer-instruction transform have to agree. A 1080x1920 clip came back as a 1080x1024 buffer
///   with the image pillarboxed inside it, which then read as landscape everywhere downstream.
/// - Passing the orientation to the pose model and letting it rotate. The preview proved the
///   orientation itself was right, but the model still found no athlete, so it is not something to
///   depend on.
///
/// Rotating here means every consumer — the model, the preview, the landmark coordinate space —
/// receives the same upright frame, and there is no orientation flag left for anyone to disagree
/// about.
final class FrameRotator {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    /// The frame rotated upright, or the original when no rotation is needed.
    func upright(_ pixelBuffer: CVPixelBuffer, orientation: UIImage.Orientation) -> CVPixelBuffer? {
        guard orientation != .up else { return pixelBuffer }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(Self.propertyOrientation(for: orientation))
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }

        guard let destination = makeBuffer(size: size) else { return nil }

        // The oriented image's extent does not start at the origin, so render it back to (0, 0)
        // rather than into whatever rect the rotation left it at.
        context.render(
            image.transformed(by: .init(translationX: -image.extent.origin.x, y: -image.extent.origin.y)),
            to: destination
        )
        return destination
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())

        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &created
            ) == kCVReturnSuccess else { return nil }

            pool = created
            poolSize = size
        }

        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess
        else { return nil }
        return buffer
    }

    private static func propertyOrientation(
        for orientation: UIImage.Orientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .right: .right
        case .left: .left
        case .down: .down
        default: .up
        }
    }
}
