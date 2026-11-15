import AppKit

/// A system font at a size and weight. Encodes as `{"size": 14.5, "weight": "medium"}`.
nonisolated public struct ThemeFont: Codable, Sendable, Equatable, Hashable {
    /// The weights a theme can name, mapped onto `NSFont.Weight`.
    public enum Weight: String, Codable, Sendable, CaseIterable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

        var nsWeight: NSFont.Weight {
            switch self {
            case .ultraLight: .ultraLight
            case .thin: .thin
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            case .black: .black
            }
        }
    }

    /// The system font's designs a theme can name.
    public enum Design: String, Codable, Sendable, CaseIterable {
        /// Fixed-width digits and letters, for code and terminal output.
        case monospaced
        case rounded
    }

    public var size: Double
    public var weight: Weight
    /// Nil is the standard system design. Omitted from theme files when nil.
    public var design: Design?

    public init(size: Double, weight: Weight = .regular, design: Design? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
    }

    /// The system font with these attributes. Bridged toll-free to `CTFont`.
    @MainActor public var nsFont: NSFont {
        switch design {
        case nil: .systemFont(ofSize: CGFloat(size), weight: weight.nsWeight)
        case .monospaced: .monospacedSystemFont(ofSize: CGFloat(size), weight: weight.nsWeight)
        case .rounded:
            NSFont.systemFont(ofSize: CGFloat(size), weight: weight.nsWeight).fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: CGFloat(size)) }
                ?? .systemFont(ofSize: CGFloat(size), weight: weight.nsWeight)
        }
    }

    /// The same font for Core Text.
    @MainActor public var ctFont: CTFont { nsFont as CTFont }
}
