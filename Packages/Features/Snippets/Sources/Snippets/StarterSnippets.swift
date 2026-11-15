import Foundation

/// A few snippets for the first run, so the list is not empty and shows what placeholders do. They
/// are ordinary snippets: the user can change or delete them, and they never come back.
nonisolated enum StarterSnippets {
    static func all(at date: Date) -> [Snippet] {
        let collection = Strings.starterCollection
        func snippet(_ id: String, _ name: String, _ text: String, keyword: String) -> Snippet {
            Snippet(
                id: "starter-" + id, name: name, text: text, keyword: keyword, collection: collection, created: date,
                modified: date)
        }
        return [
            snippet("date", Strings.starterDate, "{date}", keyword: ";date"),
            snippet("time", Strings.starterTime, "{time}", keyword: ";time"),
            snippet("timestamp", Strings.starterTimestamp, "{date format=\"yyyy-MM-dd HH:mm\"}", keyword: ";now"),
            snippet("uuid", Strings.starterUUID, "{uuid}", keyword: ";uuid"),
            snippet("reply", Strings.starterReply, Strings.starterReplyText, keyword: ";thanks"),
        ]
    }
}
