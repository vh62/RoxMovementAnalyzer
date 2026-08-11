import AVFoundation
import UIKit
import CoreMedia
import CoreVideo
import Foundation
import os

enum CameraAuthorizationState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable
}

enum CameraPosition: Equatable {
    case back
    case front

    var toggled: CameraPosition {
        switch self {
        case .back: .front
        case .front: .back
        }
    }
}

protocol CameraCaptureServicing: AnyObject {
    var session: AVCaptureSession { get }
    /// Longest a single set may record before it stops itself.
    var maximumRecordingDuration: TimeInterval { get }
    /// Maximum pose frames held for analysis/replay. Video frames are streamed, but pose frames are retained.
    var maximumCapturedPoseFrames: Int { get }
    var sampleBufferHandler: ((CVPixelBuffer, Int) -> Void)? { get set }
    /// Called on the main actor once the movie file has finished writing, which happens some
    /// time after `stopRecording()` returns.
    var recordingFinishedHandler: ((Result<URL, Error>) -> Void)? { get set }
    var authorizationState: CameraAuthorizationState { get }
    var activeCameraPosition: CameraPosition { get }
    var isConfigured: Bool { get }
    var isRunning: Bool { get }
    var isRecording: Bool { get }

    func requestAccess() async -> CameraAuthorizationState
    func configure() throws
    func startSession()
    func stopSession()
    func startRecording() throws
    func stopRecording()
    func switchCamera() throws -> CameraPosition
}

enum CameraCaptureError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddMovieOutput
    case cannotAddVideoDataOutput
    case cannotSwitchWhileRecording
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "No camera is available on this device."
        case .cannotAddInput:
            "The camera input could not be added."
        case .cannotAddMovieOutput:
            "Video recording output could not be added."
        case .cannotAddVideoDataOutput:
            "Live camera frames could not be added."
        case .cannotSwitchWhileRecording:
            "Stop recording before switching cameras."
        case .notAuthorized:
            "Camera access is required for live analysis."
        }
    }
}

final class AVFoundationCameraCaptureService: NSObject, CameraCaptureServicing {
    private static let log = Logger(subsystem: "rox.camera", category: "CaptureService")

    /// Comfortably covers a full HYROX wall-ball station — 100 reps, typically four to nine
    /// minutes — while keeping the movie file around half a gigabyte and the pose data the
    /// analysis holds in memory to roughly 18 MB.
    static let maximumRecordingDuration: TimeInterval = 300
    static let maximumCapturedPoseFrames = 20_000

    /// Stop while there is still room to finalise the file rather than failing mid-write.
    private static let minimumFreeDiskSpace: Int64 = 250 * 1024 * 1024

    var maximumRecordingDuration: TimeInterval { Self.maximumRecordingDuration }
    var maximumCapturedPoseFrames: Int { Self.maximumCapturedPoseFrames }

    let session = AVCaptureSession()
    var sampleBufferHandler: ((CVPixelBuffer, Int) -> Void)?
    var recordingFinishedHandler: ((Result<URL, Error>) -> Void)?

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "rox.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "rox.camera.video-output")
    private var activeCameraInput: AVCaptureDeviceInput?

    private(set) var isConfigured = false
    private(set) var isRunning = false
    private(set) var activeCameraPosition: CameraPosition = .back

