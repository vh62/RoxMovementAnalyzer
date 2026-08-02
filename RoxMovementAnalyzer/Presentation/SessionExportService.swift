import Foundation
import Photos
import UIKit

/// Exports finished sessions with the overlay burned in and saves them to the photo library.
///
/// App-scoped rather than owned by a view: the export outlives the screen that started it, so the
/// athlete can review their scorecard, replay the set, or walk away while it runs.
///
/// "Background" here means off the main thread and surviving navigation *within* the app. iOS
/// suspends backgrounded apps, so a job that is still running when the app leaves the foreground
/// only gets the short grace period `beginBackgroundTask` provides — it is reported as unfinished
/// rather than silently dropped.
@MainActor
@Observable
final class SessionExportService {
    enum Job: Equatable {
        case idle
        case exporting(progress: Double)
        case savingToPhotos
        case saved(URL)
        /// Exported but not in the library — usually because photo access was declined. The file is
        /// kept so it can still be shared.
        case exportedNotSaved(url: URL, reason: String)
        case failed(String)
    }

    private(set) var job: Job = .idle

    /// Whether finished sessions are copied into the photo library automatically.
    var autoSaveToPhotos: Bool {
        didSet { UserDefaults.standard.set(autoSaveToPhotos, forKey: Self.autoSaveKey) }
    }

    private static let autoSaveKey = "rox.autoSaveToPhotos"
    /// Once the user declines photo access we stop asking on later sets.
    private var photoAccessDeclined = false
    private var exportTask: Task<Void, Never>?
    private var pending: [Request] = []

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.autoSaveKey) == nil {
            defaults.set(true, forKey: Self.autoSaveKey)
        }
        self.autoSaveToPhotos = defaults.bool(forKey: Self.autoSaveKey)
    }

    // MARK: - Derived state

    var isBusy: Bool {
        switch job {
        case .exporting, .savingToPhotos: true
        case .idle, .saved, .exportedNotSaved, .failed: false
        }
    }

    /// The exported file, once one exists, whether or not it reached the library.
    var exportedURL: URL? {
        switch job {
        case .saved(let url), .exportedNotSaved(let url, _): url
        case .idle, .exporting, .savingToPhotos, .failed: nil
        }
    }

    /// Short status for the chip shown on playback and the scorecard.
    var statusText: String? {
        switch job {
        case .idle: nil
        case .exporting(let progress): "Saving video… \(Int(progress * 100))%"
        case .savingToPhotos: "Adding to Photos…"
        case .saved: "Saved to Photos"
        case .exportedNotSaved(_, let reason): reason
        case .failed(let message): message
        }
    }

    // MARK: - Running jobs

    struct Request: Equatable {
        let sourceURL: URL
        let timeline: SessionTimeline
        let station: HyroxStation
    }

    /// Queues a finished session for export. Jobs run one at a time — two concurrent exports would
    /// compete for the same CPU and finish later than running them in order.
    func start(sourceURL: URL, timeline: SessionTimeline, station: HyroxStation) {
        let request = Request(sourceURL: sourceURL, timeline: timeline, station: station)

        guard !isBusy else {
            pending.append(request)
            return
        }

        run(request)
    }

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
        pending.removeAll()
        job = .idle
    }

    /// Manual save for the case where auto-save is off, or access was declined and later granted.
    func saveExportedToPhotos() async {
        guard let url = exportedURL else { return }
        photoAccessDeclined = false
        await saveToPhotos(url)
    }

    private func run(_ request: Request) {
        job = .exporting(progress: 0)

        let exporter = OverlayVideoExporter(
            timeline: request.timeline,
            renderer: PoseOverlayRenderer(
                showsDepthGuide: request.station == .wallBalls,
                requiresFullBody: request.station == .wallBalls
            )
        )

        // Inherits the main actor, but the frame-by-frame work happens on the exporter's own
        // queue, so awaiting here does not block the UI.
        exportTask = Task { [weak self] in
            // Buys a grace period if the athlete backgrounds the app mid-export.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "rox.session-export"
            )
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }

            do {
                let url = try await exporter.export(sourceURL: request.sourceURL) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .exporting = self.job else { return }
                        self.job = .exporting(progress: progress)
                    }
                }

                guard !Task.isCancelled else { return }
                await self?.finishExport(at: url)
            } catch {
                guard !Task.isCancelled else { return }
                self?.job = .failed(error.localizedDescription)
                self?.startNextIfNeeded()
            }
        }
    }

    private func finishExport(at url: URL) async {
        guard autoSaveToPhotos, !photoAccessDeclined else {
            job = .exportedNotSaved(url: url, reason: "Saved to the app — tap to share")
            startNextIfNeeded()
            return
        }

        await saveToPhotos(url)
        startNextIfNeeded()
    }

    private func saveToPhotos(_ url: URL) async {
        job = .savingToPhotos

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            // Declining is a normal outcome, not a failure: keep the file and stop asking.
            photoAccessDeclined = true
            job = .exportedNotSaved(url: url, reason: "Photo access off — tap to share")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            job = .saved(url)
            // The library holds it now, so the working copy is redundant.
            SessionExportStore.removeExport(at: url)
        } catch {
            job = .exportedNotSaved(url: url, reason: "Couldn't add to Photos — tap to share")
        }
    }

    private func startNextIfNeeded() {
        exportTask = nil
        guard !pending.isEmpty else { return }
        run(pending.removeFirst())
    }
}
