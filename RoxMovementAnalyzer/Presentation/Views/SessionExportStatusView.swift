import SwiftUI

/// Non-blocking readout of the session export, shown wherever the athlete lands after a set.
///
/// Deliberately compact: the export runs on its own, so this reports progress rather than asking
/// for anything. It only becomes interactive when there is something the athlete has to decide —
/// a file that never reached the photo library, or a failure worth retrying.
struct SessionExportStatusView: View {
    @Environment(SessionExportService.self) private var exportService

    /// Matches the surrounding surface: the playback screen is dark, the scorecard light.
    var style: Style = .dark

    enum Style {
        case dark
        case light

        var text: Color { self == .dark ? .white : AppTheme.ink }
        var secondaryText: Color { self == .dark ? .white.opacity(0.7) : AppTheme.muted }
        var background: Color { self == .dark ? .white.opacity(0.14) : .white }
    }

    var body: some View {
        if let status = exportService.statusText {
            HStack(spacing: 10) {
                icon
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(iconColor)

                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.text)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if let url = exportService.exportedURL, !isSaved {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(style.text)
                    }
                    .accessibilityLabel("Share session video")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(style.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(status)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch exportService.job {
        case .exporting, .savingToPhotos:
            ProgressView().controlSize(.small).tint(style.text)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
        case .exportedNotSaved:
            Image(systemName: "square.and.arrow.up.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            EmptyView()
        }
    }

    private var iconColor: Color {
        switch exportService.job {
        case .saved: .green
        case .failed: .orange
        case .idle, .exporting, .savingToPhotos, .exportedNotSaved: style.secondaryText
        }
    }

    private var isSaved: Bool {
        if case .saved = exportService.job { return true }
        return false
    }
}

/// Lets the athlete turn off automatic copying to the photo library.
struct AutoSaveToggle: View {
    @Environment(SessionExportService.self) private var exportService

    var body: some View {
        @Bindable var service = exportService

        Toggle(isOn: $service.autoSaveToPhotos) {
            Text("Save sessions to Photos")
                .font(.caption.weight(.semibold))
        }
        .toggleStyle(.switch)
    }
}
