import Foundation
import Kit
import KitTemplates
import Testing

@testable import Quicklinks

@Suite("Link templates: expansion and encoding", .timeLimit(.minutes(1)))
struct LinkTemplateTests {
    // MARK: Encoding by component

    @Test(
        "A value in the query string is encoded so it cannot add parameters",
        arguments: [
            ("swift concurrency", "swift%20concurrency"),
            ("a&b=c#d?e/f", "a%26b%3Dc%23d%3Fe%2Ff"),
            ("100%", "100%25"),
            ("%41 is not decoded", "%2541%20is%20not%20decoded"),
            ("café ☕", "caf%C3%A9%20%E2%98%95"),
            ("line\r\nnext", "line%0D%0Anext"),
            ("\u{202E}reversed", "%E2%80%AEreversed"),
            ("1+1", "1%2B1"),
            ("nul\u{0}byte", "nul%00byte"),
            ("<script>\"'`", "%3Cscript%3E%22%27%60"),
            ("-._~", "-._~"),
        ])
    func queryValues(value: String, encoded: String) async {
        let link = await render("https://search.example.org/find?q={query}&page=1", ["Query": value])
        #expect(link == "https://search.example.org/find?q=\(encoded)&page=1")
    }

    @Test(
        "A value in a path keeps its slashes and nothing else",
        arguments: [
            ("org/project", "org/project"),
            ("a b?c#d", "a%20b%3Fc%23d"),
            ("%2F", "%252F"),
            ("name@scope:1", "name%40scope%3A1"),
            ("../up", "../up"),
        ])
    func pathValues(value: String, encoded: String) async {
        let link = await render("https://code.example.com/{argument name=\"Repo\"}/issues", ["Repo": value])
        #expect(link == "https://code.example.com/\(encoded)/issues")
    }

