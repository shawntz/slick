import Foundation
import Kit
import Testing

@testable import SlickApp

/// The app checks that read the top page: the selected row's subtitle, a detail page's metadata and
/// the option a list's dropdown shows. The committed scenarios run them against the real panel.
@Suite("Panel checks", .timeLimit(.minutes(1)))
struct PanelCheckTests {
    @Test func readsTheThreeChecks() throws {
        let json = #"""
            {"selectedSubtitle": "rgb(1 2 3)", "detailMetadata": {"Status": "Exited with status 0"},
             "filter": "German"}
            """#
        let step = try JSONDecoder().decode(AppStep.self, from: Data(json.utf8))
        #expect(step.selectedSubtitle == "rgb(1 2 3)")
        #expect(step.detailMetadata == ["Status": "Exited with status 0"])
        #expect(step.filter == "German")
    }

    @Test func eachMetadataItemShowsTheTextAPersonReads() {
        let link = URL(string: "https://example.com/manual")!
        let values = ScenarioMode.metadataValues([
            .label("Status", value: "Exited with status 0"), .separator,
            .link("Manual", text: "Example Manual", url: link),
            .tags("WCAG", [Tag("Normal Text AA"), Tag("Large Text AAA")]),
            .date("Started", Date(timeIntervalSince1970: 0)),
            .color("Swatch", .purple),
        ])
        #expect(
            values == [
                "Status": "Exited with status 0", "Manual": "Example Manual", "WCAG": "Normal Text AA, Large Text AAA",
            ])
    }

    @Test func aCheckWithoutAPanelFailsAndAStepWithoutChecksPasses() throws {
        let step = try JSONDecoder().decode(AppStep.self, from: Data(#"{"filter": "German"}"#.utf8))
        #expect(ScenarioMode.panelChecks(step, panel: nil) == ["the panel checks need the panel"])
        let other = try JSONDecoder().decode(AppStep.self, from: Data(#"{"hud": "Copied"}"#.utf8))
        #expect(ScenarioMode.panelChecks(other, panel: nil).isEmpty)
    }
}
