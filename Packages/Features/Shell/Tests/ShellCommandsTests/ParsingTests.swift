import Foundation
import Testing

@testable import ShellCommands

@Suite("Typed commands", .timeLimit(.minutes(1)))
struct ParsingTests {
    @Test func thePrefixClaimsOnlyAQueryWithACommandAfterIt() {
        #expect(RootQuery.claims(">ls"))
        #expect(RootQuery.claims("> ls -la"))
        #expect(RootQuery.claims(">  ls"))
        #expect(RootQuery.claims(">\tls"))
        #expect(RootQuery.claims(">"), "the prefix alone shows the hint")
        #expect(RootQuery.claims(">   "))
        #expect(RootQuery.claims("> \t "))
        #expect(RootQuery.claims(">" + String(repeating: " ", count: 2000) + "ls"))
        #expect(!RootQuery.claims(""))
        #expect(!RootQuery.claims("ls"))
        #expect(!RootQuery.claims(" > ls"), "the prefix must come first")
        #expect(!RootQuery.claims("\u{FF1E}ls"), "only the ASCII prefix")
    }

    @Test func theCommandIsWhatFollowsThePrefixAndOneSpace() {
        #expect(RootQuery.commandText(in: ">ls") == "ls")
        #expect(RootQuery.commandText(in: "> ls -la ") == "ls -la ")
        #expect(RootQuery.commandText(in: ">  ls") == " ls")
        #expect(RootQuery.commandText(in: ">\u{0338}x") == "\u{0338}x", "a mark after the prefix stays")
        #expect(RootQuery.commandText(in: "ls") == nil)
    }

    @Test func aSpaceBeforeTheCommandKeepsItOutOfHistory() throws {
        let shown = try ShellCommand.check("ls -la").get()
        #expect(!shown.isHidden && shown.text == "ls -la" && shown.trimmed == "ls -la")
        let hidden = try ShellCommand.check(" export TOKEN=x ").get()
        #expect(hidden.isHidden && hidden.trimmed == "export TOKEN=x" && hidden.text == " export TOKEN=x ")
        #expect(try ShellCommand.check("\tls").get().isHidden)
        #expect(RootQuery.query(for: shown) == "> ls -la")
        #expect(RootQuery.query(for: hidden) == ">  export TOKEN=x", "the marker survives the trip to root")
        let back = try ShellCommand.check(try #require(RootQuery.commandText(in: RootQuery.query(for: hidden)))).get()
        #expect(back.isHidden && back.trimmed == hidden.trimmed)
    }

    @Test func whatWouldNotRunAsItShowsIsRefused() {
        func problem(_ text: String) -> ShellCommand.Problem? {
            if case .failure(let problem) = ShellCommand.check(text) { return problem }
            return nil
        }
        #expect(problem("") == .empty)
        #expect(problem(" \t ") == .empty)
        #expect(problem("\u{00A0}") == .empty)
        #expect(problem("\u{200B}\u{FEFF}") == .empty)
        #expect(problem("echo safe\nrm -rf x") == .lineBreak)
        #expect(problem("echo safe\r") == .lineBreak)
        #expect(problem("echo \u{0}rm") == .lineBreak)
        #expect(problem("echo \u{1B}[31m") == .lineBreak)
        #expect(problem("echo a\u{2028}b") == .lineBreak)
        #expect(problem("echo \u{85}") == .lineBreak)
        #expect(problem("cat notes\u{202E}txt.sh") == .directionControl)
        #expect(problem("echo \u{2066}x\u{2069}") == .directionControl)
        #expect(problem("-rf") == .startsWithHyphen)
        #expect(problem(" -x") == .startsWithHyphen)
        #expect(problem(String(repeating: "a", count: ShellCommand.maximumBytes + 1)) == .tooLong)
        #expect(problem("printf 'a\\tb'\t| cat") == nil, "a tab is a space to a shell")
        #expect(problem("echo café 日本 👍🏽") == nil)
        #expect(problem(String(repeating: "a", count: ShellCommand.maximumBytes)) == nil)
    }

    @Test func durationsReadAsTenthsThenMinutesThenHours() {
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(Strings.duration(0, locale: locale) == "0.0 s")
        #expect(Strings.duration(12.34, locale: locale) == "12.3 s")
        #expect(Strings.duration(59.9, locale: locale) == "59.9 s")
        #expect(Strings.duration(125, locale: locale) == "2 min 5 s")
        #expect(Strings.duration(3 * 3600 + 7 * 60 + 9, locale: locale) == "3 h 7 min")
        #expect(Strings.duration(-4, locale: locale) == "0.0 s")
        #expect(Strings.duration(.nan, locale: locale) == "0.0 s")
        #expect(Strings.duration(.infinity, locale: locale) == "0.0 s")
        #expect(Strings.duration(1.5, locale: Locale(identifier: "de_DE")) == "1,5 s")
    }

    @Test func pageTitlesStayOnOneLineAndShort() {
        #expect(Strings.Page.title("make build") == "make build")
        let long = String(repeating: "x", count: 100)
        #expect(Strings.Page.title(long).count == 60 && Strings.Page.title(long).hasSuffix("…"))
    }
}
