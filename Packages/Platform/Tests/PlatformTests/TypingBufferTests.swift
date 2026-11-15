import CoreGraphics
import Foundation
import Kit
import Testing

@testable import Platform

/// The keystroke state machine, driven by synthetic key streams. Nothing here touches the keyboard.
@Suite struct TypingBufferTests {
    /// Types each character as its own key press.
    @discardableResult
    func type(_ text: String, into buffer: inout TypingBuffer) -> [KeywordMatch] {
        text.compactMap { buffer.handle(.characters(String($0))) }
    }

    @Test func aKeywordMatchesWhenItsLastCharacterIsTyped() {
        var buffer = TypingBuffer(keywords: [";sig", "addr"])
        #expect(type("hello ;si", into: &buffer).isEmpty)
        let match = buffer.handle(.characters("g"))
        #expect(match?.keyword == ";sig")
        #expect(match?.deleteCount == 4)
        #expect(match?.delimiter == nil)
    }

    @Test func aKeywordInsideAWordWaitsForTheOption() {
        var strict = TypingBuffer(keywords: ["sig"])
        #expect(type("designsig", into: &strict).isEmpty)
        #expect(type(" sig", into: &strict).map(\.keyword) == ["sig"])

        var loose = TypingBuffer(keywords: ["sig"], options: ExpansionOptions(expandsWithinWords: true))
        #expect(type("designsig", into: &loose).map(\.keyword) == ["sig"])

        // Digits count as word characters, punctuation does not.
        var digits = TypingBuffer(keywords: ["sig"])
        #expect(type("2sig", into: &digits).isEmpty)
        var punctuation = TypingBuffer(keywords: ["sig"])
        #expect(type("(sig", into: &punctuation).map(\.keyword) == ["sig"])
    }

    @Test func theDelimiterTriggerWaitsForSpacePunctuationOrReturn() {
        let options = ExpansionOptions(trigger: .afterDelimiter)
        var buffer = TypingBuffer(keywords: ["sig"], options: options)
        #expect(type("sig", into: &buffer).isEmpty)
        let match = buffer.handle(.characters(" "))
        #expect(match?.keyword == "sig" && match?.delimiter == " " && match?.deleteCount == 4)

        var longer = TypingBuffer(keywords: ["sig"], options: options)
        #expect(type("sigs ", into: &longer).isEmpty)
        #expect(type("sig.", into: &longer).first?.delimiter == ".")

        var returned = TypingBuffer(keywords: ["sig"], options: options)
        type("sig", into: &returned)
        #expect(returned.handle(.characters("\r"))?.delimiter == "\r")
    }

    @Test func backspaceRemovesOneCharacter() {
        var buffer = TypingBuffer(keywords: ["sig"])
        type("sih", into: &buffer)
        #expect(buffer.handle(.backspace) == nil)
        #expect(buffer.handle(.characters("g"))?.keyword == "sig")

        var empty = TypingBuffer(keywords: ["sig"])
        #expect(empty.handle(.backspace) == nil)
        #expect(empty.text.isEmpty)
    }

    @Test func movingTheInsertionPointClearsTheBuffer() {
        for event in [TypingEvent.navigation, .click, .shortcut, .escape, .focusChanged] {
            var buffer = TypingBuffer(keywords: ["sig"])
            type("si", into: &buffer)
            #expect(buffer.handle(event) == nil)
            #expect(buffer.handle(.characters("g")) == nil, "\(event)")
        }
    }

    @Test func modifierKeysAndForwardDeleteLeaveTheBufferAlone() {
        var buffer = TypingBuffer(keywords: ["sig"])
        type("si", into: &buffer)
        #expect(buffer.handle(.modifiers) == nil)
        #expect(buffer.handle(.forwardDelete) == nil)
        #expect(buffer.handle(.characters("g"))?.keyword == "sig")
    }

