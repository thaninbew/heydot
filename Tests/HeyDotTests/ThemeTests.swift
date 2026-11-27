import AVFoundation
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HeyDotKit
@testable import WakeEngine

@Test func themeIsFrostUntilThereIsADotAndDeterministicAfter() {
    #expect(Theme.forDesign(.default) == Theme.from(palette: [Accent.defaultHex]), "the default logo themes from its coral")
    let body = Accent.defaultHex, eyes = Accent.ink(for: body)  // the drawn logo: coral body, same-hue ink eyes
    #expect(DotDesign.default.fill == .colorBody)
    #expect(Accent.contrast(body, eyes) >= 4.4)
    #expect(OKLCH.hueDistance(OKLCH(hex: body).h, OKLCH(hex: eyes).h) < 3)
    #expect(Theme.frost.light == [0xFB9890, 0xF4BF8C, 0xF4A0C8] && Theme.frost.accent == Accent.ui(Accent.defaultHex))
    var avatar = DotDesign.default; avatar.signature = nil
    avatar.custom = CustomArt(id: "x", silhouette: true)
    #expect(Theme.forDesign(avatar) == .frost, "an imported avatar has no palette to read")
    for design in [DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody), DotDesign(color: .teal, accessory: .headphones, accessoryColor: .blue), DotDesign(color: .charcoal)] {
        #expect(Theme.forDesign(design) == Theme.forDesign(design))
    }
    #expect(Theme.from(palette: [0x2DB84D, 0x2F6BFF]) == Theme.from(palette: [0x2DB84D, 0x2F6BFF]))
}

@Test func themeStaysSoftAndReadableAcrossASpreadOfDots() {
    let faces = DotColor.faceColors.map(\.hex)
    let extremes: [UInt32] = [0xE0353B, 0xF6D6E8, 0xF4F0FF, 0x39FF14, 0xFF00FF, 0x00FFFF, 0x1F1F23, 0x000000, 0xFFFFFF, 0x808080]
    let palettes = (faces + extremes).map { [$0] } + faces.flatMap { a in faces.filter { $0 != a }.map { [a, $0] } }
    for palette in palettes {
        let theme = Theme.from(palette: palette)
        #expect(theme.light.count == 3 && theme.dark.count == 3)
        let label = Accent.label(on: theme.accent)
        let text = Accent.contrast(theme.accent, label)
        #expect(text >= 4.5 || (label == 0xFFFFFF && text >= 3), "pill label on \(palette): \(text)")
        for dark in [false, true] {
            let mark = Accent.mark(theme.accent, dark: dark)
            #expect(Accent.contrast(mark, dark ? Accent.darkWindow : Accent.lightWindow) >= Accent.markContrast, "marks for \(palette)")
        }
        for (stops, bounds) in [(theme.light, Theme.lightnessBounds.light), (theme.dark, Theme.lightnessBounds.dark)] {
            for stop in stops {
                let c = OKLCH(hex: stop)
                #expect(bounds.contains(c.l) || abs(c.l - bounds.lowerBound) < 0.02 || abs(c.l - bounds.upperBound) < 0.02,
                        "lightness \(c.l) for \(palette)")
                #expect(c.c <= Theme.chromaBounds.upperBound + 0.01, "chroma \(c.c) for \(palette)")
            }
        }
    }
}

@Test func themeHuesFollowTheDotAndFillTheGap() {
    // One hue: the dot's own hue leads.
    let red = Theme.from(palette: [0xE0353B])
    #expect(OKLCH.hueDistance(OKLCH(hex: red.light[0]).h, OKLCH(hex: 0xE0353B).h) < 10)
    // Two hues: both lead, the third sits in the widest gap, away from both.
    let greenBlue = Theme.from(palette: [0x2DB84D, 0x2F6BFF])
    let (g, b) = (OKLCH(hex: 0x2DB84D).h, OKLCH(hex: 0x2F6BFF).h)
    #expect(OKLCH.hueDistance(OKLCH(hex: greenBlue.light[0]).h, g) < 10)
    #expect(OKLCH.hueDistance(OKLCH(hex: greenBlue.light[1]).h, b) < 10)
    let third = OKLCH(hex: greenBlue.light[2]).h
    #expect(OKLCH.hueDistance(third, g) > 90 && OKLCH.hueDistance(third, b) > 90)
    // No hue (near-black, grey): a quiet slate theme.
    for gray: UInt32 in [0x1F1F23, 0x808080] {
        #expect(Theme.from(palette: [gray]).light.allSatisfy { OKLCH(hex: $0).c < 0.05 })
    }
    // The lime example with blue headphones reads both colours.
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    #expect(Theme.palette(for: tray) == [DotColor.lime.hex, DotColor.blue.hex])
}

