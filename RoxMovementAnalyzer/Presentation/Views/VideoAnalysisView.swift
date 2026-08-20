import AVFoundation
import PhotosUI
import SwiftUI

/// Analyse a clip the athlete already filmed, instead of standing in front of the camera.
///
/// The video runs through the identical pipeline a live set does — MediaPipe, the station's
/// analyzer, the scorecard, the replay overlay and the burned-in export — so an imported session and
/// a recorded one produce the same objects and the same screens. The only difference is where the
/// frames come from.
///
/// `PhotosPicker` runs out of process, so choosing a video needs no photo-library permission; the
/// app's add-only usage description, which exists for saving the export, is untouched.
struct VideoAnalysisView: View {
    @State private var station: HyroxStation
    @State private var selection: PhotosPickerItem?
    @State private var loadedURL: URL?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isAnalysing = false

    init(station: HyroxStation = .wallBalls) {
        self._station = State(initialValue: station)
    }

    var body: some View {
        Form {
            Section {
                Picker("Movement", selection: $station) {
                    ForEach(HyroxStation.allCases) { station in
                        Text(station.rawValue).tag(station)
                    }
                }
            } header: {
                Text("Movement")
            } footer: {
                Text(station.hasMovementAnalysis
                     ? station.ruleSummary
                     : "There is no movement analysis for \(station.rawValue) yet. The clip will "
                        + "still play back with the skeleton drawn, and the scorecard will report "
                        + "tracking coverage rather than technique.")
            }

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
                Text("Video")
            } footer: {
                Text(footerText)
            }

            if loadedURL != nil {
                Section {
                    Button("Analyse \(station.rawValue)") { isAnalysing = true }
                        .font(.headline)
                } footer: {
                    Text("The clip runs start to finish on its own, then lands on the replay with "
                         + "the overlay and the scorecard.")
                }
            }
        }
        .navigationTitle("Analyse a Video")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isAnalysing) {
            if let loadedURL {
                LiveAnalysisView(
                    viewModel: LiveAnalysisViewModel(
                        selectedStation: station,
                        cameraService: VideoFileCaptureService(url: loadedURL),
                        // A `.video`-mode estimator, which is synchronous and drops nothing.
                        // The shared live-stream one skips frames it cannot keep up with —
                        // right for a camera, wrong for a file where every frame is still
                        // there to be read.
                        poseEstimator: SharedPoseEstimator.makeVideoEstimator()
                    )
                )
            }
        }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
        .onChange(of: isAnalysing) { _, analysing in
            // Coming back from a finished analysis: forget the clip so the screen is ready for the
            // next one. Leaving it selected re-ran the same video every time the athlete stepped
            // back, which reads as the app being stuck rather than as a choice.
            guard !analysing else { return }
            selection = nil
            loadedURL = nil
            loadError = nil
        }
    }

    private var footerText: String {
        guard station.hasMovementAnalysis else {
            return "Film the whole athlete, and keep the camera still."
        }

        switch station {
        case .rowing:
            return "Film side-on to the erg, with the athlete in profile and the hips, knees and "
                + "ankles in frame for the whole stroke. Handle and layback measurements need that view."
        case .skiErg:
            return "Film side-on to the machine, with the whole athlete in profile and room above "
                + "their hands at full reach. The hinge and handle measurements need that view."
        case .burpeeBroadJumps:
            return "Film side-on, square to the direction of travel, with the hands and feet in "
                + "frame on the floor. Expect three or four reps before the athlete jumps out of "
                + "shot — this is a technique check on a few reps, not a count of the full 80 m."
        default:
            return "Film side-on, with the whole athlete in frame including the hands at the top of "
                + "the throw. Only the first few minutes of a long clip are analysed."
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
            loadedURL = movie.url
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// The temporary copies made when a video is imported.
///
/// They are not deleted when the athlete leaves the screen: the overlay export reads from the same
/// URL and outlives that screen deliberately, so removing the file on the way out would cut the
/// export off mid-job. They are cleaned up at launch instead, once nothing can still be reading them.
enum ImportedVideoStore {
    static let filePrefix = "rox-imported-"
    /// Long enough to survive an export finishing in the background, short enough that a picked
    /// video does not sit in temporary storage for days.
    private static let retention: TimeInterval = 60 * 60 * 6

    static func makeDestination(pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)\(UUID().uuidString)")
            .appendingPathExtension(pathExtension.isEmpty ? "mov" : pathExtension)
    }

    static func pruneStaleImports(now: Date = Date()) {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents where url.lastPathComponent.hasPrefix(filePrefix) {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }

            if now.timeIntervalSince(modified) > retention {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

/// Copies a picked video into the temporary directory so `AVAssetReader` has a file to open.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = ImportedVideoStore.makeDestination(
                pathExtension: received.file.pathExtension
            )

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

#Preview("Analyse a Video") {
    NavigationStack {
        VideoAnalysisView(station: .rowing)
    }
    .environment(SessionExportService())
}
