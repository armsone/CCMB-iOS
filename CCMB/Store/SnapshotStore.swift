import Foundation
import SwiftUI

/// Owns everything the screens read: the current snapshot, where it came
/// from, and the user-visible load state. The primary path is the Mac's
/// CloudKit upload in the user's own private database; picking a copied
/// `usage-v1.json` in the Files app stays as the manual fallback. Either way
/// the last good snapshot is kept in the app sandbox so a relaunch or a
/// failed refresh never blanks the screen.
@MainActor
final class SnapshotStore: ObservableObject {
    enum LoadState {
        /// No snapshot yet: first launch, or the saved copy was removed.
        case empty
        case loading
        case loaded(UsageSnapshot)
        /// A load failed and no earlier snapshot exists to fall back to.
        case failed(message: String)
    }

    enum SnapshotOrigin {
        /// Fetched from the CloudKit private database during this run.
        case cloud
        /// Read from the picked file during this run.
        case pickedFile
        /// Restored from the copy saved on a previous run.
        case savedCopy
    }

    /// Which source "새로 고침" targets. Cloud is the default; picking a
    /// file switches to file mode until the user loads from iCloud again.
    enum PreferredSource: String {
        case cloud
        case file
    }

    @Published private(set) var state: LoadState = .empty
    @Published private(set) var origin: SnapshotOrigin = .savedCopy
    @Published private(set) var preferredSource: PreferredSource = .cloud
    @Published private(set) var sourceFileName: String?
    @Published private(set) var lastReadAt: Date?
    /// Last time a CloudKit fetch brought data back, this run.
    @Published private(set) var lastCloudSyncAt: Date?
    @Published private(set) var automaticRefreshInterval: TimeInterval = 60
    @Published private(set) var nextAutomaticRefreshAt: Date?
    @Published private(set) var codexCreditsSpentLast30Minutes: Double?
    /// A refresh problem that should not hide the still-usable snapshot:
    /// shown as a banner above the cards instead of replacing them.
    @Published private(set) var refreshProblem: String?

    private let cloudClient = CloudSnapshotClient()
    private var cloudRefreshInFlight = false
    private var cloudRefreshPending = false
    private var automaticRefreshTimer: Timer?
    private var didLoadOnLaunch = false

    private static let bookmarkDefaultsKey = "pickedSnapshotBookmarkV1"
    private static let sourceNameDefaultsKey = "pickedSnapshotFileNameV1"
    private static let preferredSourceDefaultsKey = "preferredSnapshotSourceV1"
    private static let automaticRefreshDefaultsKey = "automaticRefreshIntervalSecondsV1"
    private static let codexCreditHistoryDefaultsKey = "codexCreditHistoryV1"

    private struct CreditSample: Codable {
        let observedAt: Date
        let balance: Double
    }

    static let automaticRefreshOptions: [TimeInterval] = [30, 60, 120, 300, 600]

