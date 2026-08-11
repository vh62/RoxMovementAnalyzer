import AVFoundation
import SwiftUI

/// Plays back a recorded session with the pose overlay redrawn in sync with the video.
///
/// The overlay is not baked into the recording — it is the same `PoseOverlayView` used live,
/// driven from the captured `SessionTimeline` as playback progresses.
struct SessionPlaybackView: View {
    let videoURL: URL
    let timeline: SessionTimeline
    let station: HyroxStation
    var scorecard: WorkoutScorecard?

    @State private var player: AVPlayer
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var showsTuning = false
    @State private var timeObserver: Any?
    @State private var endOfPlaybackObserver: (any NSObjectProtocol)?

    init(
        videoURL: URL,
        timeline: SessionTimeline,
        station: HyroxStation,
        scorecard: WorkoutScorecard? = nil
    ) {
        self.videoURL = videoURL
        self.timeline = timeline
        self.station = station
        self.scorecard = scorecard
        self._player = State(initialValue: AVPlayer(url: videoURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            videoStage
            controls
            exportSection
        }
        .background(.black)
        .navigationTitle("Session Replay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsTuning.toggle()
                } label: {
                    Image(systemName: showsTuning ? "ruler.fill" : "ruler")
                }
                .accessibilityLabel(showsTuning ? "Hide measurements" : "Show measurements")
            }

            if scorecard != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Scorecard") {
                        scorecardDestination
                    }
                }
            }
        }
        .onAppear(perform: startObservingPlayback)
        .onDisappear(perform: stopObservingPlayback)
    }

    @ViewBuilder
    private var scorecardDestination: some View {
        if let scorecard {
            ScorecardView(viewModel: ScorecardViewModel(scorecard: scorecard))
        }
    }

    /// The recording's shape, taken from the first tracked frame.
    private var sourceAspectRatio: Double {
        timeline.entries.first?.frame.sourceAspectRatio ?? 9.0 / 16.0
    }

    private var videoStage: some View {
        // resizeAspectFill matches PoseOverlayView.point(for:in:sourceAspectRatio:), which maps
        // normalized landmarks with the same aspect-fill letterboxing.
        PlayerLayerView(player: player, sourceAspectRatio: sourceAspectRatio)
            .overlay {
                PoseOverlayView(
                    poseFrame: timeline.frame(at: currentTime),
                    showsDepthGuide: station.showsDepthGuide,
                    requiresFullBody: station.requiresFullBody,
                    // Matches the player layer's gravity below. A portrait session derives `.fill`,
                    // which is what replay has always used.
                    scalingMode: .forSource(
                        aspectRatio: sourceAspectRatio, in: UIScreen.main.bounds.size
                    )
                )
            }
            .overlay(alignment: .top) {
                if station.hasMovementAnalysis {
                    RepCountBadge(
                        count: timeline.count(at: currentTime),
                        attempts: station.hasNoRepRule ? timeline.attempts(at: currentTime) : nil,
                        noun: station.countNoun
                    )
                    .padding(.top, 16)
                }
            }
            .overlay(alignment: .bottom) {
                faultBanner
            }
            .overlay(alignment: .bottomTrailing) {
                tuningReadout
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Calls out the inefficiency on the rep that just finished, mirroring the burned-in export.
    @ViewBuilder
    private var faultBanner: some View {
        if let fault = timeline.activeFault(at: currentTime) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fault.title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)
                Text(fault.liveMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.opacity)
            .animation(.snappy, value: fault)
        }
    }

    /// Raw measurements for the movement at the playhead, for calibrating the station's thresholds.
    ///
    /// Deliberately station-specific: the numbers worth reading while tuning wall balls have nothing
    /// in common with the ones worth reading while tuning a rowing stroke.
    @ViewBuilder
    private var tuningReadout: some View {
        if showsTuning, let movement = timeline.movement(at: currentTime) {
            VStack(alignment: .leading, spacing: 2) {
                switch timeline.analysis {
                case .wallBalls(let reps):
                    if let rep = reps.first(where: { $0.index == movement.index }) {
                        Text("REP \(rep.index + 1) · \(rep.viewpoint.rawValue)")
                            .font(.caption2.weight(.black))
                        readoutRow("depth", String(format: "%+.3f", rep.deepestDelta))
                        readoutRow("release", rep.releaseOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")
                        readoutRow("reach", rep.catchReach.map { String(format: "%.2f", $0) } ?? "—")
                        readoutRow("hands", rep.handsTracked ? "tracked" : "lost")
                    }
                case .rowing(let strokes):
                    if let stroke = strokes.first(where: { $0.index == movement.index }) {
                        Text("STROKE \(stroke.index + 1) · \(stroke.viewpoint.rawValue)")
                            .font(.caption2.weight(.black))
                        readoutRow("catch", String(format: "%.0f°", stroke.catchKneeAngle))
                        readoutRow("finish", String(format: "%.0f°", stroke.finishKneeAngle))
                        readoutRow("rate", stroke.strokeRateSPM.map { String(format: "%.1f spm", $0) } ?? "—")
                        readoutRow("ratio", stroke.recoveryRatio.map { String(format: "%.2f", $0) } ?? "—")
                        readoutRow("back", stroke.backSwingOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")
                        readoutRow("arms", stroke.armBreakOffset.map { String(format: "%+.0f ms", $0 * 1000) } ?? "—")
                        readoutRow("slide", stroke.slideRatio.map { String(format: "%.2f", $0) } ?? "—")
                        readoutRow("hands", stroke.handsTracked ? "tracked" : "lost")
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
            .padding(12)
        }
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            Text(value)
        }
        .frame(width: 128, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(.white)
                        .clipShape(Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Text(Self.timeLabel(currentTime))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)

                Slider(
                    value: $currentTime,
                    in: 0...max(duration, 0.01),
                    onEditingChanged: handleScrubbing
                )
                .tint(.white)
                .accessibilityLabel("Playback position")
                .overlay(alignment: .leading) { faultMarkers }

                Text(Self.timeLabel(duration))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black)
    }

    /// Ticks along the scrubber showing where the faulted reps are, so they can be found without
    /// scrubbing blind.
    @ViewBuilder
    private var faultMarkers: some View {
        if duration > 0, !timeline.faultedMovements.isEmpty {
            GeometryReader { proxy in
                ForEach(timeline.faultedMovements) { movement in
                    Capsule()
                        .fill(.red)
                        .frame(width: 2.5, height: 10)
                        .offset(x: proxy.size.width * min(movement.endSeconds / duration, 1) - 1.25)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Export

    /// The export runs on its own from the moment the recording lands, so this only reports on it.
    private var exportSection: some View {
        SessionExportStatusView(style: .dark)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(.black)
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            // Restarting from the end should replay rather than sit on the last frame.
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func handleScrubbing(_ editing: Bool) {
        isScrubbing = editing
        guard !editing else { return }

        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func startObservingPlayback() {
        loadDuration()

        // ~30 fps so the overlay tracks the video without redrawing more than the source frames.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
        }

        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { isPlaying = false }
        }
    }

    /// Prefers the asset's own duration, falling back to the tracked timeline if it is unavailable.
    private func loadDuration() {
        guard let item = player.currentItem else {
            duration = timeline.duration
            return
        }

        Task {
            let assetDuration = try? await item.asset.load(.duration)
            if let assetDuration, assetDuration.isNumeric, assetDuration.seconds > 0 {
                duration = assetDuration.seconds
            } else {
                duration = timeline.duration
            }
        }
    }

    private func stopObservingPlayback() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endOfPlaybackObserver)
            self.endOfPlaybackObserver = nil
        }
        player.pause()
    }

    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// AVPlayerLayer wrapper — `VideoPlayer` does not expose `videoGravity`, which has to match the
/// pose overlay's coordinate mapping or the skeleton drifts off the body.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    /// The recording's aspect ratio, so the gravity can be chosen the same way the overlay chooses
    /// its mapping: fill a portrait clip, letterbox a landscape one.
    let sourceAspectRatio: Double

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.sourceAspectRatio = sourceAspectRatio
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.sourceAspectRatio = sourceAspectRatio
    }
}

final class PlayerContainerView: UIView {
    /// Re-evaluated on every layout, because the gravity depends on the container's shape as well
    /// as the recording's.
    var sourceAspectRatio: Double = 9.0 / 16.0 {
        didSet { applyGravity() }
    }

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }

    private func applyGravity() {
        let mode = PoseOverlayGeometry.ScalingMode.forSource(
            aspectRatio: sourceAspectRatio, in: bounds.size
        )
        playerLayer.videoGravity = mode == .aspectFill ? .resizeAspectFill : .resizeAspect
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
