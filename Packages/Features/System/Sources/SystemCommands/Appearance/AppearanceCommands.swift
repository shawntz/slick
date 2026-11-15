import Kit

/// Toggle Dark Mode.
extension SystemFeature {
    var appearanceCommands: [Command] {
        [
            Command(
                id: "toggle-dark-mode", title: Strings.Appearance.title, icon: .symbol("circle.lefthalf.filled"),
                keywords: Strings.Appearance.keywords
            ) { _ in
                let appearance = self.appearance
                return try await SystemFailure.handle(Strings.Appearance.words) {
                    let dark = try await appearance.toggleDarkMode()
                    return .close(hud: HUD(dark ? Strings.Appearance.dark : Strings.Appearance.light))
                }
            }
        ]
    }
}
