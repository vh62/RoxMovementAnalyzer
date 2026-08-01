import AVFoundation
import CoreGraphics
import Foundation
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
        // Honour the track's transform so a rotated recording exports upright.
        let renderSize = CGSize(
            width: abs(naturalSize.applying(transform).width),
            height: abs(naturalSize.applying(transform).height)
        )
        let duration = try await asset.load(.duration).seconds

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
                AVVideoHeightKey: Int(renderSize.height)
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
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
        duration: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let queue = DispatchQueue(label: "rox.video.export")
        // requestMediaDataWhenReady can call back more than once; guard so the continuation is
        // only ever resumed a single time (resuming twice traps).
        let completion = CompletionGuard()

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
                            colorSpace: colorSpace
                        )
                    } catch {
                        writerInput.markAsFinished()
                        completion.finish { continuation.resume(throwing: error) }
                        return
                    }

                    adaptor.append(renderedBuffer, withPresentationTime: time)

                    if duration > 0 {
                        progress?(min(time.seconds / duration, 1))
                    }
                }
            }
        }
    }

    /// Draws one source frame plus its overlay into the destination pixel buffer.
    private func compose(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        at seconds: Double,
        renderSize: CGSize,
        colorSpace: CGColorSpace
    ) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

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

        // Draw the source frame, then flip into top-left origin coordinates so the overlay's
        // normalized y-down maths lines up with the image.
        if let sourceImage = Self.makeImage(from: source, colorSpace: colorSpace) {
            context.draw(sourceImage, in: CGRect(origin: .zero, size: renderSize))
        }

        context.saveGState()
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)

        if let entry = timeline.entry(at: seconds) {
            renderer.draw(
                PoseOverlayRenderer.Frame(
                    pose: entry.frame,
                    validReps: entry.validReps,
                    justCountedRep: entry.isCelebratingRep(at: seconds)
                ),
                in: context,
                size: renderSize
            )
        }

        context.restoreGState()
    }

    private static func makeImage(from buffer: CVPixelBuffer, colorSpace: CGColorSpace) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        return CGContext(
            data: base,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )?.makeImage()
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
