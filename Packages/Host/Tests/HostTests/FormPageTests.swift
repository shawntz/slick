import AppKit
import Foundation
import Host
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import LauncherUI
import Testing

/// Form pages: every field kind, required fields, validation, submit and file fields.
@Suite("Panel: forms", .serialized, .timeLimit(.minutes(1)))
@MainActor struct FormPageTests {
    /// What a form's submit handler saw.
    @MainActor final class Submissions {
        var values: [FormValues] = []
        var validations = 0
    }

    private func quicklinkForm(_ submissions: Submissions, requires: [Permission] = []) -> FormPage {
        FormPage(
            title: "Create Quicklink",
            fields: [
                .text("name", title: "Name", placeholder: "Name", isRequired: true),
                .text("link", title: "Link", placeholder: "https://", highlightsPlaceholders: true),
                .checkbox("pinned", title: "Pinned", label: "Show at the top", initial: true),
                .dropdown("browser", title: "Open With", options: [.init("Default"), .init("Other", value: "other")]),
                .files("icon", title: "Icon", request: OpenDialogRequest(title: "Choose an icon")),
                .tags("tags", title: "Tags", initial: ["work"]),
            ],
            submitTitle: "Save Quicklink", requires: requires,
            validate: { values in
                submissions.validations += 1
                let link = values.text("link")
                guard let open = link.firstIndex(of: "{"), !link.contains("}") else { return [:] }
                let start = link.utf16.distance(from: link.startIndex, to: open)
                return ["link": FieldError("Close the placeholder", range: start..<link.utf16.count)]
            },
            submit: { values, _ in
                submissions.values.append(values)
                return .pop
            })
    }

    private func openForm(_ fixture: PanelFixture, _ form: FormPage) throws -> FormPageController {
        try #require(fixture.open(.form(form)) as? FormPageController)
    }

    @Test func everyFieldKindMapsToARow() {
        let fields: [FormField] = [
            .text("a", title: "A", placeholder: "x", initial: "one"), .multiline("b", title: "B"),
            .password("c", title: "C"), .checkbox("d", title: "D", label: "on"),
            .dropdown("e", title: "E", options: [.init("One", value: "1")]),
            .date("f", title: "F", includesTime: false), .files("g", title: "G"), .tags("h", title: "H"),
            .application("i", title: "I", initial: "com.example.editor"), .description("Note"), .separator("j"),
        ]
        let kinds = fields.map { FormPageController.item($0).kind }
        #expect(kinds[0] == .text(placeholder: "x"))
        #expect(kinds[1] == .multiline(placeholder: ""))
        #expect(kinds[2] == .secure(placeholder: ""))
        #expect(kinds[3] == .checkbox(label: "on"))
        #expect(kinds[4] == .dropdown([MenuOption(id: "1", title: "One")]))
        #expect(kinds[5] == .date(includesTime: false))
        #expect(kinds[6] == .filePath(placeholder: "", buttonTitle: "Choose…"))
        #expect(kinds[7] == .tags(placeholder: ""))
        #expect(kinds[8] == .filePath(placeholder: "Bundle ID", buttonTitle: "Choose…"))
        #expect(kinds[9] == .description("Note"))
        #expect(kinds[10] == .separator)
        #expect(FormPageController.item(fields[0]).value == .text("one"))
        #expect(FormPageController.item(fields[4]).value == .option("1"))
        #expect(FormPageController.item(fields[8]).value == .text("com.example.editor"))
    }

