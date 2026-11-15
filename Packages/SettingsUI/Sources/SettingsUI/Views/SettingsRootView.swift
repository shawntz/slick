import SwiftUI

/// The settings window: a sidebar of panes and the selected pane.
struct SettingsRootView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPaneID.allCases, selection: $model.selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            SettingsPaneView(model: model, pane: model.selection ?? .general)
                .navigationTitle((model.selection ?? .general).title)
        }
        .overlay(alignment: .bottom) {
            ToastBanner(center: model.toasts)
                .animation(.snappy, value: model.toasts.current?.id)
        }
        .confirmations(model.confirmations)
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// One pane by its ID.
struct SettingsPaneView: View {
    let model: SettingsModel
    let pane: SettingsPaneID

    var body: some View {
        switch pane {
        case .general: GeneralPane(model: model.general)
        case .appearance: AppearancePane(model: model.appearance)
        case .rootSearch: RootSearchPane(model: model.rootSearch, icons: model.context.icons)
        case .features: FeaturesPane(model: model.features, icons: model.context.icons)
        case .permissions: PermissionsPane(model: model.permissions)
        case .learning: LearningPane(model: model.learning, icons: model.context.icons)
        case .advanced: AdvancedPane(model: model.advanced)
        case .about: AboutPane(model: model.about)
        }
    }
}
