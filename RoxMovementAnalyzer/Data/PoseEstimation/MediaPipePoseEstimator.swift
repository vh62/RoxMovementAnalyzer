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

    private let runningMode: RunningMode

    /// - Parameter runningMode: `.liveStream` for the camera, where the tracker is free to drop
    ///   frames it cannot keep up with. `.video` for a file, where it must not: an imported clip
    ///   should be analysed exhaustively rather than sampled, and the synchronous call also
    ///   throttles the decode loop to inference speed for free.
    init(
        modelName: String = "pose_landmarker_lite",
        runningMode: RunningMode = .liveStream,
        minimumPoseDetectionConfidence: Float = 0.5,
        minimumPosePresenceConfidence: Float = 0.5,
        minimumTrackingConfidence: Float = 0.5
    ) throws {
        guard let modelPath = Bundle.main.path(forResource: modelName, ofType: "task") else {
            throw MediaPipePoseEstimatorError.missingModel(modelName)
        }

        self.runningMode = runningMode
        super.init()

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = runningMode
        options.numPoses = 1
        options.minPoseDetectionConfidence = minimumPoseDetectionConfidence
        options.minPosePresenceConfidence = minimumPosePresenceConfidence
        options.minTrackingConfidence = minimumTrackingConfidence
        if runningMode == .liveStream {
            options.poseLandmarkerLiveStreamDelegate = self
        }

        self.poseLandmarker = try PoseLandmarker(options: options)
    }

    func detect(pixelBuffer: CVPixelBuffer, timestampInMilliseconds: Int) {
        let timestamp = nextTimestamp(atLeast: timestampInMilliseconds)
        do {
            storeAspectRatio(for: pixelBuffer, timestampInMilliseconds: timestamp)
            let image = try MPImage(pixelBuffer: pixelBuffer)

            if runningMode == .video {
                // Synchronous and lossless. Returns on the caller's thread, which for the file
                // source is its own decode task, so nothing blocks the main actor.
                let result = try poseLandmarker.detect(
                    videoFrame: image, timestampInMilliseconds: timestamp
                )
                emit(result, timestampInMilliseconds: timestamp)
            } else {
                try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: timestamp)
            }
        } catch {
            Self.log.error("detect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs one throwaway inference on a blank frame so the model graph is built and warmed before
    /// the first real frame arrives. Safe to call once at launch on a background thread.
    func prewarm() {
        guard runningMode == .liveStream else { return }
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

    private func storeAspectRatio(for pixelBuffer: CVPixelBuffer, timestampInMilliseconds: Int) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        stateLock.lock()
        frameAspectRatios[timestampInMilliseconds] = Double(width) / Double(height)
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

    /// Maps a MediaPipe result onto a `PoseFrame` and publishes it. Shared by both running modes so
    /// a file and the camera cannot end up with subtly different landmark handling.
    fileprivate func emit(_ result: PoseLandmarkerResult?, timestampInMilliseconds: Int) {
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

/// App-wide pose estimator, built and warmed once at launch so opening live analysis is not slow.
enum SharedPoseEstimator {
    static let shared: PoseEstimating? = try? MediaPipePoseEstimator()

    /// Triggers the (lazy) model load and a warmup inference. Call off the main thread.
    static func prewarm() {
        (shared as? MediaPipePoseEstimator)?.prewarm()
    }

    /// A separate estimator for analysing an imported video.
    ///
    /// Deliberately not the shared instance: that one is in `.liveStream` mode, which drops frames
    /// under load. That is right for a camera — a dropped frame is gone either way — and wrong for
    /// a file, where every frame is still there to be read and the athlete is entitled to have all
    /// of them analysed. Built per import rather than cached, so its tracker state starts clean.
    static func makeVideoEstimator() -> PoseEstimating? {
        try? MediaPipePoseEstimator(runningMode: .video)
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

        emit(result, timestampInMilliseconds: timestampInMilliseconds)
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