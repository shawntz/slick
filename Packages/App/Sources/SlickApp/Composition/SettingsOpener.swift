import Kit
import SettingsUI

/// Opens the settings window, or in runs that must not show windows, writes down what would have
/// opened. Command-comma, the menu bar item and deep links all come through here.
@MainActor final class SettingsOpener {
    /// What was asked to open, for scenarios and tests.
    enum Request: Equatable {
        case pane(SettingsPaneID?)
        case feature(String)
    }

    private let makeController: () -> SettingsController
    private let showsWindows: Bool
    private let onOpen: () -> Void
    private var controller: SettingsController?
    /// Every request so far, oldest first, while the window stays closed. The live app, which
    /// shows the window, keeps none.
    private(set) var requests: [Request] = []

    /// - Parameters:
    ///   - showsWindows: False keeps the window closed and only records requests. Only the live
    ///     launcher shows it, because showing it activates the app.
    ///   - onOpen: Runs on every request, shown or recorded, such as a check of the launcher
    ///     hotkey while it waits behind a macOS shortcut.
    ///   - makeController: Makes the controller on first use.
    init(
        showsWindows: Bool, onOpen: @escaping () -> Void = {},
        makeController: @escaping () -> SettingsController
    ) {
        self.showsWindows = showsWindows
        self.onOpen = onOpen
        self.makeController = makeController
    }

    /// The controller if one was made, without making one.
    var existingController: SettingsController? { controller }

    /// The controller, made on first use.
    var settingsController: SettingsController {
        if let controller { return controller }
        let made = makeController()
        controller = made
        return made
    }

    func open(_ pane: SettingsPaneID? = nil) {
        onOpen()
        guard showsWindows else {
            requests.append(.pane(pane))
            return
        }
        settingsController.show(pane)
    }

    func openFeature(_ featureID: String) {
        onOpen()
        guard showsWindows else {
            requests.append(.feature(featureID))
            return
        }
        settingsController.showFeature(featureID)
    }
}
