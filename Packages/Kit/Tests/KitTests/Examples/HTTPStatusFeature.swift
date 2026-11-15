import Foundation
import Kit

/// Example 2 of docs/FEATURES.md: a searchable list over static data, with sections, a detail pane
/// and two actions. The host filters; the source hands over every row once.
final class HTTPStatusFeature: Feature {
    static let manifest = FeatureManifest(id: "http-status", name: "HTTP Status Codes", icon: .symbol("network"))

    init(context: FeatureContext) {}

    var commands: [Command] {
        [
            Command(id: "search", title: "Search HTTP Status Codes", icon: .symbol("magnifyingglass")) { _ in
                .push(.list(ListPage(HTTPStatusList(), searchPlaceholder: "Search status codes", showsDetail: true)))
            }
        ]
    }
}

final class HTTPStatusList: ListSource {
    nonisolated struct Status: Sendable {
        let code: Int
        let phrase: String
        let meaning: String
    }

    static let statuses = [
        Status(code: 200, phrase: "OK", meaning: "The request succeeded."),
        Status(code: 201, phrase: "Created", meaning: "The request created a resource."),
        Status(code: 204, phrase: "No Content", meaning: "The request succeeded and there is no body."),
        Status(code: 301, phrase: "Moved Permanently", meaning: "The resource has a new permanent URL."),
        Status(code: 304, phrase: "Not Modified", meaning: "The cached copy is still valid."),
        Status(code: 404, phrase: "Not Found", meaning: "The server has nothing at this URL."),
        Status(code: 418, phrase: "I'm a Teapot", meaning: "The server refuses to brew coffee."),
        Status(code: 429, phrase: "Too Many Requests", meaning: "The client is being rate limited."),
        Status(code: 503, phrase: "Service Unavailable", meaning: "The server is down or overloaded."),
    ]

    func load(_ request: ListRequest) async throws -> ListResult {
        let classes = Array(Set(Self.statuses.map { $0.code / 100 })).sorted()
        return ListResult(
            sections: classes.map { statusClass in
                ListSection(
                    "\(statusClass)xx",
                    rows: Self.statuses.filter { $0.code / 100 == statusClass }.map { status in
                        Row(
                            id: ItemID("http-status", String(status.code)), title: "\(status.code) \(status.phrase)",
                            icon: .symbol("number"), keywords: [status.meaning])
                    })
            })
    }

    func actions(for row: Row) -> [Action] {
        var actions = [Action.copy(row.id.key, title: "Copy Code")]
        if let url = URL(string: "https://httpwg.org/specs/rfc9110.html#status.\(row.id.key)") {
            actions.append(.open(url, title: "Open Specification", shortcut: .open))
        }
        return actions
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let status = Self.statuses.first(where: { String($0.code) == row.id.key }) else { return nil }
        return .markdown(
            "# \(status.code) \(status.phrase)\n\n\(status.meaning)",
            metadata: [.label("Class", value: "\(status.code / 100)xx")])
    }
}
