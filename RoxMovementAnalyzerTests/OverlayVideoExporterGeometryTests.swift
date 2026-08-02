import XCTest
@testable import RoxMovementAnalyzer

/// Covers the sizing and transform maths behind the overlay export.
///
/// The size cap is what makes exporting fast — a 4K source is nine times the pixels of 720p on
/// every frame. The transform is regression cover for a bug where the track's rotation was used
/// to compute the output size but never applied when drawing, so a rotated source was stretched
/// into the rotated dimensions instead of turned.
final class OverlayVideoExporterGeometryTests: XCTestCase {

    // MARK: - Output size

    func testFourKIsCappedToSevenTwentyKeepingAspect() {
        let size = OverlayVideoExporter.outputSize(for: CGSize(width: 3840, height: 2160))

        XCTAssertEqual(max(size.width, size.height), OverlayVideoExporter.maximumOutputEdge)
        XCTAssertEqual(size.width / size.height, 3840.0 / 2160.0, accuracy: 0.01)
    }

    func testPortraitIsCappedOnItsLongEdge() {
        let size = OverlayVideoExporter.outputSize(for: CGSize(width: 1080, height: 1920))

        XCTAssertEqual(size.height, OverlayVideoExporter.maximumOutputEdge)
        XCTAssertLessThan(size.width, size.height)
    }

    func testSmallerSourcesAreNotUpscaled() {
        let size = CGSize(width: 640, height: 480)
        XCTAssertEqual(OverlayVideoExporter.outputSize(for: size), size)
    }

    func testSourceAtTheCapPassesThrough() {
        let size = CGSize(width: 1280, height: 720)
        XCTAssertEqual(OverlayVideoExporter.outputSize(for: size), size)
    }

    /// H.264 encoders expect even dimensions.
    func testDimensionsAreAlwaysEven() {
        for source in [CGSize(width: 3840, height: 2160),
                       CGSize(width: 1080, height: 1920),
                       CGSize(width: 1442, height: 1081)] {
            let size = OverlayVideoExporter.outputSize(for: source)
            XCTAssertEqual(Int(size.width) % 2, 0, "width odd for \(source)")
            XCTAssertEqual(Int(size.height) % 2, 0, "height odd for \(source)")
        }
    }

    // MARK: - Orientation

    /// The exported size for a recording, as the exporter derives it.
    private func exportedSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        return OverlayVideoExporter.outputSize(
            for: CGSize(width: abs(upright.width), height: abs(upright.height))
        )
    }

    /// Filming in portrait still produces *landscape* sensor frames plus a quarter turn, so
    /// portrait output depends entirely on the track transform being honoured.
    func testPortraitRecordingExportsPortrait() {
        for angle in [CGFloat.pi / 2, -.pi / 2] {
            let size = exportedSize(
                natural: CGSize(width: 1920, height: 1080),
                transform: CGAffineTransform(rotationAngle: angle)
            )
            XCTAssertGreaterThan(size.height, size.width, "portrait became landscape at \(angle)")
        }
    }

    func testLandscapeRecordingExportsLandscape() {
        let size = exportedSize(natural: CGSize(width: 1920, height: 1080), transform: .identity)
        XCTAssertGreaterThan(size.width, size.height)
    }

    func testOrientationSurvivesTheDownscale() {
        let landscape = exportedSize(natural: CGSize(width: 3840, height: 2160), transform: .identity)
        XCTAssertGreaterThan(landscape.width, landscape.height, "4K landscape flipped")

        let portrait = exportedSize(
            natural: CGSize(width: 3840, height: 2160),
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        XCTAssertGreaterThan(portrait.height, portrait.width, "4K portrait flipped")

        XCTAssertEqual(portrait.width / portrait.height, 2160.0 / 3840.0, accuracy: 0.02)
        XCTAssertEqual(landscape.width / landscape.height, 3840.0 / 2160.0, accuracy: 0.02)
    }

    // MARK: - Render transform

    func testRotatedSourceFillsTheOutputUpright() {
        // A portrait recording: landscape sensor frames carrying a quarter-turn.
        let natural = CGSize(width: 1920, height: 1080)
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        let upright = CGSize(
            width: abs(natural.applying(rotation).width),
            height: abs(natural.applying(rotation).height)
        )
        let output = OverlayVideoExporter.outputSize(for: upright)

        let transform = OverlayVideoExporter.renderTransform(
            naturalSize: natural, transform: rotation, outputSize: output
        )
        let mapped = CGRect(origin: .zero, size: natural).applying(transform)

        XCTAssertEqual(mapped.minX, 0, accuracy: 0.5, "rotation must not push the frame off-origin")
        XCTAssertEqual(mapped.minY, 0, accuracy: 0.5)
        XCTAssertEqual(mapped.width, output.width, accuracy: 1, "must fill, not stretch or letterbox")
        XCTAssertEqual(mapped.height, output.height, accuracy: 1)
    }

    func testUprightSourceIsScaledWithoutBeingMoved() {
        let natural = CGSize(width: 1920, height: 1080)
        let output = OverlayVideoExporter.outputSize(for: natural)

        let transform = OverlayVideoExporter.renderTransform(
            naturalSize: natural, transform: .identity, outputSize: output
        )
        let mapped = CGRect(origin: .zero, size: natural).applying(transform)

        XCTAssertEqual(mapped.minX, 0, accuracy: 0.5)
        XCTAssertEqual(mapped.minY, 0, accuracy: 0.5)
        XCTAssertEqual(mapped.width, output.width, accuracy: 1)
        XCTAssertEqual(mapped.height, output.height, accuracy: 1)
    }
}
