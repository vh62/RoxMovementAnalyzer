import AVFoundation
import CoreVideo
import SwiftUI

struct LiveAnalysisView: View {
    @Environment(SessionExportService.self) private var exportService
    @AppStorage(AppSettingsKeys.wallBallAudioCuesEnabled) private var audioCuesEnabled = false
    @AppStorage(AppSettingsKeys.skeletonOverlayEnabled) private var skeletonOverlayEnabled = false
    @AppStorage(AppSettingsKeys.angleLabelsEnabled) private var angleLabelsEnabled = false
    @AppStorage(AppSettingsKeys.depthGuideEnabled) private var depthGuideEnabled = true
    @State private var viewModel: LiveAnalysisViewModel

    /// Latest frame from a video-file source, shown in place of the camera preview.
    @State private var importedFrame: CVPixelBuffer?

    @MainActor
    init(viewModel: LiveAnalysisViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    @MainActor
    init(selectedStation: HyroxStation = .wallBalls) {
        self._viewModel = State(initialValue: LiveAnalysisViewModel(selectedStation: selectedStation))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            preview
                .ignoresSafeArea()
                .overlay {
                    PoseOverlayView(
                        poseFrame: viewModel.latestPoseFrame,
                        showsDepthGuide: viewModel.showsDepthGuide && depthGuideEnabled,
                        showsSkeleton: skeletonOverlayEnabled,
                        showsAngleLabels: angleLabelsEnabled && viewModel.showsJointAngles,
                        profileSide: viewModel.profileSide,
                        requiresFullBody: viewModel.requiresFullBody,
                        scalingMode: overlayScalingMode
                    )
                    .ignoresSafeArea()
                }
                .overlay(alignment: .top) {
                    // Sits in the upper area, clear of both the status pills and the rep badge,
                    // so the lower half of the frame — legs and feet — stays unobstructed.
                    poseDetectionOverlay
                        .padding(.top, 150)
                }
                .overlay(alignment: .top) {
                    topOverlay
                }
                .overlay(alignment: .top) {
                    liveRepBadge
                }
                .overlay(alignment: .bottomLeading) {
                    tuningReadout
                }
                .overlay {
                    processingOverlay
                }

            VStack(spacing: 12) {
                if showsCueCard {
                    cueCard
                }
                controls
            }
            .padding(16)
        }
        .background(.black)
        .navigationTitle(viewModel.selectedStation.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.audioCuesEnabled = audioCuesEnabled
            // Hook up the file source before preparing, so nothing is missed once it starts.
            configureVideoFileSource()
            await viewModel.prepareCamera()
            startVideoFileIfNeeded()
        }
        .onAppear {
            viewModel.audioCuesEnabled = audioCuesEnabled
            // Returning from playback: the camera was released when the set finished, and `.task`
            // does not run again after a push, so restart the preview here.
            viewModel.resumeSession()
        }
        .onDisappear {
            viewModel.stopSession()
        }
        .onChange(of: viewModel.sessionVideoURL) { _, url in
            // Burn the overlay in as soon as the recording lands. The service is app-scoped, so
            // this keeps running while the athlete reviews their scorecard or leaves the screen.
            guard let url, let timeline = viewModel.sessionTimeline else { return }
            exportService.start(
                sourceURL: url,
                timeline: timeline,
                station: viewModel.selectedStation
            )
        }
        .onChange(of: audioCuesEnabled) { _, isEnabled in
            viewModel.audioCuesEnabled = isEnabled
        }
        .navigationDestination(isPresented: $viewModel.showsScorecard) {
            if let scorecard = viewModel.sessionScorecard {
                ScorecardView(viewModel: ScorecardViewModel(scorecard: scorecard))
            } else {
                ScorecardView()
            }
        }
        .navigationDestination(isPresented: $viewModel.showsPlayback) {
            if let videoURL = viewModel.sessionVideoURL, let timeline = viewModel.sessionTimeline {
                SessionPlaybackView(
                    videoURL: videoURL,
                    timeline: timeline,
                    station: viewModel.selectedStation,
                    scorecard: viewModel.sessionScorecard
                )
            }
        }
    }

