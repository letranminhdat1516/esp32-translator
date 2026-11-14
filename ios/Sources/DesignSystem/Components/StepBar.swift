import SwiftUI

/// Pure state of the onboarding step bar.
struct StepProgress: Hashable, Sendable {
    let step: Int
    let total: Int

    init(step: Int, total: Int = 3) {
        self.total = max(total, 1)
        self.step = min(max(step, 1), self.total)
    }

    /// Filled segments: every step up to and including the current one.
    func isFilled(_ index: Int) -> Bool { index < step }
}

/// "Bước n/3" on the left, three 28×6 segments on the right (filled ink / 1 pt outline).
struct StepBar: View {
    let progress: StepProgress
    /// The left label, e.g. "Bước 1/3".
    let label: String

    var body: some View {
        HStack {
            Text(label).ds(.label)
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<progress.total, id: \.self) { i in
                    Rectangle()
                        .fill(progress.isFilled(i) ? DS.Color.ink : .clear)
                        .overlay(Rectangle().strokeBorder(DS.Color.ink, lineWidth: 1))
                        .frame(width: DS.Size.stepWidth, height: DS.Size.stepHeight)
                }
            }
            .accessibilityHidden(true)
        }
        .foregroundStyle(DS.Color.ink)
        .accessibilityElement(children: .combine)
    }
}
