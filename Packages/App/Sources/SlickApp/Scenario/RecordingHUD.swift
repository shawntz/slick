import Host
import Kit
import LauncherUI

/// Where HUDs go outside the live app: written down, never shown. A HUD window would appear in the
/// middle of the screen, away from the corner where scenarios and benches keep the panel.
@MainActor final class RecordingHUD: HUDDisplay {
    /// Every HUD shown so far, oldest first.
    private(set) var shown: [HUD] = []

    func show(_ hud: HUD) {
        shown.append(hud)
    }

    func prewarm() {}

    func apply(_ theme: Theme) {}
}
