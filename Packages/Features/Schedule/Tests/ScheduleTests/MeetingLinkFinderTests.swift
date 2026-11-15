import Foundation
import Testing

@testable import Schedule

/// Invitation text as people receive it, written by hand from the shapes each service sends. Every
/// address is synthetic.
@Suite("Meeting link finder", .timeLimit(.minutes(1)))
nonisolated struct MeetingLinkFinderTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        let provider: MeetingProvider?
        let link: String?

        init(_ name: String, _ text: String, _ provider: MeetingProvider?, _ link: String? = nil) {
            self.name = name
            self.text = text
            self.provider = provider
            self.link = link
        }

        var testDescription: String { name }
    }

    static let zoomInvitation = """
        Example Host is inviting you to a scheduled Zoom meeting.

        Join Zoom Meeting
        https://example.zoom.us/j/81234567890?pwd=AbCdEf123.1

        Meeting ID: 812 3456 7890
        Passcode: 123456

        ---

        One tap mobile
        +15550100,,81234567890#,,,,*123456# US

        Join by SIP
        \u{2022} 81234567890@zoomcrc.com

        Find your local number: https://example.zoom.us/u/abcdEFGH
        """

    static let meetDescription = """
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/abc-defg-hij
        Or dial: (US) +1 555-0100 PIN: 123456789#
        More phone numbers: https://tel.meet/abc-defg-hij?pin=123456789
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720
        Please do not edit this section.
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        """

    static let teamsLink =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZXhhbXBsZQ%40thread.v2/0?context=%7b%22Tid%22%3a%2200000000-0000-0000-0000-000000000000%22%2c%22Oid%22%3a%2211111111-1111-1111-1111-111111111111%22%7d"

    static let teamsInvitation = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join on your computer, mobile app or room device
        Click here to join the meeting<\(teamsLink)>
        Meeting ID: 123 456 789 012
        Passcode: abc123
        Download Teams<https://www.microsoft.com/en-us/microsoft-teams/download-app> | Join on the web<https://www.microsoft.com/microsoft-teams/join-a-meeting>
        Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=1&tenantId=2&threadId=3&messageId=0&language=en-US>
        ________________________________________________________________________________
        """

    static let teamsHTML = """
        <div style="width:100%"><span style="white-space:nowrap">________________</span></div>
        <div><span style="font-size:24px">Microsoft Teams meeting</span></div>
        <div><a class="me-email-headline" href="https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22t%22%7d" target="_blank" rel="noreferrer noopener">Join the meeting now</a></div>
        <div><a href="https://aka.ms/JoinTeamsMeeting?omkt=en-US">Learn more</a></div>
        """

    static let found: [Case] = [
        // Zoom
        Case("zoom full invitation", zoomInvitation, .zoom, "https://example.zoom.us/j/81234567890?pwd=AbCdEf123.1"),
        Case("zoom plain", "https://us02web.zoom.us/j/81234567890?pwd=ZXhhbXBsZQ", .zoom),
        Case("zoom personal room", "Room: https://zoom.us/my/example.room", .zoom, "https://zoom.us/my/example.room"),
        Case("zoom webinar", "https://zoom.us/w/91234567890?tk=abc", .zoom),
        Case("zoom for government", "https://agency.zoomgov.com/j/1612345678", .zoom),
        Case(
            "zoom app scheme", "zoommtg://zoom.us/join?action=join&confno=81234567890&pwd=abc", .zoom,
            "zoommtg://zoom.us/join?action=join&confno=81234567890&pwd=abc"),
        Case("zoom web client", "https://app.zoom.us/wc/join/123456789", .zoom),
        Case("zoom with sentence stop", "Zoom: https://zoom.us/j/123456789.", .zoom, "https://zoom.us/j/123456789"),
        Case("zoom in angle brackets", "Join<https://zoom.us/j/123456789>", .zoom, "https://zoom.us/j/123456789"),
        Case(
            "zoom in an anchor",
            "<a href=\"https://zoom.us/j/123456789?pwd=x\">https://zoom.us/j/123456789?pwd=x</a>", .zoom,
            "https://zoom.us/j/123456789?pwd=x"),
        Case("zoom in markdown", "[Join](https://zoom.us/j/123456789)", .zoom, "https://zoom.us/j/123456789"),
        Case("zoom in parentheses", "(https://zoom.us/j/123456789).", .zoom, "https://zoom.us/j/123456789"),
        Case(
            "zoom with ellipsis", "https://zoom.us/j/123456789?pwd=abc...", .zoom, "https://zoom.us/j/123456789?pwd=abc"
        ),
        Case("zoom glued to a label", "Link:https://zoom.us/j/123456789", .zoom, "https://zoom.us/j/123456789"),
        Case(
            "zoom before a no-break space", "https://zoom.us/j/123456789\u{00A0}(Passcode 1)", .zoom,
            "https://zoom.us/j/123456789"),
        Case("zoom without a scheme", "zoom.us/j/123456789", .zoom, "https://zoom.us/j/123456789"),

        // Google Meet
        Case("meet calendar description", meetDescription, .googleMeet, "https://meet.google.com/abc-defg-hij"),
        Case(
            "meet in a location with no scheme", "meet.google.com/xyz-abcd-efg", .googleMeet,
            "https://meet.google.com/xyz-abcd-efg"),
        Case("meet with account", "https://meet.google.com/abc-defg-hij?authuser=0&hs=122", .googleMeet),
        Case("meet lookup", "https://meet.google.com/lookup/abcdefghij", .googleMeet),
        Case("meet in capitals", "HTTPS://Meet.Google.com/abc-defg-hij", .googleMeet),
        Case(
            "meet in curly quotes", "\u{201C}https://meet.google.com/abc-defg-hij\u{201D}", .googleMeet,
            "https://meet.google.com/abc-defg-hij"),
        Case("meet short link", "https://g.co/meet/abc-defg-hij", .googleMeet),

        // Microsoft Teams
        Case("teams outlook invitation", teamsInvitation, .teams, teamsLink),
        Case(
            "teams outlook html", teamsHTML, .teams,
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%22t%22%7d"
        ),
        Case("teams short link", "https://teams.microsoft.com/meet/123456789012?p=AbCdEfGh", .teams),
        Case("teams personal", "https://teams.live.com/meet/9876543210987?p=xyz", .teams),
        Case("teams government", "https://gov.teams.microsoft.us/l/meetup-join/19%3ameeting_x%40thread.v2/0", .teams),
        Case(
            "teams html entity", "<a href=\"https://teams.microsoft.com/meet/123?p=abc&amp;anon=true\">Join</a>",
            .teams,
            "https://teams.microsoft.com/meet/123?p=abc&anon=true"),
        Case(
            "teams behind safe links",
            "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2540thread.v2%2F0&data=05%7C01%7C&sdata=abc&reserved=0",
            .teams, "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0"),

        // Webex, FaceTime and the rest
        Case("webex meeting", "https://example.webex.com/example/j.php?MTID=m0123456789abcdef", .webex),
        Case("webex personal room", "https://example.webex.com/meet/someone", .webex),
        Case("facetime link", "https://facetime.apple.com/join#v=1&p=AbCdEf&k=XyZ", .faceTime),
        Case("slack huddle", "https://app.slack.com/huddle/T01234567/C01234567", .slack),
        Case("whereby room", "https://whereby.com/example-room", .whereby),
        Case("jitsi room", "https://meet.jit.si/ExampleRoom123", .jitsi),
        Case("goto meeting", "https://global.gotomeeting.com/join/123456789", .goTo),
        Case("goto short", "https://meet.goto.com/123456789", .goTo),
        Case("bluejeans", "https://bluejeans.com/123456789/1234", .blueJeans),
        Case("chime", "https://chime.aws/1234567890", .chime),
        Case("skype", "https://join.skype.com/AbCdEfGhIjKl", .skype),
        Case("ringcentral", "https://v.ringcentral.com/join/123456789", .ringCentral),

        // Redirects
        Case(
            "google redirect",
            "https://www.google.com/url?q=https://zoom.us/j/123456789&sa=D&source=calendar&usg=AOvVaw",
            .zoom, "https://zoom.us/j/123456789"),
        Case(
            "url defense", "https://urldefense.com/v3/__https://zoom.us/j/123456789__;!!Abc$", .zoom,
            "https://zoom.us/j/123456789"),
    ]

    static let notFound: [Case] = [
        Case("empty", "", nil),
        Case("dial in only", "Dial in: tel:+15550100,,123456#", nil),
        Case("a document", "Agenda: https://docs.example.com/document/d/abc/edit", nil),
        Case("words only", "We will meet on zoom, link to follow", nil),
        Case("zoom home", "https://zoom.us/", nil),
        Case("zoom download", "https://zoom.us/download", nil),
        Case("zoom local numbers", "https://example.zoom.us/u/abcdEFGH", nil),
        Case("meet home", "https://meet.google.com/", nil),
        Case("meet new", "https://meet.google.com/new", nil),
        Case("meet phone numbers", "https://tel.meet/abc-defg-hij?pin=123456789", nil),
        Case("meet help", "Learn more about Meet at: https://support.google.com/a/users/answer/9282720", nil),
        Case(
            "teams help and options",
            "Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=1>",
            nil),
        Case("webex help", "https://help.webex.com/en-us/article/abc", nil),
        Case("facetime home", "https://facetime.apple.com/", nil),
        Case("look-alike host", "https://zoom.us.example.net/j/123456789", nil),
        Case("look-alike meet", "https://meet.google.com.example.net/abc-defg-hij", nil),
        Case("mail address", "Write to host@zoom.us if the link fails", nil),
    ]

    @Test(arguments: found)
    func findsTheLink(_ example: Case) throws {
        let link = try #require(MeetingLinkFinder.find(in: example.text), "\(example.name)")
        #expect(link.provider == example.provider)
        if let expected = example.link {
            #expect(link.url.absoluteString == expected)
        } else {
            #expect(link.url.absoluteString == example.text)
        }
    }

    @Test(arguments: notFound)
    func findsNothing(_ example: Case) {
        #expect(MeetingLinkFinder.find(in: example.text) == nil)
    }

    @Test func theURLFieldComesFirstThenTheLocationThenTheNotes() throws {
        let zoom = URL(string: "https://zoom.us/j/111111111")
        let agenda = URL(string: "https://docs.example.com/agenda")
        #expect(
            MeetingLinkFinder.find(url: zoom, location: "meet.google.com/abc-defg-hij", notes: Self.teamsInvitation)?
                .provider == .zoom)
        #expect(
            MeetingLinkFinder.find(url: agenda, location: "meet.google.com/abc-defg-hij", notes: Self.teamsInvitation)?
                .provider == .googleMeet)
        #expect(MeetingLinkFinder.find(url: nil, location: "Room 4", notes: Self.teamsInvitation)?.provider == .teams)
        #expect(MeetingLinkFinder.find(url: nil, location: nil, notes: nil) == nil)
    }

    @Test func theFirstMeetingLinkInATextWins() {
        let text = "Backup: https://meet.google.com/abc-defg-hij\nMain: https://zoom.us/j/123456789"
        #expect(MeetingLinkFinder.find(in: text)?.provider == .googleMeet)
    }

    @Test func aLinkPastTheScanLimitIsNotRead() {
        let filler = String(repeating: "Notes from the last meeting. ", count: 4_000)
        #expect(filler.utf8.count > MeetingLinkFinder.scanLimit)
        #expect(MeetingLinkFinder.find(in: filler + "https://zoom.us/j/123456789") == nil)
        #expect(MeetingLinkFinder.find(in: "https://zoom.us/j/123456789 " + filler)?.provider == .zoom)
    }

    @Test func oddTextNeverBreaksTheFinder() {
        let texts = [
            "\u{0000}https://zoom.us/j/1\u{0000}", "\u{202E}https://meet.google.com/abc-defg-hij",
            "https://", "http://", "https:// zoom.us/j/1", String(repeating: "/", count: 10_000),
            String(repeating: "a.b/", count: 5_000), "https://zoom.us/j/\u{1F600}",
            "https://\u{05D0}\u{05D1}.example/j/1", "facetime://", "msteams:",
        ]
        for text in texts {
            _ = MeetingLinkFinder.find(in: text)
        }
        #expect(MeetingLinkFinder.find(in: "\u{202E}https://meet.google.com/abc-defg-hij")?.provider == .googleMeet)
    }

    @Test func aLongInvitationIsReadQuickly() {
        let notes = String(repeating: Self.teamsInvitation + "\n", count: 40)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<20 { _ = MeetingLinkFinder.find(in: notes) }
        }
        #expect(elapsed < .seconds(2), "20 reads of a long invitation took \(elapsed)")
    }
}
