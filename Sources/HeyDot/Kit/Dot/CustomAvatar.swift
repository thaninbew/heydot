import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// An imported avatar. `id` names its images under Application Support/HeyDot/avatars; `silhouette` says the
/// monochrome menu bar can use its shape (it has a transparent background). Without one, the monochrome
/// menu bar falls back to the HeyDot logo and Color shows the image.
struct CustomArt: Codable, Hashable, Sendable {
    var id: String
    var silhouette: Bool
    init(id: String, silhouette: Bool) { self.id = id; self.silhouette = silhouette }
}

/// Imported avatars, normalised once on import so nothing parses SVG at draw time. Each avatar is three
/// 512 px PNGs: `<id>.png` (as drawn), `<id>-dark.png` (ink turned white, the flat vector dark-tile rule) and
/// `<id>-template.png` (the monochrome mask: the art without its `<g id="eyes">`, so eyes read as holes).
@MainActor
enum Avatars {
    enum Variant: String { case color = "", dark = "-dark", template = "-template" }

    /// Overridden by QA renders and tests.
    static var directory = Paths().support.appendingPathComponent("avatars", isDirectory: true)
    private static var cache: [String: NSImage] = [:]

    static func image(_ id: String, _ variant: Variant = .color) -> NSImage? {
        let key = id + variant.rawValue
        if let hit = cache[key] { return hit }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(key + ".png")) else { return nil }
        cache[key] = image
        return image
    }

    // MARK: Import

    struct Imported: Equatable {
        var art: CustomArt
        /// Plain-language notes for the user (what the menu bar will show, legibility).
        var notes: [String]
    }

    struct Rejected: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    nonisolated static let side = 512
    static let maxSVGBytes = 200_000
    static let maxPNGBytes = 2_000_000
    /// Shape elements only: the same list the agent prompt promises.
    static let svgElements: Set<String> = ["svg", "g", "path", "circle", "ellipse", "rect", "polygon", "polyline", "line", "title", "desc"]

    /// Validates, normalises (trims transparent margins, fits a 3/96 margin) and stores an SVG or PNG.
    static func importFile(_ url: URL) throws -> Imported {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Rejected(description: "Couldn't read that file.") }
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if isPNG { return try importPNG(data) }
        guard url.pathExtension.lowercased() == "svg" || (String(data: data.prefix(512), encoding: .utf8) ?? "").contains("<svg") else {
            throw Rejected(description: "Use an SVG or PNG file.")
        }
        return try importSVG(data)
    }

    static func checkSVG(_ text: String) throws {
        if text.range(of: "<!(DOCTYPE|ENTITY)", options: [.regularExpression, .caseInsensitive]) != nil {
            throw Rejected(description: "The SVG has a DOCTYPE or ENTITY declaration, which HeyDot doesn't accept.")
        }
        let tags = try Regex(#"<\s*([A-Za-z][\w:.-]*)"#)
        for match in text.matches(of: tags) {
            let name = String(match.output[1].substring ?? "")
            guard svgElements.contains(name) else {
                throw Rejected(description: "The SVG uses <\(name)>. Only shapes (path, circle, ellipse, rect, polygon, polyline, line, g) are allowed.")
            }
        }
        if text.range(of: #"\s(on\w+|(xlink:)?href)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"url\s*\(|javascript:|data:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw Rejected(description: "The SVG links to something (href, url(), script or data). It has to be self-contained shapes.")
        }
    }

    static func importSVG(_ data: Data) throws -> Imported {
        guard data.count <= maxSVGBytes else { throw Rejected(description: "That SVG is over 200 KB. Avatars are a few simple shapes.") }
        guard let text = String(data: data, encoding: .utf8), text.contains("<svg") else { throw Rejected(description: "That isn't a readable SVG.") }
        try checkSVG(text)
        guard let full = NSImage(data: data), full.size.width > 0, full.size.height > 0 else {
            throw Rejected(description: "macOS couldn't draw that SVG.")
        }
        try checkAspect(full.size)
        // The template drops the eyes group so they read as holes in the menu bar, as HeyDot's own dots do.
        let eyesPattern = #"<g\b[^>]*\bid\s*=\s*["']eyes["'][^>]*>.*?</g\s*>"#
        let hasEyes = text.range(of: eyesPattern, options: [.regularExpression]) != nil
        let noEyes = hasEyes ? text.replacingOccurrences(of: eyesPattern, with: "", options: [.regularExpression]) : text
        let mask = hasEyes ? NSImage(data: Data(noEyes.utf8)) ?? full : full
        var notes: [String] = []
        if !hasEyes { notes.append("No <g id=\"eyes\"> group, so the monochrome menu bar shows the whole shape solid.") }
        return try store(color: full, template: mask, notes: notes)
    }

    static func importPNG(_ data: Data) throws -> Imported {
        guard data.count <= maxPNGBytes else { throw Rejected(description: "That PNG is over 2 MB.") }
        guard let image = NSImage(data: data), let rep = image.representations.first else { throw Rejected(description: "That isn't a readable PNG.") }
        guard rep.pixelsWide >= 64, rep.pixelsHigh >= 64 else { throw Rejected(description: "That PNG is smaller than 64 px. Use at least 256 px.") }
        guard rep.pixelsWide <= 4096, rep.pixelsHigh <= 4096 else { throw Rejected(description: "That PNG is larger than 4096 px.") }
        try checkAspect(NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        return try store(color: image, template: image, notes: [])
    }

    static func checkAspect(_ size: NSSize) throws {
        let ratio = size.width / size.height
        guard ratio >= 0.5, ratio <= 2 else { throw Rejected(description: "Use a roughly square image (it's drawn in a square).") }
    }

    /// A side x side premultiplied RGBA canvas that owns its pixels.
    final class Bitmap {
        let side: Int
        let ctx: CGContext
        private let data: UnsafeMutablePointer<UInt8>
        init?(side: Int = Avatars.side) {
            self.side = side
            data = .allocate(capacity: side * side * 4)
            data.initialize(repeating: 0, count: side * side * 4)
            guard let ctx = CGContext(data: data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { data.deallocate(); return nil }
            self.ctx = ctx
        }
        deinit { data.deallocate() }
        subscript(i: Int) -> UInt8 { get { data[i] } set { data[i] = newValue } }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[(y * side + x) * 4 + 3] }
        /// Draws the image (vector art stays vector) into `rect`, y up.
        func draw(_ image: NSImage, in rect: CGRect) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        var png: Data? {
            guard let image = ctx.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    /// Bounding box (canvas pixels, y up) of pixels with alpha above a whisper.
    static func opaqueBox(_ b: Bitmap) -> CGRect? {
        var minX = b.side, minY = b.side, maxX = -1, maxY = -1
        for y in 0..<b.side { for x in 0..<b.side where b.alpha(x, y) > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        // Rows in memory run top to bottom; drawing is y up.
        return CGRect(x: minX, y: b.side - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func store(color: NSImage, template: NSImage, notes: [String]) throws -> Imported {
        let failed = Rejected(description: "Couldn't draw that image.")
        guard let probe = Bitmap() else { throw failed }
        probe.draw(color, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let box = opaqueBox(probe) else { throw Rejected(description: "That image is empty (fully transparent).") }
        // Trim transparent margins, then fit inside the 3-unit margin every dot uses.
        let k = CGFloat(side) * 90 / 96 / max(box.width, box.height)
        let fitted = CGRect(x: (CGFloat(side) - box.width * k) / 2 - box.minX * k, y: (CGFloat(side) - box.height * k) / 2 - box.minY * k,
                            width: CGFloat(side) * k, height: CGFloat(side) * k)
        guard let c = Bitmap(), let m = Bitmap(), let d = Bitmap() else { throw failed }
        c.draw(color, in: fitted)
        m.draw(template, in: fitted)
        let count = side * side
        // Transparency is measured inside the art's own box, so the margin added above doesn't count.
        let art = CGRect(x: (CGFloat(side) - box.width * k) / 2, y: (CGFloat(side) - box.height * k) / 2,
                         width: box.width * k, height: box.height * k).insetBy(dx: 2, dy: 2)
        var transparent = 0, inArt = 0, covered = 0
        for i in 0..<count {
            let a = Int(c[i * 4 + 3])
            if art.contains(CGPoint(x: i % side, y: side - 1 - i / side)) { inArt += 1; if a < 26 { transparent += 1 } }
            if m[i * 4 + 3] > 128 { covered += 1 }
            // Dark-tile variant: near-ink pixels turn white (premultiplied, so white is `a` in every channel).
            let lum = a == 0 ? 255 : (Int(c[i * 4]) * 2126 + Int(c[i * 4 + 1]) * 7152 + Int(c[i * 4 + 2]) * 722) / 10000 * 255 / a
            for ch in 0..<3 { d[i * 4 + ch] = lum < 56 ? UInt8(a) : c[i * 4 + ch] }
            d[i * 4 + 3] = UInt8(a)
        }
        let silhouette = Double(transparent) / Double(max(1, inArt)) >= 0.08
        guard let colorPNG = c.png, let darkPNG = d.png, let maskPNG = m.png else { throw Rejected(description: "Couldn't save that image.") }
        let id = SHA256.hash(data: colorPNG + maskPNG).prefix(6).map { String(format: "%02x", $0) }.joined()
        try Paths.ensureDirectory(directory, mode: 0o700)
        for (suffix, bytes) in [("", colorPNG), ("-dark", darkPNG), ("-template", maskPNG)] {
            let file = directory.appendingPathComponent(id + suffix + ".png")
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
            cache[id + suffix] = nil
        }
        var notes = notes
        if silhouette {
            notes.insert("The monochrome menu bar uses its silhouette.", at: 0)
            if Double(covered) / Double(count) < 0.18 { notes.append("It's mostly thin lines, so it may be hard to see at menu bar size.") }
        } else {
            notes.insert("It has no transparent background, so the monochrome menu bar shows the HeyDot logo. Choose Color to see it there.", at: 0)
        }
        return Imported(art: CustomArt(id: id, silhouette: silhouette), notes: notes)
    }
}
