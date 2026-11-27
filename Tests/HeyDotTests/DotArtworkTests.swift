import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HeyDotKit
@testable import WakeEngine

@Test func everyOptionDrawsInsideTheGrid() {
    var designs: [DotDesign] = DotShape.allCases.flatMap { shape in
        DotAccessory.allCases.map { DotDesign(shape: shape, accessory: $0) } +
        DotGlasses.allCases.map { DotDesign(shape: shape, glasses: $0) } +
        DotEyes.allCases.map { DotDesign(shape: shape, eyes: $0) }
    }
    let mic = DotArt.face(.default)
    #expect(mic.body.boundingBoxOfPath == CGRect(x: 28, y: 4, width: 40, height: 58))
    #expect(mic.eyeY == 34 && mic.eyeGap == 9.5 && mic.eyeW == 11 && mic.eyeH == 16)
    let glyph = DotArt.layers(.default, gutter: 4).first { $0.role == .body }!.path
    #expect(!glyph.contains(CGPoint(x: 37.5, y: 34)) && !glyph.contains(CGPoint(x: 58.5, y: 34)))
    #expect(glyph.contains(CGPoint(x: 48, y: 34)), "the bridge keeps two separate eye holes")
    #expect(!glyph.contains(CGPoint(x: 48, y: 64)) && glyph.contains(CGPoint(x: 48, y: 69)))
    designs += DotSignature.allCases.map { DotDesign(signature: $0) }
    for design in designs {
        let layers = DotArt.layers(design)
        let bounds = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        #expect(!bounds.isNull && bounds.minX >= 2.9 && bounds.minY >= 2.9 && bounds.maxX <= 93.1 && bounds.maxY <= 93.1,
                "\(design) is out of bounds: \(bounds)")
        // Sunglasses deliberately cover the eyes; their glint carries the colour instead.
        let shaded = design.glasses == .classicSunglasses || design.glasses == .roundSunglasses
        #expect(shaded || layers.contains { $0.role == .eye && !$0.path.isEmpty }, "\(design) lost its eyes")
        #expect(!shaded || layers.contains { $0.role == .glint && !$0.path.isEmpty }, "\(design) lost its glint")
    }
}

@Test func headphonesNeverCoverOrCutTheEars() {
    for shape in [DotShape.circleTwoEars, .roundedHeadTwoEars] {
        let face = DotArt.face(of: shape)
        guard let ears = face.ears else { Issue.record("\(shape) has no ears"); continue }
        let body = DotArt.layers(DotDesign(shape: shape, accessory: .headphones)).first { $0.role == .body }!.path
        // Every bit of ear is still body: nothing covers it and no gutter is cut into it (sampled every half unit).
        let box = ears.boundingBoxOfPath
        var lost = 0
        for x in stride(from: box.minX, through: box.maxX, by: 0.5) {
            for y in stride(from: box.minY, through: box.maxY, by: 0.5) {
                // Points within 0.3 of the ear's outline are boundary noise, not a cut.
                let inside = [(0.0, 0.0), (0.3, 0), (-0.3, 0), (0, 0.3), (0, -0.3)].allSatisfy { ears.contains(CGPoint(x: x + $0.0, y: y + $0.1)) }
                if inside && !body.contains(CGPoint(x: x, y: y)) { lost += 1 }
            }
        }
        #expect(lost == 0, "\(shape): headphones cover or cut \(lost) sampled points of the ears")
    }
}

@Test func designsPersistAsJSON() throws {
    let d = DotDesign(shape: .heart, color: .coral, eyes: .sleepyLids, glasses: .monocle, accessory: .crown, accessoryColor: .brown,
                      nickname: "Pip", fill: .colorBody)
    #expect(try JSONDecoder().decode(DotDesign.self, from: JSONEncoder().encode(d)) == d)
}

@MainActor private func pixels(_ view: some View, side: CGFloat = 64) -> Data? {
    let renderer = ImageRenderer(content: view.frame(width: side, height: side))
    renderer.scale = 1
    return renderer.cgImage?.dataProvider?.data as Data?
}

private func hue(_ color: Color) -> Double {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    let hex = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    return OKLCH(hex: hex).h
}

@MainActor @Test func theLogoStaysTheLogoWithANickname() {
    var named = DotDesign.default
    named.nickname = "Pip"
    #expect(pixels(DotTile(named, size: 64)) == pixels(DotTile(.default, size: 64)), "a nickname swapped the logo for a drawn mic")
    #expect(Theme.forDesign(named) == Theme.forDesign(.default))
    #expect(Accent.hex(for: named) == Accent.hex(for: .default))
}