    private var videoFileSource: VideoFileCaptureService? {
        viewModel.cameraService as? VideoFileCaptureService
    }

    /// The camera path stays on `.fill`, exactly as it always has: the preview layer fills the
    /// screen and the capture connection already rotates frames upright, so the orientations agree
    /// by construction.
    ///
    /// Only an imported clip can disagree with the screen — a RowErg video is filmed landscape —
    /// and only there is the mode derived from the footage.
    private var overlayScalingMode: PoseOverlayGeometry.ScalingMode {
        guard videoFileSource != nil, let frame = viewModel.latestPoseFrame else { return .aspectFill }
        return .forSource(aspectRatio: frame.sourceAspectRatio, in: previewSize)
    }

    /// The overlay canvas fills the screen, so its own bounds are the container the mode depends on.
    private var previewSize: CGSize {
        UIScreen.main.bounds.size
    }

    /// Mirrors the decoded frames into the preview and stops the "recording" at end of clip, so a
    /// picked video runs start to finish and lands on the scorecard without any tapping.
    private func configureVideoFileSource() {
        guard let source = videoFileSource else { return }

        source.previewFrameHandler = { buffer in
            importedFrame = buffer
        }
        source.feedFinishedHandler = {
            guard viewModel.recordingState == .recording else { return }
            viewModel.toggleRecording()
        }
    }

    private func startVideoFileIfNeeded() {
        guard videoFileSource != nil, viewModel.recordingState == .ready else { return }
        viewModel.toggleRecording()
    }

    /// A file-backed source has no capture session, so it shows the decoded frames instead of a
    /// preview layer.
    ///
    /// Sized from a `GeometryReader` rather than left to SwiftUI. Both of these wrap a plain UIView
    /// with no intrinsic content size, and `maxWidth: .infinity` only asks to grow *within* whatever
    /// SwiftUI decided the ideal size was — for a sizeless representable that ends up being derived
    /// from the siblings in the stack, which is how the decoded frame ended up as a half-size box
    /// floating off to one side. A GeometryReader fills its proposal greedily, so pinning to
    /// `proxy.size` states the size outright instead of asking for it.
    private var preview: some View {
        GeometryReader { proxy in
            Group {
                if viewModel.cameraService is VideoFileCaptureService {
                    DecodedFramePreview(pixelBuffer: importedFrame)
                } else {
                    CameraPreviewView(session: viewModel.cameraService.session)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// Covers the gap between the clip ending and the replay opening.
    ///
    /// Analysis runs over every captured frame and the movie file is still being written, so on a
    /// long set there is a real wait here. Without this the last frame just sits there and the app
    /// looks stalled rather than busy.
    @ViewBuilder
    private var processingOverlay: some View {
        if viewModel.recordingState == .processing {
            ZStack {
                Color.black.opacity(0.55)

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Analysing your set…")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Scoring every rep and building the replay.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Analysing your set")
        }
    }

    private var audioCueButton: some View {
        Button {
            audioCuesEnabled.toggle()
            viewModel.audioCuesEnabled = audioCuesEnabled
        } label: {
            Image(systemName: audioCuesEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 32)
                .background(.black.opacity(0.58))
                .clipShape(Capsule())
        }
        .accessibilityLabel(audioCuesEnabled ? "Turn audio cues off" : "Turn audio cues on")
    }

    private var topOverlay: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Label(stateLabel, systemImage: stateSymbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.58))
                    .clipShape(Capsule())

                Spacer()

                Button {
                    viewModel.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 32)
                        .background(.black.opacity(0.58))
                        .clipShape(Capsule())
                }
                .disabled(viewModel.recordingState == .recording)
                .accessibilityLabel("Switch camera")

                if viewModel.showsAnalysisControls {
                    audioCueButton

                    Button {
                        viewModel.showsTuningReadout.toggle()
                    } label: {
                        Image(systemName: viewModel.showsTuningReadout ? "ruler.fill" : "ruler")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 32)
                            .background(.black.opacity(0.58))
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel(
                        viewModel.showsTuningReadout ? "Hide measurements" : "Show measurements"
                    )
                }

                Menu {
                    ForEach(HyroxStation.allCases) { station in
                        Button(station.rawValue) {
                            viewModel.updateStation(station)
                        }
                    }
                } label: {
                    Label(viewModel.selectedStation.rawValue, systemImage: "figure.run")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.58))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if case .failed(let message) = viewModel.recordingState {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Kept deliberately low and see-through: it sits over the bottom of the frame, which is
    /// exactly where the athlete's legs and feet are, and confirming those are in shot is the
    /// whole job of the framing cue. A translucent fill shows the body through it, where a
    /// frosted material would blur precisely what needs checking.
    private var cueCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.currentCue.status.symbolName)
                    .foregroundStyle(viewModel.currentCue.status.color)
                Text(viewModel.currentCue.message)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
            }

