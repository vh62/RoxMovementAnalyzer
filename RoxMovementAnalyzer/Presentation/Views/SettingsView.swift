import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettingsKeys.wallBallAudioCuesEnabled) private var audioCuesEnabled = false
    @AppStorage(AppSettingsKeys.skeletonOverlayEnabled) private var skeletonOverlayEnabled = false
    @AppStorage(AppSettingsKeys.angleLabelsEnabled) private var angleLabelsEnabled = false
    @AppStorage(AppSettingsKeys.depthGuideEnabled) private var depthGuideEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Skeleton overlay", isOn: $skeletonOverlayEnabled)
                Toggle("Angle labels", isOn: $angleLabelsEnabled)
                Toggle("Depth guide", isOn: $depthGuideEnabled)

                Text("Keep the workout screen calm by turning on only the overlays you want to see during a set.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Live Overlays")
            }

            Section {
                Toggle("Audio cues", isOn: $audioCuesEnabled)
                Text("When enabled, Wall Balls can speak sparse corrections like “Squat lower” after a shallow missed rep. Valid reps stay visual only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Feedback")
            }

            Section {
                SettingsFeatureRow(title: "Valid rep counter", value: "On")
            } header: {
                Text("Always On")
            }

            #if DEBUG
            Section {
                Text("Debug video, raw tuning readouts, and calibration controls are available only in debug builds and are not part of production settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Developer")
            }
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsFeatureRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
}