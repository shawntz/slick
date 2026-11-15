import Foundation
import Kit

/// What a Manage Script Commands row carries, so its actions work from the row alone.
nonisolated struct ManagedScript: Codable, Hashable, Sendable {
    var path: String
    var folderPath: String
    var folderName: String
    var commandID: String
    var isRunnable: Bool
    var isFolderEnabled: Bool
}

/// Manage Script Commands: every script in every folder, grouped by folder, with its problems in
/// the detail pane. Scripts in a folder that is off are listed here, and the folder can be turned
/// on from their row.
final class ManageScriptsList: ListSource {
    private unowned let feature: ScriptsFeature

    init(feature: ScriptsFeature) {
        self.feature = feature
    }

    var changes: ChangeSignal? { feature.changes }

    func load(_ request: ListRequest) async throws -> ListResult {
        await feature.scanned()
        let catalog = feature.catalog
        let home = feature.context.storage.homeDirectory
        let allowsRemoteIcons = feature.context.settings[ScriptsSettings.remoteIcons]
        let sections = catalog.folders.compactMap { state -> ListSection? in
            let entries = catalog.entries.filter { $0.folder.path == state.folder.path }
            guard !entries.isEmpty else { return nil }
            return ListSection(
                state.folder.displayName, id: state.folder.path,
                rows: entries.map { Self.row($0, home: home, allowsRemoteIcons: allowsRemoteIcons) })
        }
        return ListResult(sections: sections)
    }

    static func row(_ entry: ScriptEntry, home: URL, allowsRemoteIcons: Bool) -> Row {
        var accessories: [Accessory] = []
        if let mode = entry.script?.mode { accessories.append(.tag(Strings.modeName(mode))) }
        if entry.hasErrors {
            accessories.append(.tag(Strings.tagProblem, color: .red))
        } else if entry.hasWarnings {
            accessories.append(.tag(Strings.tagWarning, color: .orange))
        }
        if !entry.folder.isEnabled { accessories.append(.tag(Strings.tagOff, color: .gray)) }
        let icon =
            entry.script?.icon(home: home, allowsRemote: allowsRemoteIcons)
            ?? .symbol("exclamationmark.triangle", tint: .red)
        let item = ManagedScript(
            path: entry.url.path(percentEncoded: false), folderPath: entry.folder.path,
            folderName: entry.folder.displayName, commandID: entry.commandID, isRunnable: entry.isRunnable,
            isFolderEnabled: entry.folder.isEnabled)
        return Row(
            id: ItemID(ScriptsFeature.manifest.id, "file:" + item.path), title: entry.title,
            subtitle: entry.url.lastPathComponent, icon: icon, accessories: accessories,
            keywords: [entry.url.lastPathComponent], payload: Payload(item), memory: .never)
    }

    func actions(for row: Row) -> [Action] {
        guard let item = try? row.payload?.decode(ManagedScript.self) else { return [] }
        let url = URL(filePath: item.path)
        var actions: [Action] = []
        if item.isRunnable {
            let id = ItemID.command(feature: ScriptsFeature.manifest.id, command: item.commandID)
            actions.append(.runCommand(id, title: Strings.runScript, icon: .symbol("play.fill")))
        }
        if !item.isFolderEnabled {
            actions.append(turnOnFolder(path: item.folderPath, name: item.folderName))
        }
        actions.append(.openWith(url, title: Strings.editWith).with(id: "edit-with"))
        actions.append(.reveal([url]))
        actions.append(.copyPath(url))
        return actions
    }

    /// Turns a folder on after asking, because its scripts can then run with the user's rights.
    private func turnOnFolder(path: String, name: String) -> Action {
        Action(
            Strings.turnOnFolder, id: "turn-on-folder", icon: .symbol("checkmark.shield"),
            confirmation: Confirmation(
                Strings.turnOnFolderQuestion(name), message: Strings.turnOnFolderMessage,
                confirmTitle: Strings.turnOnFolder)
        ) { [feature] context in
            await feature.enableFolder(path)
            context.showToast(.success(Strings.folderTurnedOn(name)))
            return .keepOpen
        }
    }

    func detail(for row: Row) async throws -> Detail? {
        guard let item = try? row.payload?.decode(ManagedScript.self),
            let entry = feature.catalog.entries.first(where: { $0.url.path(percentEncoded: false) == item.path })
        else { return nil }
        return Self.detail(entry)
    }

    static func detail(_ entry: ScriptEntry) -> Detail {
        var lines: [String] = []
        if !entry.folder.isEnabled { lines += [Strings.detailFolderOff, ""] }
        lines.append("**" + Strings.detailProblems + "**")
        lines.append("")
        if entry.problems.isEmpty {
            lines.append(Strings.detailNoProblems)
        } else {
            lines += entry.problems.map { "- " + Strings.problemLine($0) }
        }
        var metadata: [MetadataItem] = [
            .label(Strings.detailFile, value: entry.url.lastPathComponent),
            .label(Strings.detailFolder, value: entry.folder.displayName),
        ]
        if let script = entry.script {
            metadata.append(.label(Strings.detailMode, value: Strings.modeName(script.mode)))
            metadata.append(.label(Strings.detailInterpreter, value: script.interpreter.displayName))
        }
        metadata.append(.label(Strings.detailCommandID, value: entry.commandID))
        return Detail(.markdown(lines.joined(separator: "\n")), metadata: metadata)
    }
}
