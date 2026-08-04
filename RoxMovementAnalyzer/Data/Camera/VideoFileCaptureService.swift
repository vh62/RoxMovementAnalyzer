#if DEBUG
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Feeds a video file through the analysis pipeline in place of the live camera.
///
/// Debug-only. It exists so wall-ball analysis can be exercised repeatedly on identical footage
/// — the only practical way to calibrate `WallBallThresholds`, which otherwise needs the same set
/// performed the same way for every threshold tweak.
///
/// Because it conforms to `CameraCaptureServicing`, everything downstream (MediaPipe, the rep
/// analyzer, the live cues, the scorecard, replay and the overlay export) runs completely
/// unchanged — the frames simply arrive from `AVAssetReader` instead of the capture session.
///
/// It does not exercise the capture layer itself: portrait rotation and front-camera mirroring are
/// set on the capture connections, which do not exist here. Keep testing those on a real camera.
final class VideoFileCaptureService: NSObject, CameraCaptureServicing {
    /// How fast frames are handed to the pipeline.
    enum Pacing {
        /// Match the clip's own timing, so live cues and the fault hold behave as they would on camera.
        case realTime
        /// Push frames as fast as they decode, for quick threshold iteration.
        case fast
    }

    private static let log = Logger(subsystem: "rox.camera", category: "VideoFileCaptureService")

    /// MediaPipe's live-stream mode rejects timestamps that do not increase. Every replay restarts
    /// the file's presentation times at zero, so without a per-process offset a second run would be
    /// silently dropped and look like "pose detection stopped working".
    private static var timestampOffsetMilliseconds = 0
    private static let offsetGap = 60_000

    /// Unused — a file source has no capture session. `LiveAnalysisView` shows the decoded frames
    /// instead of a preview layer when the source is file-backed.
    let session = AVCaptureSession()

    var sampleBufferHandler: ((CMSampleBuffer, Int) -> Void)?
    var recordingFinishedHandler: ((Result<URL, Error>) -> Void)?
    /// Each decoded frame, on the main actor, so the preview can show exactly what the pose
    /// estimator just saw rather than a separately-playing copy that could drift.
    var previewFrameHandler: ((CVPixelBuffer) -> Void)?
    /// Fired on the main actor when the clip runs out, so the caller can stop the "recording".
    var feedFinishedHandler: (() -> Void)?

    let sourceURL: URL
    let pacing: Pacing

    private(set) var isConfigured = false
    private(set) var isRunning = false
    private(set) var isRecording = false
    let activeCameraPosition: CameraPosition = .back
    var authorizationState: CameraAuthorizationState { .authorized }

    /// The clip runs to its own end rather than being cut short, so the cap is only nominal here.
    /// The view model's frame ceiling is what actually bounds a very long picked video.
    var maximumRecordingDuration: TimeInterval {
        AVFoundationCameraCaptureService.maximumRecordingDuration
    }
    /// Debug videos can be arbitrarily long; keep the retained pose timeline smaller than live capture.
    let maximumCapturedPoseFrames = 6_000

    private var feedTask: Task<Void, Never>?
    private var baseTimestampMilliseconds = 0

    init(url: URL, pacing: Pacing = .realTime) {
        self.sourceURL = url
        self.pacing = pacing
        super.init()
    }

    // MARK: - CameraCaptureServicing

    func requestAccess() async -> CameraAuthorizationState { .authorized }

    func configure() throws {
        guard !isConfigured else { return }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CameraCaptureError.cameraUnavailable
        }
        isConfigured = true
    }

    func startSession() {
        guard isConfigured, !isRunning else { return }
        isRunning = true
    }

    func stopSession() {
        feedTask?.cancel()
        feedTask = nil
        isRunning = false
    }

    /// Nothing is written: the source video *is* the recording, so replay and the overlay export
    /// work against it unchanged.
    ///
    /// The clip only starts playing here, rather than when the session starts, so that no frames
    /// slip past before the pipeline is capturing them.
    func startRecording() throws {
        guard isConfigured else { throw CameraCaptureError.cameraUnavailable }
        guard !isRecording else { return }
        isRecording = true

        baseTimestampMilliseconds = Self.timestampOffsetMilliseconds
        feedTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.feedFrames()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        let url = sourceURL
        DispatchQueue.main.async { [weak self] in
            self?.recordingFinishedHandler?(.success(url))
        }
    }

    func switchCamera() throws -> CameraPosition {
        throw CameraCaptureError.cameraUnavailable
    }

    // MARK: - Feeding frames

    private func feedFrames() async {
        do {
            let asset = AVURLAsset(url: sourceURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CameraCaptureError.cameraUnavailable
            }

            let reader = try AVAssetReader(asset: asset)

            // A composition output rather than a plain track output: it applies the track's
            // preferredTransform, so a portrait clip arrives upright. The stock composition can
            // preserve a padded landscape render size for some phone videos; build a tight render
            // size here so the debug preview and overlay are not shifted into one side of the view.
            let composition = try await makeUprightComposition(asset: asset, track: track)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: [track],
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
            )
            output.videoComposition = composition
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { throw CameraCaptureError.cannotAddVideoDataOutput }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? CameraCaptureError.cameraUnavailable
            }

            var lastPresentation: Double = 0
            let start = Date()

            while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

                if pacing == .realTime {
                    // Hold each frame back so the clip plays at its own rate.
                    let delay = start.addingTimeInterval(presentation).timeIntervalSinceNow
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                }

                guard !Task.isCancelled else { break }

                sampleBufferHandler?(sampleBuffer, baseTimestampMilliseconds + Int(presentation * 1000))

                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    await MainActor.run { [weak self] in
                        self?.previewFrameHandler?(pixelBuffer)
                    }
                }

                lastPresentation = presentation
            }

            // Leave a gap so the next replay's timestamps still increase.
            Self.timestampOffsetMilliseconds =
                baseTimestampMilliseconds + Int(lastPresentation * 1000) + Self.offsetGap

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.feedFinishedHandler?()
            }
        } catch {
            Self.log.error("file source failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { [weak self] in
                self?.recordingFinishedHandler?(.failure(error))
            }
        }
    }

    private func makeUprightComposition(asset: AVAsset, track: AVAssetTrack) async throws -> AVMutableVideoComposition {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width),
            height: abs(transformedRect.height)
        )

        var finalTransform = preferredTransform
        finalTransform.tx -= transformedRect.minX
        finalTransform.ty -= transformedRect.minY

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(finalTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(nominalFrameRate.rounded(), 1))
        )
        composition.instructions = [instruction]
        return composition
    }
}
#endif
