import Kit
import KitHosting
import Testing

/// The updater of a build that cannot update itself, which every run but the live launcher uses.
@Suite(.timeLimit(.minutes(1))) struct UpdateControlTests {
    @Test func noUpdatesOffersNothingAndStaysOff() {
        let updates: any UpdateControl = NoUpdates()
        #expect(!updates.isAvailable)
        #expect(!updates.checksAutomatically)
        #expect(updates.lastCheck == nil)
        #expect(updates.waitingVersion == nil)
        #expect(!updates.canCheckNow)
    }

    @Test func noUpdatesIgnoresThePersonsSwitchAndTheCheckButton() {
        let updates = NoUpdates()
        let generation = updates.changes.generation
        updates.setChecksAutomatically(true)
        updates.checkNow()
        #expect(!updates.checksAutomatically, "a build from source never checks on its own")
        #expect(updates.lastCheck == nil, "nothing was checked")
        #expect(updates.changes.generation == generation, "nothing changed, so nothing is signalled")
    }
}
