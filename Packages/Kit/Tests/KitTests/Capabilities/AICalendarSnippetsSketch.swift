import Foundation
import Kit
import KitStorage
import KitTemplates
import KitTesting
import Testing

/// Scenario 8, AI: a detail that streams Markdown, follow-up questions, and Tab in root search
/// handing the query to the command. The endpoint is a reserved test domain; only FakeHTTP sees it.
final class AISketch: Feature {
    static let manifest = FeatureManifest(id: "ai", name: "AI", icon: .symbol("sparkles"))
    static let endpoint = URL(string: "https://ai.example.test/v1/answer") ?? URL(filePath: "/dev/null")

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(
                id: "ask", title: "Ask AI", arguments: [CommandArgument("prompt", placeholder: "Question")],
                takesRootQueryOnTab: true
            ) { context in
                let prompt = await Template.render(
                    "Answer briefly: {argument name=\"prompt\"}",
                    in: TemplateEnvironment(context: context.feature, arguments: context.arguments.values),
                    style: .prompt)
                return .push(
                    .detail(DetailPage(title: "AI", source: Conversation(http: context.feature.http, prompt: prompt))))
            }
        ]
    }
}

final class Conversation: DetailSource {
    private let http: any HTTPService
    private let prompt: String

    init(http: any HTTPService, prompt: String) {
        self.http = http
        self.prompt = prompt
    }

