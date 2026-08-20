import SwiftUI

/// Running count shown over the camera during a set and over the video on playback.
///
/// The noun is the station's, not this view's: wall balls counts *valid* reps because a rep can fail
/// the depth rule, while rowing counts strokes, every one of which counts.
struct RepCountBadge: View {
    let count: Int
    /// Attempts made, when the station has a rule a movement can fail. Shown as "5/6" so a rep lost
    /// to depth is visible at a glance instead of the count appearing to stall. Nil where every
    /// movement counts, since the ratio would always be 1:1 and say nothing.
    var attempts: Int?
    /// No default on purpose. A default would be one station's word, and the wrong one would then
    /// reach the screen silently rather than failing to compile.
    let noun: String

    private var display: String {
        guard let attempts, attempts > count else { return "\(count)" }
        return "\(count)/\(attempts)"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(display)
                .font(.system(size: 46, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(noun)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.snappy, value: display)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attempts.map { "\(count) of \($0) \(noun.lowercased())" } ?? "\(count) \(noun.lowercased())")
    }
}

#Preview("Rep Count Badge") {
    ZStack {
        Color.black
        RepCountBadge(count: 12, attempts: 14, noun: "VALID REPS")
    }
}
