import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Metal
import os

/// Writes a copy of a recorded session with the pose overlay burned into the pixels, so the clip
/// can be saved to Photos or shared and still show the skeleton, depth line and rep count.
///
/// Uses `AVAssetReader`/`AVAssetWriter` rather than an `AVVideoComposition`: the overlay changes
/// arbitrarily every frame (ruling out the CAAnimation-based `AVVideoCompositionCoreAnimationTool`)
/// and the recording is video-only, so there is no audio track to mux.
/// Ensures a one-shot completion runs exactly once, across the writer's repeated callbacks.
private final class CompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false

    func finish(_ body: () -> Void) {
        lock.lock()
        let alreadyFinished = hasFinished
        hasFinished = true
        lock.unlock()

        guard !alreadyFinished else { return }
        body()
    }
}

struct OverlayVideoExporter {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case cannotCreateContext
        case readerFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "That recording has no video to export."
            case .cannotCreateContext: "Could not prepare the video for drawing."
            case .readerFailed(let reason): "Could not read the recording: \(reason)"
            case .writerFailed(let reason): "Could not write the export: \(reason)"
            }
        }
    }

    private static let log = Logger(subsystem: "rox.video", category: "OverlayVideoExporter")

    /// Longest edge of the exported video. Capping here is the single biggest lever on export
    /// time — a 4K source is nine times the pixels of 720p, on every frame — and 720p is ample
    /// for reviewing and sharing technique. Sources already at or below this are left alone.
    static let maximumOutputEdge: CGFloat = 1280

    /// Bitrate suited to 720p H.264. Without an explicit value AVFoundation picks a high default,
    /// which makes files needlessly large and gives the encoder more work.
    static let targetBitrate = 6_000_000

    let timeline: SessionTimeline
    let renderer: PoseOverlayRenderer

    /// Renders `sourceURL` with the overlay burned in.
    ///
    /// - Parameter progress: called with 0...1 as frames are written; invoked off the main actor.
    /// - Returns: the URL of the exported movie in the app's Documents directory.
    func export(
        sourceURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // The upright size once the track's rotation is applied.
        let uprightSize = CGSize(
            width: abs(naturalSize.applying(transform).width),
            height: abs(naturalSize.applying(transform).height)
        )
        let renderSize = Self.outputSize(for: uprightSize)
        // Core Image applies the rotation via the orientation; the exporter only has to scale.
        let orientation = Self.orientation(for: transform)
        let duration = try await asset.load(.duration).seconds

        // The transform is included because it is what decides the exported orientation: a
        // portrait recording is landscape pixels plus a quarter turn, and an identity transform
        // on landscape pixels means the recording itself is landscape.
        Self.log.info("""
            exporting \(Int(naturalSize.width), privacy: .public)x\
            \(Int(naturalSize.height), privacy: .public) \
            -> \(Int(renderSize.width), privacy: .public)x\
            \(Int(renderSize.height), privacy: .public), \
            \(duration, privacy: .public)s, \
            transform [\(transform.a, privacy: .public) \(transform.b, privacy: .public) \
            \(transform.c, privacy: .public) \(transform.d, privacy: .public)] \
            -> \(String(describing: orientation), privacy: .public)
            """)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw ExportError.readerFailed("output rejected")
        }
        reader.add(readerOutput)

        let outputURL = Self.makeOutputURL()
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.targetBitrate,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
                // A Metal-backed CIContext can only render into IOSurface-backed buffers, and the
                // pool does not provide them unless asked.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw ExportError.writerFailed("input rejected")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        try await writeFrames(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            adaptor: adaptor,
            renderSize: renderSize,
            orientation: orientation,
            duration: duration,
            progress: progress
        )

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        if reader.status == .failed {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        Self.log.info("exported overlay video to \(outputURL.lastPathComponent, privacy: .public)")
        return outputURL
    }

    // MARK: - Frame loop

    private func writeFrames(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        renderSize: CGSize,
        orientation: CGImagePropertyOrientation,
        duration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let queue = DispatchQueue(label: "rox.video.export")
        // One context for the whole export — building a CIContext is expensive, and per frame it
        // would cost more than the CPU path this replaces.
        let ciContext = Self.makeCIContext()
        // requestMediaDataWhenReady can call back more than once; guard so the continuation is
        // only ever resumed a single time (resuming twice traps).
        let completion = CompletionGuard()
        var lastReportedPercent = -1

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        completion.finish { continuation.resume() }
                        return
                    }

                    let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                    guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
                          let pool = adaptor.pixelBufferPool else { continue }

                    var renderedBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &renderedBuffer)
                    guard let renderedBuffer else { continue }

                    do {
                        try compose(
                            source: sourceBuffer,
                            into: renderedBuffer,
                            at: time.seconds,
                            renderSize: renderSize,
                            orientation: orientation,
                            ciContext: ciContext,
                            colorSpace: colorSpace
                        )
                    } catch {
                        writerInput.markAsFinished()
                        completion.finish { continuation.resume(throwing: error) }
                        return
                    }

                    // A false result means the writer has already failed. Continuing to append
                    // would run the whole clip and then surface a generic error with no cause.
                    guard adaptor.append(renderedBuffer, withPresentationTime: time) else {
                        let reason = writer.error?.localizedDescription ?? "pixel buffer rejected"
                        Self.log.error(
                            "append failed at \(time.seconds, privacy: .public)s: \(reason, privacy: .public)"
                        )
                        writerInput.markAsFinished()
                        completion.finish {
                            continuation.resume(throwing: ExportError.writerFailed(reason))
                        }
                        return
                    }

                    // Only report when the whole percentage changes: at 30 fps the old per-frame
                    // callback meant ~1800 main-actor hops per minute of video.
                    if duration > 0 {
                        let fraction = min(time.seconds / duration, 1)
                        let percent = Int(fraction * 100)
                        if percent != lastReportedPercent {
                            lastReportedPercent = percent
                            progress?(fraction)
                        }
                    }
                }
            }
        }
    }

    /// Draws one source frame plus its overlay into the destination pixel buffer.
    ///
    /// The frame itself is rotated, scaled and written by Core Image on the GPU. Only the overlay
    /// — vector strokes and text — is drawn on the CPU afterwards, which is a fraction of the
    /// work of copying a full-resolution image per frame.
    private func compose(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        at seconds: Double,
        renderSize: CGSize,
        orientation: CGImagePropertyOrientation,
        ciContext: CIContext,
        colorSpace: CGColorSpace
    ) throws {
        // `oriented` turns the frame upright in Core Image's own coordinate space; scaling then
        // only has to fit it to the output size.
        let upright = CIImage(cvPixelBuffer: source).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let frameImage = upright.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(
                    CGAffineTransform(
                        scaleX: renderSize.width / extent.width,
                        y: renderSize.height / extent.height
                    )
                )
        )
        // Synchronous, so the overlay draw below safely lands on top of the rendered frame.
        ciContext.render(
            frameImage,
            to: destination,
            bounds: CGRect(origin: .zero, size: renderSize),
            colorSpace: colorSpace
        )

        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard let destinationBase = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(
                data: destinationBase,
                width: CVPixelBufferGetWidth(destination),
                height: CVPixelBufferGetHeight(destination),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw ExportError.cannotCreateContext
        }

        guard let entry = timeline.entry(at: seconds) else { return }

        // Flip into top-left origin coordinates so the overlay's normalized y-down maths lines
        // up with the image.
        context.saveGState()
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)

        renderer.draw(
            PoseOverlayRenderer.Frame(
                pose: entry.frame,
                count: entry.count,
                attempts: entry.attempts,
                justCountedRep: entry.isCelebratingRep(at: seconds),
                fault: timeline.activeFault(at: seconds),
                powerTrail: timeline.powerTrail(at: seconds)
            ),
            in: context,
            size: renderSize
        )

        context.restoreGState()
    }

    /// Output size with the long edge capped, preserving aspect ratio. Never upscales — a source
    /// already at or below the cap is passed through untouched.
    static func outputSize(for uprightSize: CGSize) -> CGSize {
        let longestEdge = max(uprightSize.width, uprightSize.height)
        guard longestEdge > 0 else { return uprightSize }

        // Applied even when no downscale is needed: H.264 rejects odd dimensions, and rotating a
        // track can yield an odd upright size.
        guard longestEdge > maximumOutputEdge else {
            return CGSize(width: uprightSize.width.evenized, height: uprightSize.height.evenized)
        }

        let scale = maximumOutputEdge / longestEdge
        return CGSize(
            width: (uprightSize.width * scale).rounded().evenized,
            height: (uprightSize.height * scale).rounded().evenized
        )
    }

    /// The image orientation matching a video track's `preferredTransform`.
    ///
    /// The transform must not be applied to a `CIImage` directly: it is expressed in a top-left
    /// origin space while Core Image works bottom-left, so applying it verbatim mirrors the
    /// rotation — a portrait clip comes out upside down. Converting to an orientation and using
    /// `CIImage.oriented(_:)` lets Core Image reconcile the two coordinate spaces itself.
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        // Matched with a tolerance rather than exactly: AVFoundation's own transforms hold exact
        // integers, but anything derived from an angle carries float error (a quarter turn gives
        // a = 6e-17, not 0), and an exact match would silently fall back to upright and misorient
        // the export. Only a/b/c/d matter — real transforms also carry a translation.
        func matches(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> Bool {
            let tolerance: CGFloat = 0.001
            return abs(transform.a - a) < tolerance
                && abs(transform.b - b) < tolerance
                && abs(transform.c - c) < tolerance
                && abs(transform.d - d) < tolerance
        }

        if matches(0, 1, -1, 0) { return .right }   // 90° clockwise — portrait
        if matches(0, -1, 1, 0) { return .left }    // 90° anticlockwise — portrait the other way
        if matches(-1, 0, 0, -1) { return .down }   // 180°
        return .up                                  // identity, or unrecognised
    }

    /// Metal-backed where possible so frame scaling runs on the GPU, falling back to the default
    /// context rather than failing the export outright.
    private static func makeCIContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpaceCreateDeviceRGB()
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }

        log.notice("no Metal device; falling back to a CPU Core Image context")
        return CIContext(options: options)
    }

    /// Exports land in Documents — `temporaryDirectory` can be purged out from under the user.
    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "rox-session-\(formatter.string(from: Date())).mov"

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(name)
    }
}

private extension CGFloat {
    /// Rounded down to an even number — H.264 encoders expect even dimensions.
    var evenized: CGFloat {
        let value = Int(self)
        return CGFloat(value - (value % 2))
    }
}
