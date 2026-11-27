import SwiftUI

/// "Menu bar icon: Monochrome / Color" with the real 18 pt glyph on a light and a dark bar, so the choice
/// shows what it does. Used in the dot maker and in Settings.
struct MenuBarIconPicker: View {
    let design: DotDesign
    @Binding var selection: MenuBarIcon
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: 6) {
            if !compact { Text("Menu bar icon").font(.caption).foregroundStyle(.secondary) }
            FrostChoice(options: [(MenuBarIcon.monochrome, "Monochrome"), (.color, "Color")], selection: $selection)
            HStack(spacing: 6) {
                bar(dark: false)
                bar(dark: true)
            }
            .accessibilityElement()
            .accessibilityLabel("Menu bar preview, \(selection == .color ? "color" : "monochrome")")
        }
    }

    func bar(dark: Bool) -> some View {
        let image = DotGlyph.image(design, state: .listening, color: selection == .color, darkBar: dark)
        return Group {
            if selection == .color { Image(nsImage: image) }
            else { Image(nsImage: image).renderingMode(.template).foregroundStyle(dark ? Color.white : Color.black) }
        }
        .frame(width: 92, height: 24)
        .background(dark ? Color(hex: 0x1E1E1E) : Color(hex: 0xE6E6E6), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
