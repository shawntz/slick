import Kit
import Synchronization

/// A selection a test sets. Reads are counted, so a test can check the selection was read only in
/// response to the user.
public final class FakeSelection: SelectionService {
    private struct State {
        var selection: Selection?
        var reads = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// What ``currentSelection()`` returns.
    public var selection: Selection? {
        get { state.withLock { $0.selection } }
        set { state.withLock { $0.selection = newValue } }
    }

    /// How many times the selection was read.
    public var reads: Int { state.withLock { $0.reads } }

    public func currentSelection() async -> Selection? {
        state.withLock { state in
            state.reads += 1
            return state.selection
        }
    }
}
