import Kit
import KitHosting
import KitTesting
import Testing

@Suite(.timeLimit(.minutes(1))) struct LinkAllowancesTests {
    let running = ItemID.command(feature: "apps", command: "running")
    let search = ItemID.command(feature: "scripts", command: "a1b2c3")

    @Test func anEntryRoundTripsWhateverItsPartsHold() throws {
        let tricky = LinkAllowances.Entry(
            command: search,
            arguments: ["argument1": "a&b=c?d#e%f g", "argument2": "", "argument3": "naïve 🙂\u{200B}"],
            title: "Search #1 & More?")
        let stored = tricky.storedValue
        #expect(!stored.contains(" "))
        #expect(stored.filter { $0 == "#" }.count == 1)
        #expect(LinkAllowances.Entry(storedValue: stored) == tricky)

        let plain = LinkAllowances.Entry(command: running, arguments: [:], title: "Running Applications")
        #expect(plain.storedValue == "cmd%3Aapps.running#Running%20Applications")
        #expect(LinkAllowances.Entry(storedValue: plain.storedValue) == plain)
    }

    @Test func textItDidNotWriteIsNotAnEntry() {
        // A bare command ID, as the first version stored, carries no title and allows nothing.
        #expect(LinkAllowances.Entry(storedValue: "cmd:apps.running") == nil)
        #expect(LinkAllowances.Entry(storedValue: "cmd%3Aapps.running?#Title") == nil)
        #expect(LinkAllowances.Entry(storedValue: "cmd%3Aapps.running?a=1&a=2#Title") == nil)
        #expect(LinkAllowances.Entry(storedValue: "cmd%3Aapps.running?=1#Title") == nil)
        #expect(LinkAllowances.Entry(storedValue: "cmd%3Aapps.running?a#Title") == nil)
        #expect(LinkAllowances.Entry(storedValue: "#Title") == nil)
    }

    @Test func anAllowanceCoversExactlyItsArgumentsAndTitle() {
        let links = LinkAllowances.settings(FakeSettings())
        let entry = LinkAllowances.Entry(command: search, arguments: ["argument1": "notes"], title: "Search")
        LinkAllowances.add(entry, in: links)
        LinkAllowances.add(entry, in: links)
        #expect(LinkAllowances.entries(in: links) == [entry])
        #expect(LinkAllowances.allows(search, arguments: ["argument1": "notes"], title: "Search", in: links))
        #expect(!LinkAllowances.allows(search, arguments: ["argument1": "other"], title: "Search", in: links))
        #expect(!LinkAllowances.allows(search, arguments: [:], title: "Search", in: links))
        #expect(
            !LinkAllowances.allows(
                search, arguments: ["argument1": "notes", "argument2": "x"], title: "Search", in: links))
        #expect(!LinkAllowances.allows(search, arguments: ["argument1": "notes"], title: "Renamed", in: links))
        #expect(!LinkAllowances.allows(running, arguments: ["argument1": "notes"], title: "Search", in: links))

        LinkAllowances.remove(entry, in: links)
        #expect(LinkAllowances.entries(in: links).isEmpty)
    }

    @Test func removeAllKeepsWhatItIsToldAndDropsUnreadableText() {
        let links = LinkAllowances.settings(FakeSettings())
        let kept = LinkAllowances.Entry(command: running, arguments: [:], title: "Running Applications")
        let gone = LinkAllowances.Entry(command: search, arguments: [:], title: "Search")
        links[LinkAllowances.key] = [kept.storedValue, "not an allowance", gone.storedValue]
        #expect(LinkAllowances.removeAll(in: links) { $0.command == running } == 2)
        #expect(links[LinkAllowances.key] == [kept.storedValue])
        #expect(LinkAllowances.removeAll(in: links) { _ in true } == 0)
    }
}
