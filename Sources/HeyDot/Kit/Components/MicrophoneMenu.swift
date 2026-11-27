import SwiftUI
import WakeEngine

/// A microphone menu: the built-in microphone first (the default), then any other input the user may choose.
struct MicrophoneMenu: View {
    let devices: [AudioInput]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Picker("Microphone", selection: $selection) {
                ForEach(MicrophoneChoices(devices: devices, selection: selection).options, id: \.uid) { option in
                    Text(option.label).tag(option.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                Text(MicrophoneChoices(devices: devices, selection: selection).current)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(.background.opacity(0.75)).shadow(color: .black.opacity(0.08), radius: 2, y: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Microphone")
        .help("HeyDot uses the built-in microphone unless you choose another here. It never switches to headphones on its own.")
    }
}

/// The picker's options, shared by the tuning screen and Settings.
struct MicrophoneChoices {
    let devices: [AudioInput]
    let selection: String?

    var builtInName: String { devices.first { $0.transport == .builtIn }?.name ?? "Built-in microphone" }

    var options: [(uid: String?, label: String)] {
        var list: [(String?, String)] = [(nil, "\(builtInName) (default)")]
        for device in devices where device.transport != .builtIn {
            list.append((device.uid, device.transport == .bluetooth ? "\(device.name) (Bluetooth)" : device.name))
        }
        if let selection, !devices.contains(where: { $0.uid == selection }) {
            list.append((selection, "Chosen microphone (not connected)"))
        }
        return list
    }

    /// What HeyDot records from now: the choice while connected, otherwise built-in.
    var current: String {
        guard let selection, let device = devices.first(where: { $0.uid == selection }) else { return builtInName }
        return device.name
    }
}
