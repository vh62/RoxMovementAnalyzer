import SwiftUI

struct StationDetailView: View {
    let station: StationScore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StationScoreCard(station: station)

                    detailBlock(title: "Rule Check", text: station.station.ruleSummary)
                    detailBlock(title: "Coach Feedback", text: station.primaryFeedback)

                    if !station.alerts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Alerts", subtitle: "Frame markers will connect here once video analysis is live")

                            ForEach(station.alerts) { alert in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(alert.title)
                                            .font(.headline)
                                            .foregroundStyle(AppTheme.ink)
                                        Spacer()
                                        Text(alert.severity.rawValue)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(alert.severity.color)
                                    }
                                    Text(alert.message)
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.muted)
                                    if let timestampLabel = alert.timestampLabel {
                                        Label(timestampLabel, systemImage: "video.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                    }
                                }
                                .padding(14)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(AppTheme.background)
            .navigationTitle(station.station.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}