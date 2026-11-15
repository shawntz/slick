import CoreBridge
import Foundation
import Kit
import os

/// Decides when exchange rates are downloaded and attaches them to the calculator.
///
/// Nothing is downloaded at launch. The first download starts when the user types a currency
/// conversion, and the next one no sooner than a day after the last success. A failed download is
/// tried again no sooner than half an hour later, or at once when the user asks. The setting turns
/// downloads off. The saved table is read from the feature's folder at activation, so answers work
/// offline with the rates of the last download, which the row dates.
final class RateKeeper {
    /// What the rates are doing, for the row a currency question shows without a table.
    enum State: Hashable, Sendable {
        case idle
        case loading
        case failed
    }

    /// The least time between two downloads that succeeded.
    static let downloadInterval: TimeInterval = 24 * 3600
    /// The least time between a failed download and the next one the feature starts by itself.
    static let retryInterval: TimeInterval = 30 * 60

    /// The table attached to the calculator, if any.
    private(set) var table: RateTable?
    private(set) var state = State.idle
    /// When the last download failed, cleared by a success.
    private(set) var lastFailure: Date?
    /// How many downloads started, for tests.
    private(set) var downloadCount = 0

    private var download: Task<Bool, Never>?
    /// Counts downloads, so one that finishes after it was cancelled cannot clear a newer one.
    private var downloadGeneration = 0
    private let service: any ExchangeRateService
    private let settings: FeatureSettings
    private let clock: any ClockService
    private let log: Logger
    private let attach: (CurrencyRates?) -> Void

    init(context: FeatureContext, service: any ExchangeRateService, attach: @escaping (CurrencyRates?) -> Void) {
        self.service = service
        self.settings = context.settings
        self.clock = context.clock
        self.log = context.log
        self.attach = attach
    }

    /// Whether the user lets the feature download rates.
    var isEnabled: Bool { settings[CalcSettings.downloadsRates] }

    /// Attaches the table the last download saved. Called at activation; reads only the feature's
    /// own folder and sends nothing.
    func restoreSaved() async {
        guard table == nil, let saved = await service.savedTable() else { return }
        // A download that finished meanwhile is newer.
        guard table == nil else { return }
        await use(saved)
    }

    /// Called by the provider when the user typed a currency conversion. Starts a download when
    /// the user allows it, none is running, the table is missing or a day old, and the last failure
    /// was long enough ago. Cheap: it runs inside the keystroke.
    func currencyQuestionTyped() {
        guard download == nil, isEnabled else { return }
        let now = clock.now
        if let table, Self.isWithin(now.timeIntervalSince(table.downloadedAt), Self.downloadInterval) { return }
        if let lastFailure, Self.isWithin(now.timeIntervalSince(lastFailure), Self.retryInterval) { return }
        startDownload()
    }

    /// Downloads now because the user asked, joining a download that is already running. Returns
    /// true when a table is attached afterwards. Sends nothing while the user has downloads off.
    func downloadNow() async -> Bool {
        guard isEnabled else { return false }
        if download == nil { startDownload() }
        _ = await download?.value
        return table != nil && lastFailure == nil
    }

    /// Waits for the download that is running, if any, without starting one. For tests.
    func waitForDownload() async {
        _ = await download?.value
    }

    /// Stops a running download, when the user turns downloads or the feature off.
    func cancel() {
        download?.cancel()
        download = nil
        downloadGeneration += 1
        if state == .loading { state = .idle }
    }

    private func startDownload() {
        downloadCount += 1
        downloadGeneration += 1
        let generation = downloadGeneration
        state = .loading
        let service = self.service
        let now = clock.now
        download = Task { [weak self] in
            let result: Result<RateTable, any Error>
            do {
                result = .success(try await service.download(at: now))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return false }
            return await self.finish(result, generation: generation)
        }
    }

    private func finish(_ result: Result<RateTable, any Error>, generation: Int) async -> Bool {
        switch result {
        case .success(let fresh):
            await use(fresh)
            guard generation == downloadGeneration else { return true }
            lastFailure = nil
            state = .idle
            download = nil
            return true
        case .failure(let error):
            log.notice("Exchange rates did not download: \(String(describing: error), privacy: .public)")
            guard generation == downloadGeneration else { return false }
            lastFailure = clock.now
            state = .failed
            download = nil
            return false
        }
    }

    private func use(_ fresh: RateTable) async {
        guard let rates = await fresh.engineRates() else { return }
        table = fresh
        attach(rates)
    }

    /// True when `elapsed` is between zero and `interval`. A clock set back reads as long ago.
    private static func isWithin(_ elapsed: TimeInterval, _ interval: TimeInterval) -> Bool {
        elapsed >= 0 && elapsed < interval
    }
}
