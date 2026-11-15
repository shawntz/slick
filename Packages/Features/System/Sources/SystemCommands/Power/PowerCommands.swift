import Kit

/// Sleep, Sleep Displays, Lock Screen, Start Screen Saver, Log Out, Restart and Shut Down.
extension SystemFeature {
    var powerCommands: [Command] {
        [
            immediate(
                .sleep, id: "sleep", title: Strings.Power.sleep, icon: "moon.zzz", keywords: Strings.Power.sleepKeywords
            ),
            immediate(
                .sleepDisplays, id: "sleep-displays", title: Strings.Power.sleepDisplays, icon: "display",
                keywords: Strings.Power.sleepDisplaysKeywords),
            immediate(
                .lockScreen, id: "lock-screen", title: Strings.Power.lockScreen, icon: "lock",
                keywords: Strings.Power.lockScreenKeywords),
            immediate(
                .startScreenSaver, id: "start-screen-saver", title: Strings.Power.startScreenSaver, icon: "sparkles",
                keywords: Strings.Power.startScreenSaverKeywords),
            session(
                .logOut, id: "log-out", title: Strings.Power.logOut, icon: "rectangle.portrait.and.arrow.right",
                keywords: Strings.Power.logOutKeywords, question: Strings.Power.logOutQuestion,
                done: Strings.Power.loggingOut),
            session(
                .restart, id: "restart", title: Strings.Power.restart, icon: "arrow.clockwise",
                keywords: Strings.Power.restartKeywords, question: Strings.Power.restartQuestion,
                done: Strings.Power.restarting),
            session(
                .shutDown, id: "shut-down", title: Strings.Power.shutDown, icon: "power",
                keywords: Strings.Power.shutDownKeywords, question: Strings.Power.shutDownQuestion,
                done: Strings.Power.shuttingDown),
        ]
    }

    /// A command that acts at once. The panel closes first, so it is not on screen when the Mac
    /// wakes, the screen unlocks or the screen saver ends. A failure then shows as a HUD. A request
    /// this Mac cannot do at all says so first, in a toast with the panel still open.
    private func immediate(
        _ request: PowerRequest, id: String, title: String, icon: String, keywords: [String]
    ) -> Command {
        let power = power
        return Command(
            id: id, title: title, icon: .symbol(icon), keywords: keywords, runPolicy: .dropWhileRunning
        ) { context in
            try await SystemFailure.handle(Strings.Power.words(for: request)) {
                try await power.checkAvailable(request)
                context.dismiss()
                try await power.perform(request)
                return .close()
            }
        }
    }

    /// A command that ends the session. It always asks first and offers no way to stop asking. The
    /// panel stays until the request is sent, so the host can show its permission card if macOS
    /// wants one.
    private func session(
        _ request: PowerRequest, id: String, title: String, icon: String, keywords: [String], question: String,
        done: String
    ) -> Command {
        let power = power
        return Command(
            id: id, title: title, icon: .symbol(icon), keywords: keywords,
            confirmation: Confirmation(
                question, message: Strings.Power.sessionMessage, confirmTitle: title, isDestructive: true),
            runPolicy: .dropWhileRunning
        ) { _ in
            try await SystemFailure.handle(Strings.Power.words(for: request)) {
                try await power.perform(request)
                return .close(hud: HUD(done))
            }
        }
    }
}
