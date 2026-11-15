import Kit

/// Where root search keeps what it learns, and whether that works. App shows it in settings.
public enum RootStatus: Hashable, Sendable {
    /// Why the engine runs in memory although it was given a data folder.
    public enum InMemoryReason: Hashable, Sendable {
        /// Another engine holds the data folder, such as a second copy of the app.
        case directoryInUse
        /// The data folder cannot be created, read or written.
        case directoryUnusable
    }

    /// The engine is opening off the main thread. Root search has no engine results yet.
    case opening
    /// The engine is open. `persistent` is true when it saves learning in the data folder.
    case ready(persistent: Bool)
    /// The engine runs in memory because the data folder could not be used. Learning works until
    /// quit and is then lost.
    case inMemory(InMemoryReason)
    /// The engine could not be made at all. Root search shows answers and fallbacks only.
    case failed(String)

    /// What settings shows. Nil when all is well.
    public var featureStatus: FeatureStatus? {
        switch self {
        case .opening, .ready:
            return nil
        case .inMemory(.directoryInUse):
            return FeatureStatus(
                .warning, "Learning is not saved",
                message:
                    "Another copy of \(Brand.name) is using the data folder. What you teach it now is lost at quit.")
        case .inMemory(.directoryUnusable):
            return FeatureStatus(
                .warning, "Learning is not saved",
                message: "The data folder cannot be written. What you teach \(Brand.name) now is lost at quit.")
        case .failed(let reason):
            return FeatureStatus(.failure, "Root search is limited", message: reason)
        }
    }
}
