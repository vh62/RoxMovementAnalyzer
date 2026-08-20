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
    /// Attempts so far, for stations where a movement can fail. Nil elsewhere, so the badge shows a
    /// bare count rather than a ratio that is always 1:1.
    var liveAttemptCount: Int?

    /// The recorded movie for the session just captured, once it has finished writing.
    var sessionVideoURL: URL?
    /// Pose frames of the session just captured, aligned to video playback time.
    var sessionTimeline: SessionTimeline?
    var showsPlayback = false
    /// Analysis of the movements completed so far, powering the tuning readout.
    var latestAnalysis: StationAnalysis = .unsupported
    /// User-controlled: voice cues are helpful for missed reps, but noisy if forced on.
    var audioCuesEnabled = false
    /// Shows raw per-movement measurements so thresholds can be calibrated against real footage.
    var showsTuningReadout = false

    /// Whether the finished session can be watched back with its overlay.
    var canReviewVideo: Bool { sessionVideoURL != nil && !(sessionTimeline?.isEmpty ?? true) }

    /// Whether the analysis controls — audio cues, the tuning readout — apply to this station.
    ///
    /// Distinct from `countNoun`, which decides the *counter*. Both ergs are analysed and want the
    /// controls; neither shows a tally.
    var showsAnalysisControls: Bool { selectedStation.hasMovementAnalysis }

    /// What the live counter is counting, or nil for a station that shows none.
    var countNoun: String? { selectedStation.countNoun }

    /// Stations whose analysis needs the whole body in frame — the skeleton is only drawn once the
    /// full body is tracked, since both analysed stations measure joint relationships across it.
    var requiresFullBody: Bool { selectedStation.requiresFullBody }

    /// Whether to draw the hip-versus-knee parallel line. Wall balls only: it is a squat-judging
    /// device and would be nonsense over a seated rower.
    var showsDepthGuide: Bool { selectedStation.showsDepthGuide }
    var showsJointAngles: Bool { selectedStation.showsJointAngles }

    /// The side of the skeleton to draw live, or nil to draw both.
    ///
    /// Nil for the first half-second while the vote settles, so the skeleton starts two-sided and
    /// switches once. Preferred over hiding the skeleton until the answer arrives.
    var profileSide: BodySide? { liveCounter.profileSide }

    private let feedbackGenerator: LiveFeedbackGenerating
    private let sessionAnalyzer: LiveSessionAnalyzing
    private let poseEstimator: PoseEstimating?
    private var capturedFrames: [PoseFrame] = []
    private var liveCounter = LiveMovementCounter(station: .wallBalls)
    private let repCuePlayer: RepCuePlaying
    private var recordingFinishTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var cueHoldUntil: Date?

    /// How long a fault cue stays on screen before the standing cue returns.
    private static let faultCueDuration: TimeInterval = 2.5
    private static let shallowRepCueCooldown: TimeInterval = 2.0

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
            liveCounter = LiveMovementCounter(station: selectedStation)
            hasLoggedFrameLimit = false
            liveRepCount = 0
            liveAttemptCount = nil
            shallowRepCueAllowedAt = .distantPast
            latestAnalysis = .unsupported
            cueHoldUntil = nil
            sessionScorecard = nil
            sessionVideoURL = nil
            sessionTimeline = nil
            analysisTask?.cancel()
            analysisTask = nil
            recordingState = .recording
            currentCue = feedbackGenerator.recordingCue(for: selectedStation)
        } catch {
            recordingState = .failed(error.localizedDescription)
        }
    }

    private func stopRecording() {
        cameraService.stopRecording()

        // The state changes *before* the work starts. Analysis used to run synchronously right
        // here, so the screen sat frozen on the last frame and only reached `.processing` once it
        // was already over — there was no moment at which anything could show progress.
        recordingState = .processing
        startAnalysis()

        // The movie file keeps writing after stopRecording() returns; wait for the delegate
        // rather than navigating to a video that does not exist yet.
        startRecordingFinishTimeout()
    }

    /// Turns the captured frames into the scorecard and replay timeline, off the main actor.
    ///
    /// A long clip is thousands of frames and every analyzer runs over all of them, which is far
    /// too much to do while the UI is trying to draw. Shared by the user tapping stop and by a
    /// recording that stopped itself at the duration or storage limit, so the set is analysed
    /// identically either way.
    private func startAnalysis() {
        let station = selectedStation
        let frames = capturedFrames
        let analyzer = sessionAnalyzer

        analysisTask = Task { [weak self] in
            let scorecard = await Task.detached(priority: .userInitiated) {
                analyzer.analyze(station: station, frames: frames)
            }.value
            let timeline = await Task.detached(priority: .userInitiated) {
                SessionTimeline(frames: frames, station: station)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.sessionScorecard = scorecard
            self.sessionTimeline = timeline
            self.currentCue = self.feedbackGenerator.completedCue(for: station)
        }
    }

    /// Navigates once *both* the movie file and the analysis are done. Either can finish first.
    private func finishSessionWhenReady() {
        Task { [weak self] in
            await self?.analysisTask?.value
            guard let self, self.recordingState == .processing else { return }
            self.finishSession()
        }
    }

    /// Falls through to the scorecard if the capture delegate never reports back, so a stalled
    /// write cannot strand the user on the processing state.
    private func startRecordingFinishTimeout() {
        recordingFinishTask?.cancel()
        recordingFinishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.recordingState == .processing else { return }
            self.finishSessionWhenReady()
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
            recordingState = .processing
            startAnalysis()
            finishSessionWhenReady()
            return
        }

        guard recordingState == .processing else { return }
        finishSessionWhenReady()
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
        guard capturedFrames.count < cameraService.maximumCapturedPoseFrames else {
            if !hasLoggedFrameLimit {
                hasLoggedFrameLimit = true
                Self.log.error(
                    "hit the captured-frame ceiling; analysis covers the first \(self.cameraService.maximumCapturedPoseFrames, privacy: .public) frames only"
                )
            }
            return
        }

        capturedFrames.append(poseFrame)

        if selectedStation.hasMovementAnalysis {
            let previousCompleted = liveCounter.completedMovements.count
            liveCounter.process(poseFrame)
            liveRepCount = liveCounter.count
            liveAttemptCount = selectedStation.hasNoRepRule ? liveCounter.attempts : nil
            latestAnalysis = liveCounter.analysis

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
        // Wall balls and burpee broad jumps are the two stations with a rule a movement can fail.
        // Neither verdict can be known before the movement finishes — a shallow rep is only settled
        // once the athlete starts back up, and a burpee can still fail rule 6 at the very end — so
        // this lands at completion rather than mid-movement, and never collides with the count.
        // Neither erg has a no-rep — every stroke and pull counts — so both stay silent.
        if selectedStation.hasNoRepRule, !movement.counted {
            playNoRepCueIfAllowed()
        }

        if let fault = movement.fault {
            currentCue = feedbackGenerator.faultCue(for: fault, station: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        } else if needsFramingHelp(for: movement) {
            currentCue = feedbackGenerator.framingCue(for: selectedStation)
            cueHoldUntil = Date().addingTimeInterval(Self.faultCueDuration)
        }
    }

    /// Whether the hands left frame during the movement, so the measurements that need them could not
    /// be taken. Every analysed station depends on the wrists, and they are lost at the point of the
    /// movement where they matter most: for the throw and both handle draws that is the top, and for
    /// a burpee it is the floor, at the bottom edge of a shot framed for a travelling athlete.
    private func needsFramingHelp(for movement: CountedMovement) -> Bool {
        switch latestAnalysis {
        case .wallBalls(let reps):
            guard let rep = reps.first(where: { $0.index == movement.index }) else { return false }
            return !rep.handsTracked
        case .rowing(let strokes):
            guard let stroke = strokes.first(where: { $0.index == movement.index }) else { return false }
            return !stroke.handsTracked
        case .skiErg(let pulls):
            guard let pull = pulls.first(where: { $0.index == movement.index }) else { return false }
            return !pull.handsTracked
        case .unsupported:
            return false
        }
    }

    private func playNoRepCueIfAllowed() {
        guard audioCuesEnabled else { return }

        let now = Date()
        guard now >= shallowRepCueAllowedAt else { return }

        repCuePlayer.playNoRepCue(selectedStation.noRepPhrase)
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