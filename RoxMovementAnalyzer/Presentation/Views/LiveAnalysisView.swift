import AVFoundation
import SwiftUI

struct LiveAnalysisView: View {
    @State private var viewModel: LiveAnalysisViewModel

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
            CameraPreviewView(session: viewModel.cameraService.session)
                .ignoresSafeArea()
                .overlay {
                    PoseOverlayView(poseFrame: viewModel.latestPoseFrame)
                        .ignoresSafeArea()
                }
                .overlay {
                    poseDetectionOverlay
                }
                .overlay(alignment: .top) {
                    topOverlay
                }

            VStack(spacing: 12) {
                cueCard
                controls
            }
            .padding(16)
        }
        .background(.black)
        .navigationTitle(viewModel.selectedStation.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.prepareCamera()
        }
        .onDisappear {
            viewModel.stopSession()
        }
        .navigationDestination(isPresented: $viewModel.showsScorecard) {
            ScorecardView()
        }
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

    private var cueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: viewModel.currentCue.status.symbolName)
                    .foregroundStyle(viewModel.currentCue.status.color)
                Text(viewModel.currentCue.message)
                    .font(.headline.weight(.black))
                    .foregroundStyle(AppTheme.ink)
            }

            Text(viewModel.currentCue.detail)
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }

    @ViewBuilder
    private var poseDetectionOverlay: some View {
        if viewModel.latestPoseFrame == nil {
            VStack(spacing: 8) {
                Image(systemName: "figure.stand")
                    .font(.title2.weight(.bold))
                Text("Looking for full body")
                    .font(.headline.weight(.black))
                Text("Pose tracking needs shoulders, hips, knees, and hands visible. A hand-only recording will not show the body skeleton.")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: 280)
            .background(.black.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
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
        case .completed: "Captured"
        case .failed: "Camera unavailable"
        }
    }

    private var stateSymbolName: String {
        switch viewModel.recordingState {
        case .idle, .preparing: "camera.metering.unknown"
        case .ready: "camera.fill"
        case .recording: "record.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var recordButtonTitle: String {
        switch viewModel.recordingState {
        case .recording: "Stop and Review"
        case .ready, .completed: "Start Recording"
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
        case .idle, .preparing, .failed: false
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

    private let connections: [(PoseLandmarkName, PoseLandmarkName)] = [
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel),
        (.leftHeel, .leftFootIndex),
        (.leftAnkle, .leftFootIndex),
        (.rightAnkle, .rightHeel),
        (.rightHeel, .rightFootIndex),
        (.rightAnkle, .rightFootIndex),
        (.leftWrist, .leftThumb),
        (.leftWrist, .leftIndex),
        (.leftWrist, .leftPinky),
        (.leftIndex, .leftPinky),
        (.rightWrist, .rightThumb),
        (.rightWrist, .rightIndex),
        (.rightWrist, .rightPinky),
        (.rightIndex, .rightPinky),
        (.nose, .leftEyeInner),
        (.leftEyeInner, .leftEye),
        (.leftEye, .leftEyeOuter),
        (.nose, .rightEyeInner),
        (.rightEyeInner, .rightEye),
        (.rightEye, .rightEyeOuter),
        (.mouthLeft, .mouthRight)
    ]

    var body: some View {
        GeometryReader { proxy in
            if let poseFrame {
                Canvas { context, size in
                    drawConnections(in: context, size: size, poseFrame: poseFrame)
                    drawLandmarks(in: context, size: size, poseFrame: poseFrame)
                }

                ForEach(angleLabels(for: poseFrame, in: proxy.size)) { label in
                    Text(label.text)
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .position(label.position)
                        .accessibilityLabel(label.accessibilityLabel)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawConnections(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for connection in connections {
            guard let start = poseFrame.landmark(connection.0), let end = poseFrame.landmark(connection.1) else { continue }
            guard start.isVisible, end.isVisible else { continue }
            var path = Path()
            path.move(to: point(for: start, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            path.addLine(to: point(for: end, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio))
            context.stroke(path, with: .color(.yellow), lineWidth: 4)
            context.stroke(path, with: .color(.black.opacity(0.72)), lineWidth: 1.5)
        }
    }

    private func drawLandmarks(in context: GraphicsContext, size: CGSize, poseFrame: PoseFrame) {
        for landmark in poseFrame.landmarks {
            guard landmark.isVisible else { continue }
            let position = point(for: landmark, in: size, sourceAspectRatio: poseFrame.sourceAspectRatio)
            let rect = CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: rect), with: .color(.red))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
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
        let containerAspectRatio = size.width / max(size.height, 1)
        let scaledSize: CGSize
        let offset: CGPoint

        if sourceAspectRatio > containerAspectRatio {
            scaledSize = CGSize(width: size.height * sourceAspectRatio, height: size.height)
            offset = CGPoint(x: (size.width - scaledSize.width) / 2, y: 0)
        } else {
            scaledSize = CGSize(width: size.width, height: size.width / max(sourceAspectRatio, 0.001))
            offset = CGPoint(x: 0, y: (size.height - scaledSize.height) / 2)
        }

        return CGPoint(
            x: offset.x + CGFloat(landmark.x) * scaledSize.width,
            y: offset.y + CGFloat(landmark.y) * scaledSize.height
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
}