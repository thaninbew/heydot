import AppKit
import SwiftUI
import WebKit

extension QARender {
    /// The sign-in window over the live, logged-out chatgpt.com, in a throwaway non-persistent store.
    /// WebKit draws out of process, so the page is captured with `takeSnapshot` and composited under the header.
    static func renderSignIn(into dir: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = NSSize(width: 980, height: 760)
            let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: {
                let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c
            }())
            web.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
            let deadline = Date().addingTimeInterval(20)
            while (web.isLoading || web.url == nil) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            RunLoop.main.run(until: Date().addingTimeInterval(4))  // let the page render after load
            for dark in [false, true] {
                let host = NSHostingView(rootView: SignInView(web: nil, state: SignInState(), done: {}).frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = KeyWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                                       backing: .buffered, defer: false)
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
                host.cacheDisplay(in: host.bounds, to: rep)
                window.orderOut(nil)
                // The header's height: everything above the web area (the Divider sits at its bottom).
                let header = host.subviews.isEmpty ? 70 : headerHeight(rep)
                web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                var page: NSImage?
                var done = false
                let config = WKSnapshotConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: size.width, height: size.height - header)
                web.setFrameSize(NSSize(width: size.width, height: size.height - header))
                web.takeSnapshot(with: config) { image, _ in page = image; done = true }
                while !done && Date() < deadline.addingTimeInterval(10) { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                let composite = NSImage(size: size)
                composite.lockFocus()
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                NSImage(cgImage: rep.cgImage!, size: size).draw(in: NSRect(origin: .zero, size: size))
                page?.draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height - header))
                composite.unlockFocus()
                guard let tiff = composite.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: dir.appendingPathComponent(dark ? "signin-window-dark.png" : "signin-window.png"))
            }
            print("qa-signin: page \(web.url?.absoluteString ?? "none"), title \(web.title ?? "")")
            return 0
        } catch {
            FileHandle.standardError.write(Data("qa-signin failed: \(error)\n".utf8))
            return 1
        }
    }

    /// Finds the header's divider: the first row from the top, below 40 px, that differs from the row above it
    /// across the whole width (the web area of the header-only render is a flat fill).
    private static func headerHeight(_ rep: NSBitmapImageRep) -> CGFloat {
        let scale = CGFloat(rep.pixelsHigh) / rep.size.height
        var last: NSColor?
        var y = Int(40 * scale)
        while y < rep.pixelsHigh {
            let c = rep.colorAt(x: rep.pixelsWide - 2, y: y)
            if let last, let c, abs(last.brightnessComponent - c.brightnessComponent) > 0.03 { return CGFloat(y) / scale + 1 }
            last = c; y += 1
        }
        return 70
    }
}
