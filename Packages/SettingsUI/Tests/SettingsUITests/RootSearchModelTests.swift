import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import SettingsUI

@MainActor @Suite(.timeLimit(.minutes(1))) struct RootSearchModelTests {
    @Test func togglesAndCounts() {
        let bed = TestBed()
        let model = RootSearchModel(context: bed.context())
        model.showSuggestions = false
        model.suggestionCount = 50
        model.showFavorites = false
        model.inlineCompletion = false
        #expect(!bed.general[HostSettings.showSuggestions])
        #expect(bed.general[HostSettings.suggestionCount] == RootSearchModel.suggestionRange.upperBound)
        #expect(!bed.general[HostSettings.showFavorites])
        #expect(!bed.general[HostSettings.inlineCompletion])
    }

    @Test func favoritesKeepTheUsersOrder() {
        let bed = TestBed()
        let app = ItemID("app", "com.example.notes")
        bed.lookUp[app] = Row(id: app, title: "Example Notes")
        bed.preferences.setFavorites([TestBed.open, app, TestBed.list])
        let model = RootSearchModel(context: bed.context())
        #expect(model.favorites.map(\.title) == ["Open Sample", "Example Notes", "List Samples"])
        model.moveFavorite(TestBed.list, by: -1)
        #expect(bed.preferences.favorites == [TestBed.open, TestBed.list, app])
        model.moveFavorites(from: [0], to: 3)
        #expect(bed.preferences.favorites == [TestBed.list, app, TestBed.open])
        model.removeFavorite(app)
        #expect(bed.preferences.favorites == [TestBed.list, TestBed.open])
    }

    @Test func unknownItemsShowTheirID() {
        let bed = TestBed()
        let file = ItemID("file", "/tmp/example.txt")
        bed.preferences.setFavorites([file])
        let model = RootSearchModel(context: bed.context())
        #expect(model.favorites.first?.title == file.rawValue)
        #expect(model.favorites.first?.isAvailable == true)
    }

    @Test func fallbacksListEveryFeatureThatIsOnWithASwitchEachThroughItemPreferences() async {
        let bed = TestBed()
        let model = RootSearchModel(context: bed.context())
        // The helper feature is off, so only the sample's fallback is listed. It starts off, as a
        // declared fallback does.
        #expect(model.fallbacks.map(\.id) == [TestBed.open])
        #expect(model.fallbacks.map(\.isOn) == [false])
        #expect(model.fallbacks.first?.item.title == "Open Sample")

        model.setFallback(TestBed.open, isOn: true)
        #expect(bed.preferences.fallbackChoices.switches == [TestBed.open: true])
        #expect(model.fallbacks.map(\.isOn) == [true])
        // Root search reads the same list.
        #expect(bed.directory.fallbacks(bed.preferences.fallbackChoices).map(\.isOn) == [true])

        // A feature turned on brings its fallback, after the ones the user placed.
        await bed.preferences.setEnabled(true, feature: "helper")
        #expect(model.fallbacks.map(\.id) == [TestBed.open, TestBed.show])
        model.moveFallback(TestBed.show, by: -1)
        #expect(model.fallbacks.map(\.id) == [TestBed.show, TestBed.open])
        #expect(bed.preferences.fallbackChoices.order == [TestBed.show, TestBed.open])
        model.moveFallbacks(from: [0], to: 2)
        #expect(model.fallbacks.map(\.id) == [TestBed.open, TestBed.show])
        model.moveFallback(TestBed.open, by: -1)
        #expect(model.fallbacks.map(\.id) == [TestBed.open, TestBed.show])

        // The old setting is neither read nor written.
        #expect(bed.general[HostSettings.fallbackCommands].isEmpty)
        bed.general[HostSettings.fallbackCommands] = [TestBed.show.rawValue]
        #expect(model.fallbacks.map(\.id) == [TestBed.open, TestBed.show])
        #expect(model.fallbacks.map(\.isOn) == [true, false])
    }

    @Test func tabCommand() {
        let bed = TestBed()
        let model = RootSearchModel(context: bed.context())
        #expect(model.tabCommand == nil)
        #expect(model.tabCandidates.map(\.id) == [TestBed.open])
        model.tabCommand = TestBed.open
        #expect(bed.general[HostSettings.tabCommand] == TestBed.open.rawValue)
        // A stored command that no longer qualifies still shows, so the picker has a value.
        bed.general[HostSettings.tabCommand] = TestBed.list.rawValue
        #expect(model.tabCandidates.map(\.id) == [TestBed.open, TestBed.list])
        model.tabCommand = nil
        #expect(bed.general[HostSettings.tabCommand] == "")
    }
}
