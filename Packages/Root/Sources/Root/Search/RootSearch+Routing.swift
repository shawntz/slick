import Kit
import KitHosting

extension RootSearch {
    /// The actions of the source that made the row, found by the row's namespace. None for a
    /// command row: Host runs commands and builds their actions itself.
    public func actions(for row: Row) -> [Action] {
        let namespace = row.id.namespace
        guard namespace != ItemID.ReservedNamespace.command else { return [] }
        return plan.owners[namespace]?.actions.actions(for: row) ?? []
    }

    /// The feature that declares a command, or that owns a row's namespace. Nil for built-in rows.
    public func featureID(for row: Row) -> String? {
        let namespace = row.id.namespace
        if namespace == ItemID.ReservedNamespace.command {
            return plan.commandFeatures[row.id] ?? configuration.directory.command(row.id)?.featureID
        }
        return plan.owners[namespace]?.featureID
    }

    /// The row for an ID: from the catalog, from what root search remembered, or, during a session,
    /// from the snapshot on screen.
    public func row(for id: ItemID) -> Row? {
        if let entry = table.entry(for: id) { return entry.row }
        if plan.owners[id.namespace] != nil, let row = memory.rememberedRow(id) { return row }
        guard inSession else { return nil }
        for section in snapshot.sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }
}
