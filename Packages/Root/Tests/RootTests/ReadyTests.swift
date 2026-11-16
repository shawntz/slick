import Foundation
import Kit
import KitHosting
import KitHostingTesting
import KitTesting
import Testing

@testable import Root

/// `ready()` waits for the work features start at activation, as far as their catalog shows it, so
/// a scenario never types before an app scan has finished.
@Suite(.timeLimit(.minutes(1))) struct ReadyTests {
    @Test func readyWaitsForAScanThatStartedAfterTheFirstLoad() async throws {
        let scanner = ScanningCatalog()
        let fixture = await RootFixture.ready(extraSources: [scanner])
        #expect(fixture.results("network").isEmpty, "the first load ran before any scan")

        // Activation starts the scan; the catalog's next read waits for it.
        let gate = AsyncGate()
        scanner.scan = Task { @MainActor in
            await gate.wait()
            return [Row(id: ItemID("scanned", "network"), title: "Network Utility")]
        }
        let readied = ReadyFlag()
        let waiting = Task { @MainActor in
            await fixture.root.ready()
            readied.isSet = true
        }
        for _ in 0..<200 { await Task.yield() }
        #expect(!readied.isSet, "ready waits while the scan runs")

        gate.open()
        await waiting.value
        #expect(fixture.results("network") == ["Network Utility"])
        await fixture.shutdown()
    }
}

/// A catalog whose rows come from a scan that activation starts, like the Apps feature's.
@MainActor final class ScanningCatalog: CatalogSource {
    let namespace = "scanned"
    var scan: Task<[Row], Never>?

    func rows() async throws -> [Row] {
        await scan?.value ?? []
    }

    func actions(for row: Row) -> [Action] { [] }
}

/// Opens once; waiters before and after pass.
@MainActor final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor final class ReadyFlag {
    var isSet = false
}
