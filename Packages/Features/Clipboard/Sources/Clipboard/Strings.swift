import Foundation
import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
///
/// Command, action, section, empty-state, toast and HUD titles, buttons and menu items use title
/// case, as macOS menus do, and end without a full stop. Everything else is a plain sentence that
/// says what will happen. Key combinations come from `KeyCombo.displayString`.
nonisolated enum Strings {
    static let featureName = "Clipboard History"
    static let summary = "Keep what you copy, search it, and paste it again later."

    enum Permissions {
        static let pasteboard = "Read what you copy in other apps, so it can be kept in your history."
        static let accessibility = "Paste the item you choose into the app you were using."
    }

    enum Commands {
        static let history = "Clipboard History"
        static let historyKeywords = ["paste", "pasteboard", "copied", "clips"]
        static let clearHistory = "Clear Clipboard History"
        static let clearHistoryKeywords = ["delete", "erase", "clipboard"]
        static let clearRecent = "Clear Recent Clipboard History"
        static let clearRecentKeywords = ["delete", "erase", "clipboard", "last"]
        static let pauseRecording = "Pause Clipboard Recording"
        static let resumeRecording = "Resume Clipboard Recording"
        static let toggleKeywords = ["clipboard", "private", "stop", "start", "recording"]
        static let periodPlaceholder = "Period"
        static let searchPlaceholder = "Search clipboard history"

        static let clearHistoryConfirmation = Confirmation(
            "Delete Your Clipboard History?",
            message: "Every item that is not pinned is deleted. Pinned items stay. This cannot be undone.",
            confirmTitle: "Delete History", isDestructive: true)
        static let clearRecentConfirmation = Confirmation(
            "Delete Recent Clipboard History?",
            message: "Items copied in the period you chose are deleted. Pinned items stay. This cannot be undone.",
            confirmTitle: "Delete", isDestructive: true)

        static let paused = "Clipboard Recording Is Paused"
        static let resumed = "Clipboard Recording Is On"
    }

    /// The periods Clear Recent Clipboard History offers.
    enum Period {
        static func title(for period: RecentPeriod) -> String {
            switch period {
            case .fiveMinutes: "Last 5 Minutes"
            case .fifteenMinutes: "Last 15 Minutes"
            case .hour: "Last Hour"
            case .day: "Last 24 Hours"
            }
        }
    }

    enum Kinds {
        static func title(for kind: ClipKind) -> String {
            switch kind {
            case .text: "Text"
            case .richText: "Rich text"
            case .link: "Link"
            case .color: "Color"
            case .image: "Image"
            case .files: "Files"
            }
        }
    }

    enum Filter {
        static let title = "Type"

        static func title(for filter: KindFilter) -> String {
            switch filter {
            case .all: "All Types"
            case .pinned: "Pinned"
            case .text: "Text"
            case .images: "Images"
            case .links: "Links"
            case .files: "Files"
            case .colors: "Colors"
            }
        }
    }

    enum List {
        static let pinnedSection = "Pinned"

        static let emptyTitle = "No Clipboard History Yet"
        static let emptyMessage = "Copy text, a link, an image or a file in any app, and it shows up here."
        static let noMatchesTitle = "No Matches"
        static let noMatchesMessage = "Nothing in your clipboard history contains this text."
        static let emptyPinnedTitle = "No Pinned Items"
        static let emptyPinnedMessage =
            "Pin an item with \(KeyCombo(.period, .command).displayString) to keep it until you unpin it."

        static func emptyFilterTitle(_ filter: KindFilter) -> String {
            "No \(Filter.title(for: filter))"
        }

        static let pausedTitle = "Recording Is Paused"
        static let pausedMessage = "New copies are not saved until you resume."
        static let resume = "Resume Recording"
        static let notAllowedTitle = "Copies Are Not Being Recorded"
        static let notAllowedMessage = "Allow Paste from Other Apps, so new copies can be saved."
        static let allow = "Allow Access"
        static let damagedTitle = "Your Earlier Clipboard History Could Not Be Read"
        static let damagedMessage = "A new history was started. The damaged copy was kept, not deleted."
        static let showDamaged = "Show Damaged Copy in Finder"
    }

    enum Rows {
        static let image = "Image"

        static func image(width: Int, height: Int) -> String {
            "Image (\(width) \u{00D7} \(height))"
        }

        static func files(_ count: Int) -> String {
            "\(count) Files"
        }

        static let manyFiles = "Many Files"

        static let emptyText = "Blank text"
    }

    enum Detail {
        static let application = "Application"
        static let type = "Type"
        static let characters = "Characters"
        static let words = "Words"
        static let dimensions = "Dimensions"
        static let items = "Items"
        static let size = "Size"
        static let copied = "Copied"
        static let firstCopied = "First copied"
        static let timesCopied = "Times copied"
        static let pinned = "Pinned"
        static let link = "Link"
        static let color = "Color"

        static func dimensions(width: Int, height: Int) -> String {
            "\(width) \u{00D7} \(height) pixels"
        }

        static func cutNotice(shown: Int) -> String {
            "\n\nThe preview shows the first \(shown) characters."
        }
    }

    enum Actions {
        static func paste(to app: String?) -> String {
            app.map { "Paste to \($0)" } ?? "Paste"
        }

        static let copy = "Copy to Clipboard"
        static let copied = "Copied to Clipboard"
        static let pastePlainText = "Paste as Plain Text"
        static let openLink = "Open Link"
        static let openFiles = "Open"
        static let reveal = "Show in Finder"

        static func openManyConfirmation(_ count: Int) -> Confirmation {
            Confirmation(
                "Open \(count) Files?", message: "Each file opens in its default app.", confirmTitle: "Open All")
        }
        static let pin = "Pin"
        static let unpin = "Unpin"
        static let pinned = "Pinned"
        static let unpinned = "Unpinned"
        static let saveAsSnippet = "Save as Snippet"
        static let delete = "Delete"
        static let deleteAll = "Delete All"
        static let deleteSection = "Delete"

        static let deleteConfirmation = Confirmation(
            "Delete This Item?", message: "It is removed from your clipboard history. This cannot be undone.",
            confirmTitle: "Delete",
            isDestructive: true, suppressionKey: "delete-item")
        static let deleteAllConfirmation = Confirmation(
            "Delete All Clipboard History?",
            message: "Every item that is not pinned is deleted. Pinned items stay. This cannot be undone.",
            confirmTitle: "Delete All", isDestructive: true)

        static let deleted = "Item Deleted"

        static func deleted(_ count: Int) -> String {
            switch count {
            case 0: "Nothing to Delete"
            case 1: "Deleted 1 Item"
            default: "Deleted \(count) Items"
            }
        }

        static let missing = ActionFailure(
            "This Item Is Gone", message: "It was deleted from your clipboard history.")
        static let noPlainText = ActionFailure("This Item Has No Text to Paste")
        static let pasteFailed = ActionFailure(
            "Could Not Paste",
            message: "The item is on the clipboard. Press \(KeyCombo(.v, .command).displayString) to paste it.")
    }

    enum Suggestion {
        static func title(_ preview: String) -> String {
            "Paste \u{201C}\(preview)\u{201D}"
        }

        static func subtitle(from app: String?) -> String {
            app.map { "Just copied from \($0)" } ?? "Just copied"
        }
    }

    enum Status {
        static let needsAccess = "Clipboard History Cannot See What You Copy"
        static let needsAccessMessage = "Allow Paste from Other Apps, so new copies can be saved."
        static let paused = "Recording Is Paused"
        static let pausedMessage = "Nothing you copy is saved until you resume. Your history stays."
    }

    enum Settings {
        static let recordingSection = "Recording"
        static let pause = "Pause recording"
        static let pauseInfo = "While paused, nothing you copy is saved. Your history stays and you can still paste it."
        static let accessInfo = "Clipboard history reads what you copy only while this access is allowed."

        static let historySection = "History"
        static let retention = "Keep items for"
        static let retentionInfo =
            "Older items are deleted. Shortening this deletes them right away. Pinned items stay until you unpin them."
        static let maximumItems = "Keep at most"
        static let maximumItemsInfo =
            "When the history is full, the oldest unpinned items are deleted first. Lowering this deletes them right away."
        static let imageStorage = "Space for images"
        static let imageStorageInfo =
            "When images take more space, the oldest unpinned ones are deleted first. Lowering this deletes them right away."
        static let clear = "Clear History"
        static let clearInfo = "Deletes every item that is not pinned."

        static let pastingSection = "Pasting"
        static let primaryAction = "Return key"
        static let movesToTop = "Move an item to the top when you paste or copy it"
        static let accessibilityInfo = "Pasting into other apps needs Accessibility. Copying does not."

        static let privacySection = "Privacy"
        static let ignoredApps = "Never record copies from"
        static let ignoredAppsInfo = "Password managers are on this list from the start."

        static func storage(folder: String) -> String {
            "Clipboard history keeps the text, rich text, links, colors, images and file references you copy. "
                + "It stays on this Mac, in \(folder), and is never sent anywhere. "
                + "Items that apps mark as passwords or as temporary are never saved. "
                + "For a file, only its location is kept, not the file itself."
        }

        static func retentionTitle(_ value: Retention) -> String {
            switch value {
            case .day: "1 Day"
            case .week: "1 Week"
            case .month: "1 Month"
            case .threeMonths: "3 Months"
            case .sixMonths: "6 Months"
            case .year: "1 Year"
            case .forever: "Forever"
            }
        }

        /// Asked before a shorter time to keep items, which deletes the older ones at once.
        static func shortenRetention(to value: Retention) -> Confirmation {
            Confirmation(
                "Delete Items Older than \(retentionTitle(value))?",
                message: "Items you copied before then are deleted now. Pinned items stay.",
                confirmTitle: "Delete Older Items", isDestructive: true)
        }

        /// Asked before a lower item cap, which deletes the oldest items at once.
        static func lowerItemCap(to count: Int, locale: Locale) -> Confirmation {
            Confirmation(
                "Keep Only the Newest \(itemsOption(count, locale: locale))?",
                message: "Older items beyond that are deleted now. Pinned items stay.",
                confirmTitle: "Delete Older Items", isDestructive: true)
        }

        /// Asked before less space for images, which deletes the oldest images at once.
        static func lowerImageSpace(to megabytes: Int, locale: Locale) -> Confirmation {
            Confirmation(
                "Keep at Most \(self.megabytes(megabytes, locale: locale)) of Images?",
                message: "The oldest images beyond that are deleted now. Pinned images stay.",
                confirmTitle: "Delete Older Images", isDestructive: true)
        }

        static func primaryActionTitle(_ value: PrimaryAction) -> String {
            switch value {
            case .paste: "Paste into the App You Were Using"
            case .copy: "Copy to the Clipboard"
            }
        }

        /// An item cap as the picker's menu and the question before a lower cap show it.
        static func itemsOption(_ count: Int, locale: Locale) -> String {
            "\(count.formatted(.number.locale(locale))) Items"
        }

        static func megabytes(_ count: Int, locale: Locale) -> String {
            count >= 1_000 && count % 1_000 == 0
                ? "\((count / 1_000).formatted(.number.locale(locale))) GB"
                : "\(count.formatted(.number.locale(locale))) MB"
        }
    }
}
