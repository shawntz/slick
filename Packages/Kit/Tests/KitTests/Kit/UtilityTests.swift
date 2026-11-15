import Kit
import KitTesting
import Testing

@Suite("Debouncer and ChangeSignal")
struct UtilityTests {
    @Test func debouncerRunsOnlyTheLastWorkAfterTheQuietPeriod() async {
        let clock = FakeClock()
        let debouncer = Debouncer(delay: .milliseconds(300), clock: clock)
        var ran: [String] = []
        debouncer.schedule { ran.append("first") }
        await clock.waitForSleepers()
        debouncer.schedule { ran.append("second") }
        await clock.waitForSleepers()
        clock.advance(by: .milliseconds(299))
        await Task.yield()
        #expect(ran.isEmpty)
        #expect(debouncer.isPending)
        clock.advance(by: .milliseconds(1))
        while debouncer.isPending { await Task.yield() }
        #expect(ran == ["second"])
    }

    @Test func cancelledWorkNeverRuns() async {
        let clock = FakeClock()
        let debouncer = Debouncer(delay: .seconds(1), clock: clock)
        var ran = false
        debouncer.schedule { ran = true }
        await clock.waitForSleepers()
        debouncer.cancel()
        clock.advance(by: .seconds(5))
        for _ in 0..<100 { await Task.yield() }
        #expect(!ran)
        #expect(!debouncer.isPending)
    }

    @Test func signalsReachEveryListenerAndCoalesce() async {
        let signal = ChangeSignal()
        var first = signal.stream().makeAsyncIterator()
        var second = signal.stream().makeAsyncIterator()
        #expect(signal.listenerCount == 2)
        signal.send()
        signal.send()
        #expect(await first.next() != nil)
        #expect(await second.next() != nil)
    }

    @Test func listenersLeaveWhenTheirTaskIsCancelled() async {
        let signal = ChangeSignal()
        let task = Task {
            for await _ in signal.stream() {}
        }
        while signal.listenerCount == 0 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(signal.listenerCount == 0)
    }
}
