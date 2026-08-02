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
    /// Most recently completed rep, powering the tuning readout.
    var latestRep: WallBallRep?
    /// Shows raw per-rep measurements so thresholds can be calibrated against real footage.
    var showsTuningReadout = false

    /// Whether the finished session can be watched back with its overlay.
    var canReviewVideo: Bool { sessionVideoURL != nil && !(sessionTimeline?.isEmpty ?? true) }

    /// Whether a live rep counter is available for the selected station (currently Wall Balls only).
    var showsLiveRepCount: Bool { selectedStation == .wallBalls }

    /// Stations whose analysis needs the whole body in frame — the skeleton is only drawn once the
    /// full body is tracked (Wall Balls relies on hip-vs-knee depth, so a partial body is useless).
    var requiresFullBody: Bool { selectedStation == .wallBalls }

    private let feedbackGenerator: LiveFeedbackGenerating
    private let sessionAnalyzer: LiveSessionAnalyzing
    private let poseEstimator: PoseEstimating?
    private var capturedFrames: [PoseFrame] = []
    private var liveRepAnalyzer = WallBallRepAnalyzer()
    private var recordingFinishTask: Task<Void, Never>?
    private var cueHoldUntil: Date?

    /// How long a fault cue stays on screen before the standing cue returns.
    private static let faultCueDuration: TimeInterval = 2.5

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

    /// Restarts the camera after a finished set released it.
    ///
    /// Navigating to playback pushes on top of this screen rather than replacing it, so `.task`
    /// does not run again on the way back — the view calls this from `onAppear` instead.
    /// Both capture services no-op when already running or not yet configured.
    func resumeSession() {
        guard recordingState == .completed || recordingState == .ready else { return }
        cameraService.startSession()
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
            // The previous set released the camera, so make sure it is running before recording
            // again. No-ops when it already is.
            cameraService.startSession()
            try cameraService.startRecording()
            capturedFrames.removeAll(keepingCapacity: true)
            liveRepAnalyzer = WallBallRepAnalyzer()
            liveRepCount = 0
            latestRep = nil
            cueHoldUntil = nil
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

        // Release the camera before replay and the overlay export start. Playback pushes on top
        // of this screen rather than replacing it, so `onDisappear` never fires and the capture
        // session would otherwise keep running alongside an AVPlayer, an asset reader and an
        // asset writer — enough concurrent pipelines to take mediaserverd down, which surfaces
        // as the export failing with a generic "cannot complete action".
        cameraService.stopSession()

        if canReviewVideo {
            showsPlayback = true
        } else {
            showsScorecard = true
        }
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
            let previousRepCount = liveRepAnalyzer.completedReps.count
            liveRepAnalyzer.process(poseFrame)
            liveRepCount = liveRepAnalyzer.validRepsSoFar

            if liveRepAnalyzer.completedReps.count > previousRepCount,
               let rep = liveRepAnalyzer.completedReps.last {
                handleCompletedRep(rep)
            }
        }

        refreshCueIfExpired()
    }

    /// Shows coaching for the rep just finished, held long enough to read before the standing cue
    /// returns.
    private func handleCompletedRep(_ rep: WallBallRep) {
        latestRep = rep

        if let fault = rep.faults.first {
            currentCue = feedbackGenerator.faultCue(for: fault, station: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        } else if !rep.handsTracked {
            currentCue = feedbackGenerator.framingCue(for: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        }
    }

    /// Restores the standing recording cue once a fault cue has had its time.
    ///
    /// The cue is deliberately not reassigned every frame: `LiveFeedbackCue.id` is a fresh UUID, so
    /// two identical cues never compare equal and reassigning would churn observation 30–60×/second.
    private func refreshCueIfExpired() {
        guard let hold = cueHoldUntil else { return }
        guard Date() >= hold else { return }

        cueHoldUntil = nil
        currentCue = feedbackGenerator.recordingCue(for: selectedStation)
    }
}