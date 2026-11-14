import SwiftUI

/// The square switch: 52×28 radius 6; on = ink track with a #4C8FE8 knob on the right, off = ink outline with an
/// ink knob on the left.
struct InstrumentToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                InstrumentSwitch(isOn: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// The switch graphic alone.
struct InstrumentSwitch: View {
    let isOn: Bool

    var body: some View {
        let track = RoundedRectangle(cornerRadius: DS.Radius.toggle, style: .continuous)
        RoundedRectangle(cornerRadius: DS.Radius.knob, style: .continuous)
            .fill(isOn ? DS.Color.lightBlue : DS.Color.ink)
            .frame(width: DS.Size.knob, height: DS.Size.knob)
            .padding(3)
            .frame(width: DS.Size.toggleWidth, height: DS.Size.toggleHeight, alignment: isOn ? .trailing : .leading)
            .background(isOn ? DS.Color.ink : .clear, in: track)
            .overlay { if !isOn { track.strokeBorder(DS.Color.ink, lineWidth: 1.5) } }
            .animation(.snappy(duration: 0.18), value: isOn)
            .frame(minHeight: DS.Size.minTarget)
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
}
