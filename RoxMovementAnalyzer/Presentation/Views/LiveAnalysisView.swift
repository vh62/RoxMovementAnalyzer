import AVFoundation
import CoreVideo
import SwiftUI

struct LiveAnalysisView: View {
    @Environment(SessionExportService.self) private var exportService
    @AppStorage("wallBallAudioCuesEnabled") private var audioCuesEnabled = false
    @State private var viewModel: LiveAnalysisViewModel

    #if DEBUG
    /// Latest frame from the debug video-file source, shown in place of the camera preview.
    @State private var debugFrame: CVPixelBuffer?
    #endif

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
                        showsDepthGuide: viewModel.showsLiveRepCount,
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
                .overlay(alignment: .top) {
                    validRepConfirmation
                }
                .overlay(alignment: .bottomLeading) {
                    tuningReadout
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
            #if DEBUG
            // Hook up the file source before preparing, so nothing is missed once it starts.
            configureDebugVideoSource()
            #endif
            await viewModel.prepareCamera()
            #if DEBUG
            startDebugVideoIfNeeded()
            #endif
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
            #if DEBUG
            guard debugVideoSource == nil else { return }
            #endif
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

    #if DEBUG
    private var debugVideoSource: VideoFileCaptureService? {
        viewModel.cameraService as? VideoFileCaptureService
    }

    private var overlayScalingMode: PoseOverlayGeometry.ScalingMode {
        debugVideoSource == nil ? .aspectFill : .aspectFit
    }

    /// Mirrors the decoded frames into the preview and stops the "recording" at end of clip, so a
    /// picked video runs start to finish and lands on the scorecard without any tapping.
    private func configureDebugVideoSource() {
        guard let source = debugVideoSource else { return }

        source.previewFrameHandler = { buffer in
            debugFrame = buffer
        }
        source.feedFinishedHandler = {
            guard viewModel.recordingState == .recording else { return }
            viewModel.toggleRecording()
        }
    }

    private func startDebugVideoIfNeeded() {
        guard debugVideoSource != nil, viewModel.recordingState == .ready else { return }
        viewModel.toggleRecording()
    }
    #endif

    #if !DEBUG
    private var overlayScalingMode: PoseOverlayGeometry.ScalingMode { .aspectFill }
    #endif

    /// A file-backed debug source has no capture session, so it shows the decoded frames instead
    /// of a preview layer.
    @ViewBuilder
    private var preview: some View {
        #if DEBUG
        if viewModel.cameraService is VideoFileCaptureService {
            DecodedFramePreview(pixelBuffer: debugFrame)
        } else {
            CameraPreviewView(session: viewModel.cameraService.session)
        }
        #else
        CameraPreviewView(session: viewModel.cameraService.session)
        #endif
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

                if viewModel.showsLiveRepCount {
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
        if viewModel.recordingState == .recording, viewModel.showsLiveRepCount {
            RepCountBadge(count: viewModel.liveRepCount)
                .padding(.top, 72)
        }
    }

    @ViewBuilder
    private var validRepConfirmation: some View {
        if viewModel.recordingState == .recording,
           viewModel.showsLiveRepCount,
           viewModel.showsValidRepConfirmation {
            Text("+1")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.green)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .padding(.top, 158)
                .id(viewModel.validRepConfirmationID)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.72).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .animation(.spring(response: 0.26, dampingFraction: 0.68), value: viewModel.validRepConfirmationID)
                .animation(.easeOut(duration: 0.18), value: viewModel.showsValidRepConfirmation)
                .accessibilityLabel("Valid rep counted")
        }
    }

