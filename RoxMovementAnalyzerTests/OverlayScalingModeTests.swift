import XCTest
@testable import RoxMovementAnalyzer

/// Covers how video is fitted into its container, and therefore where the overlay puts landmarks.
///
/// Wall balls is filmed portrait and RowErg landscape, so a single hardcoded fill mode cannot serve
/// both: aspect-filling a landscape clip onto a portrait phone throws away most of the frame width,
/// and with it most of the machine.
final class OverlayScalingModeTests: XCTestCase {

    private let portraitScreen = CGSize(width: 400, height: 860)
    private let portraitSource = 1080.0 / 1920.0
    private let landscapeSource = 1920.0 / 1080.0

    func testPortraitClipOnAPortraitScreenFills() {
        XCTAssertEqual(
            PoseOverlayGeometry.ScalingMode.forSource(aspectRatio: portraitSource, in: portraitScreen),
            .aspectFill,
            "orientations agree, so cropping a sliver off the sides is the right trade"
        )
    }

    func testLandscapeClipOnAPortraitScreenFits() {
        XCTAssertEqual(
            PoseOverlayGeometry.ScalingMode.forSource(aspectRatio: landscapeSource, in: portraitScreen),
            .aspectFit,
            "filling would keep about a quarter of the frame width and lose most of the erg"
        )
    }

    func testFillingALandscapeClipWouldHaveCroppedMostOfTheWidth() {
        let filled = PoseOverlayGeometry.mediaRect(
            in: portraitScreen, sourceAspectRatio: landscapeSource, scalingMode: .aspectFill
        )
        // The visible slice is the intersection with the screen, so compare against the full frame.
        let fullWidth = portraitScreen.height * landscapeSource
        XCTAssertLessThan(
            filled.width / fullWidth, 0.3,
            "this is the behaviour being avoided — quantified so it cannot creep back"
        )
    }

    func testFittingALandscapeClipKeepsTheWholeFrame() {
        let rect = PoseOverlayGeometry.mediaRect(
            in: portraitScreen, sourceAspectRatio: landscapeSource, scalingMode: .aspectFit
        )

        XCTAssertEqual(rect.width, portraitScreen.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, portraitScreen.width / landscapeSource, accuracy: 0.5)
        XCTAssertGreaterThan(rect.minY, 0, "letterboxed above")
        XCTAssertLessThan(rect.maxY, portraitScreen.height, "and below")
    }

    func testLandmarksLandInsideTheVideoRectInBothModes() {
        for (aspect, mode) in [(portraitSource, PoseOverlayGeometry.ScalingMode.aspectFill),
                               (landscapeSource, .aspectFit)] {
            let rect = PoseOverlayGeometry.mediaRect(
                in: portraitScreen, sourceAspectRatio: aspect, scalingMode: mode
            )
            let centre = PoseOverlayGeometry.point(
                forNormalizedX: 0.5, y: 0.5, in: portraitScreen,
                sourceAspectRatio: aspect, scalingMode: mode
            )

            XCTAssertEqual(centre.x, portraitScreen.width / 2, accuracy: 0.5)
            XCTAssertEqual(centre.y, portraitScreen.height / 2, accuracy: 0.5)
            XCTAssertEqual(rect.midX, centre.x, accuracy: 0.5)
        }
    }

    // MARK: - What the skeleton draws

    /// The overlay is a form reference, so every bone drawn must connect joints it also draws.
    func testEveryConnectionJoinsDrawnLandmarks() {
        for (start, end) in PoseOverlayGeometry.connections {
            XCTAssertTrue(
                start.isDrawnInOverlay && end.isDrawnInOverlay,
                "\(start)-\(end) draws a bone to a landmark the overlay hides"
            )
        }
    }

    func testFaceFingersAndFeetAreNotDrawn() {
        let hidden: Set<PoseLandmarkName> = [
            .nose, .leftEyeInner, .leftEye, .leftEyeOuter,
            .rightEyeInner, .rightEye, .rightEyeOuter,
            .leftEar, .rightEar, .mouthLeft, .mouthRight,
            .leftThumb, .rightThumb, .leftIndex, .rightIndex,
            .leftPinky, .rightPinky,
            .leftHeel, .rightHeel, .leftFootIndex, .rightFootIndex
        ]

        for name in PoseLandmarkName.allCases {
            XCTAssertEqual(
                name.isDrawnInOverlay, !hidden.contains(name),
                "\(name) is on the wrong side of the drawn/hidden split"
            )
        }
    }

    /// Every joint a measurement reads must keep drawing — the wrist and ankle especially, since
    /// the fan of landmarks beyond each of them is what was removed.
    func testMeasuredJointsAreStillDrawn() {
        let measured: [PoseLandmarkName] = [
            .leftShoulder, .rightShoulder, .leftHip, .rightHip,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
            .leftElbow, .rightElbow, .leftWrist, .rightWrist
        ]

        XCTAssertTrue(measured.allSatisfy(\.isDrawnInOverlay))
    }

    func testFillModeIsUnchangedFromTheOriginalMapping() {
        // Regression cover: the camera path must map exactly as it did before content modes existed.
        let point = PoseOverlayGeometry.point(
            forNormalizedX: 0.25, y: 0.75, in: portraitScreen,
            sourceAspectRatio: portraitSource, scalingMode: .aspectFill
        )

        // A 9:16 clip is *taller* in proportion than this screen, so filling pins the height and
        // crops the sides — the frame is 483.75pt wide inside a 400pt container.
        let scaledWidth = portraitScreen.height * portraitSource
        XCTAssertEqual(
            point.x,
            (portraitScreen.width - scaledWidth) / 2 + 0.25 * scaledWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(point.y, 0.75 * portraitScreen.height, accuracy: 0.001)
    }
}