    var hasPickedFile: Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) != nil
    }

    private var cacheURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCMB", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("last-usage-v1.json")
    }

    /// Shows the saved copy immediately so a relaunch never starts empty,
    /// then asks the preferred source for anything newer.
    func loadOnLaunch() {
        guard !didLoadOnLaunch else { return }
        didLoadOnLaunch = true
        preferredSource = UserDefaults.standard.string(forKey: Self.preferredSourceDefaultsKey)
            .flatMap(PreferredSource.init(rawValue:)) ?? .cloud
        let savedInterval = UserDefaults.standard.double(forKey: Self.automaticRefreshDefaultsKey)
        automaticRefreshInterval = Self.automaticRefreshOptions.contains(savedInterval) ? savedInterval : 60
        updateCodexCreditSpend()
        scheduleAutomaticRefresh()
        sourceFileName = UserDefaults.standard.string(forKey: Self.sourceNameDefaultsKey)
        if let data = try? Data(contentsOf: cacheURL),
           let snapshot = try? UsageSnapshot.parse(data) {
            state = .loaded(snapshot)
            origin = .savedCopy
        }
        refresh(isAutomatic: true)
    }

    func setAutomaticRefreshInterval(_ seconds: TimeInterval) {
        guard Self.automaticRefreshOptions.contains(seconds) else { return }
        automaticRefreshInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.automaticRefreshDefaultsKey)
        scheduleAutomaticRefresh()
    }

    func usePickedFile() {
        guard hasPickedFile else { return }
        setPreferredSource(.file)
        refreshFromPickedFile()
    }

    /// Foreground return and pull-to-refresh both land here.
    func refresh(isAutomatic: Bool = false) {
        // A user-initiated refresh becomes the new cadence anchor. Without
        // recreating the timer, the countdown restarts visually but the old
        // timer can still fire a few seconds later.
        if !isAutomatic {
            scheduleAutomaticRefresh()
        }
        switch preferredSource {
        case .cloud:
            Task { await refreshFromCloud(isAutomatic: isAutomatic) }
        case .file:
            refreshFromPickedFile(isLaunch: isAutomatic)
        }
    }

    /// The primary path: read the single latest-snapshot record the Mac
    /// keeps in this Apple ID's private database. Failures never discard a
    /// snapshot already on screen — they become the banner instead.
    func refreshFromCloud(isAutomatic: Bool = false) async {
        guard !cloudRefreshInFlight else {
            cloudRefreshPending = true
            return
        }
        cloudRefreshInFlight = true
        defer {
            cloudRefreshInFlight = false
            if cloudRefreshPending {
                cloudRefreshPending = false
                Task { await refreshFromCloud(isAutomatic: true) }
            }
        }

        setPreferredSource(.cloud)
        if case .loaded = state {} else if !isAutomatic {
            state = .loading
        }

        do {
            let result = try await cloudClient.fetchLatest()
            let snapshot = try UsageSnapshot.parse(result.data)
            persistGoodCopy(result.data)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .cloud
            lastReadAt = Date()
            lastCloudSyncAt = Date()
            refreshProblem = nil
        } catch {
            let message = (error as? CloudFetchError)?.errorDescription
                ?? (error as? SnapshotError)?.errorDescription
                ?? "잠시 후 다시 시도해 주세요. iCloud에서 사용량을 읽지 못했습니다."
            switch state {
            case .loaded:
                // Remote failure keeps the last good snapshot on screen.
                refreshProblem = message
            case .empty where isAutomatic:
                // First launch without data: the welcome screen shows the
                // problem inline instead of replacing the onboarding steps.
                refreshProblem = message
            default:
                state = .failed(message: message)
            }
        }
    }

    /// Handles a fresh pick from the file importer. The picker grants
    /// security-scoped access which must be balanced exactly once.
    func importPicked(url: URL) {
        state = .loading
        refreshProblem = nil
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try readData(from: url)
            let snapshot = try UsageSnapshot.parse(data)
            saveBookmark(for: url)
            sourceFileName = url.lastPathComponent
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.sourceNameDefaultsKey)
            persistGoodCopy(data)
            setPreferredSource(.file)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .pickedFile
            lastReadAt = Date()
        } catch {
            fail(with: error)
        }
    }

    /// Re-reads the bookmarked file. Without a usable bookmark the existing
    /// snapshot stays on screen and the banner asks the user to pick again.
    func refreshFromPickedFile(isLaunch: Bool = false) {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else {
            if !isLaunch {
                refreshProblem = "파일을 다시 선택해 주세요. 이전에 선택한 파일 기록이 없습니다."
            }
            return
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            refreshProblem = "파일을 다시 선택해 주세요. 이전에 선택한 파일에 더 이상 접근할 수 없습니다."
            return
        }

        refreshProblem = nil
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try readData(from: url)
            let snapshot = try UsageSnapshot.parse(data)
            if isStale { saveBookmark(for: url) }
            persistGoodCopy(data)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .pickedFile
            lastReadAt = Date()
        } catch {
            // On launch a missing/renamed file is normal (iCloud eviction,
            // Mac-side rewrite); keep the saved copy quiet until the user
            // asks for a refresh.
            if case .loaded = state {
                refreshProblem = (error as? SnapshotError)?.errorDescription
                    ?? "파일 앱에서 usage-v1.json을 다시 선택해 주세요. 파일을 읽지 못했습니다."
            } else if !isLaunch {
                fail(with: error)
            }
        }
    }

    /// Drops the picked-file link and the saved copy. Used from the empty
    /// and error states' "처음부터 다시" action.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.sourceNameDefaultsKey)
        try? FileManager.default.removeItem(at: cacheURL)
        sourceFileName = nil
        refreshProblem = nil
        setPreferredSource(.cloud)
        state = .empty
    }

    private func setPreferredSource(_ source: PreferredSource) {
        preferredSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.preferredSourceDefaultsKey)
    }

    private func scheduleAutomaticRefresh() {
        automaticRefreshTimer?.invalidate()
        nextAutomaticRefreshAt = Date().addingTimeInterval(automaticRefreshInterval)
        let timer = Timer(timeInterval: automaticRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nextAutomaticRefreshAt = Date().addingTimeInterval(self.automaticRefreshInterval)
                self.refresh(isAutomatic: true)
            }
        }
        timer.tolerance = min(5, automaticRefreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        automaticRefreshTimer = timer
    }

    private func readData(from url: URL) throws -> Data {
        // NSFileCoordinator lets iCloud Drive download a not-yet-local file
        // instead of failing on the placeholder.
        var coordinatorError: NSError?
        var readError: Error?
        var result = Data()
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            do {
                result = try Data(contentsOf: actualURL)
            } catch {
                readError = error
            }
        }
        if coordinatorError != nil || readError != nil {
            throw SnapshotError.unreadable
        }
        return result
    }

    private func saveBookmark(for url: URL) {
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        }
    }

    private func persistGoodCopy(_ data: Data) {
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
    }

    private func recordCodexCreditSample(from snapshot: UsageSnapshot) {
        guard let balance = snapshot.services[.codex]?.creditBalance else { return }
        var samples = loadCodexCreditSamples()
        let now = Date()
        samples.append(CreditSample(observedAt: now, balance: balance))
        samples = samples.filter { now.timeIntervalSince($0.observedAt) <= 24 * 60 * 60 }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: Self.codexCreditHistoryDefaultsKey)
        }
        updateCodexCreditSpend(samples: samples, now: now)
    }

    private func updateCodexCreditSpend(
        samples: [CreditSample]? = nil,
        now: Date = Date()
    ) {
        let samples = (samples ?? loadCodexCreditSamples()).sorted { $0.observedAt < $1.observedAt }
        let cutoff = now.addingTimeInterval(-30 * 60)
        guard let baseline = samples.last(where: { $0.observedAt <= cutoff }) else {
            codexCreditsSpentLast30Minutes = nil
            return
        }
        let windowSamples = [baseline] + samples.filter { $0.observedAt > cutoff }
        codexCreditsSpentLast30Minutes = zip(windowSamples, windowSamples.dropFirst()).reduce(0) { total, pair in
            total + max(0, pair.0.balance - pair.1.balance)
        }
    }

    private func loadCodexCreditSamples() -> [CreditSample] {
        guard let data = UserDefaults.standard.data(forKey: Self.codexCreditHistoryDefaultsKey),
              let samples = try? JSONDecoder().decode([CreditSample].self, from: data) else {
            return []
        }
        return samples
    }

    private func fail(with error: Error) {
        let message = (error as? SnapshotError)?.errorDescription
            ?? "파일 앱에서 usage-v1.json을 다시 선택해 주세요. 파일을 읽지 못했습니다."
        if case .loaded = state {
            // Never replace a good snapshot with an error page.
            refreshProblem = message
        } else {
            state = .failed(message: message)
        }
    }
}
