import Kit
import KitHosting
import KitHostingTesting
import Testing

@Suite struct RootSourceTests {
    let calendar = Row(id: ItemID("app", "com.example.calendar"), title: "Calendar")
    let notes = Row(id: ItemID("app", "com.example.notes"), title: "Notes")
    let newNote = Row(id: .command(feature: "notes", command: "new"), title: "New Note")
    let search = Row(id: .command(feature: "web", command: "search"), title: "Search the Web")

    @Test func sessionFiltersIgnoringCaseAndRecordsCalls() throws {
        let source = FakeRootSource(rows: [calendar, notes, newNote], fallbacks: [search])

        let empty = source.begin()
        #expect(empty.sections.map(\.kind) == [.suggested])
        #expect(empty.rows.count == 3)
        let typed = source.update(query: "NOTE")
        #expect(typed.sections.map(\.kind) == [.results, .fallbacks])
        #expect(typed.sections.first?.rows.map(\.title) == ["Notes", "New Note"])
        #expect(typed.rows.first?.titleHighlights == [0..<4])
        #expect(source.titleHighlights(for: newNote) == [4..<8])
        #expect(typed.revision > empty.revision)
        #expect(typed.completion == RootCompletion(id: notes.id, text: "NOTEs"))
        #expect(typed.completion?.ghostText(after: "NOTE") == "s")
        #expect(source.update(query: "zzz").sections.map(\.kind) == [.fallbacks])
        source.didRun(notes, launch: .root)
        source.end()

        #expect(
            source.calls == [
                .begin, .update("NOTE"), .update("zzz"), .didRun(notes.id, .root), .end,
            ])
        #expect(!source.isInSession)
    }

    @Test func commandRowsGetNoActionsAndRowsMapToFeatures() {
        let source = FakeRootSource(rows: [calendar, newNote])
        source.rowActions = { _ in [Action("Open") { _ in .close() }] }
        source.featureIDs = ["app": "apps"]
        #expect(source.actions(for: newNote).isEmpty)
        #expect(source.actions(for: calendar).map(\.title) == ["Open"])
        #expect(source.featureID(for: newNote) == "notes")
        #expect(source.featureID(for: calendar) == "apps")
        #expect(source.row(for: newNote.id)?.title == "New Note")
        #expect(source.row(for: ItemID("app", "missing")) == nil)
        source.forget(calendar.id)
        #expect(source.calls == [.forget(calendar.id)])
        #expect(source.update(query: "zzz").emptyState?.title == "No Results")
    }

    @Test func lateSectionsAppendBeforeFallbacksAndSignal() {
        let source = FakeRootSource(rows: [calendar], fallbacks: [search])
        source.marksQueriesLoading = true
        _ = source.begin()
        let typed = source.update(query: "cal")
        #expect(typed.isLoading)
        let generation = source.changes.generation
        let file = Row(id: ItemID("file", "/tmp/calendar.txt"), title: "calendar.txt")
        source.simulateLateSection(
            RootSection(id: "files", title: "Files", rows: [file], kind: .provider(namespace: "file")))
        #expect(source.changes.generation == generation + 1)
        #expect(source.snapshot.sections.map(\.id) == ["results", "files", "fallbacks"])
        #expect(!source.snapshot.isLoading)
        #expect(source.snapshot.revision == typed.revision + 1)
        #expect(source.snapshot.section(containing: file.id)?.kind == .provider(namespace: "file"))
    }

    @Test(arguments: [
        (RootSection.Kind.suggested, LaunchSource.suggestion), (.fallbacks, .fallback), (.favorites, .root),
        (.answers, .root), (.results, .root), (.provider(namespace: "file"), .root),
    ])
    func sectionKindsPickTheLaunchSource(kind: RootSection.Kind, launch: LaunchSource) {
        #expect(kind.launchSource == launch)
    }

    @Test func completionGhostText() {
        let completion = RootCompletion(id: calendar.id, text: "Calendar")
        #expect(completion.ghostText(after: "cal") == "endar")
        #expect(completion.ghostText(after: "Calendar") == nil)
        #expect(completion.ghostText(after: "note") == nil)
    }
}
