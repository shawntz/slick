import Foundation
import Kit

/// The actions of a file or folder row, wherever it shows: root search, the Search Files page, or
/// a row root search rebuilt from a snapshot after a relaunch. Everything comes from the row's ID
/// and payload, so building them reads nothing.
///
/// Return opens, Command-Return shows the item in Finder, as in the Apps feature. Uses on the
/// Search Files page are recorded for its recents; root search records its own.
@MainActor final class FileActions {
    private let controller: IndexController

    init(controller: IndexController) {
        self.controller = controller
    }

    func actions(for row: Row) -> [Action] {
        let url = FileRows.url(of: row)
        let name = Paths.name(of: row.id.key)
        let controller = controller
        // The question names the item as its row does: on one line, drawn in stored order.
        var trash = Action.moveToTrash([url]).then { _ in await controller.applyNow([url]) }
        trash.confirmation = Confirmation(
            Strings.Actions.trashQuestion(FileRows.title(for: name)), confirmTitle: Strings.Actions.trashConfirm,
            isDestructive: true)
        return [
            Action.open(url).recordingUse(),
            Action.reveal([url]).with(shortcut: .secondaryAction).recordingUse(),
            Action.openWith(url).recordingUse(),
            Action.quickLook(url),
            Action.copy(
                .files([url]), title: Strings.Actions.copyFile, hud: Strings.Actions.copiedFile, shortcut: .copy
            )
            .with(id: "copy-file").recordingUse(),
            Action.copyPath(url).recordingUse(),
            Action.copy(name, title: Strings.Actions.copyName, hud: Strings.Actions.copiedName).with(id: "copy-name"),
            Action.share([.file(url)]),
            // The index learns of the move at once, so the page that reloads no longer lists it.
            trash,
        ]
    }
}

extension IndexController {
    /// Queues these paths as one batch and waits until it was applied.
    func applyNow(_ urls: [URL]) async {
        submit(urls)
        await waitUntilIdle()
    }
}