@Test func accentIsTheDotsOwnMainColourWithALabelThatReads() {
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    let theme = Theme.forDesign(tray)
    #expect(theme.accent == DotColor.lime.hex, "Tray's accent is the lime of its body, not a darkened olive")
    #expect(Accent.label(on: DotColor.lime.hex) != 0xFFFFFF, "dark ink on lime")
    #expect(Accent.contrast(DotColor.lime.hex, Accent.label(on: DotColor.lime.hex)) >= 4.5)
    #expect(Accent.label(on: 0x1B2A6B) == 0xFFFFFF, "white on navy")
    #expect(Accent.label(on: DotColor.violet.hex) == 0xFFFFFF, "white on the default violet")
    #expect(Accent.label(on: 0xB3141B) == 0xFFFFFF, "white on deep red")
    #expect(Accent.label(on: DotColor.yellow.hex) != 0xFFFFFF)
    // Every dot colour fills the pill as itself.
    for color in DotColor.faceColors { #expect(Accent.pill(color.hex) == color.hex) }
    // Marks keep the hue: lime deepens on a light window only as far as 3:1.
    let mark = Accent.mark(DotColor.lime.hex, dark: false)
    #expect(OKLCH.hueDistance(OKLCH(hex: mark).h, OKLCH(hex: DotColor.lime.hex).h) < 8)
    #expect(Accent.contrast(mark, Accent.lightWindow) < 3.4, "only as deep as needed")
    #expect(Accent.mark(DotColor.lime.hex, dark: true) == DotColor.lime.hex, "lime already reads on a dark window")
}

@Test func accentReadsOnEveryDotColourInLightAndDark() {
    let sources = DotColor.allCases.map(\.hex) + [Accent.defaultHex, 0x1F1F23, 0xF4F0FF, 0xFFFFFF, 0x000000]
    for raw in sources {
        let fill = Accent.ui(raw)
        #expect(Accent.contrast(fill, 0xFFFFFF) >= 4.5, "white button text on \(String(raw, radix: 16))")
        #expect(Accent.contrast(fill, Accent.lightWindow) >= 3, "marks on a light window")
        #expect(Accent.contrast(fill, Accent.darkWindow) >= 3, "button on a dark window")
        #expect(Accent.contrast(Accent.mark(fill, dark: true), Accent.darkWindow) >= Accent.markContrast, "marks on a dark window (3:1 since round 7)")
    }
    #expect(Accent.hex(for: .default) == Accent.ui(Accent.defaultHex), "an undesigned dot uses the logo's coral")
    #expect(Accent.hex(for: DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)) == Accent.ui(DotColor.lime.hex))
    #expect(Accent.hex(for: DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody)) != Accent.hex(for: DotDesign(color: .yellow)))
}

@Test func backdropIsLedByTheMainColour() {
    var tray = DotDesign(shape: .roundedTriangle, color: .lime, accessory: .headphones, fill: .colorBody); tray.accessoryColor = .blue
    let theme = Theme.forDesign(tray)
    #expect(theme.wash == theme.light[0] && theme.weights[0] > theme.weights[1] && theme.weights[1] >= theme.weights[2])
    #expect(OKLCH.hueDistance(OKLCH(hex: theme.light[0]).h, OKLCH(hex: DotColor.lime.hex).h) < 8, "the lead stop is lime")
    #expect(OKLCH(hex: theme.light[0]).c > OKLCH(hex: theme.light[1]).c, "supporting stops are quieter")
    #expect(Theme.frost.wash == nil && Theme.frost.weights == [1, 1, 1], "Frost is unchanged")
}
