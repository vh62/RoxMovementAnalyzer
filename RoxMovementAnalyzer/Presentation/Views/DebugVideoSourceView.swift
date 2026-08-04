#if DEBUG
import AVFoundation
import PhotosUI
import SwiftUI

/// Debug entry point: run a video from the photo library through the analysis pipeline instead of
/// the live camera.
///
/// Exists so thresholds can be calibrated against the same footage repeatedly — the alternative is
/// performing an identical set for every tweak. Never ships: the whole file is `#if DEBUG`.
///
/// `PhotosPicker` runs out of process, so picking a video needs no photo-library permission; the
/// app's add-only usage description is untouched.
struct DebugVideoSourceView: View {
    let station: HyroxStation

    @State private var selection: PhotosPickerItem?
    @State private var loadedURL: URL?
    @State private var pacing: VideoFileCaptureService.Pacing = .realTime
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Form {
            Section {
                PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                    Label(
                        loadedURL == nil ? "Choose a video" : "Choose a different video",
                        systemImage: "film"
                    )
                }

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Copying video…").foregroundStyle(.secondary)
                    }
                }

                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Source")
            } footer: {
                Text("Runs the clip through MediaPipe and the full analysis pipeline exactly as the "
                     + "live camera would. Capture settings — portrait rotation and front-camera "
                     + "mirroring — are not exercised here.")
            }

            Section("Speed") {
                Picker("Pacing", selection: $pacing) {
                    Text("Real time").tag(VideoFileCaptureService.Pacing.realTime)
                    Text("As fast as possible").tag(VideoFileCaptureService.Pacing.fast)
                }
                .pickerStyle(.segmented)
            }

            if let loadedURL {
                Section {
                    NavigationLink("Analyse \(station.rawValue)") {
                        LiveAnalysisView(
                            viewModel: LiveAnalysisViewModel(
                                selectedStation: station,
                                cameraService: VideoFileCaptureService(url: loadedURL, pacing: pacing)
                            )
                        )
                    }
                    .font(.headline)
                } footer: {
                    Text("The clip plays start to finish on its own, then lands on the scorecard.")
                }
            }
        }
        .navigationTitle("Video Source")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    /// `PhotosPickerItem` hands back data, not a URL, so it is copied to a temp file the asset
    /// reader can open.
    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                loadError = "That item could not be read as a video."
                return
            }

            removeTemporaryPickedVideo(at: loadedURL)
            loadedURL = movie.url
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func removeTemporaryPickedVideo(at url: URL?) {
        guard let url,
              url.deletingLastPathComponent() == FileManager.default.temporaryDirectory,
              url.lastPathComponent.hasPrefix(PickedMovie.temporaryFilePrefix) else { return }

        try? FileManager.default.removeItem(at: url)
    }
}

/// Copies a picked video into the temporary directory so `AVAssetReader` has a file to open.
private struct PickedMovie: Transferable {
    static let temporaryFilePrefix = "rox-debug-source-"

    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}
#endif
