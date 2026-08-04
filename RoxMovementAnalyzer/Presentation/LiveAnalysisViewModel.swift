import AVFoundation
import Foundation
import os

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
    /// Brief visual confirmation when a valid wall-ball rep is counted.
    var showsValidRepConfirmation = false
    var validRepConfirmationID = UUID()
    /// User-controlled: voice cues are helpful for missed reps, but noisy if forced on.
    var audioCuesEnabled = false
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
    private let repCuePlayer: RepCuePlaying
    private var capturedFrames: [PoseFrame] = []
    private var liveRepAnalyzer = WallBallRepAnalyzer()
    private var recordingFinishTask: Task<Void, Never>?
    private var validRepConfirmationTask: Task<Void, Never>?
    private var cueHoldUntil: Date?

    /// How long a fault cue stays on screen before the standing cue returns.
    private static let faultCueDuration: TimeInterval = 2.5
    private static let shallowRepCueCooldown: TimeInterval = 2.0

    /// Backstop on the pose buffer — roughly 5.5 minutes at 60 fps, comfortably clear of the
    /// capture service's duration cap.
    private static let maximumCapturedFrames = 20_000

    private static let log = Logger(subsystem: "rox.analysis", category: "LiveAnalysisViewModel")

    private var hasLoggedFrameLimit = false
    private var shallowRepCueAllowedAt = Date.distantPast

    init(
        selectedStation: HyroxStation = .wallBalls,
        cameraService: CameraCaptureServicing = AVFoundationCameraCaptureService(),
        feedbackGenerator: LiveFeedbackGenerating = StationRuleLiveFeedbackGenerator(),
        sessionAnalyzer: LiveSessionAnalyzing = PoseSessionAnalyzer(),
        poseEstimator: PoseEstimating? = SharedPoseEstimator.shared,
        repCuePlayer: RepCuePlaying = SystemRepCuePlayer()
    ) {
        self.selectedStation = selectedStation
        self.cameraService = cameraService
        self.feedbackGenerator = feedbackGenerator
        self.sessionAnalyzer = sessionAnalyzer
        self.poseEstimator = poseEstimator
        self.repCuePlayer = repCuePlayer
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
            hasLoggedFrameLimit = false
            liveRepCount = 0
            latestRep = nil
            showsValidRepConfirmation = false
            validRepConfirmationTask?.cancel()
            validRepConfirmationTask = nil
            cueHoldUntil = nil
            shallowRepCueAllowedAt = .distantPast
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
        finalizeAnalysis()

        // The movie file keeps writing after stopRecording() returns; wait for the delegate
        // rather than navigating to a video that does not exist yet.
        recordingState = .processing
        startRecordingFinishTimeout()
    }

    /// Turns the captured frames into the scorecard and replay timeline.
    ///
    /// Shared by the user tapping stop and by a recording that stopped itself at the duration or
    /// storage limit, so the set is analysed identically either way.
    private func finalizeAnalysis() {
        sessionScorecard = sessionAnalyzer.analyze(station: selectedStation, frames: capturedFrames)
        sessionTimeline = SessionTimeline(frames: capturedFrames, station: selectedStation)
        currentCue = feedbackGenerator.completedCue(for: selectedStation)
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

        // Still recording means AVFoundation stopped this itself, at the duration cap or the
        // storage floor. The analysis has not run yet — without this the app would sit on
        // "Recording" forever with no scorecard.
        if recordingState == .recording {
            cameraService.stopRecording()
            finalizeAnalysis()
            finishSession()
            return
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

        // The duration cap should stop things long before this, but the debug video-file source
        // has no movie output and therefore no limit. Stop growing rather than doing it silently.
        guard capturedFrames.count < Self.maximumCapturedFrames else {
            if !hasLoggedFrameLimit {
                hasLoggedFrameLimit = true
                Self.log.error(
                    "hit the captured-frame ceiling; analysis covers the first \(Self.maximumCapturedFrames, privacy: .public) frames only"
                )
            }
            return
        }

        capturedFrames.append(poseFrame)

        if selectedStation == .wallBalls {
            let previousRepCount = liveRepAnalyzer.completedReps.count
            let previousValidRepCount = liveRepAnalyzer.validRepsSoFar
            liveRepAnalyzer.process(poseFrame)
            liveRepCount = liveRepAnalyzer.validRepsSoFar

            if liveRepCount > previousValidRepCount {
                showValidRepConfirmation()
            }

            if liveRepAnalyzer.completedReps.count > previousRepCount,
               let rep = liveRepAnalyzer.completedReps.last {
                handleCompletedRep(rep)
            }
        }
        refreshCueIfExpired()
    }

    private func showValidRepConfirmation() {
        validRepConfirmationTask?.cancel()
        validRepConfirmationID = UUID()
        showsValidRepConfirmation = true

        validRepConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled, let self else { return }
            self.showsValidRepConfirmation = false
            self.validRepConfirmationTask = nil
        }
    }

    /// Shows coaching for the rep just finished, held long enough to read before the standing cue
    /// returns.
    private func handleCompletedRep(_ rep: WallBallRep) {
        latestRep = rep

        if !rep.reachedDepth {
            playShallowRepCueIfAllowed()
        }

        if let fault = rep.faults.first {
            currentCue = feedbackGenerator.faultCue(for: fault, station: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        } else if !rep.handsTracked {
            currentCue = feedbackGenerator.framingCue(for: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        }
    }

    private func playShallowRepCueIfAllowed() {
        guard audioCuesEnabled else { return }

        let now = Date()
        guard now >= shallowRepCueAllowedAt else { return }

        repCuePlayer.playShallowRepCue()
        shallowRepCueAllowedAt = now.addingTimeInterval(Self.shallowRepCueCooldown)
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