@MainActor @Test func theLogoAndDotsMadeFromItStayCoral() {
    let brand = OKLCH(hex: Accent.defaultHex).h
    var edits: [DotDesign] = [.default]
    for edit in [{ (d: inout DotDesign) in d.eyes = .dots }, { $0.glasses = .monocle }, { $0.accessory = .crown }, { $0.fill = .inkBody }] {
        var d = DotDesign.default; edit(&d); edits.append(d)
    }
    for design in edits {
        let paint = DotView.palette(design, .standard)
        let body = design.fill == .colorBody ? paint(.body)! : paint(.eye)!
        #expect(OKLCH.hueDistance(hue(body), brand) < 30, "\(design) is drawn purple, not in the logo's coral")
    }
}

@Test func theShapeRowOffersTheLogoBack() {
    let tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, nickname: "Tray")
    #expect(ShapeChoice.all.first == .heyDot)
    #expect(ShapeChoice(.default) == .heyDot && ShapeChoice(tray) == .shape(.roundedTriangle))
    let back = ShapeChoice.heyDot.applied(to: tray)
    #expect(back.isLogo && back.nickname == "Tray")
    var avatar = tray
    avatar.custom = CustomArt(id: "x", silhouette: true)
    #expect(ShapeChoice(avatar) == nil && ShapeChoice.heyDot.applied(to: avatar).isLogo)
}

@Test func savedLogosLoadAsTheLogoKeepingTheirNickname() throws {
    // HeyDot 0.2.0 saved the logo with the violet of the earlier flat mic, in a file without a version.
    let saved = DotDesign(color: .violet, nickname: "Pip", fill: .colorBody, signature: .mic)
    let json = try JSONSerialization.data(withJSONObject: ["design": JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))])
    let loaded = try JSONDecoder().decode(AppSettings.self, from: json).design
    #expect(loaded.nickname == "Pip")
    #expect(Theme.forDesign(loaded) == Theme.forDesign(.default) && Accent.hex(for: loaded) == Accent.hex(for: .default))
}

@Test func aVioletMicChosenNowStaysVioletAfterRelaunch() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let store = SettingsStore(url: Paths(home: home).settings)
    var settings = AppSettings()
    settings.design = DotDesign.default.withNickname("Pip")
    settings.design.color = .violet  // the Violet swatch, picked on the logo
    try store.save(settings)
    let loaded = try store.load()
    #expect(loaded.design == settings.design && !loaded.design.isLogo)
}

@MainActor @Test func avatarImportValidatesAndMakesAMenuBarSilhouette() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let saved = Avatars.directory
    Avatars.directory = dir.appendingPathComponent("avatars")
    defer { Avatars.directory = saved }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name); try text.write(to: url, atomically: true, encoding: .utf8); return url
    }
    let good = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
      <path fill="#0A0A0B" fill-rule="evenodd" d="M16 52a32 32 0 1 0 64 0a32 32 0 1 0 -64 0Z M35 46h10v18h-10Z M51 46h10v18h-10Z"/>
      <g id="eyes"><rect x="35" y="46" width="10" height="18" rx="5" fill="#C6E82B"/><rect x="51" y="46" width="10" height="18" rx="5" fill="#C6E82B"/></g>
    </svg>
    """
    let imported = try Avatars.importFile(try file("good.svg", good))
    #expect(imported.art.silhouette)
    // The eyes are drawn in colour but are holes in the monochrome mask.
    let color = try #require(Avatars.image(imported.art.id)), mask = try #require(Avatars.image(imported.art.id, .template))
    func alpha(_ image: NSImage, _ x: Int, _ y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.colorAt(x: x * rep.pixelsWide / 96, y: y * rep.pixelsHigh / 96)?.alphaComponent ?? 0
    }
    // Import trims the margins and fits the art to 90 of 96 units: the circle (16...80) grows by 90/64.
    #expect(alpha(color, 37, 52) > 0.9 && alpha(mask, 37, 52) < 0.1)  // eye centre (40, 55) before fitting
    #expect(alpha(mask, 48, 17) > 0.9)  // the body, (48, 30) before fitting, is solid in both
    for bad in [good.replacingOccurrences(of: "<g id=\"eyes\">", with: "<script>alert(1)</script><g id=\"eyes\">"),
                good.replacingOccurrences(of: "fill=\"#0A0A0B\"", with: "fill=\"url(https://example.com/x)\""),
                good.replacingOccurrences(of: "<path", with: "<image href=\"file:///etc/passwd\"/><path"),
                "<?xml version=\"1.0\"?><!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>" + good,
                "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 50\"><rect width=\"300\" height=\"50\"/></svg>"] {
        #expect(throws: Avatars.Rejected.self) { try Avatars.importFile(try file("bad.svg", bad)) }
    }
    // An opaque PNG has no silhouette: the monochrome menu bar falls back to the logo.
    let square = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1).setFill(); rect.fill(); return true
    }
    let rep = NSBitmapImageRep(data: square.tiffRepresentation!)!
    let png = dir.appendingPathComponent("square.png")
    try rep.representation(using: .png, properties: [:])!.write(to: png)
    #expect(try !Avatars.importFile(png).art.silhouette)
}
