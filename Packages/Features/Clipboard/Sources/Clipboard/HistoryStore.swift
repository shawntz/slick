import Foundation
import Kit
import KitStorage
import os

/// Clipboard history on disk: one SQLite database with a full-text index, and a folder of images
/// and thumbnails beside it, all in the feature's own data folder.
///
/// An item's row ID is its place in the history: copying an item again, or using it, gives it the
/// highest ID, so "newest first" is a walk down the primary key and a search can stop after one
/// page. The item's identity is its ``ItemKey``, which never changes.
///
/// The database opens on first use inside the actor, so making the store touches nothing and no
/// call ever runs on the main thread.
///
/// A deleted item leaves nothing to read in the files. The database overwrites what it frees, every
/// delete empties the write-ahead log, and the folder is left out of backups. The full-text index
/// keeps a deleted row's trigrams until it is rewritten, which takes about 150 ms at 10,000 items,
/// so it is rewritten after every delete the user asks for, at the first prune of each session, and
/// after every ``pruneRewriteThreshold`` items that prunes removed.
actor HistoryStore {
    /// Characters of text a row shows and short searches look at.
    static let previewLength = 300
    /// Text up to this many bytes travels with its row, so the row can stand for it.
    static let shortTextBytes = 2_000
    /// Characters of each text the full-text index covers.
    static let indexedCharacters = 100_000
    /// Pinned items the first page shows.
    static let pinnedLimit = 1_000
    /// Items prunes may remove before the full-text index is rewritten without their trigrams.
    /// Prunes run after every copy, so rewriting each time would cost a copy 150 ms.
    static let pruneRewriteThreshold = 256

    nonisolated let folder: URL
    nonisolated let databaseURL: URL
    nonisolated let imagesFolder: URL
    nonisolated let thumbnailsFolder: URL

    private var database: SQLiteDatabase?
    /// The folder a damaged database was moved to in this session, so the history page can say so.
    private(set) var damagedCopy: URL?
    /// Items prunes removed since the full-text index was last rewritten.
    private var prunedSinceRewrite = 0
    /// True once a prune ran in this session.
    private var hasPruned = false
    /// How many times the full-text index was rewritten in this session. For tests.
    private(set) var indexRewrites = 0

    /// A store in `folder`. Touches nothing until the first call.
    init(folder: URL) {
        self.folder = folder
        databaseURL = folder.appending(path: "history.sqlite", directoryHint: .notDirectory)
        imagesFolder = folder.appending(path: "images", directoryHint: .isDirectory)
        thumbnailsFolder = folder.appending(path: "thumbnails", directoryHint: .isDirectory)
    }

    // MARK: - Writing

    /// Saves a capture, or moves the item that holds the same content to the top. Returns its key.
    @discardableResult
    func record(_ capture: Capture, at date: Date) throws -> ItemKey {
        let database = try open()
        let key = capture.key
        let exists = try !database.query("SELECT 1 FROM item WHERE key = ?", [key.sqlite]) { _ in true }.isEmpty
        if exists {
            try database.transaction {
                try database.run(
                    """
                    UPDATE item SET id = (SELECT max(id) FROM item) + 1, kind = ?, rtf = ?, source = coalesce(?, source),
                        copied = ?, copy_count = copy_count + 1
                    WHERE key = ?
                    """,
                    [
                        .text(capture.kind.rawValue), SQLiteValue(capture.rtf), SQLiteValue(capture.source),
                        .date(date),
                        key.sqlite,
                    ])
            }
            return key
        }
        var files = (image: String?.none, thumbnail: String?.none)
        var size: (width: Int, height: Int)?
        if let image = capture.image {
            files = try writeImage(image, type: capture.imageType, key: key)
            size = ImageFiles.pixelSize(of: image)
        }
        do {
            try database.transaction {
                try insert(capture, key: key, files: files, size: size, date: date, into: database)
            }
        } catch {
            removeFiles([files.image.map { imagesFolder.appending(path: $0) }, files.thumbnail.map(thumbnailURL)])
            throw error
        }
        return key
    }

    /// Saves many captures in one transaction, oldest first. For benchmarks and tests that need a
    /// large history quickly; images are not supported.
    func record(batch captures: [(capture: Capture, date: Date)]) throws {
        let database = try open()
        try database.transaction {
            for (capture, date) in captures where capture.image == nil {
                try insert(capture, key: capture.key, files: (nil, nil), size: nil, date: date, into: database)
            }
        }
    }

    /// Moves an item to the top, as after the user pasted it from the history. Returns false when
    /// the item is gone.
    @discardableResult
    func moveToTop(_ key: ItemKey, at date: Date) throws -> Bool {
        let database = try open()
        return try database.transaction {
            try database.run(
                "UPDATE item SET id = (SELECT max(id) FROM item) + 1, copied = ? WHERE key = ?",
                [.date(date), key.sqlite])
            return database.changes > 0
        }
    }

    /// Pins or unpins an item. Returns false when the item is gone.
    @discardableResult
    func setPinned(_ isPinned: Bool, key: ItemKey) throws -> Bool {
        let database = try open()
        try database.run("UPDATE item SET pinned = ? WHERE key = ?", [.bool(isPinned), key.sqlite])
        return database.changes > 0
    }

    /// Deletes one item and its files. Returns false when it was already gone.
    @discardableResult
    func delete(_ key: ItemKey) throws -> Bool {
        try erasing(deleteItems(where: "key = ?", [key.sqlite])) > 0
    }

    /// Deletes every item, or every unpinned one, with their files. Returns how many went.
    @discardableResult
    func deleteAll(keepingPinned: Bool) throws -> Int {
        try erasing(deleteItems(where: keepingPinned ? "pinned = 0" : "1", []))
    }

    /// Deletes unpinned items copied at or after `date`. Returns how many went.
    @discardableResult
    func delete(copiedSince date: Date) throws -> Int {
        try erasing(deleteItems(where: "pinned = 0 AND copied >= ?", [.date(date)]))
    }

    /// Applies the retention period, the item cap and the image storage cap to unpinned items,
    /// oldest first. Pinned items are never pruned. Returns how many items went.
    @discardableResult
    func prune(_ policy: PrunePolicy) throws -> Int {
        let database = try open()
        var removed = 0
        if let cutoff = policy.cutoff {
            removed += try deleteItems(where: "pinned = 0 AND copied < ?", [.date(cutoff)])
        }
        // Row IDs only grow, so the span from the lowest to the highest bounds the count. The walk
        // to the cap runs only when the history may be over it.
        let span =
            try database.query("SELECT (SELECT min(id) FROM item), (SELECT max(id) FROM item)") { row in
                (row.int(1) ?? 0) - (row.int(0) ?? 0) + 1
            }.first ?? 0
        if span > policy.maximumItems {
            let boundary =
                try database.query(
                    "SELECT id FROM item WHERE pinned = 0 ORDER BY id DESC LIMIT 1 OFFSET ?",
                    [SQLiteValue(policy.maximumItems)]
                ) { $0.int(0) }.first ?? nil
            if let boundary {
                removed += try deleteItems(where: "pinned = 0 AND id <= ?", [.integer(boundary)])
            }
        }
        let imageBytes =
            try database.query("SELECT sum(byte_count) FROM item WHERE kind = 'image' AND pinned = 0") {
                $0.int(0) ?? 0
            }.first ?? 0
        if imageBytes > policy.maximumImageBytes {
            removed += try deleteItems(
                where: """
                    id IN (SELECT id FROM (SELECT id, sum(byte_count) OVER (ORDER BY id DESC) AS total
                        FROM item WHERE kind = 'image' AND pinned = 0) WHERE total > ?)
                    """,
                [SQLiteValue(policy.maximumImageBytes)])
        }
        // The first prune of a session also clears what the last session's prunes left in the index.
        let isFirst = !hasPruned
        hasPruned = true
        prunedSinceRewrite += removed
        guard removed > 0 || isFirst else { return 0 }
        return try erasing(removed, rewritingIndex: isFirst || prunedSinceRewrite >= Self.pruneRewriteThreshold)
    }

    // MARK: - Reading

    /// One page of items for the history list, newest first. The first page also holds the pinned
    /// items that match. Stops with `CancellationError` when the calling task is cancelled.
    func page(_ request: PageRequest) throws -> HistoryPage {
        let database = try open()
        var pinned: [ItemSummary] = []
        if request.cursor == nil {
            pinned = try items(pinned: true, request, limit: Self.pinnedLimit, in: database)
        }
        guard request.filter != .pinned else { return HistoryPage(pinned: pinned, items: [], nextCursor: nil) }
        var items = try items(pinned: false, request, limit: request.limit + 1, in: database)
        var next: Int64?
        if items.count > request.limit {
            items.removeLast()
            next = items.last?.order
        }
        return HistoryPage(pinned: pinned, items: items, nextCursor: next)
    }

    /// One item's summary, or nil when it is gone.
    func summary(_ key: ItemKey) throws -> ItemSummary? {
        try open().query("SELECT \(Self.summaryColumns) FROM item WHERE key = ?", [key.sqlite]) { summary(from: $0) }
            .first
    }

    /// One item with its whole content, or nil when it is gone.
    func detail(_ key: ItemKey) throws -> ItemDetail? {
        try open().query(
            "SELECT \(Self.summaryColumns), text, rtf, image_type, first_copied, copy_count FROM item WHERE key = ?",
            [key.sqlite]
        ) { row in
            ItemDetail(
                summary: summary(from: row), text: row.string(13), rtf: row.data(14), imageType: row.string(15),
                firstCopied: row.date(16) ?? .distantPast, copyCount: Int(row.int(17) ?? 1))
        }.first
    }

    /// The item as the pasteboard takes it, or nil when it is gone. With `plainText`, styled text and
    /// links become plain text and files become their paths; an image has no plain form and gives
    /// nil.
    func content(_ key: ItemKey, plainText: Bool = false) throws -> PasteboardContent? {
        let rows = try open().query(
            "SELECT kind, text, rtf, image_file, image_type FROM item WHERE key = ?", [key.sqlite]
        ) { row in
            (
                kind: row.string(0).flatMap(ClipKind.init(rawValue:)), text: row.string(1), rtf: row.data(2),
                imageFile: row.string(3), imageType: row.string(4)
            )
        }
        guard let stored = rows.first, let kind = stored.kind else { return nil }
        if plainText { return stored.text.map(PasteboardContent.text) }
        let text = stored.text ?? ""
        switch kind {
        case .text, .color:
            return .text(text)
        case .richText:
            return stored.rtf.map { .richText(rtf: $0, plain: text) } ?? .text(text)
        case .link:
            return URL(string: text).map(PasteboardContent.url) ?? .text(text)
        case .files:
            return .files(Self.fileURLs(text))
        case .image:
            guard let file = stored.imageFile else { return nil }
            let data = try Data(contentsOf: imagesFolder.appending(path: file))
            return .image(data, typeIdentifier: stored.imageType ?? "public.png")
        }
    }

    /// The text copied `offset` items ago, newest first, skipping images: what `{clipboard
    /// offset=N}` reads.
    func text(offset: Int) throws -> String? {
        guard offset >= 0 else { return nil }
        return try open().query(
            "SELECT text FROM item WHERE text IS NOT NULL AND kind != 'image' ORDER BY id DESC LIMIT 1 OFFSET ?",
            [SQLiteValue(offset)]
        ) { $0.string(0) }.first ?? nil
    }

    /// How many items the history holds.
    func count() throws -> Int {
        Int(try open().query("SELECT count(*) FROM item") { $0.int(0) ?? 0 }.first ?? 0)
    }

    /// SQLite's `secure_delete` on the open database: 1 when it overwrites what it frees. For tests.
    func secureDeleteMode() throws -> Int {
        Int(try open().query("PRAGMA secure_delete") { $0.int(0) ?? 0 }.first ?? 0)
    }

    /// True when the folder is left out of backups. For tests.
    nonisolated var isExcludedFromBackup: Bool {
        (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    /// Every item's key, newest first. For tests.
    func keys() throws -> [ItemKey] {
        try open().query("SELECT key FROM item ORDER BY id DESC") { ItemKey(sqlite: $0.int(0) ?? 0) }
    }

    /// Closes the database. The next call opens it again.
    func close() {
        database?.close()
        database = nil
    }

    // MARK: - Internals

    private static let summaryColumns = """
        id, key, kind, preview, CASE WHEN byte_count <= \(shortTextBytes) THEN text END, image_file, thumbnail_file,
        width, height, byte_count, source, copied, pinned
        """

    /// The database, opened on first use. A file SQLite cannot read is never repaired in place or
    /// deleted: it moves, with the images it names, into a folder of its own, and a new history
    /// starts. Otherwise every copy would fail from then on.
    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        do {
            return try openDatabase()
        } catch let error as SQLiteError where Self.isDamage(error) {
            damagedCopy = try setDamagedFilesAside()
            return try openDatabase()
        }
    }

    private func openDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: databaseURL)
        try database.migrate(HistorySchema.migrations(foldingAccents: HistorySchema.supportsAccentFolding))
        // A backup would keep every item the user deletes later. Without the mark the history
        // still works, so a failure only goes to the log.
        do {
            try Self.excludeFromBackups(folder)
        } catch {
            HistoryStore.log.error(
                "Could not keep the history out of backups: \(error.localizedDescription, privacy: .private)")
        }
        self.database = database
        return database
    }

    private static let log = KitLog.logger(category: "clipboard.store")

    /// Marks a folder, and so everything in it, as left out of Time Machine and other backups.
    nonisolated static func excludeFromBackups(_ folder: URL) throws {
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// True for the errors SQLite gives for a file that is not a database or is corrupt. A full disk,
    /// a lock or a missing folder is not damage, and leaves the file where it is.
    nonisolated static func isDamage(_ error: SQLiteError) -> Bool {
        let corrupt: Int32 = 11
        let notADatabase: Int32 = 26
        return [corrupt, notADatabase].contains(error.code & 0xFF)
    }

    /// Moves the database, its journal files, the images and the thumbnails into `damaged-N` in the
    /// same folder, with the first free N. Returns that folder.
    private func setDamagedFilesAside() throws -> URL {
        let manager = FileManager.default
        var number = 1
        var destination = folder.appending(path: "damaged-1", directoryHint: .isDirectory)
        while manager.fileExists(atPath: destination.path) {
            number += 1
            destination = folder.appending(path: "damaged-\(number)", directoryHint: .isDirectory)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = databaseURL.lastPathComponent
        let items = [
            name, name + "-wal", name + "-shm", imagesFolder.lastPathComponent, thumbnailsFolder.lastPathComponent,
        ]
        for item in items where manager.fileExists(atPath: folder.appending(path: item).path) {
            try manager.moveItem(at: folder.appending(path: item), to: destination.appending(path: item))
        }
        return destination
    }

    /// Items newest first. How a search runs depends on what it looks through, so a common word stays
    /// fast at 50,000 items:
    /// - all items, or text: walk the full-text index in descending row order and stop after a page;
    /// - one rarer kind, such as links: collect the matches, then walk that kind's index;
    /// - pinned items: walk them and ask the index about each one.
    private func items(pinned: Bool, _ request: PageRequest, limit: Int, in database: SQLiteDatabase) throws
        -> [ItemSummary]
    {
        var source = "item"
        var order = "id"
        var conditions: [String] = []
        var parameters: [SQLiteValue] = []
        if let match = request.query.matchExpression {
            if pinned {
                // Pinned items are few: probe the index once for each of them.
                source = "item CROSS JOIN item_search ON item_search.rowid = item.id"
                conditions.append("item_search MATCH ?")
            } else if let kinds = request.filter.kinds, !kinds.contains(.text) {
                // A rarer kind: walk that kind's index against the set of matches.
                conditions.append("id IN (SELECT rowid FROM item_search WHERE item_search MATCH ?)")
            } else {
                source = "item_search JOIN item ON item.id = item_search.rowid"
                order = "item_search.rowid"
                conditions.append("item_search MATCH ?")
            }
            parameters.append(.text(match))
        }
        conditions.append("pinned = ?")
        parameters.append(.bool(pinned))
        if let kinds = request.filter.kinds {
            conditions.append("kind IN (" + kinds.map { _ in "?" }.joined(separator: ", ") + ")")
            parameters += kinds.map { .text($0.rawValue) }
        }
        for pattern in request.query.likePatterns {
            conditions.append("preview LIKE ? ESCAPE '\\'")
            parameters.append(.text(pattern))
        }
        if let cursor = request.cursor {
            conditions.append("\(order) < ?")
            parameters.append(.integer(cursor))
        }
        parameters.append(SQLiteValue(limit))
        let sql = """
            SELECT \(Self.summaryColumns) FROM \(source) WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order) DESC LIMIT ?
            """
        return try database.query(sql, parameters) { summary(from: $0) }
    }

    private func insert(
        _ capture: Capture, key: ItemKey, files: (image: String?, thumbnail: String?), size: (width: Int, height: Int)?,
        date: Date, into database: SQLiteDatabase
    ) throws {
        try database.run(
            """
            INSERT INTO item (key, kind, text, preview, rtf, image_file, thumbnail_file, image_type, width, height,
                byte_count, source, first_copied, copied)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                key.sqlite, .text(capture.kind.rawValue), SQLiteValue(capture.text),
                SQLiteValue(capture.text.map(Self.preview)), SQLiteValue(capture.rtf),
                SQLiteValue(files.image), SQLiteValue(files.thumbnail), SQLiteValue(capture.imageType),
                SQLiteValue(size?.width), SQLiteValue(size?.height), SQLiteValue(capture.byteCount),
                SQLiteValue(capture.source), .date(date), .date(date),
            ])
    }

    /// Writes the image and its thumbnail, named by the key. Returns their file names; the
    /// thumbnail's is nil when ImageIO could not read the image.
    private func writeImage(_ data: Data, type: String?, key: ItemKey) throws -> (image: String?, thumbnail: String?) {
        let manager = FileManager.default
        try manager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)
        let name = key.hex + "." + ImageFiles.fileExtension(for: type)
        try data.write(to: imagesFolder.appending(path: name), options: .atomic)
        let thumbnail = key.hex + ".png"
        let madeThumbnail = ImageFiles.writeThumbnail(of: data, to: thumbnailURL(thumbnail))
        return (name, madeThumbnail ? thumbnail : nil)
    }

    private func thumbnailURL(_ name: String) -> URL {
        thumbnailsFolder.appending(path: name)
    }

    /// Clears what `removed` deleted rows left in the files and returns `removed`. The freed pages
    /// are already overwritten. With `rewritingIndex`, which a delete the user asked for always
    /// sets, the full-text index is rewritten without the deleted rows' trigrams. Then the
    /// write-ahead log is copied in and emptied, so it keeps no page from before the delete.
    private func erasing(_ removed: Int, rewritingIndex: Bool? = nil) throws -> Int {
        let rewritingIndex = rewritingIndex ?? (removed > 0)
        guard let database, removed > 0 || rewritingIndex else { return removed }
        if rewritingIndex {
            try database.execute("INSERT INTO item_search (item_search) VALUES ('optimize')")
            indexRewrites += 1
            prunedSinceRewrite = 0
        }
        try database.checkpointAndTruncateLog()
        return removed
    }

    /// Deletes the rows that match and then their files. Returns how many rows went.
    private func deleteItems(where condition: String, _ parameters: [SQLiteValue]) throws -> Int {
        let database = try open()
        let files = try database.transaction {
            let files = try database.query("SELECT image_file, thumbnail_file FROM item WHERE \(condition)", parameters)
            {
                [$0.string(0).map { imagesFolder.appending(path: $0) }, $0.string(1).map(thumbnailURL)]
            }
            try database.run("DELETE FROM item WHERE \(condition)", parameters)
            return files
        }
        removeFiles(files.flatMap(\.self))
        return files.count
    }

    private func removeFiles(_ urls: [URL?]) {
        for case let url? in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func summary(from row: SQLiteRow) -> ItemSummary {
        ItemSummary(
            order: row.int(0) ?? 0,
            key: ItemKey(sqlite: row.int(1) ?? 0),
            kind: row.string(2).flatMap(ClipKind.init(rawValue:)) ?? .text,
            preview: row.string(3),
            shortText: row.string(4),
            imageURL: row.string(5).map { imagesFolder.appending(path: $0) },
            thumbnailURL: row.string(6).map(thumbnailURL),
            pixelWidth: row.int(7).map(Int.init),
            pixelHeight: row.int(8).map(Int.init),
            byteCount: Int(row.int(9) ?? 0),
            source: row.string(10),
            copied: row.date(11) ?? .distantPast,
            isPinned: row.bool(12) ?? false)
    }

    /// What a row shows and a short search looks at: the text from its first character that is not
    /// white space, so text that starts with many blank lines still has a title.
    nonisolated static func preview(_ text: String) -> String {
        String(text.drop(while: \.isWhitespace).prefix(previewLength))
    }

    /// File URLs from paths stored one per line.
    nonisolated static func fileURLs(_ paths: String) -> [URL] {
        paths.split(separator: "\n").map { URL(filePath: String($0)) }
    }
}
