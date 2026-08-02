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

    // MARK: - Orientation derivation

    /// `preferredTransform` is expressed in a top-left origin space while Core Image works
    /// bottom-left. Applying it to a CIImage directly mirrors the rotation and the export comes out
    /// upside down, so it is converted to an orientation and handed to `CIImage.oriented(_:)`.
    ///
    /// Note the earlier rect-based transform tests could not have caught that: a vertical flip
    /// leaves the bounding rectangle unchanged.
    func testOrientationMatchesTheTrackTransform() {
        XCTAssertEqual(OverlayVideoExporter.orientation(for: .identity), .up)

        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)),
            .right,
            "portrait, rotated 90 degrees clockwise"
        )
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)),
            .left,
            "portrait the other way"
        )
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)),
            .down,
            "rotated 180 degrees"
        )
    }

    /// The transforms AVFoundation actually produces carry translations; only a/b/c/d decide the
    /// orientation.
    func testOrientationIgnoresTranslation() {
        let withTranslation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        XCTAssertEqual(OverlayVideoExporter.orientation(for: withTranslation), .right)
    }

    func testUnrecognisedTransformFallsBackToUpright() {
        // A scale-only transform is not a rotation; treat it as upright rather than guessing.
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(scaleX: 2, y: 2)),
            .up
        )
    }

    /// A quarter turn built from an angle carries float error — `a` comes out as 6e-17 rather
    /// than 0 — so matching the matrix exactly would silently report "upright" and misorient the
    /// export.
    func testOrientationToleratesFloatingPointError() {
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(rotationAngle: .pi / 2)),
            .right
        )
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(rotationAngle: -.pi / 2)),
            .left
        )
        XCTAssertEqual(
            OverlayVideoExporter.orientation(for: CGAffineTransform(rotationAngle: .pi)),
            .down
        )
    }
}
