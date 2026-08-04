#if DEBUG
import CoreImage
import CoreVideo
import SwiftUI
import UIKit

/// Shows the frame the pose estimator just analysed, for the debug video-file source.
///
/// Deliberately renders the decoded frame itself rather than playing the same file alongside it:
/// a separate player would drift from the frames actually being analysed, and the main reason to
/// look at this preview is to check the pose overlay lines up with the body.
///
/// Uses aspect-fit for picked debug videos so calibration clips are never visually cropped.
/// `LiveAnalysisView` passes the same fit mode to `PoseOverlayView`, keeping the overlay aligned.
struct DecodedFramePreview: UIViewRepresentable {
    let pixelBuffer: CVPixelBuffer?

    func makeUIView(context: Context) -> FrameView {
        let view = FrameView()
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
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
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.masksToBounds = true
            layer.addSublayer(imageLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // No implicit animation: frames arrive continuously and a fade would smear them.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = bounds
            CATransaction.commit()
        }

        func display(_ pixelBuffer: CVPixelBuffer?) {
            guard let pixelBuffer else { return }

            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = cgImage
            CATransaction.commit()
        }
    }
}
#endif