    var authorizationState: CameraAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }

    var isRecording: Bool {
        movieOutput.isRecording
    }

    func requestAccess() async -> CameraAuthorizationState {
        guard authorizationState == .notDetermined else { return authorizationState }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }

    func configure() throws {
        guard authorizationState == .authorized else { throw CameraCaptureError.notAuthorized }
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        guard let cameraInput = try makeCameraInput(position: .back) ?? makeCameraInput(position: .front) else {
            throw CameraCaptureError.cameraUnavailable
        }
        guard session.canAddInput(cameraInput) else { throw CameraCaptureError.cannotAddInput }
        session.addInput(cameraInput)
        activeCameraInput = cameraInput
        activeCameraPosition = cameraInput.device.position == .front ? .front : .back

        guard session.canAddOutput(movieOutput) else { throw CameraCaptureError.cannotAddMovieOutput }
        session.addOutput(movieOutput)

        // Let AVFoundation enforce the limits: it stops and finalises a valid file on its own,
        // where a hand-rolled timer risks losing the recording. Both cases report the stop with
        // AVErrorRecordingSuccessfullyFinishedKey, which the finish delegate already treats as
        // success.
        movieOutput.maxRecordedDuration = CMTime(
            seconds: Self.maximumRecordingDuration, preferredTimescale: 600
        )
        movieOutput.minFreeDiskSpaceLimit = Self.minimumFreeDiskSpace

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // MediaPipe's MPImage(sampleBuffer:) requires 32BGRA; the capture default is YUV, which fails.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraCaptureError.cannotAddVideoDataOutput }
        session.addOutput(videoOutput)

        configureOutputConnections()
        isConfigured = true
    }

    /// Rotates the movie and video-data outputs to upright portrait so MediaPipe receives an
    /// upright frame, and mirrors the front camera so the pose overlay matches the mirrored preview.
    private func configureOutputConnections() {
        let portraitAngle: CGFloat = 90
        let shouldMirror = activeCameraPosition == .front

        for (label, output) in [("video", videoOutput as AVCaptureOutput),
                                ("movie", movieOutput as AVCaptureOutput)] {
            guard let connection = output.connection(with: .video) else {
                Self.log.error("no video connection for the \(label, privacy: .public) output")
                continue
            }

            if connection.isVideoRotationAngleSupported(portraitAngle) {
                connection.videoRotationAngle = portraitAngle
            } else {
                // Previously skipped silently, which is how a landscape recording could come out
                // of a portrait-framed session with nothing reported anywhere.
                //
                // One literal rather than concatenation: a log message is an OSLogMessage, not a
                // String, so `+` does not apply to it.
                Self.log.error("""
                    \(label, privacy: .public) output cannot rotate to portrait; \
                    recording will stay in sensor orientation
                    """)
            }

            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = shouldMirror
            }
        }
    }

    /// Reports what the outputs will actually record, so an orientation problem names itself.
    private func logConnectionOrientation() {
        let video = videoOutput.connection(with: .video)?.videoRotationAngle ?? -1
        let movie = movieOutput.connection(with: .video)?.videoRotationAngle ?? -1
        Self.log.info("""
            recording with rotation — video output: \(video, privacy: .public)°, \
            movie output: \(movie, privacy: .public)°
            """)
    }

    func startSession() {
        guard isConfigured, !isRunning else { return }
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
            self?.isRunning = true
        }
    }

    func stopSession() {
        guard isRunning else { return }
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            self?.isRunning = false
        }
    }

    func startRecording() throws {
        guard isConfigured else { throw CameraCaptureError.cameraUnavailable }
        guard !movieOutput.isRecording else { return }

        // Re-apply rotation here, outside the session configuration block where it was first set.
        // The movie connection is what decides the recorded file's orientation, and it has to be
        // right at the moment recording starts — otherwise the file comes out in sensor
        // orientation (landscape) even though the data output feeding the pose model is upright.
        configureOutputConnections()
        logConnectionOrientation()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rox-live-analysis-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func switchCamera() throws -> CameraPosition {
        guard isConfigured else { throw CameraCaptureError.cameraUnavailable }
        guard !movieOutput.isRecording else { throw CameraCaptureError.cannotSwitchWhileRecording }

        let targetPosition = activeCameraPosition.toggled
        guard let newInput = try makeCameraInput(position: targetPosition) else {
            throw CameraCaptureError.cameraUnavailable
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let activeCameraInput {
            session.removeInput(activeCameraInput)
        }

        guard session.canAddInput(newInput) else {
            if let activeCameraInput, session.canAddInput(activeCameraInput) {
                session.addInput(activeCameraInput)
            }
            throw CameraCaptureError.cannotAddInput
        }

        session.addInput(newInput)
        activeCameraInput = newInput
        activeCameraPosition = targetPosition
        configureOutputConnections()
        return targetPosition
    }

    private func makeCameraInput(position: CameraPosition) throws -> AVCaptureDeviceInput? {
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            return nil
        }

        return try AVCaptureDeviceInput(device: camera)
    }
}

extension AVFoundationCameraCaptureService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // AVFoundation reports an error even for recordings that finished successfully (for
        // example when stopping hits a file-size limit), flagging the usable ones with
        // AVErrorRecordingSuccessfullyFinishedKey. Treat those as success.
        let finishedSuccessfully = (error as? NSError)
            .flatMap { $0.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool } ?? false

        let result: Result<URL, Error>
        if let error, !finishedSuccessfully {
            result = .failure(error)
        } else {
            result = .success(outputFileURL)
        }

        DispatchQueue.main.async { [weak self] in
            self?.recordingFinishedHandler?(result)
        }
    }
}

extension AVFoundationCameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampInMilliseconds = Int(CMTimeGetSeconds(timestamp) * 1000)
        // The capture connection already rotates to portrait, so buffers arrive upright.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sampleBufferHandler?(pixelBuffer, timestampInMilliseconds)
    }
}