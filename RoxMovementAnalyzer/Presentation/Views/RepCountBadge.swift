import SwiftUI

/// Valid-rep readout shown over the camera during a set and over the video on playback.
struct RepCountBadge: View {
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 46, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text("VALID REPS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.snappy, value: count)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) valid reps")
    }
}

#Preview("Rep Count Badge") {
    ZStack {
        Color.black
        RepCountBadge(count: 12)
    }
}
