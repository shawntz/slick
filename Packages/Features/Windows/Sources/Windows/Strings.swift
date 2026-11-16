/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Command, action, section, empty-state, toast and HUD titles, buttons and menu items use title
/// case, as macOS menus do. Everything else is a plain sentence.
nonisolated enum Strings {
    // MARK: - The feature

    static let featureName = "Window Management"
    static let summary = "Move and resize windows from the keyboard, and switch to any open window."
    static let accessibilityReason =
        "Move and resize the frontmost window, and list, focus, minimize and close open windows."

    // MARK: - Command titles

    static let leftHalf = "Left Half"
    static let rightHalf = "Right Half"
    static let topHalf = "Top Half"
    static let bottomHalf = "Bottom Half"
    static let topLeftQuarter = "Top Left Quarter"
    static let topRightQuarter = "Top Right Quarter"
    static let bottomLeftQuarter = "Bottom Left Quarter"
    static let bottomRightQuarter = "Bottom Right Quarter"
    static let firstThird = "First Third"
    static let centerThird = "Center Third"
    static let lastThird = "Last Third"
    static let firstTwoThirds = "First Two Thirds"
    static let centerTwoThirds = "Center Two Thirds"
    static let lastTwoThirds = "Last Two Thirds"
    static let maximize = "Maximize"
    static let almostMaximize = "Almost Maximize"
    static let maximizeHeight = "Maximize Height"
    static let maximizeWidth = "Maximize Width"
    static let center = "Center"
    static let restore = "Restore"
    static let makeLarger = "Make Larger"
    static let makeSmaller = "Make Smaller"
    static let moveLeft = "Move Left"
    static let moveRight = "Move Right"
    static let moveUp = "Move Up"
    static let moveDown = "Move Down"
    static let nextDisplay = "Next Display"
    static let previousDisplay = "Previous Display"
    static let toggleFullScreen = "Toggle Full Screen"
    static let switchWindows = "Switch Windows"

    /// The names a half takes as it cycles: two thirds, then one third. Step 0 is the command title.
    static func halfStep(_ edge: Edge, step: Int) -> String {
        switch (edge, step) {
        case (.left, 1): "Left Two Thirds"
        case (.left, 2): "Left Third"
        case (.right, 1): "Right Two Thirds"
        case (.right, 2): "Right Third"
        case (.top, 1): "Top Two Thirds"
        case (.top, 2): "Top Third"
        case (.bottom, 1): "Bottom Two Thirds"
        case (.bottom, 2): "Bottom Third"
        case (.left, _): leftHalf
        case (.right, _): rightHalf
        case (.top, _): topHalf
        case (.bottom, _): bottomHalf
        }
    }

    // MARK: - Search keywords

    static let windowKeywords = ["window", "snap", "tile", "layout"]
    static let displayKeywords = ["screen", "monitor"]
    static let maximizeKeywords = ["fill", "zoom"]
    static let restoreKeywords = ["undo", "reset"]
    static let sizeKeywords = ["resize", "grow", "shrink"]
    static let switchKeywords = ["windows", "focus", "go to window", "window switcher"]

    // MARK: - After a layout command

    static let noWindow = "The Frontmost App Has No Window"
    static let fullScreen = "Leave Full Screen to Move This Window"
    static let cannotMove = "This Window Cannot Be Moved"
    static let noDisplay = "No Display Shows This Window"
    static let onlyOneDisplay = "There Is Only One Display"
    static let nothingToRestore = "This Window Has No Earlier Frame to Restore"
    static let largest = "The Window Is as Large as It Can Be"
    static let smallest = "The Window Is as Small as It Can Be"
    static let fullScreenUnsupported = "This Window Cannot Go Full Screen"
    static let enteredFullScreen = "The Window Is Now Full Screen"
    static let exitedFullScreen = "The Window Has Left Full Screen"

    // MARK: - Errors

    static let accessibilityMissing = "Window Management Needs Accessibility"
    static let windowGone = "The Window Has Closed"
    static let refused = "The App Did Not Allow That Change"

    // MARK: - Switch Windows

    static let switchPlaceholder = "Search windows by title or app"
    static let windowsSection = "Open Windows"
    static let noWindowsTitle = "No Open Windows"
    static let noWindowsMessage = "Windows you open in any app show here."
    static let currentTag = "Current"
    static let minimizedTag = "Minimized"
    static let hiddenTag = "Hidden"
    static let switchToWindow = "Switch to Window"
    static let minimizeWindow = "Minimize Window"
    static let closeWindow = "Close Window"
    /// Names the window, so a list that went stale cannot close a window the user did not mean.
    /// Long titles are cut, since the card has room for a line or two.
    static func closeQuestion(title: String?, app: String?) -> String {
        if let title, !title.isEmpty {
            let shown = title.count > 50 ? title.prefix(49) + "\u{2026}" : Substring(title)
            return "Close \u{201C}\(shown)\u{201D}?"
        }
        if let app, !app.isEmpty { return "Close This \(app) Window?" }
        return "Close This Window?"
    }

    static func closeMessage(app: String?) -> String {
        guard let app, !app.isEmpty else { return "If it has unsaved changes, the app asks what to do with them." }
        return "If it has unsaved changes, \(app) asks what to do with them."
    }
    static let minimizedToast = "Minimized the Window"
    static let closedToast = "Closed the Window"
    static let needsAccessTitle = "Switch Windows Needs Accessibility"
    static let needsAccessMessage = "Grant Accessibility to list the windows of other apps."
    static let grantAccess = "Grant Access"

    // MARK: - Settings

    static let layoutSection = "Layout"
    static let windowGap = "Gap between windows"
    static let windowGapInfo = "Space between two windows that share a side."
    static let screenGap = "Gap at screen edges"
    static let screenGapInfo = "Space between a window and the edges of the screen, the menu bar and the Dock."
    static let almostMaximizeSize = "Almost Maximize size"
    static let almostMaximizeInfo = "How much of the screen Almost Maximize covers. The window stays centered."
    static let pointsUnit = "pt"
    static let percentUnit = "%"
    static let repeatSection = "Repeated Presses"
    static let repeatPicker = "When a half is pressed again"
    static let repeatInfo = "Applies to Left, Right, Top and Bottom Half when the window is already there."
    static let feedbackSection = "Feedback"
    static let showsLayoutName = "Show the layout name after each command"
    static let showsLayoutNameInfo = "A message always shows when a command cannot move the window."
    static let accessSection = "Access"
    static let accessInfo = "Window commands and Switch Windows need it to see and move other apps' windows."
    static let hotkeysSection = "Hotkeys"
    static let noHotkeysNote =
        "Window commands have no hotkeys until you add them. To use the shortcuts of another window manager, apply one of the presets above."
    static let turnOffNote =
        "If you already use a window manager, you can turn Window Management off as a whole in the Features pane."

    static func repeatTitle(_ behavior: RepeatBehavior) -> String {
        switch behavior {
        case .cycleSizes: "Cycle Through Two Thirds and One Third"
        case .moveAcrossDisplays: "Move to the Display on That Side"
        case .none: "Keep the Half"
        }
    }

    // MARK: - Hotkey presets

    static let rectanglePreset = "Rectangle and Magnet"
    static let spectaclePreset = "Spectacle"
}
