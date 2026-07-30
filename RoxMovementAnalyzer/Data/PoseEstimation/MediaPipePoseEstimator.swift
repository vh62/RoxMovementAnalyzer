import CoreMedia
import Foundation
import MediaPipeTasksVision
import os

final class MediaPipePoseEstimator: NSObject, PoseEstimating {
    private static let log = Logger(subsystem: "rox.pose", category: "MediaPipePoseEstimator")

    var poseFrameHandler: ((PoseFrame) -> Void)?

    private var poseLandmarker: PoseLandmarker!
    private var frameAspectRatios: [Int: Double] = [:]
    private let aspectRatioLock = NSLock()

    init(
        modelName: String = "pose_landmarker_lite",
        minimumPoseDetectionConfidence: Float = 0.5,
        minimumPosePresenceConfidence: Float = 0.5,
        minimumTrackingConfidence: Float = 0.5
    ) throws {
        guard let modelPath = Bundle.main.path(forResource: modelName, ofType: "task") else {
            throw MediaPipePoseEstimatorError.missingModel(modelName)
        }

        super.init()

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = minimumPoseDetectionConfidence
        options.minPosePresenceConfidence = minimumPosePresenceConfidence
        options.minTrackingConfidence = minimumTrackingConfidence
        options.poseLandmarkerLiveStreamDelegate = self

        self.poseLandmarker = try PoseLandmarker(options: options)
    }

    func detect(sampleBuffer: CMSampleBuffer, timestampInMilliseconds: Int) {
        do {
            storeAspectRatio(for: sampleBuffer, timestampInMilliseconds: timestampInMilliseconds)
            let image = try MPImage(sampleBuffer: sampleBuffer)
            try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: timestampInMilliseconds)
        } catch {
            Self.log.error("detect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func storeAspectRatio(for sampleBuffer: CMSampleBuffer, timestampInMilliseconds: Int) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.height > 0 else { return }

        aspectRatioLock.lock()
        frameAspectRatios[timestampInMilliseconds] = Double(dimensions.width) / Double(dimensions.height)
        aspectRatioLock.unlock()
    }

    private func consumeAspectRatio(timestampInMilliseconds: Int) -> Double {
        aspectRatioLock.lock()
        defer { aspectRatioLock.unlock() }

        let aspectRatio = frameAspectRatios.removeValue(forKey: timestampInMilliseconds)
        return aspectRatio ?? (9 / 16)
    }
}

extension MediaPipePoseEstimator: PoseLandmarkerLiveStreamDelegate {
    func poseLandmarker(
        _ poseLandmarker: PoseLandmarker,
        didFinishDetection result: PoseLandmarkerResult?,
        timestampInMilliseconds: Int,
        error: Error?
    ) {
        if let error {
            Self.log.error("detection callback error: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let landmarks = result?.landmarks.first else {
            Self.log.debug("no pose detected at \(timestampInMilliseconds)")
            return
        }

        var poseLandmarks: [PoseLandmark] = []
        poseLandmarks.reserveCapacity(landmarks.count)

        for index in landmarks.indices {
            guard let name = PoseLandmarkName(rawValue: index) else { continue }
            let landmark = landmarks[index]
            poseLandmarks.append(
                PoseLandmark(
                    name: name,
                    x: Double(landmark.x),
                    y: Double(landmark.y),
                    z: Double(landmark.z),
                    visibility: nil,
                    presence: nil
                )
            )
        }

        poseFrameHandler?(
            PoseFrame(
                timestampInMilliseconds: timestampInMilliseconds,
                sourceAspectRatio: consumeAspectRatio(timestampInMilliseconds: timestampInMilliseconds),
                landmarks: poseLandmarks
            )
        )
    }
}

enum MediaPipePoseEstimatorError: LocalizedError {
    case missingModel(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let modelName):
            "Missing MediaPipe model asset: \(modelName).task"
        }
    }
}