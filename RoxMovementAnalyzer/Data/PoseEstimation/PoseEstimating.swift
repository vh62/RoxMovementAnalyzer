import CoreVideo
import Foundation

protocol PoseEstimating: AnyObject {
    var poseFrameHandler: ((PoseFrame) -> Void)? { get set }

    /// - Parameter pixelBuffer: an **upright** frame. Rotation is the source's job, so nothing here
    ///   depends on the model honouring an orientation flag — a portrait clip decodes to a landscape
    ///   buffer, and a model handed that sideways finds no athlete at all.
    func detect(pixelBuffer: CVPixelBuffer, timestampInMilliseconds: Int)
}
