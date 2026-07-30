import AVFoundation
import Foundation

@MainActor
@Observable
final class LiveAnalysisViewModel {
    enum RecordingState: Equatable {
        case idle
        case preparing
        case ready
        case recording
        case completed
        case failed(String)
    }

    let cameraService: CameraCaptureServicing

    var selectedStation: HyroxStation
    var recordingState: RecordingState = .idle
    var authorizationState: CameraAuthorizationState = .notDetermined
    var currentCue: LiveFeedbackCue
    var showsScorecard = false
    var latestPoseFrame: PoseFrame?
    var activeCameraPosition: CameraPosition = .back
    var sessionScorecard: WorkoutScorecard?
    var liveRepCount = 0

    /// Whether a live rep counter is available for the selected station (currently Wall Balls only).
    var showsLiveRepCount: Bool { selectedStation == .wallBalls }

    private let feedbackGenerator: LiveFeedbackGenerating
    private let sessionAnalyzer: LiveSessionAnalyzing
    private let poseEstimator: PoseEstimating?
    private var capturedFrames: [PoseFrame] = []
    private var liveRepCounter = WallBallRepCounter()

    init(
        selectedStation: HyroxStation = .wallBalls,
        cameraService: CameraCaptureServicing = AVFoundationCameraCaptureService(),
        feedbackGenerator: LiveFeedbackGenerating = StationRuleLiveFeedbackGenerator(),
        sessionAnalyzer: LiveSessionAnalyzing = PoseSessionAnalyzer(),
        poseEstimator: PoseEstimating? = SharedPoseEstimator.shared
    ) {
        self.selectedStation = selectedStation
        self.cameraService = cameraService
        self.feedbackGenerator = feedbackGenerator
        self.sessionAnalyzer = sessionAnalyzer
        self.poseEstimator = poseEstimator
        self.currentCue = feedbackGenerator.readyCue(for: selectedStation)
    }

    func updateStation(_ station: HyroxStation) {
        selectedStation = station
        currentCue = feedbackGenerator.readyCue(for: station)
    }

    func prepareCamera() async {
        recordingState = .preparing
        authorizationState = await cameraService.requestAccess()

        guard authorizationState == .authorized else {
            recordingState = .failed("Enable camera access in Settings to use live analysis.")
            return
        }

        do {
            try cameraService.configure()
            configurePoseEstimation()
            activeCameraPosition = cameraService.activeCameraPosition
            cameraService.startSession()
            recordingState = .ready
            currentCue = feedbackGenerator.readyCue(for: selectedStation)
        } catch {
            recordingState = .failed(error.localizedDescription)
        }
    }

    func toggleRecording() {
        switch recordingState {
        case .ready, .completed:
            startRecording()
        case .recording:
            stopRecording()
        case .idle, .preparing, .failed:
            break
        }
    }

    func stopSession() {
        cameraService.stopSession()
    }

    func switchCamera() {
        guard recordingState != .recording else {
            currentCue = LiveFeedbackCue(
                station: selectedStation,
                message: "Stop recording first",
                detail: "Camera switching is available before or after a set, not during recording.",
                status: .caution
            )
            return
        }

        do {
            latestPoseFrame = nil
            activeCameraPosition = try cameraService.switchCamera()
            currentCue = feedbackGenerator.readyCue(for: selectedStation)
        } catch {
            currentCue = LiveFeedbackCue(
                station: selectedStation,
                message: "Camera switch failed",
                detail: error.localizedDescription,
                status: .needsWork
            )
        }
    }

    private func startRecording() {
        do {
            try cameraService.startRecording()
            capturedFrames.removeAll(keepingCapacity: true)
            liveRepCounter = WallBallRepCounter()
            liveRepCount = 0
            sessionScorecard = nil
            recordingState = .recording
            currentCue = feedbackGenerator.recordingCue(for: selectedStation)
        } catch {
            recordingState = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() {
        cameraService.stopRecording()
        sessionScorecard = sessionAnalyzer.analyze(station: selectedStation, frames: capturedFrames)
        recordingState = .completed
        currentCue = feedbackGenerator.completedCue(for: selectedStation)
        showsScorecard = true
    }

    private func configurePoseEstimation() {
        guard let estimator = poseEstimator else {
            currentCue = LiveFeedbackCue(
                station: selectedStation,
                message: "Pose model unavailable",
                detail: "The pose model could not be loaded. Reinstall the app and try again.",
                status: .needsWork
            )
            return
        }

        estimator.poseFrameHandler = { [weak self] poseFrame in
            Task { @MainActor in
                self?.handlePoseFrame(poseFrame)
            }
        }

        cameraService.sampleBufferHandler = { [weak estimator] sampleBuffer, timestampInMilliseconds in
            estimator?.detect(
                sampleBuffer: sampleBuffer,
                timestampInMilliseconds: timestampInMilliseconds
            )
        }
    }

    private func handlePoseFrame(_ poseFrame: PoseFrame) {
        guard !poseFrame.landmarks.isEmpty else { return }
        latestPoseFrame = poseFrame

        guard recordingState == .recording else { return }
        capturedFrames.append(poseFrame)

        if selectedStation == .wallBalls {
            liveRepCounter.process(poseFrame)
            liveRepCount = liveRepCounter.result.validReps
        }

        currentCue = feedbackGenerator.recordingCue(for: selectedStation)
    }
}