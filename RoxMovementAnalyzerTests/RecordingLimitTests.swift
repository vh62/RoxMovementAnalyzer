import AVFoundation
import CoreMedia
import UIKit
import XCTest
@testable import RoxMovementAnalyzer

/// Covers a recording that stops itself — at the duration cap or the storage floor — rather than
/// because the athlete tapped stop.
///
/// That path used to do nothing at all: `handleRecordingFinished` only acted when the state was
/// `.processing`, which is reached exclusively via the stop button, so an AVFoundation-initiated
/// stop left the app on "Recording" with no scorecard.
@MainActor
final class RecordingLimitTests: XCTestCase {

    /// Stands in for the capture session so the delegate callback can be fired on demand.
    private final class FakeCaptureService: CameraCaptureServicing {
        let session = AVCaptureSession()
        var maximumRecordingDuration: TimeInterval = 300
        var maximumCapturedPoseFrames = 20_000
        var sampleBufferHandler: ((CVPixelBuffer, Int) -> Void)?
        var recordingFinishedHandler: ((Result<URL, Error>) -> Void)?
        var authorizationState: CameraAuthorizationState = .authorized
        var activeCameraPosition: CameraPosition = .back
        private(set) var isConfigured = true
        private(set) var isRunning = false
        private(set) var isRecording = false

        private(set) var stopRecordingCallCount = 0

        func requestAccess() async -> CameraAuthorizationState { .authorized }
        func configure() throws {}
        func startSession() { isRunning = true }
        func stopSession() { isRunning = false }
        func startRecording() throws { isRecording = true }
        func stopRecording() {
            isRecording = false
            stopRecordingCallCount += 1
        }
        func switchCamera() throws -> CameraPosition { .back }

        /// Mimics AVFoundation ending the recording on its own and reporting the finished file.
        func simulateLimitReached(url: URL) {
            recordingFinishedHandler?(.success(url))
        }
    }

    private func makeViewModel(_ service: FakeCaptureService) -> LiveAnalysisViewModel {
        // poseEstimator: nil keeps MediaPipe out of the test entirely.
        LiveAnalysisViewModel(
            selectedStation: .wallBalls,
            cameraService: service,
            poseEstimator: nil
        )
    }

    /// Waits for a condition, since the scorecard and timeline are now built off the main actor.
    /// Polls rather than sleeping a fixed interval so a fast machine is not made to wait.
    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    func testRecordingThatStopsItselfStillProducesAScorecard() async {
        let service = FakeCaptureService()
        let viewModel = makeViewModel(service)

        await viewModel.prepareCamera()
        viewModel.toggleRecording()
        XCTAssertEqual(viewModel.recordingState, .recording, "precondition: recording started")

        let url = URL(fileURLWithPath: "/tmp/rox-test-session.mov")
        service.simulateLimitReached(url: url)

        XCTAssertNotEqual(
            viewModel.recordingState, .recording,
            "an AVFoundation-initiated stop must not leave the app stuck on Recording"
        )

        await waitUntil("the session to finish analysing") {
            viewModel.recordingState == .completed
        }
        XCTAssertNotNil(viewModel.sessionScorecard, "the set must still be analysed")
        XCTAssertNotNil(viewModel.sessionTimeline)
        XCTAssertEqual(viewModel.sessionVideoURL, url)
    }

    /// The capture output has already stopped, but telling it again must be harmless — the service
    /// guards on its own state.
    func testSelfStoppedRecordingTellsTheCaptureOutputToStop() async {
        let service = FakeCaptureService()
        let viewModel = makeViewModel(service)

        await viewModel.prepareCamera()
        viewModel.toggleRecording()
        service.simulateLimitReached(url: URL(fileURLWithPath: "/tmp/rox-test-session.mov"))

        XCTAssertGreaterThan(service.stopRecordingCallCount, 0)
    }

    /// The ordinary path must be untouched by the auto-stop branch.
    func testTappingStopStillWorks() async {
        let service = FakeCaptureService()
        let viewModel = makeViewModel(service)

        await viewModel.prepareCamera()
        viewModel.toggleRecording()
        viewModel.toggleRecording()

        XCTAssertEqual(
            viewModel.recordingState, .processing,
            "tapping stop waits for the file before navigating"
        )

        service.simulateLimitReached(url: URL(fileURLWithPath: "/tmp/rox-test-session.mov"))

        await waitUntil("the session to finish analysing") {
            viewModel.recordingState == .completed
        }
        XCTAssertNotNil(viewModel.sessionScorecard)
    }

    func testCapIsFiveMinutes() {
        XCTAssertEqual(AVFoundationCameraCaptureService.maximumRecordingDuration, 300)
    }
}
