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
    /// Analysis of the movements completed so far, powering the tuning readout.
    var latestAnalysis: StationAnalysis = .unsupported
    /// Shows raw per-movement measurements so thresholds can be calibrated against real footage.
    var showsTuningReadout = false

    /// Whether the finished session can be watched back with its overlay.
    var canReviewVideo: Bool { sessionVideoURL != nil && !(sessionTimeline?.isEmpty ?? true) }

    /// Whether a live count is available for the selected station.
    var showsLiveRepCount: Bool { selectedStation.hasMovementAnalysis }

    /// Stations whose analysis needs the whole body in frame — the skeleton is only drawn once the
    /// full body is tracked, since both analysed stations measure joint relationships across it.
    var requiresFullBody: Bool { selectedStation.requiresFullBody }

    /// Whether to draw the hip-versus-knee parallel line. Wall balls only: it is a squat-judging
    /// device and would be nonsense over a seated rower.
    var showsDepthGuide: Bool { selectedStation.showsDepthGuide }

    private let feedbackGenerator: LiveFeedbackGenerating
    private let sessionAnalyzer: LiveSessionAnalyzing
    private let poseEstimator: PoseEstimating?
    private var capturedFrames: [PoseFrame] = []
    private var liveCounter = LiveMovementCounter(station: .wallBalls)
    private let audioCoach = SessionAudioCoach()
    private var recordingFinishTask: Task<Void, Never>?
    private var cueHoldUntil: Date?

    /// How long a fault cue stays on screen before the standing cue returns.
    private static let faultCueDuration: TimeInterval = 2.5

    /// Backstop on the pose buffer — roughly 5.5 minutes at 60 fps, comfortably clear of the
    /// capture service's duration cap.
    private static let maximumCapturedFrames = 20_000

    private static let log = Logger(subsystem: "rox.analysis", category: "LiveAnalysisViewModel")

    private var hasLoggedFrameLimit = false

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
        // Leaving the screen mid-set must not leave the session ducking the athlete's music.
        audioCoach.endSession()
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
            liveCounter = LiveMovementCounter(station: selectedStation)
            hasLoggedFrameLimit = false
            audioCoach.startSession()
            liveRepCount = 0
            latestAnalysis = .unsupported
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
        audioCoach.endSession()

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

        cameraService.sampleBufferHandler = { [weak estimator] pixelBuffer, timestampInMilliseconds in
            estimator?.detect(
                pixelBuffer: pixelBuffer,
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

        if selectedStation.hasMovementAnalysis {
            let previousCompleted = liveCounter.completedMovements.count
            let previousCount = liveCounter.count
            liveCounter.process(poseFrame)
            liveRepCount = liveCounter.count
            latestAnalysis = liveCounter.analysis

            // Counted the moment it happens — when the hips break parallel, which is when a judge
            // would call it, or at the catch that opens a stroke — rather than when the record
            // closes about a second later.
            if liveCounter.count > previousCount {
                audioCoach.announce(rep: liveCounter.count)
            }

            let completed = liveCounter.completedMovements
            if completed.count > previousCompleted, let movement = completed.last {
                handleCompletedMovement(movement)
            }
        }

        refreshCueIfExpired()
    }

    /// Shows coaching for the movement just finished, held long enough to read before the standing
    /// cue returns.
    private func handleCompletedMovement(_ movement: CountedMovement) {
        // Only wall balls has a rule a movement can fail. A shallow rep cannot be known until the
        // athlete starts back up, so this lands at completion rather than at the bottom, and it
        // never collides with the count: a rep either broke parallel and was counted, or it did not
        // and is called here. Rowing has no no-rep — every stroke counts — so it stays silent.
        if selectedStation.hasNoRepRule, !movement.counted {
            audioCoach.announceNoRep()
        }

        if let fault = movement.fault {
            currentCue = feedbackGenerator.faultCue(for: fault, station: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        } else if needsFramingHelp(for: movement) {
            currentCue = feedbackGenerator.framingCue(for: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        }
    }

    /// Whether the hands left frame during the movement, so the throw or the handle draw could not
    /// be measured. Both stations depend on the wrists and both lose them the same way.
    private func needsFramingHelp(for movement: CountedMovement) -> Bool {
        switch latestAnalysis {
        case .wallBalls(let reps):
            guard let rep = reps.first(where: { $0.index == movement.index }) else { return false }
            return !rep.handsTracked
        case .rowing(let strokes):
            guard let stroke = strokes.first(where: { $0.index == movement.index }) else { return false }
            return !stroke.handsTracked
        case .unsupported:
            return false
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