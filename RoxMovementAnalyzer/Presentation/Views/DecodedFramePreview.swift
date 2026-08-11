import CoreImage
import CoreVideo
import SwiftUI
import UIKit

/// Shows the frame the pose estimator just analysed, for the video-file source.
///
/// Deliberately renders the decoded frame itself rather than playing the same file alongside it:
/// a separate player would drift from the frames actually being analysed, and the main reason to
/// look at this preview is to check the pose overlay lines up with the body.
struct DecodedFramePreview: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer?

    func makeUIView(context: Context) -> FrameView {
        let view = FrameView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        // UIKit derives `layer.contentsGravity` from `contentMode` on every layout pass, so these
        // two have to agree or the view silently overwrites the gravity chosen below.
        view.contentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ uiView: FrameView, context: Context) {
        uiView.display(pixelBuffer)
    }

    final class FrameView: UIView {
        private let context = CIContext(options: [.useSoftwareRenderer: false])
        private let imageLayer = CALayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Anchored at the origin so the frame set below is the whole story — no implicit
            // centring on a position that might not have been updated.
            imageLayer.anchorPoint = .zero
            imageLayer.position = .zero
            imageLayer.masksToBounds = true
            layer.addSublayer(imageLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            syncImageLayerFrame()
        }

        func display(_ pixelBuffer: CVPixelBuffer?) {
            guard let pixelBuffer else { return }

            // Already upright — the source rotates before handing the buffer over.
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { return }

            // Match however the overlay is mapping landmarks onto this same frame. A landscape
            // RowErg clip aspect-filled onto a portrait phone would keep about a quarter of its
            // width, so it letterboxes instead.
            let aspectRatio = image.extent.height > 0
                ? Double(image.extent.width / image.extent.height)
                : 1
            let mode = PoseOverlayGeometry.ScalingMode.forSource(aspectRatio: aspectRatio, in: bounds.size)

            // No implicit animation: frames arrive continuously and a fade would smear them.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Re-applied per frame rather than only on layout. A layout pass that never fires leaves
            // the layer at a stale rect, which is exactly how the frame ended up drawn off to one
            // side while every other measurement said the container was full-screen.
            syncImageLayerFrame()
            imageLayer.contentsGravity = mode == .aspectFill ? .resizeAspectFill : .resizeAspect
            imageLayer.contents = cgImage
            CATransaction.commit()
        }

        private func syncImageLayerFrame() {
            let rect = CGRect(origin: .zero, size: bounds.size)
            if imageLayer.frame != rect {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                imageLayer.frame = rect
                CATransaction.commit()
            }
        }
    }
}
