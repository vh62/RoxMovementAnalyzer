import SwiftUI

struct OverallTechniqueHeader: View {
    let scorecard: WorkoutScorecard
    let summary: ScorecardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.ink.opacity(0.08), lineWidth: 14)

                    Circle()
                        .trim(from: 0, to: CGFloat(summary.overallScore) / 100)
                        .stroke(summary.rating.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(summary.overallScore)")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.ink)
                        Text("/100")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppTheme.muted)
                    }
                }
                .frame(width: 118, height: 118)
                .accessibilityLabel("Overall technique score \(summary.overallScore) out of 100")

                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.rating.rawValue)
                        .font(.title.weight(.black))
                        .foregroundStyle(AppTheme.ink)

                    Text(summary.rating.summary)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        SummaryPill(label: "Stations", value: "\(scorecard.stations.count)")
                        SummaryPill(label: "Alerts", value: "\(summary.criticalAlerts.count)")
                    }
                }
            }

            Text("Post-workout analysis for \(scorecard.athleteName) using movement rules for depth, alignment, sequence, cadence, and load dominance.")
                .font(.footnote)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [.white, Color(red: 0.94, green: 0.98, blue: 0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }
}

struct RedFlagStrip: View {
    let alerts: [RedFlagAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Red-Flag Alerts", subtitle: "Review these clips first")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(alerts) { alert in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(alert.severity.color)
                                Text(alert.severity.rawValue)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(alert.severity.color)
                            }

                            Text(alert.title)
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(2)

                            Text(alert.station.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.muted)

                            if let timestampLabel = alert.timestampLabel {
                                Label(timestampLabel, systemImage: "video.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                            }
                        }
                        .padding(14)
                        .frame(width: 210, alignment: .leading)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(alert.severity.color.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct StationScoreCard: View {
    let station: StationScore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: station.station.symbolName)
                    .font(.title3)
                    .foregroundStyle(station.status.color)
                    .frame(width: 34, height: 34)
                    .background(station.status.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(station.station.rawValue)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)

                    Text(station.primaryFeedback)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(station.score)")
                        .font(.title3.weight(.black))
                        .foregroundStyle(station.status.color)
                    Label(station.status.rawValue, systemImage: station.status.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(station.status.color)
                        .labelStyle(.titleAndIcon)
                }
            }

            FlowLayout(spacing: 8) {
                ForEach(station.metrics) { metric in
                    MetricChip(metric: metric)
                }
            }

            if !station.alerts.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.red)
                    Text("\(station.alerts.count) alert\(station.alerts.count == 1 ? "" : "s") detected")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
    }
}

struct MetricChip: View {
    let metric: MetricResult

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(metric.status.color)
                .frame(width: 7, height: 7)
            Text(metric.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
            Text(metric.value)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(metric.status.color.opacity(0.1))
        .clipShape(Capsule())
    }
}

struct SummaryPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(AppTheme.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
    }
}