            // The supporting line is unreadable from where the athlete stands anyway, so it only
            // appears when the camera is not live — errors, and the wrap-up after a set.
            if showsCueDetail {
                Text(viewModel.currentCue.detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The cue card earns its place on screen or it does not appear.
    ///
    /// Anything needing attention — a fault to correct, a failure to report — always shows.
    /// Otherwise it stays out of the way: while waiting to start there is nothing to say that the
    /// record button does not already say, and while the framing prompt is up that prompt is the
    /// better signal, since it reflects what is actually being tracked.
    private var showsCueCard: Bool {
        switch viewModel.currentCue.status {
        case .caution, .needsWork:
            return true
        case .strong, .raceReady:
            break
        }

        if viewModel.recordingState == .ready { return false }
        return !showsBodyPrompt
    }

    /// Detail is hidden while the camera is live so the frame stays clear.
    private var showsCueDetail: Bool {
        switch viewModel.recordingState {
        case .ready, .recording: false
        case .idle, .preparing, .processing, .completed, .failed: true
        }
    }

    @ViewBuilder
    private var liveRepBadge: some View {
        if viewModel.recordingState == .recording, let noun = viewModel.countNoun {
            RepCountBadge(
                count: viewModel.liveRepCount,
                attempts: viewModel.liveAttemptCount,
                noun: noun
            )
            .padding(.top, 72)
        }
    }

    /// Raw measurements from the last completed movement, for calibrating the station's thresholds.
    @ViewBuilder
    private var tuningReadout: some View {
        if viewModel.showsTuningReadout {
            VStack(alignment: .leading, spacing: 2) {
                switch viewModel.latestAnalysis {
                case .wallBalls(let reps):
                    if let rep = reps.last {
                        Text("REP \(rep.index + 1) · \(rep.viewpoint.rawValue)")
                            .font(.caption2.weight(.black))
                        Text("depth  \(String(format: "%+.3f", rep.deepestDelta))")
                        Text("release \(rep.releaseOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")")
                        Text("reach  \(rep.catchReach.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("hands  \(rep.handsTracked ? "tracked" : "lost")")
                    }
                case .rowing(let strokes):
                    if let stroke = strokes.last {
                        Text("STROKE \(stroke.index + 1) · \(stroke.viewpoint.rawValue)")
                            .font(.caption2.weight(.black))
                        Text("catch  \(String(format: "%.0f°", stroke.catchKneeAngle))")
                        Text("rate   \(stroke.strokeRateSPM.map { String(format: "%.1f spm", $0) } ?? "—")")
                        Text("ratio  \(stroke.recoveryRatio.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("back   \(stroke.backSwingOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")")
                        Text("arms   \(stroke.armBreakOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")")
                        Text("slide  \(stroke.slideRatio.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("hands  \(stroke.handsTracked ? "tracked" : "lost")")
                    }
                case .skiErg(let pulls):
                    if let pull = pulls.last {
                        Text("PULL \(pull.index + 1) · \(pull.viewpoint.rawValue)")
                            .font(.caption2.weight(.black))
                        Text("catch  \(String(format: "%.0f°", pull.catchShoulderAngle))")
                        Text("rate   \(pull.pullRateSPM.map { String(format: "%.1f/min", $0) } ?? "—")")
                        Text("ratio  \(pull.recoveryRatio.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("lean   \(pull.finishForwardLean.map { String(format: "%.0f°", $0) } ?? "—")")
                        Text("hinge  \(pull.hingeToKneeRatio.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("peak   \(pull.peakAtDriveFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")")
                        Text("load   \(pull.catchConnection.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("dip    \(pull.midDriveDip.map { String(format: "%.2f", $0) } ?? "—")")
                        Text("hands  \(pull.handsTracked ? "tracked" : "lost")")
                    }
                case .unsupported:
                    EmptyView()
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
        }
    }

    /// Shows the framing prompt when there is no pose yet, or — for full-body stations like Wall
    /// Balls — when only part of the body is in frame (so the skeleton is intentionally hidden).
    private var showsBodyPrompt: Bool {
        guard let frame = viewModel.latestPoseFrame else { return true }
        return viewModel.requiresFullBody && !frame.hasFullBody
    }

    /// A slim pill rather than a card: this shows while the athlete is still positioning
    /// themselves, so it must not cover the body they are trying to fit in shot. The explanation
    /// it used to carry could not be read from that distance anyway.
    @ViewBuilder
    private var poseDetectionOverlay: some View {
        if showsBodyPrompt {
            Label("Step back — full body not in frame", systemImage: "figure.stand")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
        }
    }

    /// Sized to the label rather than the screen.
    ///
    /// A full-width block at the bottom was covering the athlete's feet, which is exactly where the
    /// eye needs to go for depth. This keeps a comfortable tap target while giving the frame back.
    private var controls: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            Label(recordButtonTitle, systemImage: recordButtonSymbolName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(recordButtonColor)
                .clipShape(Capsule())
        }
        .disabled(!canToggleRecording)
    }

    private var stateLabel: String {
        switch viewModel.recordingState {
        case .idle: "Idle"
        case .preparing: "Preparing camera"
        case .ready: "Ready"
        case .recording: "Recording"
        case .processing: "Saving video"
        case .completed: "Captured"
        case .failed: "Camera unavailable"
        }
    }

    private var stateSymbolName: String {
        switch viewModel.recordingState {
        case .idle, .preparing: "camera.metering.unknown"
        case .ready: "camera.fill"
        case .recording: "record.circle.fill"
        case .processing: "hourglass"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var recordButtonTitle: String {
        switch viewModel.recordingState {
        case .recording: "Stop and Review"
        case .ready, .completed: "Start Recording"
        case .processing: "Saving Video…"
        case .idle, .preparing: "Preparing"
        case .failed: "Camera Required"
        }
    }

    private var recordButtonSymbolName: String {
        viewModel.recordingState == .recording ? "stop.fill" : "record.circle"
    }

    private var recordButtonColor: Color {
        viewModel.recordingState == .recording ? .red : AppTheme.ink
    }

    private var canToggleRecording: Bool {
        switch viewModel.recordingState {
        case .ready, .recording, .completed: true
        case .idle, .preparing, .processing, .failed: false
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct PoseOverlayView: View {
    let poseFrame: PoseFrame?
    var showsDepthGuide = false
    var showsSkeleton = true
    var showsAngleLabels = true
    /// The SkiErg hand path for the pull at this moment, tinted by pulling effort. Empty everywhere
    /// else, which is what keeps this a no-op for the stations that have no force curve.
    var powerTrail: [SkiPull.PowerSample] = []
    /// Draw only this side of the athlete, or nil to draw both. Set when the camera is beside the
    /// athlete, where the far limb is MediaPipe's estimate rather than a tracked joint.
    var profileSide: BodySide?
    /// When true, the skeleton is only drawn if the whole body is tracked (see PoseFrame.hasFullBody).
    var requiresFullBody = false
    /// How the video underneath is fitted, so the skeleton lands on the body.
    ///
    /// Defaults to `.aspectFill` — the long-standing behaviour of the camera preview, which must
    /// not change. Only the imported-video path passes anything else, because only there can the
    /// footage's orientation disagree with the screen's.
    var scalingMode: PoseOverlayGeometry.ScalingMode = .aspectFill


    var body: some View {
        GeometryReader { proxy in
            if let poseFrame, !requiresFullBody || poseFrame.hasFullBody {
                Canvas { context, size in
                    if showsDepthGuide {
                        drawDepthGuide(in: context, size: size, poseFrame: poseFrame)
                    }
                    // Under the skeleton: the trail is the widest thing drawn, and the bones have to
                    // stay readable over it.
                    drawPowerTrail(in: context, size: size, poseFrame: poseFrame)
                    if showsSkeleton {
                        drawConnections(in: context, size: size, poseFrame: poseFrame)
                        drawLandmarks(in: context, size: size, poseFrame: poseFrame)
                    }
                }

                // Dark and translucent rather than solid yellow. These sit right on the joints they
                // describe, so a bright opaque chip hides the very thing the athlete is checking.
                // Legible against a gym floor or dark kit, without becoming the brightest thing in
                // the frame.
                ForEach(showsAngleLabels ? angleLabels(for: poseFrame, in: proxy.size) : []) { label in
                    Text(label.text)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .position(label.position)
                        .accessibilityLabel(label.accessibilityLabel)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Draws a horizontal reference line at knee height. The hip crease must drop below this line
    /// for a legal wall-ball squat, so the line turns green once the hips are below it.
    private func drawDepthGuide(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        guard let guide = PoseOverlayGeometry.depthGuide(for: poseFrame) else { return }

        let kneeY = PoseOverlayGeometry.point(
            forNormalizedX: 0.5,
            y: guide.kneeLevel,
            in: size,
            sourceAspectRatio: poseFrame.sourceAspectRatio,
            scalingMode: scalingMode
        ).y

        // Spans the video, not the container: run edge to edge and the line carries on over the
        // letterbox bars, where it is measuring nothing.
        let videoRect = PoseOverlayGeometry.mediaRect(
            in: size, sourceAspectRatio: poseFrame.sourceAspectRatio, scalingMode: scalingMode
        )
        guard videoRect.width > 0, kneeY >= videoRect.minY, kneeY <= videoRect.maxY else { return }

        let hipsBelow = guide.hasReachedDepth
        let guideColor: Color = hipsBelow ? .green : .white

        var line = Path()
        line.move(to: CGPoint(x: videoRect.minX, y: kneeY))
        line.addLine(to: CGPoint(x: videoRect.maxX, y: kneeY))
        context.stroke(line, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 5, dash: [12, 7]))
        context.stroke(line, with: .color(guideColor), style: StrokeStyle(lineWidth: 3, dash: [12, 7]))

        var label = context.resolve(
            Text(hipsBelow ? "Depth reached" : "Squat hips below line")
                .font(.caption2.weight(.black))
        )
        label.shading = .color(guideColor)
        context.draw(label, at: CGPoint(x: videoRect.midX, y: max(kneeY - 14, videoRect.minY + 12)))
    }

    /// Draws the hand path for the pull at the playhead, weighted by how hard the athlete was pulling
    /// as the hands passed through each part of their range.
    private func drawPowerTrail(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for segment in PoseOverlayGeometry.trailSegments(
            powerTrail, in: size,
            sourceAspectRatio: poseFrame.sourceAspectRatio, scalingMode: scalingMode
        ) {
            let shading = PoseOverlayGeometry.trailShading(intensity: segment.intensity)
            var path = Path()
            path.move(to: segment.from)
            path.addLine(to: segment.to)
            context.stroke(
                path,
                with: .color(.orange.opacity(shading.alpha)),
                style: StrokeStyle(lineWidth: shading.width, lineCap: .round)
            )
        }
    }

    private func drawConnections(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for connection in PoseOverlayGeometry.connections(for: profileSide) {
            guard let start = poseFrame.landmark(connection.0), let end = poseFrame.landmark(connection.1) else { continue }
            guard start.isVisible, end.isVisible else { continue }
            var path = Path()
            path.move(to: point(for: start, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            path.addLine(to: point(for: end, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            // A thin dark line under a translucent white one: readable over both a bright gym wall
            // and dark kit, without the saturated colour competing with the athlete.
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 3)
            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1.5)
        }
    }

    private func drawLandmarks(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        // Filters what is *drawn*, never what is measured. `shoulderToTorsoRatio` reads the apparent
        // shoulder spread, and a narrow spread is exactly what tells `viewpoint` the camera is beside
        // the athlete — removing the far shoulder from the pose itself would destroy the reading that
        // decides this filtering is on at all.
        let drawn = profileSide.map(PoseOverlayGeometry.landmarks(for:))

        for landmark in poseFrame.landmarks {
            guard landmark.isVisible, landmark.name.isDrawnInOverlay else { continue }
            guard drawn?.contains(landmark.name) ?? true else { continue }
            let position = point(for: landmark, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio)
            let rect = CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.7)))
        }
    }

    private func angleLabels(for poseFrame: PoseFrame, in size: CGSize) -> [PoseAngleLabel] {
        var labels: [PoseAngleLabel] = []

        if poseFrame.areVisible(.leftShoulder, .rightShoulder, .leftHip, .rightHip),
           let angle = poseFrame.torsoLeanAngle(), let hipCenter = poseFrame.midpoint(.leftHip, .rightHip) {
            labels.append(label("Back", angle: angle, at: hipCenter, poseFrame: poseFrame, size: size))
        }

        if poseFrame.areVisible(.leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftKnee, .rightKnee),
           let angle = poseFrame.hipHingeAngle(), let hipCenter = poseFrame.midpoint(.leftHip, .rightHip) {
            labels.append(label("Hinge", angle: angle, at: hipCenter, poseFrame: poseFrame, size: size, yOffset: -28))
        }

        // In profile only the drawn side is labelled, and the L/R prefix goes with it: that prefix
        // exists to tell two labels apart, and there are no longer two.
        let sides: [BodySide] = profileSide.map { [$0] } ?? [.left, .right]
        let prefixed = sides.count > 1

        for side in sides {
            let name = prefixed ? (side == .left ? "L " : "R ") : ""

            if poseFrame.areVisible(side.hip, side.knee, side.ankle),
               let angle = poseFrame.angle(at: side.knee, from: side.hip, to: side.ankle),
               let knee = poseFrame.landmark(side.knee) {
                labels.append(label(name + "knee", angle: angle, at: knee, poseFrame: poseFrame, size: size))
            }

            if poseFrame.areVisible(side.shoulder, side.elbow, side.wrist),
               let angle = poseFrame.angle(at: side.elbow, from: side.shoulder, to: side.wrist),
               let elbow = poseFrame.landmark(side.elbow) {
                labels.append(label(name + "elbow", angle: angle, at: elbow, poseFrame: poseFrame, size: size))
            }
        }

        return labels
    }

    private func label(_ title: String, angle: Double, at landmark: PoseLandmark, poseFrame: PoseFrame, size: CGSize, yOffset: CGFloat = 0) -> PoseAngleLabel {
        var position = point(for: landmark, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio)
        position.y += yOffset
        return PoseAngleLabel(title: title, angle: angle, position: position)
    }

    private func point(for landmark: PoseLandmark, in size: CGSize, sourceAspectRatio: Double) -> CGPoint {
        PoseOverlayGeometry.point(
            for: landmark, in: size, sourceAspectRatio: sourceAspectRatio, scalingMode: scalingMode
        )
    }
}

private struct PoseAngleLabel: Identifiable {
    let id = UUID()
    let title: String
    let angle: Double
    let position: CGPoint

    var text: String {
        "\(title) \(Int(angle.rounded()))°"
    }

    var accessibilityLabel: String {
        "\(title) angle \(Int(angle.rounded())) degrees"
    }
}

#Preview("Live Analysis") {
    NavigationStack {
        LiveAnalysisView(selectedStation: .wallBalls)
    }
    .environment(SessionExportService())
}