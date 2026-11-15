import Foundation
import Kit
import KitTesting
import Testing

@testable import Apps

@Suite("System Settings panes", .timeLimit(.minutes(1)))
struct SettingsPaneTests {
    @Test func findsPanesThatAllowDeepLinksSortedByName() async throws {
        let panes = try await AppTree().library().settingsPanes()
        #expect(panes.map(\.name) == ["Battery", "Network", "Sound"], "a widget and a locked pane are skipped")
    }

    @Test func takesNamesFromTheSystemInTheUsersLanguage() async throws {
        let panes = try await AppTree().library(languages: ["de"]).settingsPanes()
        #expect(panes.map(\.name) == ["Batterie", "Network", "Ton"])
    }

    @Test func anchorsComeFromSearchTermsWithTheirOtherTitlesAndIndexWords() async throws {
        let network = try #require(try await AppTree().library().settingsPanes().first { $0.name == "Network" })
        #expect(network.anchors.map(\.id) == ["Advanced Ethernet", "DNS"], "an anchor titled like its pane is dropped")
        let dns = try #require(network.anchors.last)
        #expect(dns.title == "DNS servers")
        #expect(dns.keywords == ["Name servers", "dns", "domain", "resolver"])
    }

    @Test func capsTheIndexWordsOfOneAnchor() {
        let words = (1...40).map { "word\($0)" }.joined(separator: ", ")
        let terms: [String: Any] = ["Big": ["localizableStrings": [["title": "Big section", "index": words]]]]
        let anchors = SettingsPaneScanner.anchors(from: terms, paneName: "Pane")
        #expect(anchors.first?.keywords.count == SettingsPaneScanner.keywordLimit)
    }

    @Test func deepLinksNameThePaneAndPercentEncodeTheAnchor() {
        #expect(
            SettingsLink.url(forKey: "com.example.pane")?.absoluteString == "x-apple.systempreferences:com.example.pane"
        )
        #expect(
            SettingsLink.url(forKey: SettingsLink.key(pane: "com.example.pane", anchor: "Privacy_Accessibility"))?
                .absoluteString == "x-apple.systempreferences:com.example.pane?Privacy_Accessibility")
        #expect(
            SettingsLink.url(forKey: "com.example.pane?Advanced Ethernet")?.absoluteString
                == "x-apple.systempreferences:com.example.pane?Advanced%20Ethernet")
        #expect(SettingsLink.url(forKey: "") == nil)
    }

    @Test @MainActor func everyPaneAndAnchorIsARootRowThatOpensItsLink() async throws {
        let apps = try await AppsHarness()
        let rows = try await apps.settingRows()
        #expect(
            rows.map(\.title) == [
                "Battery", "Network", "Ethernet options", "DNS servers", "Sound", "Output device",
            ])
        let dns = try #require(rows.first { $0.title == "DNS servers" })
        #expect(dns.subtitle == "System Settings › Network")
        #expect(dns.memory == .learnOnly)
        #expect(dns.icon == .file(path: apps.tree.path("Extensions/Network.appex")))
        #expect(rows.first?.icon == .app(bundleID: "com.apple.systempreferences"), "Battery has no icon of its own")
        try await apps.harness.performRoot("open", on: dns)
        #expect(
            apps.fakes.workspace.opened.map(\.absoluteString) == [
                "x-apple.systempreferences:com.example.network-settings?DNS"
            ])
        #expect(apps.harness.isClosed)
        #expect(apps.unexpectedIssues.isEmpty)
    }

    @Test @MainActor func copiesTheLink() async throws {
        let apps = try await AppsHarness()
        let sound = try #require(try await apps.settingRows().first { $0.title == "Sound" })
        try await apps.harness.performRoot("Copy Link", on: sound)
        #expect(apps.fakes.pasteboard.copiedTexts == ["x-apple.systempreferences:com.example.sound-settings"])
    }

    @Test @MainActor func turningPanesOffEmptiesTheCatalog() async throws {
        let apps = try await AppsHarness()
        #expect(try await !apps.settingRows().isEmpty)
        apps.harness.context.settings[AppsSettings.showsSettingsPanes] = false
        #expect(try await apps.settingRows().isEmpty)
        let source = try #require(apps.feature.catalogSources.first { $0.namespace == SettingsPaneCatalog.namespace })
        #expect(source.reloadsOnSettings == [AppsSettings.showsSettingsPanes.erased], "root reloads at once")
    }

    @Test @MainActor func actionsWorkFromTheRowKeyAlone() async throws {
        let apps = try await AppsHarness()
        let remembered = Row(id: ItemID("setting", "com.example.pane?Some Anchor"), title: "Some Anchor")
        let actions = apps.harness.rootActions(for: remembered)
        #expect(actions.map(\.title) == ["Open in System Settings", "Copy Link"])
    }
}
