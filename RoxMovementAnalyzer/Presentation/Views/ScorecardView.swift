import SwiftUI

struct ScorecardView: View {
    @State private var viewModel: ScorecardViewModel
    @State private var selectedStation: StationScore?

    init(viewModel: ScorecardViewModel = ScorecardViewModel()) {
        self._viewModel = State(initialValue: viewModel)
    }

    // Deliberately no NavigationStack of its own: this view is always pushed onto an existing
    // stack (from the training hub, or from session playback), and nesting one here would render
    // a second navigation bar inside the pushed screen.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                OverallTechniqueHeader(scorecard: viewModel.scorecard, summary: viewModel.summary)

                // The session video is still exporting while this is read; report it here so the
                // athlete does not have to go back to playback to find out where it got to.
                SessionExportStatusView(style: .light)

                if !viewModel.summary.criticalAlerts.isEmpty {
                    RedFlagStrip(alerts: Array(viewModel.summary.criticalAlerts.prefix(5)))
                }

                stationSection
                recommendationSection
                videoSettingsSection
            }
            .padding(20)
        }
        .background(AppTheme.background)
        .navigationTitle("HYROX Scorecard")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedStation) { station in
            StationDetailView(station: station)
                .presentationDetents([.medium, .large])
        }
    }

    private var videoSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Session Video", subtitle: "Where your recordings end up")

            VStack(alignment: .leading, spacing: 6) {
                AutoSaveToggle()
                Text("Your set is saved with the skeleton, depth line and rep count drawn on.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        }
    }

    private var stationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Station Breakdown", subtitle: "Technique, rules, and red flags")

            ForEach(viewModel.scorecard.stations) { station in
                Button {
                    selectedStation = station
                } label: {
                    StationScoreCard(station: station)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Next Training Focus", subtitle: "Three corrections to review first")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(viewModel.summary.topRecommendations.enumerated()), id: \.offset) { index, recommendation in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(AppTheme.ink))

                        Text(recommendation)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        }
    }
}

#Preview("Scorecard") {
    NavigationStack {
        ScorecardView()
    }
    .environment(SessionExportService())
}