    @Test func deadKeysAndComposedCharactersMatch() {
        // A dead key types nothing; the next key brings the composed character.
        var composed = TypingBuffer(keywords: ["café"])
        type("caf", into: &composed)
        #expect(composed.handle(.characters("")) == nil)
        let match = composed.handle(.characters("é"))
        #expect(match?.keyword == "café" && match?.deleteCount == 4)

        // A combining mark merges with the letter before it.
        var combining = TypingBuffer(keywords: ["café"])
        type("cafe", into: &combining)
        #expect(combining.handle(.characters("\u{0301}"))?.deleteCount == 4)

        // An emoji with a skin tone is one character, deleted with one press.
        var emoji = TypingBuffer(keywords: ["👍🏽!"])
        #expect(type("👍🏽!", into: &emoji).first?.deleteCount == 2)
    }

    @Test func theLongestKeywordWins() {
        var buffer = TypingBuffer(keywords: ["sig", ";sig", "g"], options: ExpansionOptions(expandsWithinWords: true))
        #expect(type(";sig", into: &buffer).map(\.keyword) == [";sig"])
    }

    @Test func anInsertDeletesTheKeywordAndPlacesTheCursor() throws {
        var buffer = TypingBuffer(keywords: ["sig"])
        let matchTyped = type(" sig", into: &buffer)
        let match = try #require(matchTyped.first)
        #expect(buffer.isAwaiting)
        let plan = buffer.finish(match, with: .insert(Expansion("Best, Sam", charactersAfterCursor: 3)))
        #expect(plan == ExpansionPlan(deleteCount: 3, text: "Best, Sam", leftCount: 3))
        #expect(
            plan?.keystrokes
                == Keystroke.deletes(3) + [.text("Best, Sam")] + Keystroke.lefts(3))
        #expect(!buffer.isAwaiting)
        #expect(buffer.text.isEmpty)
    }

    @Test func charactersTypedWhileWaitingAreRetyped() throws {
        var buffer = TypingBuffer(keywords: ["sig"], options: ExpansionOptions(trigger: .afterDelimiter))
        let matchTyped = type("sig ", into: &buffer)
        let match = try #require(matchTyped.first)
        type("ab", into: &buffer)
        #expect(buffer.handle(.backspace) == nil)
        let plan = buffer.finish(match, with: .insert(Expansion("X", charactersAfterCursor: 1)))
        // The keyword, the space and "a" go; "X", the space and "a" come back; the cursor moves
        // back over "a", the space and one character of the expansion.
        #expect(plan == ExpansionPlan(deleteCount: 5, text: "X a", leftCount: 3))
    }

    @Test func movingAwayWhileWaitingDropsTheAnswer() throws {
        var buffer = TypingBuffer(keywords: ["sig"])
        let matchTyped = type("sig", into: &buffer)
        let match = try #require(matchTyped.first)
        #expect(buffer.handle(.click) == nil)
        #expect(buffer.finish(match, with: .insert(Expansion("X"))) == nil)

        // Deleting back into the keyword cancels it too.
        let secondTyped = type("sig", into: &buffer)
        let second = try #require(secondTyped.first)
        buffer.handle(.backspace)
        #expect(buffer.finish(second, with: .insert(Expansion("X"))) == nil)
        // A stale match is ignored.
        #expect(buffer.finish(match, with: .insert(Expansion("X"))) == nil)
    }

    @Test func noNewMatchStartsWhileOneWaits() throws {
        var buffer = TypingBuffer(keywords: ["a", "b"])
        let typed = buffer.handle(.characters("a"))
        let first = try #require(typed)
        #expect(buffer.handle(.characters(" b")) == nil)
        #expect(buffer.finish(first, with: .insert(Expansion("1")))?.text == "1 b")
    }

    @Test func anIgnoredKeywordStaysAndTypingGoesOn() throws {
        var buffer = TypingBuffer(keywords: ["ab", "abc"])
        let shortTyped = type("ab", into: &buffer)
        let short = try #require(shortTyped.first)
        #expect(buffer.finish(short, with: .ignore) == nil)
        #expect(buffer.handle(.characters("c"))?.keyword == "abc")
    }

    @Test func aCommandDeletesTheKeywordAndKeepsTheDelimiter() throws {
        var buffer = TypingBuffer(keywords: ["mtg"], options: ExpansionOptions(trigger: .afterDelimiter))
        let matchTyped = type("mtg,", into: &buffer)
        let match = try #require(matchTyped.first)
        let id = ItemID("cmd", "snippets.meeting")
        let finished = buffer.finish(match, with: .runCommand(id, arguments: ["who": "team"]))
        let plan = try #require(finished)
        #expect(plan.deleteCount == 4 && plan.text == "," && plan.leftCount == 1)
        #expect(plan.command == id && plan.arguments == ["who": "team"])
    }

    @Test func aLongStreamKeepsOnlyWhatMatchingNeeds() {
        var buffer = TypingBuffer(keywords: ["sig"])
        type(String(repeating: "typing along ", count: 200), into: &buffer)
        #expect(buffer.text.count <= 8)
        #expect(type("sig", into: &buffer).map(\.keyword) == ["sig"])
    }

    @Test func keywordsCanChangeWithoutLosingWhatWasTyped() {
        var buffer = TypingBuffer(keywords: ["old"])
        type(" ne", into: &buffer)
        buffer.update(keywords: ["new", ""])
        #expect(buffer.keywords == ["new"])
        #expect(buffer.handle(.characters("w"))?.keyword == "new")
    }

    @Test func keyEventsDecodeIntoTypingEvents() {
        #expect(TypingEventDecoder.keyDown(keyCode: Key.a.code, flags: [], characters: "a") == .characters("a"))
        #expect(TypingEventDecoder.keyDown(keyCode: Key.a.code, flags: .maskShift, characters: "A") == .characters("A"))
        #expect(
            TypingEventDecoder.keyDown(keyCode: Key.e.code, flags: .maskAlternate, characters: "") == .characters(""))
        #expect(TypingEventDecoder.keyDown(keyCode: Key.a.code, flags: .maskCommand, characters: "a") == .shortcut)
        #expect(TypingEventDecoder.keyDown(keyCode: Key.a.code, flags: .maskControl, characters: "\u{1}") == .shortcut)
        #expect(TypingEventDecoder.keyDown(keyCode: Key.delete.code, flags: [], characters: "\u{7F}") == .backspace)
        #expect(
            TypingEventDecoder.keyDown(keyCode: Key.forwardDelete.code, flags: [], characters: "") == .forwardDelete)
        #expect(
            TypingEventDecoder.keyDown(keyCode: Key.leftArrow.code, flags: [], characters: "\u{F702}") == .navigation)
        #expect(TypingEventDecoder.keyDown(keyCode: 0x7A, flags: [], characters: "\u{F704}") == .navigation)
        #expect(TypingEventDecoder.keyDown(keyCode: Key.escape.code, flags: [], characters: "\u{1B}") == .escape)
        #expect(TypingEventDecoder.keyDown(keyCode: Key.return.code, flags: [], characters: "\r") == .characters("\r"))
        #expect(TypingEventDecoder.keyDown(keyCode: Key.tab.code, flags: [], characters: "\t") == .characters("\t"))
    }

    /// Builds events in memory, as the tap would receive them. Nothing is posted.
    @Test func eventsMadeInMemoryDecode() throws {
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: Key.s.code, keyDown: true))
        let units = Array("s".utf16)
        key.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        #expect(TypingEventDecoder.event(type: .keyDown, event: key) == .characters("s"))
        #expect(TypingEventDecoder.event(type: .flagsChanged, event: key) == .modifiers)
        #expect(TypingEventDecoder.event(type: .leftMouseDown, event: key) == .click)
        #expect(TypingEventDecoder.event(type: .keyUp, event: key) == nil)
    }
}
