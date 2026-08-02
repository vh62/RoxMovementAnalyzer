import CoreMedia
import CoreVideo
import Foundation
import MediaPipeTasksVision
import os

final class MediaPipePoseEstimator: NSObject, PoseEstimating {
    private static let log = Logger(subsystem: "rox.pose", category: "MediaPipePoseEstimator")

    var poseFrameHandler: ((PoseFrame) -> Void)?

    private var poseLandmarker: PoseLandmarker!
    private var frameAspectRatios: [Int: Double] = [:]
    private let stateLock = NSLock()
    private var lastTimestamp = Int.min

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
        let timestamp = nextTimestamp(atLeast: timestampInMilliseconds)
        do {
            storeAspectRatio(for: sampleBuffer, timestampInMilliseconds: timestamp)
            let image = try MPImage(sampleBuffer: sampleBuffer)
            try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: timestamp)
        } catch {
            Self.log.error("detect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs one throwaway inference on a blank frame so the model graph is built and warmed before
    /// the first real frame arrives. Safe to call once at launch on a background thread.
    func prewarm() {
        guard let pixelBuffer = Self.makeBlankPixelBuffer(width: 256, height: 256) else { return }
        let timestamp = nextTimestamp(atLeast: 0)
        do {
            let image = try MPImage(pixelBuffer: pixelBuffer)
            try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: timestamp)
        } catch {
            Self.log.error("prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Live-stream mode requires strictly increasing timestamps. Enforcing that here lets a single
    /// warmed instance be reused across camera restarts, whose presentation timestamps may reset.
    private func nextTimestamp(atLeast requested: Int) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        let timestamp = max(requested, lastTimestamp + 1)
        lastTimestamp = timestamp
        return timestamp
    }

    private static func makeBlankPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    private func storeAspectRatio(for sampleBuffer: CMSampleBuffer, timestampInMilliseconds: Int) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        guard dimensions.height > 0 else { return }

        stateLock.lock()
        frameAspectRatios[timestampInMilliseconds] = Double(dimensions.width) / Double(dimensions.height)
        // Frames dropped by the tracker never get consumed; drop their stale entries so the map
        // does not grow without bound over a long session.
        if frameAspectRatios.count > 120 {
            let cutoff = timestampInMilliseconds - 2000
            frameAspectRatios = frameAspectRatios.filter { $0.key >= cutoff }
        }
        stateLock.unlock()
    }

    private func consumeAspectRatio(timestampInMilliseconds: Int) -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }

        let aspectRatio = frameAspectRatios.removeValue(forKey: timestampInMilliseconds)
        return aspectRatio ?? (9 / 16)
    }
}

/// App-wide pose estimator, built and warmed once at launch so opening live analysis is not slow.
enum SharedPoseEstimator {
    static let shared: PoseEstimating? = try? MediaPipePoseEstimator()

    /// Triggers the (lazy) model load and a warmup inference. Call off the main thread.
    static func prewarm() {
        (shared as? MediaPipePoseEstimator)?.prewarm()
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
                    visibility: landmark.visibility?.doubleValue,
                    presence: landmark.presence?.doubleValue
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