    @Test func aValueInTheHostCannotEndTheHost() async throws {
        let template = "https://{argument name=\"Team\"}.example.com/board"
        #expect(
            await render(template, ["Team": "evil.example.net/x?y#z"])
                == "https://evil.example.net%2Fx%3Fy%23z.example.com/board")
        #expect(await render(template, ["Team": "user@other"]) == "https://user%40other.example.com/board")
        #expect(await render(template, ["Team": "a:1"]) == "https://a%3A1.example.com/board")
        #expect(LinkTemplate(template).webHost == nil, "a value in the host means no favicon")
    }

    @Test func aValueAfterASchemeWithoutSlashesEncodesSlashes() async {
        let link = await render(
            "mailto:{argument name=\"To\"}", ["To": "a@example.com?cc=b@example.com"])
        #expect(link == "mailto:a%40example.com%3Fcc%3Db%40example.com")
        #expect(
            await render("tel:{argument name=\"Number\"}", ["Number": "//evil.example"]) == "tel:%2F%2Fevil.example")
    }

    @Test func aValueInTheFragmentIsEncoded() async {
        let link = await render("https://docs.example.com/page#{argument name=\"Section\"}", ["Section": "a b#c"])
        #expect(link == "https://docs.example.com/page#a%20b%23c")
    }

    @Test func modifiersChooseTheirOwnEncoding() async {
        #expect(
            await render("https://x.example.com/{argument name=\"P\" | raw}", ["P": "a b/c?d"])
                == "https://x.example.com/a b/c?d")
        #expect(
            await render("https://x.example.com/{argument name=\"P\" | percent-encode}", ["P": "a/b c"])
                == "https://x.example.com/a%2Fb%20c")
        #expect(
            await render("https://x.example.com/?q={argument name=\"Q\" | uppercase}", ["Q": "abc d"])
                == "https://x.example.com/?q=ABC%20D")
        #expect(
            await render("https://x.example.com/?q={argument name=\"Q\" | trim}", ["Q": "  padded \n"])
                == "https://x.example.com/?q=padded")
    }

    // MARK: Arguments

    @Test func namedArgumentsTakeTheirDefaultsWhenEmpty() async {
        let template =
            "https://translate.example.com/?text={argument name=\"Text\"}&to={argument name=\"To\" default=\"en\"}"
        #expect(await render(template, ["Text": "hola"]) == "https://translate.example.com/?text=hola&to=en")
        #expect(
            await render(template, ["Text": "hola", "To": "fr"]) == "https://translate.example.com/?text=hola&to=fr")
        let arguments = LinkTemplate(template).commandArguments
        #expect(arguments.map(\.name) == ["Text", "To"])
        #expect(arguments.map(\.isOptional) == [false, true])
        #expect(arguments.last?.defaultValue == "en")
    }

    @Test func optionsMakeADropdownArgument() {
        let arguments = LinkTemplate("https://x.example.com/?size={argument name=\"Size\" options=\"s, m, l\"}")
            .commandArguments
        #expect(arguments.first?.kind == .dropdown([.init("s"), .init("m"), .init("l")]))
    }

    @Test func unnamedArgumentsKeepTheirOwnValues() async {
        let template = "https://x.example.com/{argument}/{argument}?q={argument}"
        #expect(LinkTemplate(template).arguments.map(\.key) == ["#1", "#2", "#3"])
        #expect(
            await render(template, ["#1": "a", "#2": "b/c", "#3": "c d"]) == "https://x.example.com/a/b/c?q=c%20d")
    }

    @Test func aNameUsedTwiceSharesOneValue() async {
        let template = "https://x.example.com/{argument name=\"Term\"}?again={argument name=\"Term\"}"
        #expect(LinkTemplate(template).arguments.count == 1)
        #expect(await render(template, ["Term": "a b"]) == "https://x.example.com/a%20b?again=a%20b")
    }

    @Test func theShortFormIsTheQueryArgument() async {
        let template = LinkTemplate("https://search.example.org/?q={query}")
        #expect(template.arguments.map(\.key) == [LinkTemplate.queryArgumentName])
        #expect(template.takesQuery)
        #expect(template.source == "https://search.example.org/?q={query}", "the link is stored as written")
        #expect(
            await render("https://search.example.org/?q={query}", ["Query": "x y"])
                == "https://search.example.org/?q=x%20y")
    }

    @Test(
        "Takes the query when the first argument is free text and the rest have defaults",
        arguments: [
            ("https://x.example.com/?q={query}", true),
            ("https://x.example.com/?q={argument name=\"A\"}&b={argument name=\"B\" default=\"1\"}", true),
            ("https://x.example.com/?q={argument name=\"A\"}&b={argument name=\"B\"}", false),
            ("https://x.example.com/?q={argument name=\"A\" options=\"x, y\"}", false),
            ("https://x.example.com/", false),
            ("https://x.example.com/?q={clipboard}", false),
        ])
    func takesQuery(link: String, expected: Bool) {
        #expect(LinkTemplate(link).takesQuery == expected)
    }

    // MARK: Other placeholders

    @Test func clipboardSelectionDateAndUUIDAreRenderedAndEncoded() async {
        #expect(
            await render("https://x.example.com/?q={clipboard}", clipboard: "copied text")
                == "https://x.example.com/?q=copied%20text")
        #expect(
            await render("https://x.example.com/?q={selection}", selection: "picked & chosen")
                == "https://x.example.com/?q=picked%20%26%20chosen")
        #expect(
            await render("https://x.example.com/{date format=\"yyyy-MM-dd\"}") == "https://x.example.com/2027-01-15")
        #expect(
            await render("https://x.example.com/?id={uuid}")
                == "https://x.example.com/?id=00010203-0405-0607-0809-0A0B0C0D0E0F")
    }

    @Test func unknownBracesStayAsTyped() async {
        #expect(await render("https://x.example.com/?json={a}") == "https://x.example.com/?json={a}")
    }

    // MARK: A value that starts the link

    @Test func aBareDomainAtTheStartBecomesAWebLink() async throws {
        let template = LinkTemplate("{clipboard}")
        #expect(template.startsWithValue)
        let url = try await template.url(in: environment(clipboard: "  docs.example.com/guide  "))
        #expect(url.absoluteString == "https://docs.example.com/guide")
        let direct = try await template.url(in: environment(clipboard: "https://example.org/a?b=c"))
        #expect(direct.absoluteString == "https://example.org/a?b=c")
    }

    @Test(
        "A value at the start may not pick a scheme other than the web",
        arguments: ["javascript:alert(1)", "file:///etc/hosts", "data:text/html,hello", "x-example-app://run"])
    func startingValueMustBeWeb(value: String) async {
        await #expect(throws: LinkError.notWeb) {
            try await LinkTemplate("{clipboard}").url(in: environment(clipboard: value))
        }
    }

    @Test func anEmptyStartingValueIsNotALink() async {
        await #expect(throws: LinkError.notALink) {
            try await LinkTemplate("{clipboard}").url(in: environment(clipboard: nil))
        }
    }

    @Test func theCheckRefusesALinkWhoseSchemeChanged() {
        #expect(throws: LinkError.schemeChanged) {
            try LinkTemplate.check("javascript:alert(1)", writtenScheme: "https")
        }
        #expect(throws: LinkError.notALink) { try LinkTemplate.check("https://", writtenScheme: "https") }
        #expect(throws: Never.self) { try LinkTemplate.check("slack://open", writtenScheme: "slack") }
    }

    // MARK: Reading the link

    @Test func theWebHostIsTheLiteralHostLowercased() {
        #expect(LinkTemplate("https://User@Docs.Example.com:8443/x?q={query}").webHost == "docs.example.com")
        #expect(LinkTemplate("http://localhost:3000/{query}").webHost == "localhost")
        #expect(LinkTemplate("slack://open").webHost == nil)
        #expect(LinkTemplate("{clipboard}").webHost == nil)
    }

    @Test func theDisplayTextDropsTheSchemeAndWWW() {
        #expect(LinkTemplate("https://www.example.com/a?q={query}").displayText == "example.com/a?q={query}")
        #expect(LinkTemplate("slack://open").displayText == "slack://open")
    }

    // MARK: Checking what the user typed

    @Test func aBareAddressGetsAScheme() {
        #expect(LinkTemplate.validated("  docs.example.com/guide  ") == .valid("https://docs.example.com/guide"))
        #expect(LinkTemplate.validated("localhost:8080/{query}") == .valid("http://localhost:8080/{query}"))
        #expect(LinkTemplate.validated("https://docs.example.com") == .valid("https://docs.example.com"))
    }

    @Test(
        "Deep links, mail links and links that start with a value are fine",
        arguments: [
            "mailto:{argument name=\"To\"}", "slack://channel?team={argument name=\"Team\"}",
            "x-example-notes://open?vault=Notes&file={query}", "{clipboard}", "{selection}",
        ])
    func validLinks(link: String) {
        #expect(LinkTemplate.validated(link) == .valid(link))
    }

    @Test func mistakesPointAtThePlaceholderInTheTypedText() throws {
        let typed = "  x.example.com/{query}?q={clipboard offset=-1}"
        guard case .invalid(let error) = LinkTemplate.validated(typed) else {
            Issue.record("expected an error")
            return
        }
        let expected = (typed as NSString).range(of: "{clipboard offset=-1}")
        #expect(error.range == expected.location..<expected.location + expected.length)
        #expect(error.message.hasPrefix("Fix this placeholder:"))
    }

    @Test func aFourthArgumentIsAMistake() {
        let link = "https://x.example.com/{argument}/{argument}/{argument}/{argument}"
        guard case .invalid(let error) = LinkTemplate.validated(link) else {
            Issue.record("expected an error")
            return
        }
        #expect(error.message.contains("at most 3"))
    }

    @Test func otherMistakes() {
        #expect(LinkTemplate.validated("example") == .invalid(FieldError(Strings.linkNeedsScheme)))
        #expect(LinkTemplate.validated("https://") == .invalid(FieldError(Strings.linkNeedsHost)))
        #expect(LinkTemplate.validated("https://a.example.com/\nb") == .invalid(FieldError(Strings.linkOneLine)))
        let long = "https://x.example.com/" + String(repeating: "a", count: LinkTemplate.maximumLength)
        #expect(LinkTemplate.validated(long) == .invalid(FieldError(Strings.linkTooLong)))
    }

    @Test func aVeryLongValueIsEncodedWhole() async {
        let value = String(repeating: "a b/", count: 5000)
        let link = await render("https://x.example.com/?q={query}", ["Query": value])
        #expect(link.count == "https://x.example.com/?q=".count + 5000 * "a%20b%2F".count)
    }
}
