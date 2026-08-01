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
        }
        .background(.black)
        .navigationTitle("Session Replay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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

    private var videoStage: some View {
        // resizeAspectFill matches PoseOverlayView.point(for:in:sourceAspectRatio:), which maps
        // normalized landmarks with the same aspect-fill letterboxing.
        PlayerLayerView(player: player)
            .overlay {
                PoseOverlayView(
                    poseFrame: timeline.frame(at: currentTime),
                    showsDepthGuide: station == .wallBalls,
                    requiresFullBody: station == .wallBalls
                )
            }
            .overlay(alignment: .top) {
                if station == .wallBalls {
                    RepCountBadge(count: timeline.validReps(at: currentTime))
                        .padding(.top, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                Text(Self.timeLabel(duration))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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

/// AVPlayerLayer wrapper — `VideoPlayer` does not expose `videoGravity`, which must be
/// aspect-fill for the pose overlay's coordinate mapping to line up with the video.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
