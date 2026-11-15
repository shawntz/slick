import Foundation
import Kit
import KitTesting
import Testing

@Suite("Settings picker confirmation", .timeLimit(.minutes(1)))
struct SettingConfirmationTests {
    nonisolated enum Retention: String, SettingValue, CaseIterable {
        case day, week, month

        var days: Int {
            switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            }
        }
    }

    nonisolated enum HistorySettings {
        static let retention = SettingKey("retention", default: Retention.month)
        static let maximum = SettingKey("maximum", default: 500)
    }

    /// A history whose shorter retention and lower cap delete at once.
    final class History: Feature {
        static let manifest = FeatureManifest(id: "history", name: "History", icon: .symbol("clock"))
        init(context: FeatureContext) {}

        static let shorter = Confirmation("Delete Older Items?", confirmTitle: "Delete", isDestructive: true)

        var settingsPane: SettingsPane? {
            SettingsPane(items: [
                .picker("Keep History For", key: HistorySettings.retention, titles: { $0.rawValue.capitalized }) {
                    stored, chosen in
                    chosen.days < stored.days ? Self.shorter : nil
                },
                .picker(
                    "Keep At Most", key: HistorySettings.maximum, options: [(100, "100"), (500, "500")]
                ) { stored, chosen in
                    chosen < stored ? Self.shorter : nil
                },
                .picker("Plain", key: SettingKey("plain", default: Retention.day)) { $0.rawValue },
            ])
        }
    }

    @Test func aShorterChoiceAsksAndIsStoredWhenConfirmed() throws {
        let harness = FeatureHarness(History.self)
        #expect(try harness.chooseSetting("Keep History For", option: "Week"))
        #expect(harness.confirmations == [History.shorter])
        #expect(harness.context.settings[HistorySettings.retention] == .week)
    }

    @Test func aDeclinedChoiceKeepsTheStoredValue() throws {
        let harness = FeatureHarness(History.self)
        harness.confirmationAnswer = false
        #expect(try !harness.chooseSetting("Keep History For", option: "Day"))
        #expect(harness.context.settings[HistorySettings.retention] == .month)
        #expect(harness.fakes.settings.values.isEmpty)
    }

    @Test func aChoiceThatLosesNothingDoesNotAsk() throws {
        let harness = FeatureHarness(History.self)
        harness.context.settings[HistorySettings.retention] = .day
        #expect(try harness.chooseSetting("Keep History For", option: "Week"))
        #expect(try harness.chooseSetting("Keep History For", option: "Week"))
        #expect(try harness.chooseSetting("Plain", option: "week"))
        #expect(harness.confirmations.isEmpty)
    }

    @Test func worksForOptionPickersToo() throws {
        let harness = FeatureHarness(History.self)
        #expect(try harness.chooseSetting("Keep At Most", option: "100"))
        #expect(harness.confirmations == [History.shorter])
        #expect(harness.context.settings[HistorySettings.maximum] == 100)
    }

    /// The settings window's view: the stored value as the service holds it.
    @Test func readsAMissingOrMistypedStoredValueAsTheDefault() throws {
        let item = try #require(FeatureHarness(History.self).feature.settingsPane?.sections.first?.items.first)
        #expect(item.confirmation(choosing: .string("week"), stored: nil) == History.shorter)
        #expect(item.confirmation(choosing: .string("week"), stored: .int(3)) == History.shorter)
        #expect(item.confirmation(choosing: .string("month"), stored: nil) == nil)
        #expect(item.confirmation(choosing: .string("week"), stored: .string("day")) == nil)
        #expect(SettingsItem.toggle("Toggle", key: SettingKey("t", default: true)).changeConfirmation == nil)
    }

    @Test func namesWhatItCannotFind() {
        let harness = FeatureHarness(History.self)
        #expect(throws: HarnessError.noSuchSettingsPicker("Missing")) {
            try harness.chooseSetting("Missing", option: "Day")
        }
        #expect(throws: HarnessError.noSuchOption("Year")) {
            try harness.chooseSetting("Keep History For", option: "Year")
        }
    }
}
