/// A page that shows one detail, such as a streamed AI answer or a script's full output.
public struct DetailPage: Sendable {
    public var title: String?
    public var source: any DetailSource

    public init(title: String? = nil, source: any DetailSource) {
        self.title = title
        self.source = source
    }

    /// A page that shows a fixed detail with fixed actions.
    @MainActor public init(title: String? = nil, detail: Detail, actions: [Action] = []) {
        self.init(title: title, source: StaticDetailSource(detail: detail, actions: actions))
    }
}

/// The data behind a detail page.
///
/// The host starts ``start()`` when the page appears and applies each update with
/// ``Detail/apply(_:)``, so text can stream in token by token; it draws at most one update per
/// display frame. When ``followUp`` is set, the search field becomes a follow-up field; on Return the
/// host cancels a stream that is still running, calls ``followUp(_:)`` and applies that stream on top
/// of what is shown. Leaving the page cancels the streams. Reload starts again.
///
/// `start()` runs on the main actor. Read and parse in a `@concurrent` function or a task that is not
/// on the main actor, and only yield updates to the continuation, which is `Sendable`.
@MainActor public protocol DetailSource: AnyObject, Sendable {
    /// The updates that build the detail. Finish the stream when done; throw to show an error.
    func start() -> AsyncThrowingStream<DetailUpdate, any Error>

    /// The actions for what is shown now, which the host passes in. The host asks when the page
    /// opens, when a stream ends and when ``actionsChanged`` fires, not after every update.
    func actions(for detail: Detail) -> [Action]

    /// Fires when the actions should be asked for again, such as when a stream starts and "Stop"
    /// should appear. Default nil.
    var actionsChanged: ChangeSignal? { get }

    /// When set, the page accepts follow-up text in the search field.
    var followUp: FollowUp? { get }

    /// Answers a follow-up. Default: an empty stream.
    func followUp(_ text: String) -> AsyncThrowingStream<DetailUpdate, any Error>
}

extension DetailSource {
    public var actionsChanged: ChangeSignal? { nil }
    public var followUp: FollowUp? { nil }

    public func followUp(_ text: String) -> AsyncThrowingStream<DetailUpdate, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// How a detail page asks for follow-up text.
public struct FollowUp: Hashable, Sendable {
    /// The search field's placeholder, such as "Ask a follow-up question".
    public var placeholder: String

    public init(placeholder: String) {
        self.placeholder = placeholder
    }
}

/// A detail source that shows one fixed detail.
@MainActor final class StaticDetailSource: DetailSource {
    private let detail: Detail
    private let fixedActions: [Action]

    init(detail: Detail, actions: [Action]) {
        self.detail = detail
        self.fixedActions = actions
    }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let detail = detail
        return AsyncThrowingStream { continuation in
            continuation.yield(.replace(detail))
            continuation.finish()
        }
    }

    func actions(for detail: Detail) -> [Action] {
        fixedActions
    }
}