    /// Raw measurements from the last completed rep, for calibrating `WallBallThresholds`.
    @ViewBuilder
    private var tuningReadout: some View {
        if viewModel.showsTuningReadout, let rep = viewModel.latestRep {
            VStack(alignment: .leading, spacing: 2) {
                Text("REP \(rep.index + 1) · \(rep.viewpoint.rawValue)")
                    .font(.caption2.weight(.black))
                Text("depth  \(String(format: "%+.3f", rep.deepestDelta))")
                Text("release \(rep.releaseOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")")
                Text("reach  \(rep.catchReach.map { String(format: "%.2f", $0) } ?? "—")")
                Text("hands  \(rep.handsTracked ? "tracked" : "lost")")
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

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.toggleRecording()
            } label: {
                Label(recordButtonTitle, systemImage: recordButtonSymbolName)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(recordButtonColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!canToggleRecording)
        }
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
    /// When true, the skeleton is only drawn if the whole body is tracked (see PoseFrame.hasFullBody).
    var requiresFullBody = false
    var scalingMode: PoseOverlayGeometry.ScalingMode = .aspectFill


    var body: some View {
        GeometryReader { proxy in
            if let poseFrame, !requiresFullBody || poseFrame.hasFullBody {
                Canvas { context, size in
                    if showsDepthGuide {
                        drawDepthGuide(in: context, size: size, poseFrame: poseFrame)
                    }
                    drawConnections(in: context, size: size, poseFrame: poseFrame)
                    drawLandmarks(in: context, size: size, poseFrame: poseFrame)
                }

                ForEach(angleLabels(for: poseFrame, in: proxy.size)) { label in
                    Text(label.text)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
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
        let mediaRect = PoseOverlayGeometry.mediaRect(
            in: size,
            sourceAspectRatio: poseFrame.sourceAspectRatio,
            scalingMode: scalingMode
        )

        let hipsBelow = guide.hasReachedDepth
        let guideColor: Color = hipsBelow ? .green : .white

        var line = Path()
        line.move(to: CGPoint(x: mediaRect.minX, y: kneeY))
        line.addLine(to: CGPoint(x: mediaRect.maxX, y: kneeY))
        context.stroke(line, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 5, dash: [12, 7]))
        context.stroke(line, with: .color(guideColor), style: StrokeStyle(lineWidth: 3, dash: [12, 7]))

        var label = context.resolve(
            Text(hipsBelow ? "Depth reached" : "Squat hips below line")
                .font(.caption2.weight(.black))
        )
        label.shading = .color(guideColor)
        context.draw(label, at: CGPoint(x: mediaRect.midX, y: max(kneeY - 14, 12)))
    }

    private func drawConnections(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for connection in PoseOverlayGeometry.connections {
            guard let start = poseFrame.landmark(connection.0), let end = poseFrame.landmark(connection.1) else { continue }
            guard start.isVisible, end.isVisible else { continue }
            var path = Path()
            path.move(to: point(for: start, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            path.addLine(to: point(for: end, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 3)
            context.stroke(path, with: .color(.cyan.opacity(0.34)), lineWidth: 2)
        }
    }

    private func drawLandmarks(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for landmark in poseFrame.landmarks {
            guard landmark.isVisible else { continue }
            let position = point(for: landmark, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio)
            let rect = CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.48)))
            context.stroke(Path(ellipseIn: rect), with: .color(.cyan.opacity(0.38)), lineWidth: 1)
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

        if poseFrame.areVisible(.leftHip, .leftKnee, .leftAnkle),
           let angle = poseFrame.angle(at: .leftKnee, from: .leftHip, to: .leftAnkle), let knee = poseFrame.landmark(.leftKnee) {
            labels.append(label("L knee", angle: angle, at: knee, poseFrame: poseFrame, size: size))
        }

        if poseFrame.areVisible(.rightHip, .rightKnee, .rightAnkle),
           let angle = poseFrame.angle(at: .rightKnee, from: .rightHip, to: .rightAnkle), let knee = poseFrame.landmark(.rightKnee) {
            labels.append(label("R knee", angle: angle, at: knee, poseFrame: poseFrame, size: size))
        }

        if poseFrame.areVisible(.leftShoulder, .leftElbow, .leftWrist),
           let angle = poseFrame.angle(at: .leftElbow, from: .leftShoulder, to: .leftWrist), let elbow = poseFrame.landmark(.leftElbow) {
            labels.append(label("L elbow", angle: angle, at: elbow, poseFrame: poseFrame, size: size))
        }

        if poseFrame.areVisible(.rightShoulder, .rightElbow, .rightWrist),
           let angle = poseFrame.angle(at: .rightElbow, from: .rightShoulder, to: .rightWrist), let elbow = poseFrame.landmark(.rightElbow) {
            labels.append(label("R elbow", angle: angle, at: elbow, poseFrame: poseFrame, size: size))
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
            for: landmark,
            in: size,
            sourceAspectRatio: sourceAspectRatio,
            scalingMode: scalingMode
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