    let followUp: FollowUp? = FollowUp(placeholder: "Ask a follow-up question")

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        answer(prompt)
    }

    func followUp(_ text: String) -> AsyncThrowingStream<DetailUpdate, any Error> {
        answer(text, after: "\n\n---\n\n**\(text)**\n\n")
    }

    /// The host passes what it shows, so the source keeps no copy of the transcript.
    func actions(for detail: Detail) -> [Action] {
        guard case .markdown(let transcript) = detail.body else { return [] }
        return [.copy(transcript, title: "Copy Answer")]
    }

    /// Reads the streamed body off the main actor; chunks are decoded whole characters at a time.
    private func answer(_ prompt: String, after prefix: String? = nil) -> AsyncThrowingStream<DetailUpdate, any Error> {
        let http = http
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DetailUpdate.self)
        let task = Task.detached {
            do {
                if let prefix { continuation.yield(.append(prefix)) }
                let response = try await http.stream(
                    HTTPRequest(AISketch.endpoint, method: "POST", body: Data(prompt.utf8)))
                var decoder = UTF8StreamDecoder()
                for try await chunk in response.body {
                    continuation.yield(.append(decoder.decode(chunk)))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// The calendar feature's own event source. The live one wraps EventKit; tests use fixed meetings.
nonisolated protocol MeetingSource: Sendable {
    func meetings(from start: Date, to end: Date) async throws -> [Meeting]
}

nonisolated struct Meeting: Sendable {
    var id: String
    var title: String
    var start: Date
    var link: URL?
}

nonisolated struct FixedMeetings: MeetingSource {
    let all: [Meeting]

    func meetings(from start: Date, to end: Date) async throws -> [Meeting] {
        all.filter { $0.start >= start && $0.start <= end }.sorted { $0.start < $1.start }
    }
}

/// Scenario 9, calendar: a suggestion trigger with an expiry and a stable instance ID, a list
/// sectioned by day, and a permission flow that only starts when the user runs the command.
final class CalendarSketch: Feature, SuggestionTrigger {
    static let manifest = FeatureManifest(
        id: "calendar", name: "Calendar", icon: .symbol("calendar"),
        permissions: [PermissionNeed(.calendars, reason: "Show your upcoming meetings and offer to join them.")])

    private let context: FeatureContext
    private let source: any MeetingSource

    convenience init(context: FeatureContext) {
        self.init(context: context, source: FixedMeetings(all: []))
    }

    init(context: FeatureContext, source: any MeetingSource) {
        self.context = context
        self.source = source
    }

    let id = "meeting-soon"
    let namespace = "calendar"
    let prior = AcceptancePrior(accepts: 4, rejects: 1)
    let refreshInterval: Duration? = .seconds(60)
    let requires: [Permission] = [.calendars]
    var suggestionTriggers: [any SuggestionTrigger] { [self] }

    func suggestions(at date: Date) async throws -> [Suggestion] {
        try await source.meetings(from: date - 600, to: date + 900).compactMap { meeting in
            guard meeting.link != nil else { return nil }
            // One occurrence of a meeting is not worth remembering in root search's catalog.
            let row = Row(
                id: ItemID(namespace, meeting.id), title: "Join \(meeting.title)", icon: .symbol("video"),
                memory: .never)
            return Suggestion(
                id: "\(meeting.id)@\(Int(meeting.start.timeIntervalSince1970))", row: row,
                urgency: .ramp(start: meeting.start - 900, full: meeting.start - 300, end: meeting.start + 600),
                expires: meeting.start + 600, imminentFrom: meeting.start - 300)
        }
    }

    func actions(for row: Row) -> [Action] {
        [Action("Join Meeting") { _ in .close() }]
    }

    var commands: [Command] {
        [
            Command(id: "schedule", title: "My Schedule", requires: [.calendars]) { context in
                let clock = context.clock
                let meetings = try await self.source.meetings(from: clock.now, to: clock.now + 7 * 86_400)
                // Day titles come from the injected clock: Calendar.isDateInToday reads the system's.
                let sections = DaySections(clock: clock, direction: .future).sections(meetings, date: \.start) {
                    Row(id: ItemID(self.namespace, $0.id), title: $0.title, accessories: [.date($0.start)])
                }
                return .push(.list(ListPage(sections: sections) { _ in [] }))
            }
        ]
    }
}

/// Scenario 10, snippets: a text-expansion service started at launch, a create form with multiline
/// text, and import and export through file dialogs.
final class SnippetsSketch: Feature {
    static let manifest = FeatureManifest(
        id: "snippets", name: "Snippets", icon: .symbol("text.quote"),
        permissions: [
            PermissionNeed(.inputMonitoring, reason: "Notice when you type a snippet's keyword."),
            PermissionNeed(.accessibility, reason: "Replace the keyword with the snippet's text."),
        ])

    nonisolated struct Snippet: Codable, Hashable, Sendable {
        var name: String
        var keyword: String
        var text: String
    }

    let context: FeatureContext
    let declarationChanges: ChangeSignal? = ChangeSignal()
    private(set) var snippets: [Snippet] = []
    private(set) var expansionStatus: TextExpansionStatus = .stopped

    init(context: FeatureContext) {
        self.context = context
    }

    /// Settings shows this at the top of the pane, with a Grant button for the permission.
    var status: FeatureStatus? {
        guard case .needsPermission(let permission) = expansionStatus else { return nil }
        return FeatureStatus(.warning, "Keywords do not expand", requires: [permission])
    }

    func activate() async {
        let context = context
        expansionStatus = await context.textExpansion.start(
            keywords: Set(snippets.map(\.keyword)), options: ExpansionOptions()
        ) { keyword in
            guard let text = await self.text(forKeyword: keyword) else { return .ignore }
            let environment = TemplateEnvironment(context: context) { name in await self.text(named: name) }
            return .insert(await Template(text).render(in: environment).expansion)
        }
        declarationChanges?.send()
    }

    func deactivate() async {
        await context.textExpansion.stop()
    }

    func text(forKeyword keyword: String) -> String? { snippets.first { $0.keyword == keyword }?.text }
    func text(named name: String) -> String? { snippets.first { $0.name == name }?.text }

    private func replace(_ updated: [Snippet]) async {
        snippets = updated
        await context.textExpansion.updateKeywords(Set(updated.map(\.keyword)))
    }

    var commands: [Command] {
        [
            Command(id: "create", title: "Create Snippet") { _ in
                .push(
                    .form(
                        FormPage(
                            title: "Create Snippet",
                            fields: [
                                .text("name", title: "Name", isRequired: true), .text("keyword", title: "Keyword"),
                                .multiline("text", title: "Snippet", highlightsPlaceholders: true, isRequired: true),
                            ],
                            validate: { values in
                                self.snippets.contains { $0.keyword == values.text("keyword") }
                                    ? ["keyword": "Another snippet uses this keyword"] : [:]
                            },
                            submit: { values, _ in
                                await self.replace(
                                    self.snippets + [
                                        Snippet(
                                            name: values.text("name"), keyword: values.text("keyword"),
                                            text: values.text("text"))
                                    ])
                                return .pop
                            })))
            },
            Command(id: "import", title: "Import Snippets") { context in
                guard
                    let file = await context.feature.fileDialogs.chooseFiles(OpenDialogRequest(allowedTypes: ["json"]))
                        .first
                else {
                    return .keepOpen
                }
                let imported = try await JSONFileStore<[Snippet]>(url: file).load(default: [])
                let fresh = imported.filter { snippet in !self.snippets.contains { $0.keyword == snippet.keyword } }
                await self.replace(self.snippets + fresh)
                context.showToast(.success("Imported \(fresh.count) snippets"))
                return .keepOpen
            },
            Command(id: "export", title: "Export Snippets") { context in
                guard
                    let file = await context.feature.fileDialogs.chooseSaveLocation(
                        SaveDialogRequest(suggestedName: "snippets.json"))
                else {
                    return .keepOpen
                }
                try await JSONFileStore<[Snippet]>(url: file).save(self.snippets)
                return .close(hud: "Exported \(self.snippets.count) snippets")
            },
        ]
    }
}

@Suite("Scenario: AI, calendar and snippets")
struct AICalendarSnippetsSketchTests {
    @Test func aiStreamsAnswersAndFollowUps() async throws {
        let harness = FeatureHarness(AISketch.self)
        #expect(harness.issues.isEmpty)
        #expect(try harness.command("ask").takesRootQueryOnTab)
        harness.fakes.http.stub(AISketch.endpoint, chunks: ["Glass ", "is ", "amorphous."])
        try await harness.run("ask", arguments: ["prompt": "what is glass"], launch: .tabFromRoot)
        #expect(harness.detail?.body == .markdown("Glass is amorphous."))
        #expect(harness.fakes.http.requests.first?.body == Data("Answer briefly: \"\"\"what is glass\"\"\"".utf8))

        harness.fakes.http.stub(AISketch.endpoint, chunks: ["Mostly silica."])
        try await harness.followUp("made of?")
        #expect(harness.detail?.body == .markdown("Glass is amorphous.\n\n---\n\n**made of?**\n\nMostly silica."))
        try await harness.perform("Copy Answer")
        #expect(harness.fakes.pasteboard.copiedTexts.first?.hasSuffix("Mostly silica.") == true)
    }

    @Test func calendarSuggestsAMeetingOnlyWithPermissionAndUntilItExpires() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let now = fakes.clock.now
        let meetings = [
            Meeting(id: "standup", title: "Standup", start: now + 240, link: URL(string: "https://meet.example.com/a")),
            Meeting(id: "lunch", title: "Lunch", start: now + 86_400),
            Meeting(id: "review", title: "Review", start: now + 2 * 86_400 + 3600),
        ]
        let harness = FeatureHarness(fakes: fakes) { CalendarSketch(context: $0, source: FixedMeetings(all: meetings)) }
        #expect(harness.issues.isEmpty)
        #expect(try await harness.suggestions().isEmpty, "no permission, no suggestion, and no prompt")
        #expect(fakes.permissions.requests.isEmpty)

        fakes.permissions.set(.calendars, to: .granted)
        let suggestion = try #require(try await harness.suggestions().first)
        #expect(suggestion.id == "standup@\(Int((now + 240).timeIntervalSince1970))")
        #expect(suggestion.isImminent(at: now))
        #expect(suggestion.urgency.value(at: now) == 1)
        let remembered = try JSONDecoder().decode(Row.self, from: try JSONEncoder().encode(suggestion.row))
        #expect(harness.rootActions(for: remembered).map(\.title) == ["Join Meeting"], "routed by namespace")
        fakes.clock.advance(by: .seconds(240 + 601))
        #expect(try await harness.suggestions().isEmpty)
    }

    @Test func calendarScheduleAsksForAccessOnlyWhenRun() async throws {
        let fakes = FakeServices(permissions: .notDetermined)
        let now = fakes.clock.now
        let meetings = [
            Meeting(id: "a", title: "Standup", start: now + 3600),
            Meeting(id: "b", title: "Lunch", start: now + 86_400),
            Meeting(id: "c", title: "Review", start: now + 2 * 86_400),
        ]
        let harness = FeatureHarness(fakes: fakes) { CalendarSketch(context: $0, source: FixedMeetings(all: meetings)) }
        await #expect(throws: HarnessError.permissionRequired([.calendars])) { try await harness.run("schedule") }
        harness.grantsMissingPermissions = true
        try await harness.run("schedule")
        #expect(fakes.permissions.requests == [.calendars])
        #expect(harness.sections.map(\.title) == ["Today", "Tomorrow", "Monday"])
    }

    @Test func snippetsExpandWithPlaceholdersAndRoundTripThroughFiles() async throws {
        let harness = FeatureHarness(SnippetsSketch.self)
        #expect(harness.issues.isEmpty)
        await harness.activate()
        try await harness.run("create")
        try harness.fill("name", text: "Sign-off")
        try harness.fill("keyword", text: ";sig")
        try harness.fill("text", text: "Thanks,\n{cursor}\n{date format=\"yyyy-MM-dd\"}")
        try await harness.submit()
        let expansion = await harness.fakes.textExpansion.type(";sig")
        #expect(expansion == .insert(Expansion("Thanks,\n\n2026-11-14", charactersAfterCursor: 11)))

        try await harness.run("create")
        try harness.fill("name", text: "Other")
        try harness.fill("keyword", text: ";sig")
        try harness.fill("text", text: "x")
        await #expect(throws: HarnessError.invalidForm(["keyword": "Another snippet uses this keyword"])) {
            try await harness.submit()
        }

        let export = harness.fakes.storage.root.appending(path: "exported.json")
        harness.fakes.fileDialogs.saveLocation = export
        try await harness.run("export")
        #expect(harness.huds == ["Exported 1 snippets"])
        try await JSONFileStore<[SnippetsSketch.Snippet]>(url: export).save([
            SnippetsSketch.Snippet(name: "Hi", keyword: ";hi", text: "Hello")
        ])
        harness.fakes.fileDialogs.filesToChoose = [export]
        try await harness.run("import")
        #expect(harness.toasts.last?.title == "Imported 1 snippets")
        #expect(await harness.fakes.textExpansion.type(";hi") == .insert(Expansion("Hello")))
    }

    @Test func snippetsReportAMissingPermissionWithoutPrompting() async {
        let harness = FeatureHarness(SnippetsSketch.self)
        harness.fakes.textExpansion.missingPermission = .inputMonitoring
        await harness.activate()
        #expect(harness.feature.expansionStatus == .needsPermission(.inputMonitoring))
        #expect(harness.feature.status?.requires == [.inputMonitoring])
        #expect(harness.issues.isEmpty)
        #expect(harness.fakes.permissions.requests.isEmpty)
    }
}
