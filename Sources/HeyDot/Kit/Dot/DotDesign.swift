import SwiftUI

// The dot maker uses original vector artwork in DotGeometry.swift.

public enum DotShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case circle, roundedTriangle, capsule, roundedHeadTwoEars, sixLobedFlower, heart, fourLobedButterfly,
         circleTwoEars, twelveScallopedRosette, hexagon, roundedDiamond
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .circle: "Circle"
        case .roundedTriangle: "Rounded triangle"
        case .capsule: "Capsule"
        case .roundedHeadTwoEars: "Rounded head with two ears"
        case .sixLobedFlower: "Six lobed flower"
        case .heart: "Heart"
        case .fourLobedButterfly: "Four lobed butterfly"
        case .circleTwoEars: "Circle with two ears"
        case .twelveScallopedRosette: "Twelve scalloped rosette"
        case .hexagon: "Hexagon"
        case .roundedDiamond: "Rounded diamond"
        }
    }
}

public enum DotColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case pink, orchid, violet, blue, cyan, teal, lime, yellow, coral
    case charcoal, brown  // accessory colours only
    public var id: String { rawValue }
    public static let faceColors: [DotColor] = [.pink, .orchid, .violet, .blue, .cyan, .teal, .lime, .yellow, .coral]
    public static let accessoryColors: [DotColor] = faceColors + [.charcoal, .brown]
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// Our palette. The available face and accessory colours.
    public var hex: UInt32 {
        switch self {
        case .pink: 0xFF5FA2
        case .orchid: 0xD65CF0
        case .violet: 0x7B61FF
        case .blue: 0x2F6BFF
        case .cyan: 0x1FC6F0
        case .teal: 0x12BFA0
        case .lime: 0xC6E82B
        case .yellow: 0xFFD21E
        case .coral: 0xFF7A1A
        case .charcoal: 0x1F1F23
        case .brown: 0x8C5A3C
        }
    }
    public var color: Color { Color(hex: hex) }
}

public enum DotEyes: String, Codable, CaseIterable, Sendable, Identifiable {
    case sweptLids, oval, sparkleCapsules, highlightCapsules, dots, roundHighlights, crescentInset, sleepyLids
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sweptLids: "Swept lids"
        case .oval: "Oval"
        case .sparkleCapsules: "Sparkle capsules"
        case .highlightCapsules: "Highlight capsules"
        case .dots: "Dots"
        case .roundHighlights: "Round highlights"
        case .crescentInset: "Crescent inset"
        case .sleepyLids: "Sleepy lids"
        }
    }
}

public enum DotGlasses: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, monocle, tallOvalFrames, separateTrapezoidLenses, classicSunglasses, roundSunglasses
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "None"
        case .monocle: "Monocle"
        case .tallOvalFrames: "Tall oval frames"
        case .separateTrapezoidLenses: "Separate trapezoid lenses"
        case .classicSunglasses: "Classic sunglasses"
        case .roundSunglasses: "Round sunglasses"
        }
    }
}

public enum DotAccessory: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, headphones, bowTie, beanie, hat, beret, bulb, tuft, crown
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "None"
        case .headphones: "Headphones"
        case .bowTie: "Bow tie"
        case .beanie: "Beanie"
        case .hat: "Hat"
        case .beret: "Beret"
        case .bulb: "Bulb"
        case .tuft: "Tuft"
        case .crown: "Crown"
        }
    }
}

/// Hand-authored bodies that sit outside the shape list: the HeyDot logo, earlier logo candidates,
/// and the v2 logo candidates (LogoV2.swift, review board only).
public enum DotSignature: String, Codable, CaseIterable, Sendable {
    case hey, heyWave, heyBubble
    case exclaim, perk, callOut, mic, sunrise
}

/// How Color is applied. flat vector default: ink body, colour in the eyes. Optional: colour body, ink eyes.
public enum DotFill: String, Codable, CaseIterable, Sendable {
    case inkBody, colorBody
}

public struct DotDesign: Codable, Equatable, Hashable, Sendable {
    public var shape: DotShape = .circle
    public var color: DotColor = .violet
    public var eyes: DotEyes = .oval
    public var glasses: DotGlasses = .none
    public var accessory: DotAccessory = .none
    public var accessoryColor: DotColor = .charcoal
    public var nickname: String = ""
    public var fill: DotFill = .colorBody
    /// When set, the body is a hand-authored mark instead of `shape`. Picking a shape clears it.
    public var signature: DotSignature?
    /// An imported avatar drawn instead of the dot (Design your dot > Custom avatar). Picking a shape clears it.
    public var custom: CustomArt?

    public init(shape: DotShape = .circle, color: DotColor = .violet, eyes: DotEyes = .oval, glasses: DotGlasses = .none,
                accessory: DotAccessory = .none, accessoryColor: DotColor = .charcoal, nickname: String = "",
                fill: DotFill = .colorBody, signature: DotSignature? = nil, custom: CustomArt? = nil) {
        self.shape = shape; self.color = color; self.eyes = eyes; self.glasses = glasses; self.accessory = accessory
        self.accessoryColor = accessoryColor; self.nickname = nickname; self.fill = fill; self.signature = signature
        self.custom = custom
    }

    /// The HeyDot logo: the dot as a microphone head in its cradle ("8. Open cradle", picked from the round-3 board).
    public static let `default` = DotDesign(fill: .colorBody, signature: .mic)
    /// The previous default (sound arcs). Saved designs equal to it load as the new default.
    static let previousDefault = DotDesign(fill: .inkBody, signature: .hey)

    public var isDefaultLogo: Bool { signature == .mic || signature == .hey || signature == .heyWave || signature == .heyBubble }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
