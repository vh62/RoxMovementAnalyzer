import AVFoundation
import CoreMedia
import Foundation

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
    var sampleBufferHandler: ((CMSampleBuffer, Int) -> Void)? { get set }
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
    let session = AVCaptureSession()
    var sampleBufferHandler: ((CMSampleBuffer, Int) -> Void)?

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

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraCaptureError.cannotAddVideoDataOutput }
        session.addOutput(videoOutput)

        isConfigured = true
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
        sampleBufferHandler?(sampleBuffer, timestampInMilliseconds)
    }
}