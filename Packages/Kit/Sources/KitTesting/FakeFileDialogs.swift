import Foundation
import Kit
import Synchronization

/// File dialogs that answer with what a test set, and record what was asked.
public final class FakeFileDialogs: FileDialogService {
    private struct State {
        var filesToChoose: [URL] = []
        var saveLocation: URL?
        var openRequests: [OpenDialogRequest] = []
        var saveRequests: [SaveDialogRequest] = []
    }

    private let state = Mutex(State())

    public init() {}

    /// What the next open dialogs return. Empty plays the user cancelling.
    public var filesToChoose: [URL] {
        get { state.withLock { $0.filesToChoose } }
        set { state.withLock { $0.filesToChoose = newValue } }
    }

    /// What the next save dialogs return. Nil plays the user cancelling.
    public var saveLocation: URL? {
        get { state.withLock { $0.saveLocation } }
        set { state.withLock { $0.saveLocation = newValue } }
    }

    public var openRequests: [OpenDialogRequest] { state.withLock { $0.openRequests } }
    public var saveRequests: [SaveDialogRequest] { state.withLock { $0.saveRequests } }

    public func chooseFiles(_ request: OpenDialogRequest) async -> [URL] {
        state.withLock { state in
            state.openRequests.append(request)
            return state.filesToChoose
        }
    }

    public func chooseSaveLocation(_ request: SaveDialogRequest) async -> URL? {
        state.withLock { state in
            state.saveRequests.append(request)
            return state.saveLocation
        }
    }
}
