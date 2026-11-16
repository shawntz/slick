/// Every string of the feature that a person reads, in one place so it can be translated. Color
/// values, format names such as HSL, and code such as `NSColor(...)` are not translated.
nonisolated enum ColorStrings {
    // MARK: Feature and commands

    static let featureName = "Colors"
    static let summary = "Pick colors on screen, keep them, and convert colors you type between formats."
    static let accessibilityReason = "Paste a color into the frontmost app."
    static let pickCommand = "Pick Color"
    static let pickKeywords = ["color picker", "eyedropper", "sample color", "colour", "hex", "rgb"]
    static let historyCommand = "Color History"
    static let historyKeywords = ["colors", "colours", "swatches", "palette", "picked colors"]

    // MARK: Picking

    static func copied(_ text: String) -> String { "Copied \(text)" }
    static let unreadableTitle = "Could Not Read the Color"
    static let unreadableMessage = "The screen gave a color without red, green and blue values. Try another spot."

    // MARK: Formats

    static func formatTitle(_ format: ColorFormat) -> String {
        switch format {
        case .hex: "Hex"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .hsb: "HSB"
        case .hwb: "HWB"
        case .oklch: "OKLCH"
        case .swiftUI: "SwiftUI"
        case .appKit: "AppKit"
        case .cssVariable: "CSS Variable"
        }
    }

    static func copyAs(_ format: ColorFormat) -> String { "Copy as \(formatTitle(format))" }
    static func pasteAs(_ format: ColorFormat) -> String { "Paste as \(formatTitle(format))" }
    static let otherFormats = "Other Formats"

    // MARK: Typed colors and contrast

    static let outsideSRGB = "Outside sRGB"
    static let openHistory = "Open Color History"
    static func contrastSubtitle(_ foreground: String, _ background: String) -> String {
        "\(foreground) on \(background)"
    }
    static let copyRatio = "Copy Ratio"
    static let copyResult = "Copy Result"
    static let copiedResult = "Copied Contrast Result"
    static func contrastResult(_ ratio: String, normal: WCAGLevel, large: WCAGLevel) -> String {
        "\(ratio), \(levelText(normal)) for normal text, \(levelText(large)) for large text"
    }

    // MARK: WCAG

    static func levelText(_ level: WCAGLevel) -> String {
        switch level {
        case .fail: "fails"
        case .aa: "AA"
        case .aaa: "AAA"
        }
    }

    static func normalTag(_ level: WCAGLevel) -> String {
        level == .fail ? "Normal Text Fails" : "Normal Text \(levelText(level))"
    }

    static func largeTag(_ level: WCAGLevel) -> String {
        level == .fail ? "Large Text Fails" : "Large Text \(levelText(level))"
    }

    // MARK: History page

    static let historyPlaceholder = "Search colors"
    static let pinnedSection = "Pinned"
    static let emptyTitle = "No Colors Yet"
    static let emptyMessage = "Pick a color on screen, or copy a color you type in root search, such as #663399."
    static let colorNotFound = "Color Not Found"
    static let colorNotFoundMessage = "The color is no longer in the history."

    // MARK: Detail

    static let nameLabel = "Name"
    static let cssNameLabel = "CSS Name"
    static let contrastOnWhite = "Contrast on White"
    static let contrastOnBlack = "Contrast on Black"
    static let wcagOnWhite = "WCAG on White"
    static let wcagOnBlack = "WCAG on Black"
    static let gamutLabel = "Gamut"
    static let gamutOutside = "Outside sRGB. Every format shows the nearest sRGB color."
    static let extendedLabel = "Extended sRGB"
    static let sourceLabel = "Source"
    static let sourcePicked = "Picked on screen"
    static let sourceTyped = "Typed in root search"
    static let addedLabel = "Added"

    // MARK: History actions

    static let pin = "Pin Color"
    static let unpin = "Unpin Color"
    static func pinnedToast(_ title: String) -> String { "Pinned \(title)" }
    static func unpinnedToast(_ title: String) -> String { "Unpinned \(title)" }
    static let rename = "Name This Color"
    static let renameField = "Name"
    static let renamePlaceholder = "Brand blue"
    static let renameInfo =
        "Shown instead of the hex value, and used for the CSS variable. Leave it empty to remove it."
    static let renameSubmit = "Save Name"
    static func nameTooLong(_ limit: Int) -> String { "Use \(limit) characters or fewer." }
    static let renamedToast = "Saved Name"
    static let removedNameToast = "Removed Name"
    static let delete = "Delete Color"
    static func deleteQuestion(_ title: String) -> String { "Delete “\(title)” from History?" }
    static let deleteMessage = "The color, its name and its pin are deleted."
    static let deleteConfirm = "Delete"
    static let deletedToast = "Deleted Color"
    static let clearHistory = "Clear History"
    static let clearQuestion = "Clear Color History?"
    static let clearMessage = "Deletes every color in the history except pinned ones."
    static let clearConfirm = "Clear History"
    static let clearedToast = "Cleared Color History"

    // MARK: Settings

    static let formatsSection = "Formats"
    static let defaultFormat = "Default format"
    static let defaultFormatInfo = "Return copies this format, Pick Color copies it, and typed colors show it first."
    static func defaultFormatOption(_ format: ColorFormat) -> String {
        "\(formatTitle(format)), \(sampleText(format))"
    }
    static let hexCase = "Hex digits"
    static func hexCaseOption(_ hexCase: HexCase) -> String {
        hexCase == .uppercase ? "Uppercase, #66CC99" : "Lowercase, #66cc99"
    }
    static let rootSection = "Root Search"
    static let convertsTypedColors = "Convert colors you type"
    static let convertsTypedColorsInfo =
        "Type #663399, rgb(102 51 153), hsl, hwb or oklch, or color and a CSS name, such as color rebeccapurple. "
        + "Type contrast and two colors for the WCAG ratio."
    static let historySection = "History"
    static let historyLimit = "Keep at most"
    static func historyLimitOption(_ count: Int) -> String { "\(count) Colors" }
    static let historyLimitInfo =
        "Pinned colors are always kept. A smaller number asks first, then deletes the oldest colors."
    static func limitQuestion(_ count: Int) -> String { "Keep Only \(count) Colors?" }
    static func limitMessage(_ count: Int) -> String {
        "Deletes the oldest colors past \(count) at once. Pinned colors stay."
    }
    static let limitConfirm = "Delete Older Colors"
    static func historyFooter(appName: String) -> String {
        "Colors are kept in a file on this Mac. \(appName) sends nothing anywhere."
    }

    // MARK: Status

    static let readOnlyTitle = "Color History Is Read Only"
    static let readOnlyMessage =
        "The history file comes from a newer version, so changes are shown but not saved. Update to keep them."

    /// The sample each format shows in the default format picker.
    private static func sampleText(_ format: ColorFormat) -> String {
        switch format {
        case .hex: "#663399"
        case .rgb: "rgb(102 51 153)"
        case .hsl: "hsl(270 50% 40%)"
        case .hsb: "hsb(270 66.7% 60%)"
        case .hwb: "hwb(270 20% 40%)"
        case .oklch: "oklch(44.03% 0.1603 303.37)"
        case .swiftUI: "Color(red: 0.4, …)"
        case .appKit: "NSColor(srgbRed: 0.4, …)"
        case .cssVariable: "--color-663399"
        }
    }
}
