import SwiftUI

struct TrainingHubView: View {
    @State private var selectedStation: HyroxStation = .wallBalls

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    liveAnalysisCard
                    movementSelector
                    recentReviewCard
                    #if DEBUG
                    debugVideoSourceCard
                    #endif
                }
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle("ROX Coach")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    #if DEBUG
    /// Development only — analyse an existing video instead of standing in front of the camera.
    private var debugVideoSourceCard: some View {
        NavigationLink {
            DebugVideoSourceView(station: selectedStation)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ladybug.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AppTheme.muted)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Analyse a video (debug)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Run a saved clip through the pipeline")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()
            }
            .padding(14)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
    #endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live technique feedback")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(AppTheme.ink)

            Text("Record a station, get one clear coaching cue during the set, then review the scorecard when you stop.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveAnalysisCard: some View {
        NavigationLink {
            LiveAnalysisView(viewModel: LiveAnalysisViewModel(selectedStation: selectedStation))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "camera.viewfinder")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Start Live Analysis")
                        .font(.headline.weight(.black))
                        .foregroundStyle(AppTheme.ink)
                    Text(selectedStation.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(16)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var movementSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Movement", subtitle: "Choose the rule set before recording")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                ForEach(HyroxStation.allCases) { station in
                    Button {
                        selectedStation = station
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: station.symbolName)
                                .foregroundStyle(selectedStation == station ? .white : AppTheme.ink)
                                .frame(width: 28, height: 28)

                            Text(station.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(selectedStation == station ? .white : AppTheme.ink)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .frame(minHeight: 58)
                        .background(selectedStation == station ? AppTheme.ink : .white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(station.rawValue)")
                }
            }
        }
    }

    private var recentReviewCard: some View {
        NavigationLink {
            ScorecardView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.teal)
                    .frame(width: 42, height: 42)
                    .background(.teal.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Review sample scorecard")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text("Post-session scores, red flags, and training focus")
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()
            }
            .padding(14)
            .background(.white.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

#Preview("Training Hub") {
    TrainingHubView()
        .environment(SessionExportService())
}