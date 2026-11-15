import Kit
import KitHosting
import Observation

/// The features pane: every registered feature with its switch, and a page per feature.
@Observable final class FeaturesModel {
    /// One feature as the list shows it.
    struct Summary: Identifiable {
        var id: String
        var name: String
        var summary: String
        var icon: Icon
        var isEnabled: Bool
        var status: FeatureStatus?
        var commandCount: Int
    }

    @ObservationIgnored private let context: SettingsContext
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private var pages: [String: FeatureDetailModel] = [:]
    private let revision = Revision()
    /// The feature pages pushed in the pane, by feature ID.
    var path: [String] = []

    init(context: SettingsContext) {
        self.context = context
        tasks.follow(context.directory.changes, bumping: revision)
        tasks.follow(context.preferences.changes, bumping: revision)
    }

    /// Every feature in registration order.
    var features: [Summary] {
        revision.track()
        return context.directory.features.map { entry in
            Summary(
                id: entry.id, name: entry.manifest.name, summary: entry.manifest.summary, icon: entry.manifest.icon,
                isEnabled: entry.isEnabled, status: entry.status, commandCount: entry.commands.count)
        }
    }

    /// The user's switch for a feature.
    func isEnabled(_ featureID: String) -> Bool {
        revision.track()
        return context.preferences.isEnabled(feature: featureID)
    }

    /// Turns a feature on or off and waits until the runtime has activated or deactivated it.
    func setEnabled(_ enabled: Bool, feature featureID: String) async {
        await context.preferences.setEnabled(enabled, feature: featureID)
        revision.bump()
    }

    /// The page model for a feature, made once and kept while the window lives.
    func page(_ featureID: String) -> FeatureDetailModel {
        if let page = pages[featureID] { return page }
        let page = FeatureDetailModel(featureID: featureID, context: context)
        pages[featureID] = page
        return page
    }

    /// Shows a feature's page.
    func open(_ featureID: String) {
        path = [featureID]
    }
}
