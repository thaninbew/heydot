import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Design your dot": ChatGPT's dot designer categories and labels, drawn in our style, with the nickname
/// first and the Custom avatar section (import, design with your agent) last.
struct DotMakerView: View {
    @State var draft: DotDesign
    @State var menuBarIcon: MenuBarIcon = .monochrome
    var onSave: (DotDesign, MenuBarIcon) -> Void
    var onCancel: () -> Void

    @State private var importNotes: [String] = []
    @State private var importError: String?
    @State private var promptCopied = false
    @State private var showPrompt = false

    static let avatarPrompt = String(decoding: PackageResources.AvatarAgentPrompt_md, as: UTF8.self)

    var drawn: Bool { draft.custom == nil }

    var body: some View {
        HStack(spacing: 0) {
            preview
                .frame(width: 280)
                .background(Color.primary.opacity(0.03))
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        group("Nickname") {
                            TextField("Nickname", text: $draft.nickname, prompt: Text("Your dot"))
                                .modifier(FrostField())
                                .frame(maxWidth: 280)
                        }
                        group("Shape") {
                            grid(ShapeChoice.all, selected: ShapeChoice(draft), label: \.label) { $0.applied(to: draft) }
                                apply: { draft = $0.applied(to: draft) }
                        }
                        group("Color") { swatches(DotColor.faceColors, selected: draft.color) { draft.color = $0 } }
                        group("Eyes") {
                            grid(DotEyes.allCases, selected: draft.eyes, label: \.label) { e in var d = draft; d.eyes = e; d.custom = nil; return d }
                                apply: { draft.eyes = $0; draft.custom = nil }
                        }
                        group("Glasses") {
                            grid(DotGlasses.allCases, selected: draft.glasses, label: \.label) { g in var d = draft; d.glasses = g; d.custom = nil; return d }
                                apply: { draft.glasses = $0; draft.custom = nil }
                        }
                        group("Accessories") {
                            grid(DotAccessory.allCases, selected: draft.accessory, label: \.label) { a in var d = draft; d.accessory = a; d.custom = nil; return d }
                                apply: { draft.accessory = $0; draft.custom = nil }
                        }
                        group("Accessory color") {
                            swatches(DotColor.accessoryColors, selected: draft.accessoryColor) { draft.accessoryColor = $0 }
                                .disabled(draft.accessory == .none)
                                .opacity(draft.accessory == .none ? 0.4 : 1)
                        }
                        group("Custom avatar") { custom }
                    }
                    .padding(24)
                }
                Divider()
                HStack(spacing: Frost.Space.m) {
                    Button("Reset to HeyDot") { draft = draft.logo }.frostButton(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).frostButton(.secondary)
                    Button("Save") { onSave(draft, menuBarIcon) }.keyboardShortcut(.defaultAction).frostButton(.primary)
                }
                .padding(Frost.Space.l)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(FrostBackdrop(animated: false).ignoresSafeArea())
        .frostTheme(draft)
    }

    var preview: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            DotTile(draft, size: 168, dark: false)
            DotTile(draft, size: 72, dark: true)
            Text(draft.nickname.isEmpty ? "Your dot" : draft.nickname)
                .font(.title3.weight(.semibold))
                .foregroundStyle(draft.nickname.isEmpty ? .secondary : .primary)
            if drawn {
                VStack(spacing: 6) {
                    Text("Color goes on").font(.caption).foregroundStyle(.secondary)
                    FrostChoice(options: [(DotFill.inkBody, "Eyes"), (.colorBody, "Body")], selection: $draft.fill)
                }
                .help("Our style keeps an ink body and puts your colour in the eyes. Choose Body to colour the whole dot.")
            } else {
                Text("Your imported avatar. Pick a shape to draw a dot instead.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            MenuBarIconPicker(design: draft, selection: $menuBarIcon)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: Custom

    var custom: some View {
        VStack(alignment: .leading, spacing: Frost.Space.l) {
            VStack(alignment: .leading, spacing: 8) {
                Text("An SVG or PNG, roughly square. A transparent background lets the monochrome menu bar use its shape.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Frost.Space.s) {
                    Button(action: importAvatar) { Label("Import SVG or PNG\u{2026}", systemImage: "square.and.arrow.down") }
                        .frostButton(.chip)
                    if draft.custom != nil {
                        Button("Remove", role: .destructive) { draft.custom = nil; importNotes = []; importError = nil }.frostButton(.chip)
                    }
                }
                if let importError { FrostBanner(good: false, message: importError) { EmptyView() } }
                ForEach(importNotes, id: \.self) { note in
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Design with your agent").font(.subheadline.weight(.semibold))
                Text("Paste this prompt into your coding agent (Claude Code, Codex and the like). It draws an avatar in HeyDot's style as an SVG you can import here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.avatarPrompt, forType: .string)
                        promptCopied = true
                    } label: { Label("Copy prompt", systemImage: "doc.on.doc") }
                    .frostButton(.chip)
                    Button(showPrompt ? "Hide prompt" : "Show prompt") { showPrompt.toggle() }.frostButton(.chip)
                    if promptCopied {
                        Label("Copied", systemImage: "checkmark").font(.callout).foregroundStyle(.frostMark)
                    }
                }
                if showPrompt { FrostCodePreview(text: Self.avatarPrompt) }
            }
        }
    }

    func importAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SVG or PNG avatar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try Avatars.importFile(url)
            draft.custom = imported.art
            importNotes = imported.notes
            importError = nil
        } catch {
            importError = (error as? Avatars.Rejected)?.description ?? error.localizedDescription
            importNotes = []
        }
    }

    // MARK: Building blocks

    func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    func grid<T: Hashable & Identifiable>(_ items: [T], selected: T?, label: KeyPath<T, String>,
                                         design: @escaping (T) -> DotDesign, apply: @escaping (T) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                OptionCell(design: design(item), label: item[keyPath: label], selected: item == selected) { apply(item) }
            }
        }
    }

    func swatches(_ colors: [DotColor], selected: DotColor, apply: @escaping (DotColor) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(colors) { color in
                Button { apply(color) } label: {
                    Circle().fill(color.color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().strokeBorder(color == selected ? Color.primary : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(color.label)
                .accessibilityLabel(color.label)
                .accessibilityAddTraits(color == selected ? .isSelected : [])
            }
        }
    }
}

/// The Shape row: the HeyDot logo first, then the drawn shapes.
enum ShapeChoice: Hashable, Identifiable {
    case heyDot, shape(DotShape)
    static let all: [ShapeChoice] = [.heyDot] + DotShape.allCases.map(ShapeChoice.shape)

    /// The choice the design shows: HeyDot for the logo's mic (also once restyled), nil for an imported avatar.
    init?(_ design: DotDesign) {
        guard design.custom == nil else { return nil }
        switch design.signature {
        case nil: self = .shape(design.shape)
        case .mic: self = .heyDot
        default: return nil
        }
    }

    var id: String { if case .shape(let s) = self { s.rawValue } else { "heyDot" } }
    var label: String { if case .shape(let s) = self { s.label } else { "HeyDot" } }

    /// HeyDot brings back the whole logo; a shape keeps the rest of the design. Both keep the nickname.
    func applied(to design: DotDesign) -> DotDesign {
        switch self {
        case .heyDot: return design.logo
        case .shape(let shape):
            var d = design; d.shape = shape; d.signature = nil; d.custom = nil; return d
        }
    }
}

struct OptionCell: View {
    let design: DotDesign
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.self) private var env

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    // The logo is its own PNG artwork, as on the preview tile; every other design is drawn.
                    if design.isLogo { DotTile(design, size: 72) } else { DotView(design).padding(10) }
                }
                .frame(width: 72, height: 72)
                .background(Color(hex: 0xF3F2EE))
                .clipShape(RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Frost.Radius.field, style: .continuous)
                        .strokeBorder(selected ? env.frostMark : (hover ? Color.primary.opacity(0.25) : Color.primary.opacity(0.06)),
                                      lineWidth: selected ? 2.5 : 1)
                )
                Text(label)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 88)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
