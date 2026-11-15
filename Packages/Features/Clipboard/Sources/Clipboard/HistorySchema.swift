import KitStorage

/// The history database's schema, as numbered migrations. Never edit a migration that has shipped;
/// append one.
///
/// The indexes lead with the columns every query fixes, so SQLite picks them without statistics:
/// `item_order` walks unpinned items newest first, `item_kind` serves the type filter and the image
/// storage cap, and `item_age` serves retention and Clear Recent. `item_order` also holds the
/// preview, so a search for a word under three characters tests each row in the index alone and
/// reads the table only for a match.
///
/// The whole text and the styling come last in each row, so reading a row's other columns never
/// reads the overflow pages of a long text.
nonisolated enum HistorySchema {
    /// The migrations. The full-text index folds accents when the system's SQLite can, which needs
    /// version 3.45.
    static func migrations(foldingAccents: Bool) -> [String] {
        let tokenizer = foldingAccents ? "trigram remove_diacritics 1" : "trigram"
        return [
            """
            CREATE TABLE item (
                id INTEGER PRIMARY KEY,
                key INTEGER NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                copied REAL NOT NULL,
                first_copied REAL NOT NULL,
                copy_count INTEGER NOT NULL DEFAULT 1,
                byte_count INTEGER NOT NULL,
                source TEXT,
                image_file TEXT,
                thumbnail_file TEXT,
                image_type TEXT,
                width INTEGER,
                height INTEGER,
                preview TEXT,
                text TEXT,
                rtf BLOB
            );
            CREATE INDEX item_order ON item (pinned, id, preview);
            CREATE INDEX item_kind ON item (kind, pinned, id);
            CREATE INDEX item_age ON item (pinned, copied);
            CREATE VIRTUAL TABLE item_search USING fts5(
                body, content = '', contentless_delete = 1, tokenize = '\(tokenizer)'
            );
            CREATE TRIGGER item_search_insert AFTER INSERT ON item WHEN new.text IS NOT NULL BEGIN
                INSERT INTO item_search (rowid, body) VALUES (new.id, substr(new.text, 1, \(HistoryStore.indexedCharacters)));
            END;
            CREATE TRIGGER item_search_delete AFTER DELETE ON item WHEN old.text IS NOT NULL BEGIN
                DELETE FROM item_search WHERE rowid = old.id;
            END;
            CREATE TRIGGER item_search_update AFTER UPDATE OF id, text ON item BEGIN
                DELETE FROM item_search WHERE rowid = old.id AND old.text IS NOT NULL;
                INSERT INTO item_search (rowid, body)
                    SELECT new.id, substr(new.text, 1, \(HistoryStore.indexedCharacters)) WHERE new.text IS NOT NULL;
            END;
            """
        ]
    }

    /// True when SQLite's trigram tokenizer can fold accents, checked once in a private database in
    /// memory.
    static let supportsAccentFolding: Bool = {
        guard let probe = try? SQLiteDatabase.inMemory() else { return false }
        defer { probe.close() }
        return
            (try? probe.execute("CREATE VIRTUAL TABLE probe USING fts5(x, tokenize = 'trigram remove_diacritics 1')"))
            != nil
    }()
}
