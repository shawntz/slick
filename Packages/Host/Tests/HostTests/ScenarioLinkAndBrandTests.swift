import AppKit
import Foundation
import Host
import Kit
import KitTesting
import LauncherUI
import Testing

/// Two scenario features a file needs to prove what a person sees: a step that clicks a link the
/// detail shows, and `{brand}` in a toast expectation, so a file never writes the app's name.
@Suite("Scenario: links and the app's name", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ScenarioLinkAndBrandTests {
    private let otherApp = URL(string: "example-app://do?thing=1")!

    private func makeRunner(_ fixture: PanelFixture) -> ScenarioRunner {
        let output = fixture.runtime.fakes.storage.root.appending(path: "scenario-out", directoryHint: .isDirectory)
        let runner = ScenarioRunner(panel: fixture.panel, output: output, placesInCorner: false)
        runner.log = { _ in }
        return runner
    }

    /// The click goes through the pane, where a person's would, so a link to another app's scheme
    /// asks first. A link the detail does not show fails the step.
    @Test func aScenarioClicksALinkTheDetailShows() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let workspace = fixture.runtime.fakes.workspace
        let page = try #require(
            fixture.open(.detail(DetailPage(title: "Answer", detail: .markdown("See [the app](\(otherApp))."))))
                as? DetailPageController)
        #expect(await waitUntil { page.pane.linkTargets == [otherApp] })
        let runner = makeRunner(fixture)
        let clicked = await runner.run(
            Scenario(
                name: "click",
                steps: [
                    .clickLink(otherApp.absoluteString),
                    .expect(ScenarioExpectation(toast: "Not a Web Link: \(otherApp.absoluteString)")),
                ]))
        #expect(clicked.passed, "\(clicked.reason ?? "")")
        #expect(workspace.opened.isEmpty, "the link asks first")

        let missing = await runner.run(Scenario(name: "missing", steps: [.clickLink("example-app://other")]))
        #expect(missing.reason?.contains("no link to \"example-app://other\"") == true, "\(missing.reason ?? "")")
        let json = #"{"name": "x", "steps": [{"clickLink": "example-app://do"}]}"#
        let decoded = try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
        #expect(decoded.steps == [.clickLink("example-app://do")])
    }

    @Test func aToastExpectationNamesTheAppAsBrand() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.panel.showToast(.success("Opened by " + Brand.name), id: ToastID(1), origin: nil)
        let result = await makeRunner(fixture).run(
            Scenario(name: "brand", steps: [.expect(ScenarioExpectation(toast: "Opened by {brand}"))]))
        #expect(result.passed, "\(result.reason ?? "")")
    }
}
