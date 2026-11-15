import Foundation
import Kit
import os

/// The people the feature knows, read from the store when something asks for them and kept in
/// memory while the feature is on. Nothing is written to disk.
///
/// - ``current()`` reads the store the first time something needs people: the Search Contacts list,
///   or root search when the user allowed access and kept people in root search. It never calls
///   the service while access is missing, so it never raises a prompt.
/// - After the first read it follows the store's changes. Each change reads the store again off
///   the main thread, swaps the snapshot, and sends ``changes``, so an open list and root search
///   reload.
/// - When access goes away, found by a read or by a check before one, it forgets everyone, stops
///   following, and sends ``changes``.
@MainActor final class PeopleDirectory {
    /// Sent when the people changed or access went away.
    let changes = ChangeSignal()
    /// True when a reader got nothing because access was missing, so the next read that finds
    /// people tells it with ``changes``.
    var announcesNextRead = false

    private let service: any PeopleService
    private let permissions: PermissionReader
    private let log: Logger
    private(set) var snapshot: PeopleSnapshot?
    private var loading: Task<PeopleSnapshot, any Error>?
    private var readsAgain = false
    private var follower: Task<Void, Never>?
    /// Counts forgets, so a read that ends after one never brings people back.
    private var epoch = 0
    private var photos = PhotoCache(capacity: 64)

    init(service: any PeopleService, permissions: PermissionReader, log: Logger) {
        self.service = service
        self.permissions = permissions
        self.log = log
    }

    /// True when the user allowed access. Never prompts and never waits.
    var hasAccess: Bool { permissions.isGranted(.contacts) }

    /// True while the directory follows the store's changes.
    var isFollowing: Bool { follower != nil }

    /// The person with this store identifier, from the last read. Cheap enough for `actions(for:)`.
    func person(id: String) -> Person? {
        snapshot?.person(id: id)
    }

    /// The people, read from the store when there is no current read. Throws
    /// ``PeopleError/accessMissing`` without calling the service when access is missing.
    func current() async throws -> PeopleSnapshot {
        guard hasAccess else {
            forget()
            throw PeopleError.accessMissing
        }
        if let snapshot, loading == nil { return snapshot }
        return try await startReading().value
    }

    /// Forgets everyone and stops following the store. Sends ``changes`` when there was something
    /// to forget, so whatever shows people reloads.
    func forget() {
        let hadPeople = snapshot != nil || loading != nil || follower != nil
        epoch += 1
        release(snapshot)
        snapshot = nil
        loading?.cancel()
        loading = nil
        readsAgain = false
        follower?.cancel()
        follower = nil
        photos.removeAll()
        if hadPeople { changes.send() }
    }

    /// The person's photo scaled down to a thumbnail, read and scaled off the main thread. Kept in
    /// memory for the last 64 people shown. Nil when there is none or it cannot be read.
    func thumbnail(for person: Person) async -> Data? {
        guard person.hasPhoto, hasAccess else { return nil }
        if let cached = photos[person.id] { return cached }
        let epoch = epoch
        let data: Data?
        do {
            data = try await PhotoThumbnail.read(person.id, from: service)
        } catch PeopleError.accessMissing {
            if self.epoch == epoch { forget() }
            return nil
        } catch {
            return nil
        }
        guard self.epoch == epoch, let data else { return nil }
        photos[person.id] = data
        return data
    }

    /// Waits until no read is running, for tests.
    func waitUntilIdle() async {
        while let loading {
            _ = try? await loading.value
            if self.loading == loading { break }
        }
    }

    // MARK: - Private

    /// Frees a snapshot off the main thread: ten thousand people take a few milliseconds to free.
    /// The task holds the last reference once the caller lets go.
    private func release(_ old: PeopleSnapshot?) {
        guard let old else { return }
        Task.detached(priority: .utility) { withExtendedLifetime(old) {} }
    }

    /// The read running now, or a new one. Readers share it.
    private func startReading() -> Task<PeopleSnapshot, any Error> {
        if let loading { return loading }
        let epoch = epoch
        let service = service
        let task = Task { [weak self] in
            do {
                let snapshot = try await PeopleSnapshot.read(from: service)
                self?.finishReading(snapshot, epoch: epoch)
                return snapshot
            } catch {
                self?.failReading(error, epoch: epoch)
                throw error
            }
        }
        loading = task
        return task
    }

    private func finishReading(_ result: PeopleSnapshot, epoch: Int) {
        guard self.epoch == epoch else { return }
        let replaced = snapshot != nil
        release(snapshot)
        snapshot = result
        loading = nil
        follow()
        if readsAgain {
            readsAgain = false
            _ = startReading()
            return
        }
        if replaced || announcesNextRead {
            announcesNextRead = false
            changes.send()
        }
    }

    private func failReading(_ error: any Error, epoch: Int) {
        guard self.epoch == epoch else { return }
        loading = nil
        readsAgain = false
        if error as? PeopleError == .accessMissing {
            forget()
        } else if !(error is CancellationError) {
            log.error("Reading contacts failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Follows the store from the first read that succeeded until a forget.
    private func follow() {
        guard follower == nil else { return }
        let storeChanges = service.storeChanges()
        follower = Task { [weak self] in
            for await _ in storeChanges {
                self?.storeDidChange()
            }
        }
    }

    /// Reads again in the background. A change during a read marks it, and a second read follows
    /// the first, since the first may have missed the change.
    private func storeDidChange() {
        photos.removeAll()
        guard hasAccess else {
            forget()
            return
        }
        if loading != nil {
            readsAgain = true
        } else {
            _ = startReading()
        }
    }
}

/// A few thumbnails in memory, the least recently used dropped first.
struct PhotoCache {
    let capacity: Int
    private var entries: [String: Data] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    subscript(id: String) -> Data? {
        get { entries[id] }
        set {
            order.removeAll { $0 == id }
            entries[id] = newValue
            guard newValue != nil else { return }
            order.append(id)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
    }

    mutating func removeAll() {
        entries = [:]
        order = []
    }
}
