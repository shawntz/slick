import Foundation
import Kit
import KitHosting

/// Makes the updater for one run.
///
/// Sparkle's updater exists in one case only: the live launcher, started from a bundle whose
/// Info.plist carries a feed address and a public key. Scenarios, the selftest, benchmarks, every
/// test and every build without a feed get ``KitHosting/NoUpdates``, and no Sparkle object is made.
public enum Updates {
    /// The updater for a run in `environment` from `bundle`. `remindsInMenu` says whether the menu
    /// bar menu can offer an update a scheduled check found, which it can while the menu bar item is
    /// shown. When it cannot, Sparkle shows the update in its own window.
    public static func make(
        environment: RunEnvironment, bundle: Bundle, remindsInMenu: @escaping @MainActor () -> Bool
    ) -> any UpdateControl {
        make(environment: environment, info: bundle.infoDictionary ?? [:]) { configuration in
            SparkleUpdates(bundle: bundle, configuration: configuration, remindsInMenu: remindsInMenu)
        }
    }

    /// The decision behind ``make(environment:bundle:remindsInMenu:)``, with the step that builds
    /// Sparkle's updater passed in, so tests can prove when it runs without running it.
    static func make(
        environment: RunEnvironment, info: [String: Any],
        build: (UpdateConfiguration) -> any UpdateControl
    ) -> any UpdateControl {
        guard environment == .live, let configuration = UpdateConfiguration(info: info) else { return NoUpdates() }
        return build(configuration)
    }
}
