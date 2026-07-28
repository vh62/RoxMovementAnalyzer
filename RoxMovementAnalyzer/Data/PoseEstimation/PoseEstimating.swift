import CoreMedia
import Foundation

protocol PoseEstimating: AnyObject {
    var poseFrameHandler: ((PoseFrame) -> Void)? { get set }

    func detect(sampleBuffer: CMSampleBuffer, timestampInMilliseconds: Int)
}