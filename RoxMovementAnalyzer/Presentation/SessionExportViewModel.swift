import Foundation
import Photos

/// Drives exporting a session recording with the overlay burned in, and saving it to Photos.
@MainActor
@Observable
final class SessionExportViewModel {
    enum State: Equatable {
        case idle
        case exporting(progress: Double)
        case exported(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var savedToPhotos = false

    private let timeline: SessionTimeline
    private let station: HyroxStation
    private var exportTask: Task<Void, Never>?

    init(timeline: SessionTimeline, station: HyroxStation) {
        self.timeline = timeline
        self.station = station
    }

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    var exportedURL: URL? {
        if case .exported(let url) = state { return url }
        return nil
    }

    func export(sourceURL: URL) {
        guard !isExporting else { return }

        savedToPhotos = false
        state = .exporting(progress: 0)

        let exporter = OverlayVideoExporter(
            timeline: timeline,
            renderer: PoseOverlayRenderer(
                showsDepthGuide: station == .wallBalls,
                requiresFullBody: station == .wallBalls
            )
        )

        exportTask = Task { [weak self] in
            do {
                let url = try await exporter.export(sourceURL: sourceURL) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isExporting else { return }
                        self.state = .exporting(progress: progress)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.state = .exported(url)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
        state = .idle
    }

    /// Copies the exported clip into the user's photo library, requesting add-only access first.
    func saveToPhotos() async {
        guard let url = exportedURL else { return }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state = .failed("Allow photo access in Settings to save the video.")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            savedToPhotos = true
        } catch {
            state = .failed("Could not save to Photos: \(error.localizedDescription)")
        }
    }
}
