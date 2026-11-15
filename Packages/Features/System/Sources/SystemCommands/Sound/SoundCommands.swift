import Kit

/// Mute, Unmute, Toggle Mute, Volume Up, Volume Down and Set Volume.
///
/// Each command reads the device first, so a device without a volume control or a mute switch gets
/// a sentence that says so. Raising the volume unmutes, as the volume keys do. Runs are serial, so
/// fast repeated presses of Volume Up each start from the level the last one set.
extension SystemFeature {
    var soundCommands: [Command] {
        [
            Command(
                id: "mute", title: Strings.Sound.mute, icon: .symbol("speaker.slash"),
                keywords: Strings.Sound.muteKeywords
            ) {
                _ in
                try await self.setMuted { _ in true }
            },
            Command(
                id: "unmute", title: Strings.Sound.unmute, icon: .symbol("speaker.wave.2"),
                keywords: Strings.Sound.unmuteKeywords
            ) { _ in
                try await self.setMuted { _ in false }
            },
            Command(
                id: "toggle-mute", title: Strings.Sound.toggleMute, icon: .symbol("speaker"),
                keywords: Strings.Sound.toggleMuteKeywords
            ) { _ in
                try await self.setMuted { !$0 }
            },
            Command(
                id: "volume-up", title: Strings.Sound.volumeUp, icon: .symbol("speaker.plus"),
                keywords: Strings.Sound.volumeUpKeywords
            ) { context in
                let divisions = context.settings[SystemSettings.volumeStep].divisions
                return try await self.changeVolume { VolumeLevel.stepped($0, divisions: divisions, up: true) }
            },
            Command(
                id: "volume-down", title: Strings.Sound.volumeDown, icon: .symbol("speaker.minus"),
                keywords: Strings.Sound.volumeDownKeywords
            ) { context in
                let divisions = context.settings[SystemSettings.volumeStep].divisions
                return try await self.changeVolume { VolumeLevel.stepped($0, divisions: divisions, up: false) }
            },
            Command(
                id: "set-volume", title: Strings.Sound.setVolume, icon: .symbol("speaker.wave.3"),
                keywords: Strings.Sound.setVolumeKeywords,
                arguments: [CommandArgument("level", placeholder: Strings.Sound.levelPlaceholder)]
            ) { context in
                guard let level = VolumeLevel.parse(context.arguments["level"] ?? "") else {
                    throw ActionFailure(Strings.Sound.invalidLevel, message: Strings.Sound.invalidLevelHint)
                }
                return try await self.changeVolume { _ in level }
            },
        ]
    }

    /// Reads the device, or says plainly that there is none to change.
    private func soundState() async throws -> SoundState {
        do {
            return try await sound.state()
        } catch SystemFailure.unavailable {
            throw ActionFailure(Strings.Sound.noOutput)
        }
    }

    /// Sets the mute switch to what `next` makes of the current state.
    private func setMuted(_ next: @Sendable (Bool) -> Bool) async throws -> ActionOutcome {
        let sound = sound
        let state = try await soundState()
        guard let muted = state.isMuted else { throw ActionFailure(Strings.Sound.cannotMute) }
        let mute = next(muted)
        return try await SystemFailure.handle(Strings.Sound.muteWords) {
            try await sound.setMuted(mute)
            return .close(hud: HUD(mute ? Strings.Sound.muted : Strings.Sound.unmuted))
        }
    }

    /// Sets the volume to what `next` makes of the current level, and unmutes when the new level is
    /// above zero.
    private func changeVolume(_ next: @Sendable (Double) -> Double) async throws -> ActionOutcome {
        let sound = sound
        let state = try await soundState()
        guard let volume = state.volume else { throw ActionFailure(Strings.Sound.noVolumeControl) }
        let level = min(1, max(0, next(volume)))
        return try await SystemFailure.handle(Strings.Sound.volumeWords) {
            try await sound.setVolume(level)
            if level > 0, state.isMuted == true {
                try await sound.setMuted(false)
            }
            return .close(hud: HUD(Strings.Sound.volume(VolumeLevel.percent(level))))
        }
    }
}
