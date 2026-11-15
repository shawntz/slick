import AppKit

/// A colour in a theme: a system colour or an sRGB value, with an alpha.
///
/// It encodes as one short string so theme files stay readable: `"label"`, `"secondaryLabel@0.9"`,
/// `"#1E90FF"` or `"#000000@0.35"`. System colours follow the appearance they are resolved in, so
/// `"label"` is near black in light mode and near white in dark mode.
nonisolated public struct ThemeColor: Sendable, Equatable, Hashable {
    /// The system colours a theme can name. Each resolves through the matching `NSColor`.
    public enum System: String, Sendable, CaseIterable, Codable {
        case label, secondaryLabel, tertiaryLabel, quaternaryLabel
        case separator, accent, white, black
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray
    }

    /// Where the colour comes from before alpha is applied.
    public enum Source: Sendable, Equatable, Hashable {
        case system(System)
        case srgb(red: Double, green: Double, blue: Double)
    }

    public var source: Source
    /// Multiplies the source colour's own alpha.
    public var alpha: Double

    public init(_ system: System, alpha: Double = 1) {
        source = .system(system)
        self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        source = .srgb(red: red, green: green, blue: blue)
        self.alpha = alpha
    }

    /// The same colour with its alpha multiplied by `factor`.
    public func scaled(by factor: Double) -> ThemeColor {
        var copy = self
        copy.alpha = min(1, max(0, alpha * factor))
        return copy
    }

    /// The colour as AppKit sees it. Semantic colours stay dynamic until drawn.
    @MainActor public var nsColor: NSColor {
        let base: NSColor
        switch source {
        case .system(let system): base = system.nsColor
        case .srgb(let red, let green, let blue):
            base = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        return alpha >= 1 ? base : base.withAlphaComponent(base.alphaComponent * alpha)
    }

    /// The colour resolved for `appearance`, ready for Core Graphics and Core Text.
    @MainActor public func cgColor(in appearance: NSAppearance) -> CGColor {
        var resolved = CGColor(gray: 0, alpha: 1)
        appearance.performAsCurrentDrawingAppearance { resolved = nsColor.cgColor }
        return resolved
    }
}

extension ThemeColor.System {
    @MainActor fileprivate var nsColor: NSColor {
        switch self {
        case .label: .labelColor
        case .secondaryLabel: .secondaryLabelColor
        case .tertiaryLabel: .tertiaryLabelColor
        case .quaternaryLabel: .quaternaryLabelColor
        case .separator: .separatorColor
        case .accent: .controlAccentColor
        case .white: .white
        case .black: .black
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }
}

// MARK: - String form

extension ThemeColor: Codable, CustomStringConvertible, LosslessStringConvertible {
    /// Parses `"name"`, `"name@alpha"`, `"#RRGGBB"` or `"#RRGGBB@alpha"`.
    public init?(_ description: String) {
        let parts = description.split(separator: "@", maxSplits: 1).map(String.init)
        guard let head = parts.first, !head.isEmpty else { return nil }
        var alpha = 1.0
        if parts.count == 2 {
            guard let value = Double(parts[1]), (0...1).contains(value) else { return nil }
            alpha = value
        }
        if head.hasPrefix("#") {
            let hex = head.dropFirst()
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                alpha: alpha
            )
        } else {
            guard let system = System(rawValue: head) else { return nil }
            self.init(system, alpha: alpha)
        }
    }

    public var description: String {
        let head: String
        switch source {
        case .system(let system): head = system.rawValue
        case .srgb(let red, let green, let blue):
            let bytes = [red, green, blue].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
            head =
                "#"
                + bytes.map { byte in
                    let hex = String(byte, radix: 16, uppercase: true)
                    return hex.count == 1 ? "0" + hex : hex
                }.joined()
        }
        if alpha >= 1 { return head }
        return head + "@" + String(format: "%g", (alpha * 1000).rounded() / 1000)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ThemeColor(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a theme colour: \(text)")
            )
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