    @Test func aMissingRequiredFieldIsShownWithoutValidating() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let submissions = Submissions()
        let page = try openForm(fixture, quicklinkForm(submissions))
        #expect(fixture.panel.surface.actionBar.content.primaryTitle == "Save Quicklink")
        fixture.press(.submit(.command))
        #expect(await waitUntil { !page.errors.isEmpty })
        #expect(page.errors == ["name": "Required"])
        #expect(page.form.content.items.first?.error == "Required")
        #expect(submissions.validations == 0)
        #expect(submissions.values.isEmpty)
        #expect(!page.isSubmitting)
    }

    @Test func validationErrorsSelectTheirRangeAndClearOnEdit() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let submissions = Submissions()
        let page = try openForm(fixture, quicklinkForm(submissions))
        page.fill("name", .text("Docs"))
        page.fill("link", .text("https://example.com/{query"))
        page.submit()
        #expect(await waitUntil { page.errors["link"] != nil })
        #expect(page.errors["link"]?.range == 20..<26)
        #expect(page.form.content.items[1].error == "Close the placeholder")
        #expect(page.form.focusedID == "link")
        #expect(page.selectedErrorRange == NSRange(location: 20, length: 6))
        page.fill("link", .text("https://example.com/{query}"))
        #expect(page.errors.isEmpty)
        #expect(page.form.content.items[1].error == nil)
    }

    @Test func aValidFormSubmitsItsValuesAndPops() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let submissions = Submissions()
        let page = try openForm(fixture, quicklinkForm(submissions))
        page.fill("name", .text("Docs"))
        page.fill("link", .text("https://example.com"))
        page.fill("browser", .text("other"))
        fixture.press(.submit(.command))
        #expect(await waitUntil { submissions.values.count == 1 })
        let values = try #require(submissions.values.first)
        #expect(values.text("name") == "Docs")
        #expect(values.bool("pinned"))
        #expect(values.text("browser") == "other")
        #expect(values.strings("tags") == ["work"])
        #expect(values.files("icon").isEmpty)
        #expect(await waitUntil { fixture.panel.top === fixture.panel.rootPage }, "the outcome popped the form")
        #expect(page.submissions == 1)
    }

    @Test func aFileFieldChoosesThroughTheDialogService() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let submissions = Submissions()
        let page = try openForm(fixture, quicklinkForm(submissions))
        let chosen = fixture.runtime.fakes.storage.root.appending(path: "icon.png")
        fixture.runtime.fakes.fileDialogs.filesToChoose = [chosen]
        page.form.onChooseFile?("icon")
        #expect(await waitUntil { page.values.files("icon") == [chosen] })
        #expect(fixture.runtime.fakes.fileDialogs.openRequests.first?.title == "Choose an icon")
    }

    @Test func anApplicationFieldStoresTheBundleID() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let app = fixture.runtime.fakes.storage.root.appending(path: "Sample Editor.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.sample-editor", "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: contents.appending(path: "Info.plist"))
        let form = FormPage(title: "Pick", fields: [.application("app", title: "App")]) { _, _ in .keepOpen }
        let page = try openForm(fixture, form)
        fixture.runtime.fakes.fileDialogs.filesToChoose = [app]
        page.form.onChooseFile?("app")
        #expect(await waitUntil { page.values.text("app") == "com.example.sample-editor" })
        #expect(fixture.runtime.fakes.fileDialogs.openRequests.first?.allowedTypes == ["app"])
    }

    @Test func requiresAsksForThePermissionBeforeValidating() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        fixture.runtime.fakes.permissions.set(.accessibility, to: .notDetermined)
        let submissions = Submissions()
        let page = try openForm(fixture, quicklinkForm(submissions, requires: [.accessibility]))
        page.fill("name", .text("Docs"))
        page.submit()
        #expect(await waitUntil { fixture.panel.pendingCard != nil })
        #expect(submissions.validations == 0, "nothing validates before the grant")
        fixture.panel.pendingCard?.onConfirm?()
        #expect(await waitUntil { submissions.values.count == 1 })
        #expect(fixture.runtime.fakes.permissions.requests == [.accessibility])
    }

    @Test func aThrowingSubmitShowsAFailureToastAndKeepsTheForm() async throws {
        let fixture = await PanelFixture.make()
        defer { fixture.close() }
        let form = FormPage(title: "Send", fields: [.text("to", title: "To")]) { _, _ in
            throw ActionFailure("Could not send")
        }
        let page = try openForm(fixture, form)
        fixture.command("k")
        #expect(fixture.panel.actionEntries.map(\.title) == ["Save"])
        fixture.panel.actionCard.selectItem(at: 0)
        fixture.panel.actionCard.onActivate?(try #require(fixture.panel.actionCard.selectedItem))
        #expect(await waitUntil { fixture.panel.surface.actionBar.toast?.text == "Could not send" })
        #expect(fixture.panel.top === page)
        #expect(await waitUntil { !page.isSubmitting })
    }
}
