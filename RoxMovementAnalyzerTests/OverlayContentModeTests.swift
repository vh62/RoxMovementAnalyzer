import XCTest
@testable import RoxMovementAnalyzer

/// Covers how video is fitted into its container, and therefore where the overlay puts landmarks.
///
/// Wall balls is filmed portrait and RowErg landscape, so a single hardcoded fill mode cannot serve
/// both: aspect-filling a landscape clip onto a portrait phone throws away most of the frame width,
/// and with it most of the machine.
final class OverlayContentModeTests: XCTestCase {

    private let portraitScreen = CGSize(width: 400, height: 860)
    private let portraitSource = 1080.0 / 1920.0
    private let landscapeSource = 1920.0 / 1080.0

    func testPortraitClipOnAPortraitScreenFills() {
        XCTAssertEqual(
            PoseOverlayGeometry.ContentMode.forSource(aspectRatio: portraitSource, in: portraitScreen),
            .fill,
            "orientations agree, so cropping a sliver off the sides is the right trade"
        )
    }

    func testLandscapeClipOnAPortraitScreenFits() {
        XCTAssertEqual(
            PoseOverlayGeometry.ContentMode.forSource(aspectRatio: landscapeSource, in: portraitScreen),
            .fit,
            "filling would keep about a quarter of the frame width and lose most of the erg"
        )
    }

    func testFillingALandscapeClipWouldHaveCroppedMostOfTheWidth() {
        let filled = PoseOverlayGeometry.videoRect(
            in: portraitScreen, sourceAspectRatio: landscapeSource, contentMode: .fill
        )
        // The visible slice is the intersection with the screen, so compare against the full frame.
        let fullWidth = portraitScreen.height * landscapeSource
        XCTAssertLessThan(
            filled.width / fullWidth, 0.3,
            "this is the behaviour being avoided — quantified so it cannot creep back"
        )
    }

    func testFittingALandscapeClipKeepsTheWholeFrame() {
        let rect = PoseOverlayGeometry.videoRect(
            in: portraitScreen, sourceAspectRatio: landscapeSource, contentMode: .fit
        )

        XCTAssertEqual(rect.width, portraitScreen.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, portraitScreen.width / landscapeSource, accuracy: 0.5)
        XCTAssertGreaterThan(rect.minY, 0, "letterboxed above")
        XCTAssertLessThan(rect.maxY, portraitScreen.height, "and below")
    }

    func testLandmarksLandInsideTheVideoRectInBothModes() {
        for (aspect, mode) in [(portraitSource, PoseOverlayGeometry.ContentMode.fill),
                               (landscapeSource, .fit)] {
            let rect = PoseOverlayGeometry.videoRect(
                in: portraitScreen, sourceAspectRatio: aspect, contentMode: mode
            )
            let centre = PoseOverlayGeometry.point(
                forNormalizedX: 0.5, y: 0.5, in: portraitScreen,
                sourceAspectRatio: aspect, contentMode: mode
            )

            XCTAssertEqual(centre.x, portraitScreen.width / 2, accuracy: 0.5)
            XCTAssertEqual(centre.y, portraitScreen.height / 2, accuracy: 0.5)
            XCTAssertEqual(rect.midX, centre.x, accuracy: 0.5)
        }
    }

    func testFillModeIsUnchangedFromTheOriginalMapping() {
        // Regression cover: the camera path must map exactly as it did before content modes existed.
        let point = PoseOverlayGeometry.point(
            forNormalizedX: 0.25, y: 0.75, in: portraitScreen,
            sourceAspectRatio: portraitSource, contentMode: .fill
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
