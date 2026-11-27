import SwiftUI

/// A full-width row that behaves like a menu item: icon, title, hover highlight.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.tertiary).font(.callout) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
