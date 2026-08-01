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
        /// Recording stopped; waiting for the movie file to finish writing.
        case processing
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

    /// The recorded movie for the session just captured, once it has finished writing.
    var sessionVideoURL: URL?
    /// Pose frames of the session just captured, aligned to video playback time.
    var sessionTimeline: SessionTimeline?
    var showsPlayback = false

    /// Whether the finished session can be watched back with its overlay.
    var canReviewVideo: Bool { sessionVideoURL != nil && !(sessionTimeline?.isEmpty ?? true) }

    /// Whether a live rep counter is available for the selected station (currently Wall Balls only).
    var showsLiveRepCount: Bool { selectedStation == .wallBalls }

    /// Stations whose analysis needs the whole body in frame — the skeleton is only drawn once the
    /// full body is tracked (Wall Balls relies on hip-vs-knee depth, so a partial body is useless).
    var requiresFullBody: Bool { selectedStation == .wallBalls }

    private let feedbackGenerator: LiveFeedbackGenerating
    private let sessionAnalyzer: LiveSessionAnalyzing
    private var poseEstimator: PoseEstimating?
    private var capturedFrames: [PoseFrame] = []
    private var liveRepCounter = WallBallRepCounter()
    private var recordingFinishTask: Task<Void, Never>?

    init(
        selectedStation: HyroxStation = .wallBalls,
        cameraService: CameraCaptureServicing = AVFoundationCameraCaptureService(),
        feedbackGenerator: LiveFeedbackGenerating = StationRuleLiveFeedbackGenerator(),
        sessionAnalyzer: LiveSessionAnalyzing = PoseSessionAnalyzer()
    ) {
        self.selectedStation = selectedStation
        self.cameraService = cameraService
        self.feedbackGenerator = feedbackGenerator
        self.sessionAnalyzer = sessionAnalyzer
        self.currentCue = feedbackGenerator.readyCue(for: selectedStation)

        cameraService.recordingFinishedHandler = { [weak self] result in
            MainActor.assumeIsolated {
                self?.handleRecordingFinished(result)
            }
        }
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
        case .idle, .preparing, .processing, .failed:
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
            sessionVideoURL = nil
            sessionTimeline = nil
            recordingState = .recording
            currentCue = feedbackGenerator.recordingCue(for: selectedStation)
        } catch {
            recordingState = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() {
        cameraService.stopRecording()
        sessionScorecard = sessionAnalyzer.analyze(station: selectedStation, frames: capturedFrames)
        sessionTimeline = SessionTimeline(frames: capturedFrames, station: selectedStation)
        currentCue = feedbackGenerator.completedCue(for: selectedStation)

        // The movie file keeps writing after stopRecording() returns; wait for the delegate
        // rather than navigating to a video that does not exist yet.
        recordingState = .processing
        startRecordingFinishTimeout()
    }

    /// Falls through to the scorecard if the capture delegate never reports back, so a stalled
    /// write cannot strand the user on the processing state.
    private func startRecordingFinishTimeout() {
        recordingFinishTask?.cancel()
        recordingFinishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.recordingState == .processing else { return }
            self.finishSession()
        }
    }

    private func handleRecordingFinished(_ result: Result<URL, Error>) {
        recordingFinishTask?.cancel()
        recordingFinishTask = nil

        switch result {
        case .success(let url):
            sessionVideoURL = url
        case .failure:
            // Analysis still stands without the video; only the replay is unavailable.
            sessionVideoURL = nil
        }

        guard recordingState == .processing else { return }
        finishSession()
    }

    private func finishSession() {
        recordingState = .completed

        if canReviewVideo {
            showsPlayback = true
        } else {
            showsScorecard = true
        }
    }

    private func configurePoseEstimation() {
        do {
            let estimator = try MediaPipePoseEstimator()
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

            poseEstimator = estimator
        } catch {
            currentCue = LiveFeedbackCue(
                station: selectedStation,
                message: "Pose model unavailable",
                detail: error.localizedDescription,
                status: .needsWork
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