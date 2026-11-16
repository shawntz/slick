import Kit
import KitHosting
import Observation

/// The panes of the settings window, in sidebar order.
public enum SettingsPaneID: String, CaseIterable, Identifiable, Sendable {
    case general
    case appearance
    case rootSearch
    case features
    case permissions
    case learning
    case advanced
    case about

    public var id: String { rawValue }

    /// The pane's name in the sidebar and the window title.
    public var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .rootSearch: "Root Search"
        case .features: "Features"
        case .permissions: "Permissions"
        case .learning: "Learning"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .rootSearch: "magnifyingglass"
        case .features: "square.grid.2x2"
        case .permissions: "hand.raised"
        case .learning: "brain"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

/// The settings window's state: the selected pane and one model per pane.
@Observable final class SettingsModel {
    var selection: SettingsPaneID? = .general
    @ObservationIgnored let context: SettingsContext
    @ObservationIgnored let general: GeneralModel
    @ObservationIgnored let appearance: AppearanceModel
    @ObservationIgnored let rootSearch: RootSearchModel
    @ObservationIgnored let features: FeaturesModel
    @ObservationIgnored let permissions: PermissionsModel
    @ObservationIgnored let learning: LearningModel
    @ObservationIgnored let advanced: AdvancedModel
    @ObservationIgnored let about: AboutModel

    init(dependencies: SettingsDependencies) {
        let context = SettingsContext(dependencies)
        self.context = context
        general = GeneralModel(context: context)
        appearance = AppearanceModel(context: context)
        rootSearch = RootSearchModel(context: context)
        features = FeaturesModel(context: context)
        permissions = PermissionsModel(context: context)
        learning = LearningModel(context: context)
        advanced = AdvancedModel(context: context)
        about = AboutModel(info: dependencies.about, context: context)
    }

    var toasts: ToastCenter { context.toasts }
    var confirmations: ConfirmationCenter { context.confirmations }

    /// Shows a pane.
    func show(_ pane: SettingsPaneID) {
        selection = pane
    }

    /// Shows a feature's page in the features pane.
    func showFeature(_ featureID: String) {
        selection = .features
        features.open(featureID)
    }
}
