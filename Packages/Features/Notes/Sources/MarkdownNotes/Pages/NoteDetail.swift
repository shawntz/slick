import Foundation
import Kit

/// A note in the detail pane: its Markdown, then its tags, date, word count and file. Built off the
/// main thread, because counting the words of a long note is not free.
nonisolated enum NoteDetail {
    @concurrent static func make(
        _ note: NoteRecord, read: Result<NoteRead, ActionFailure>, isPinned: Bool, limits: NoteLimits,
        locale: Locale
    ) async -> Detail {
        let body: DetailBody
        var words: Int?
        if note.isDataless {
            body = .markdown(Strings.notDownloadedBody)
        } else {
            switch read {
            case .success(let read):
                let shown = read.text.prefix(limits.previewCharacters)
                let isCut = read.isCut || shown.endIndex < read.text.endIndex
                body = .markdown(String(shown) + (isCut ? Strings.cutPreview(shown.count, locale: locale) : ""))
                words = wordCount(read.text)
            case .failure(let failure):
                body = .text(Strings.unreadableBody(failure.message ?? failure.title))
            }
        }
        var metadata: [MetadataItem] = []
        var tags = isPinned ? [Tag(Strings.pinnedTag, color: .orange)] : []
        tags += note.tags.map { Tag("#" + DisplayText.oneLine($0), color: .accent) }
        if !tags.isEmpty { metadata.append(.tags(Strings.tagsLabel, tags)) }
        metadata.append(.date(Strings.modifiedLabel, note.modified))
        if let words {
            metadata.append(
                .label(Strings.wordsLabel, value: words.formatted(IntegerFormatStyle<Int>.number.locale(locale))))
        }
        metadata.append(.label(Strings.fileLabel, value: DisplayText.fileName(note.fileName)))
        return Detail(body, metadata: metadata)
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}

/// A note on a page of its own, for a note opened from root search or from a toast. It reads the
/// file when the page shows and offers the note's actions.
final class NoteDetailSource: DetailSource {
    private unowned let feature: NotesFeature
    private let fileName: String

    init(feature: NotesFeature, fileName: String) {
        self.feature = feature
        self.fileName = fileName
    }

    func start() -> AsyncThrowingStream<DetailUpdate, any Error> {
        let library = feature.library
        let fileName = fileName
        let locale = feature.context.clock.locale
        return AsyncThrowingStream { continuation in
            let task = Task {
                await library.ready()
                guard let note = library.index.note(named: fileName) else {
                    continuation.finish(throwing: Strings.noteGone)
                    return
                }
                let read =
                    note.isDataless
                    ? .failure(Strings.notDownloaded) : await NoteDetailSource.read(fileName, library: library)
                let detail = await NoteDetail.make(
                    note, read: read, isPinned: library.pinned.contains(fileName), limits: library.limits,
                    locale: locale)
                continuation.yield(.replace(detail))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func actions(for detail: Detail) -> [Action] {
        feature.actions.actions(for: fileName, place: .page)
    }

    /// The note's text for the pane, or why it could not be read.
    static func read(_ fileName: String, library: NoteLibrary) async -> Result<NoteRead, ActionFailure> {
        do {
            return .success(try await library.read(fileName, limit: library.limits.bytesPerNote))
        } catch let failure as ActionFailure {
            return .failure(failure)
        } catch {
            return .failure(ActionFailure(String(describing: error)))
        }
    }
}
