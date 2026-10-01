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
        /// Fetched from the home NAS during this run.
        case nas
        /// Restored from the copy saved on a previous run.
        case savedCopy
    }

    /// Which source "새로 고침" targets. Cloud is the default; picking a
    /// file or connecting to the NAS switches mode until the user loads from
    /// iCloud again.
    enum PreferredSource: String {
        case cloud
        case file
        case nas
    }

    @Published private(set) var state: LoadState = .empty
    @Published private(set) var origin: SnapshotOrigin = .savedCopy
    @Published private(set) var preferredSource: PreferredSource = .cloud
    /// What the snapshot currently on screen actually came from, which can
    /// trail `preferredSource` when a switch to a new source fails after an
    /// older source's data is already showing (e.g. an iCloud switch that
    /// errors while NAS data is still displayed). Screens that explain the
    /// displayed data (header, stale banner, footnote, history) must read
    /// this instead of `preferredSource`, which only says where the next
    /// refresh will go.
    @Published private(set) var displayedSource: PreferredSource = .cloud
    /// The exact NAS origin (scheme+host+port) the currently displayed NAS
    /// snapshot actually came from, so a later address change is never
    /// mislabeled as the new address until a fetch against it succeeds.
    @Published private(set) var displayedNASAddress: String?
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
    /// A small, distinct issue label for the optional Gemini online relay
    /// fetch only — never written into `refreshProblem`, which describes the
    /// main NAS snapshot fetch. The last successfully fetched/cached online
    /// reading stays on screen regardless of this.
    @Published private(set) var geminiOnlineIssue: String?
    /// Same idea for the optional NAS-stored consumption history fetch; the
    /// last good history stays on screen regardless of this.
    @Published private(set) var nasHistoryIssue: String?

    /// Fixed playground address, shared by login and usage reads.
    let nasBaseURLString = NASConfig.baseURLString
    /// True while the first NAS connect attempt (after login) is in flight.
    @Published private(set) var nasConnecting = false
    /// Surfaced only on the login sheet / connect action; a later failure
    /// while NAS is already the active source uses `refreshProblem` instead.
    @Published private(set) var nasConnectError: String?
    /// Presented by `RootView`; set by `requestNASLogin()`.
    @Published var isNASLoginPresented = false

    private let cloudClient = CloudSnapshotClient()
    private let nasClient = NASSnapshotClient()
    private let geminiOnlineClient = NASGeminiOnlineClient()
    private let nasHistoryClient = NASConsumptionHistoryClient()
    private var cloudRefreshInFlight = false
    private var cloudRefreshPending = false
    private var nasRefreshInFlight = false
    private var nasRefreshPending = false
    private var automaticRefreshTimer: Timer?
    private var didLoadOnLaunch = false
    /// Bumped on every explicit user source selection (loading from iCloud,
    /// picking a file, connecting to or re-connecting the NAS, changing the
    /// NAS address, or resetting). Any in-flight load started before the
    /// bump checks this before writing its result, so switching sources
    /// mid-flight — or re-selecting the same source after navigating away
    /// and back — can never let a stale result overwrite a newer one. The
    /// automatic timer never bumps this, so it can only ever refresh
    /// whatever the user most recently chose.
    private var generation = 0

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

    private func cacheURL(for source: PreferredSource) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCMB", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The NAS response is a different wire shape from the Mac's
        // usage-v1.json, so it needs its own cache file and parser on
        // relaunch.
        let filename = source == .nas ? "last-usage-nas-v1.json" : "last-usage-v1.json"
        return directory.appendingPathComponent(filename)
    }

    /// Shows the saved copy immediately so a relaunch never starts empty,
    /// then asks the preferred source for anything newer.
    func loadOnLaunch() {
        guard !didLoadOnLaunch else { return }
        didLoadOnLaunch = true
        preferredSource = UserDefaults.standard.string(forKey: Self.preferredSourceDefaultsKey)
            .flatMap(PreferredSource.init(rawValue:)) ?? .cloud
        displayedSource = preferredSource
        let savedInterval = UserDefaults.standard.double(forKey: Self.automaticRefreshDefaultsKey)
        automaticRefreshInterval = Self.automaticRefreshOptions.contains(savedInterval) ? savedInterval : 60
        updateCodexCreditSpend()
        scheduleAutomaticRefresh()
        sourceFileName = UserDefaults.standard.string(forKey: Self.sourceNameDefaultsKey)
        if let data = try? Data(contentsOf: cacheURL(for: preferredSource)) {
            if preferredSource == .nas {
                // A cached NAS copy from a since-changed address must never
                // be shown under the new address's identity; it is simply
                // skipped here (and left on disk untouched) rather than
                // mislabeled or destructively deleted. The comparison is the
                // full origin (scheme+host+port), not just the host, so a
                // port-only change is never mistaken for the same NAS.
                if Self.nasCacheOrigin(data) == NASConfig.baseURL.absoluteString,
                   let snapshot = try? UsageSnapshot.parseNAS(data) {
                    state = .loaded(applyingCachedNASExtras(to: snapshot))
                    origin = .savedCopy
                    displayedNASAddress = NASConfig.baseURL.absoluteString
                    codexCreditsSpentLast30Minutes = nil
                }
            } else if let snapshot = try? UsageSnapshot.parse(data) {
                state = .loaded(snapshot)
                origin = .savedCopy
            }
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
        generation += 1
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
        case .nas:
            refreshFromNAS(isAutomatic: isAutomatic)
        }
    }

    /// The primary path: read the single latest-snapshot record the Mac
    /// keeps in this Apple ID's private database. Failures never discard a
    /// snapshot already on screen — they become the banner instead.
    func refreshFromCloud(isAutomatic: Bool = false) async {
        if isAutomatic {
            // The automatic timer must only ever refresh whatever the user
            // most recently chose; if cloud isn't the active selection (e.g.
            // a NAS connect is in flight or already won), this tick is not
            // for cloud at all.
            guard preferredSource == .cloud else { return }
        } else {
            // A manual "iCloud에서 불러오기" selection must register
            // immediately, before the in-flight coalescing below, so it is
            // never silently dropped by an older in-flight request from a
            // different source finishing after this one started.
            generation += 1
            setPreferredSource(.cloud)
        }
        let myGeneration = generation
        guard !cloudRefreshInFlight else {
            cloudRefreshPending = true
            return
        }
        cloudRefreshInFlight = true
        defer {
            cloudRefreshInFlight = false
            if cloudRefreshPending {
                cloudRefreshPending = false
                // Resume as long as cloud is still the selected source; the
                // newest pending request must run even if an older
                // generation finished in between, rather than being dropped.
                if preferredSource == .cloud {
                    Task { await refreshFromCloud(isAutomatic: true) }
                }
            }
        }

        if case .loaded = state {} else if !isAutomatic {
            state = .loading
        }

        do {
            let result = try await cloudClient.fetchLatest()
            let snapshot = try UsageSnapshot.parse(result.data)
            guard myGeneration == generation, preferredSource == .cloud else { return }
            persistGoodCopy(result.data, source: .cloud)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .cloud
            displayedSource = .cloud
            lastReadAt = Date()
            lastCloudSyncAt = Date()
            refreshProblem = nil
        } catch {
            guard myGeneration == generation, preferredSource == .cloud else { return }
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
        generation += 1
        if case .loaded = state {} else { state = .loading }
        refreshProblem = nil
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try readData(from: url)
            let snapshot = try UsageSnapshot.parse(data)
            saveBookmark(for: url)
            sourceFileName = url.lastPathComponent
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.sourceNameDefaultsKey)
            persistGoodCopy(data, source: .file)
            setPreferredSource(.file)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .pickedFile
            displayedSource = .file
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
            persistGoodCopy(data, source: .file)
            state = .loaded(snapshot)
            recordCodexCreditSample(from: snapshot)
            origin = .pickedFile
            displayedSource = .file
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
        generation += 1
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.sourceNameDefaultsKey)
        try? FileManager.default.removeItem(at: cacheURL(for: .file))
        try? FileManager.default.removeItem(at: cacheURL(for: .nas))
        try? FileManager.default.removeItem(at: geminiOnlineCacheURL())
        try? FileManager.default.removeItem(at: nasHistoryCacheURL())
        try? FileManager.default.removeItem(at: legacyNASHistoryCacheURL())
        sourceFileName = nil
        refreshProblem = nil
        nasConnectError = nil
        setPreferredSource(.cloud)
        displayedSource = .cloud
        displayedNASAddress = nil
        state = .empty
    }

    /// Whether the WebKit-managed NAS login from an earlier visit is still
    /// present, so reconnecting only shows the login sheet when actually
    /// needed.
    func hasNASSession() async -> Bool {
        await nasClient.checkSession()
    }

    /// Entry point for every "NAS에서 불러오기" action. Skips the login
    /// sheet when a session cookie is already present.
    func requestNASLogin() {
        nasConnectError = nil
        // Captured before the session check so a different source selected
        // while the check is in flight (e.g. the user picks iCloud instead)
        // is never undone by this call reconnecting or popping the sheet
        // once the check finally resolves.
        generation += 1
        let myGeneration = generation
        Task {
            let sessionExists = await hasNASSession()
            guard myGeneration == generation else { return }
            if sessionExists {
                connectNAS()
            } else {
                isNASLoginPresented = true
            }
        }
    }

    /// Called after a successful login in the NAS sheet, or directly when a
    /// session cookie is already present. The active source only switches to
    /// NAS once this first fetch actually succeeds, so a login in progress
    /// never blanks whatever is already on screen.
    func connectNAS() {
        guard !nasConnecting else { return }
        generation += 1
        let myGeneration = generation
        nasConnecting = true
        nasConnectError = nil
        Task {
            defer { nasConnecting = false }
            do {
                let data = try await nasClient.fetchUsage(refresh: false)
                let snapshot = try UsageSnapshot.parseNAS(data)
                guard myGeneration == generation else { return }
                persistGoodCopy(data, source: .nas)
                setPreferredSource(.nas)
                state = .loaded(applyingCachedNASExtras(to: snapshot))
                origin = .nas
                displayedSource = .nas
                displayedNASAddress = NASConfig.baseURL.absoluteString
                lastReadAt = Date()
                refreshProblem = nil
                codexCreditsSpentLast30Minutes = nil
                scheduleAutomaticRefresh()
                refreshGeminiOnline(generation: myGeneration)
                refreshNASHistory(generation: myGeneration)
            } catch {
                guard myGeneration == generation else { return }
                if let fetchError = error as? NASFetchError, case .notAuthenticated = fetchError {
                    // The session cookie could have expired between the
                    // precheck and this fetch; offer the login sheet again
                    // instead of only showing an error string.
                    nasConnectError = fetchError.errorDescription
                    isNASLoginPresented = true
                } else {
                    nasConnectError = (error as? NASFetchError)?.errorDescription
                        ?? "NAS 응답을 해석할 수 없습니다. NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요."
                }
            }
        }
    }

    /// Foreground return, pull-to-refresh, and the automatic timer land here
    /// once NAS is the active source. A manual refresh asks the NAS to
    /// bypass its own cache (`refresh=1`); the automatic timer never does,
    /// since a forced collection can take up to ~65 seconds.
    func refreshFromNAS(isAutomatic: Bool = false) {
        Task { await performNASRefresh(isAutomatic: isAutomatic) }
    }

    private func performNASRefresh(isAutomatic: Bool) async {
        if !isAutomatic { generation += 1 }
        let myGeneration = generation
        guard !nasRefreshInFlight else {
            nasRefreshPending = true
            return
        }
        nasRefreshInFlight = true
        defer {
            nasRefreshInFlight = false
            if nasRefreshPending {
                nasRefreshPending = false
                // Resume as long as NAS is still the selected source; the
                // newest pending request must run even if an older
                // generation finished in between, rather than being dropped.
                if preferredSource == .nas {
                    Task { await performNASRefresh(isAutomatic: true) }
                }
            }
        }

        // The user may have switched away from NAS (or re-selected it, or
        // changed the address) while this was queued or in flight.
        guard preferredSource == .nas, myGeneration == generation else { return }
        if case .loaded = state {} else if !isAutomatic {
            state = .loading
        }

        do {
            let data = try await nasClient.fetchUsage(refresh: !isAutomatic)
            let snapshot = try UsageSnapshot.parseNAS(data)
            guard preferredSource == .nas, myGeneration == generation else { return }
            persistGoodCopy(data, source: .nas)
            state = .loaded(applyingCachedNASExtras(to: snapshot))
            origin = .nas
            displayedSource = .nas
            displayedNASAddress = NASConfig.baseURL.absoluteString
            lastReadAt = Date()
            refreshProblem = nil
            refreshGeminiOnline(generation: myGeneration)
            refreshNASHistory(generation: myGeneration)
        } catch {
            guard preferredSource == .nas, myGeneration == generation else { return }
            let message = (error as? NASFetchError)?.errorDescription
                ?? "NAS 응답을 해석할 수 없습니다. NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요."
            switch state {
            case .loaded:
                // Remote failure (including an expired session) keeps the
                // last good snapshot on screen.
                refreshProblem = message
            case .empty where isAutomatic:
                refreshProblem = message
            default:
                state = .failed(message: message)
            }
            // A manual refresh that hits an expired/invalid session can
            // offer the login sheet directly; the automatic timer never
            // does, so it can never pop the sheet up unprompted.
            if !isAutomatic, let fetchError = error as? NASFetchError, case .notAuthenticated = fetchError {
                isNASLoginPresented = true
            }
        }
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

    private func persistGoodCopy(_ data: Data, source: PreferredSource) {
        let toWrite = source == .nas ? Self.sanitizedNASCopy(data, origin: NASConfig.baseURL.absoluteString) : data
        guard let toWrite else { return }
        try? toWrite.write(to: cacheURL(for: source), options: [.atomic, .completeFileProtection])
    }

    /// Only an allowlist of display-relevant NAS fields is ever written to
    /// disk: no raw server error strings, accounts, paths, or credentials.
    /// The configured origin (scheme+host+port) is stamped alongside so a
    /// later address change — including a port-only change — can tell this
    /// copy no longer belongs to the active NAS.
    private static func sanitizedNASCopy(_ data: Data, origin: String) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = object["report"] as? [String: Any],
              let services = report["services"] as? [[String: Any]] else {
            return nil
        }
        let allowedServiceKeys: Set<String> = ["service", "stale", "ok", "fetched_at"]
        let allowedItemKeys: Set<String> = ["name", "window", "remaining_percent", "resets_at"]
        let sanitizedServices = services.map { service -> [String: Any] in
            var out: [String: Any] = [:]
            for key in allowedServiceKeys {
                if let value = service[key] { out[key] = value }
            }
            let items = (service["items"] as? [[String: Any]]) ?? []
            out["items"] = items.map { item -> [String: Any] in
                var sanitizedItem: [String: Any] = [:]
                for key in allowedItemKeys {
                    if let value = item[key] { sanitizedItem[key] = value }
                }
                // Only the two known credits fields are ever copied — never
                // the whole nested dict, which could otherwise smuggle
                // through auth tokens or other server-internal fields.
                if let credits = item["credits"] as? [String: Any] {
                    var sanitizedCredits: [String: Any] = [:]
                    if let balance = credits["balance"] as? NSNumber, balance.doubleValue.isFinite, balance.doubleValue >= 0 {
                        sanitizedCredits["balance"] = balance
                    }
                    if let unlimited = credits["unlimited"] as? Bool {
                        sanitizedCredits["unlimited"] = unlimited
                    }
                    if !sanitizedCredits.isEmpty {
                        sanitizedItem["credits"] = sanitizedCredits
                    }
                }
                return sanitizedItem
            }
            return out
        }
        let sanitized: [String: Any] = [
            "report": ["services": sanitizedServices],
            "baseURLOrigin": origin
        ]
        return try? JSONSerialization.data(withJSONObject: sanitized)
    }

    /// Reads just the stamped origin from a previously sanitized NAS cache,
    /// without parsing it as a full snapshot.
    private static func nasCacheOrigin(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["baseURLOrigin"] as? String
    }

    private func geminiOnlineCacheURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCMB", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("last-gemini-online-v1.json")
    }

    /// Only a reading cached against the exact currently configured NAS
    /// origin is ever reused, so a later NAS address change can never show a
    /// stale online reading under the new address's identity.
    private func loadCachedGeminiOnline() -> GeminiOnlineReading? {
        guard let data = try? Data(contentsOf: geminiOnlineCacheURL()),
              Self.nasCacheOrigin(data) == NASConfig.baseURL.absoluteString else {
            return nil
        }
        return UsageSnapshot.parseGeminiOnlineRelay(data)
    }

    /// Only the allowlisted contract fields are ever written back to disk —
    /// no raw NAS paths, auth, or error text.
    private func persistGeminiOnline(_ reading: GeminiOnlineReading) {
        let fetchedAtFormatter = ISO8601DateFormatter()
        fetchedAtFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var online: [String: Any] = [
            "fetchedAt": fetchedAtFormatter.string(from: reading.fetchedAt)
        ]
        if let value = reading.fiveHourRemainingPercent { online["fiveHourRemainingPercent"] = value }
        if let value = reading.weeklyRemainingPercent { online["weeklyRemainingPercent"] = value }
        if let value = reading.fiveHourResetText { online["fiveHourResetText"] = value }
        if let value = reading.weeklyResetText { online["weeklyResetText"] = value }
        let sanitized: [String: Any] = [
            "schemaVersion": 1,
            "gemini": ["online": online],
            "baseURLOrigin": NASConfig.baseURL.absoluteString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized) else { return }
        try? data.write(to: geminiOnlineCacheURL(), options: [.atomic, .completeFileProtection])
    }

    /// Best-effort fetch of the private NAS-stored Gemini web-session relay
    /// file. Entirely optional: a missing file, an invalid contract, a
    /// network failure, or a source/generation switch while this is in
    /// flight all leave the just-displayed NAS snapshot (and any previously
    /// cached online reading) exactly as they were.
    private func refreshGeminiOnline(generation myGeneration: Int) {
        Task {
            let outcome: Result<GeminiOnlineReading, NASFetchError>
            do {
                let data = try await geminiOnlineClient.fetchStoredOnline()
                if let reading = UsageSnapshot.parseGeminiOnlineRelay(data) {
                    outcome = .success(reading)
                } else {
                    outcome = .failure(.unreadableResponse)
                }
            } catch let error as NASFetchError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.network)
            }

            // The generation/source check applies to every branch below: a
            // switch away from NAS (or a newer attempt already in flight)
            // must not let this stale result write either the snapshot, the
            // cache, or the issue label.
            guard myGeneration == generation, preferredSource == .nas, displayedSource == .nas else { return }

            switch outcome {
            case .success(let reading):
                // A reading older than what is already cached/displayed
                // must never replace it, even on a successful fetch.
                if let current = loadCachedGeminiOnline(), current.fetchedAt >= reading.fetchedAt {
                    geminiOnlineIssue = nil
                    return
                }
                if case .loaded(let snapshot) = state {
                    state = .loaded(snapshot.applyingGeminiOnline(reading))
                }
                persistGeminiOnline(reading)
                geminiOnlineIssue = nil
            case .failure(let error):
                geminiOnlineIssue = Self.geminiOnlineIssueLabel(for: error)
            }
        }
    }

    /// The Gemini online reading and the consumption history are separate
    /// optional extras; each cached copy is attached on its own, so one
    /// missing never hides the other.
    private func applyingCachedNASExtras(to snapshot: UsageSnapshot) -> UsageSnapshot {
        let withOnline = loadCachedGeminiOnline().map(snapshot.applyingGeminiOnline) ?? snapshot
        return loadCachedNASHistory().map(withOnline.applyingNASHistory) ?? withOnline
    }

    private func nasHistoryCacheURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCMB", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("last-nas-usage-history-v1.json")
    }

    /// Cache of the retired Mac-relayed history. Never read; only removed
    /// together with everything else by `reset()`.
    private func legacyNASHistoryCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCMB", isDirectory: true)
            .appendingPathComponent("last-nas-consumption-history-v1.json")
    }

    /// Like the Gemini online cache, only a copy stamped with the exact
    /// currently configured NAS origin is ever reused. The NAS contract
    /// sits under its own key so the strict parser sees exactly the
    /// contract and nothing else.
    private func loadCachedNASHistory() -> NASConsumptionHistory? {
        guard let data = try? Data(contentsOf: nasHistoryCacheURL()),
              data.count <= UsageSnapshot.nasHistoryMaxBytes + 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["baseURLOrigin"] as? String == NASConfig.baseURL.absoluteString,
              let history = object["history"] as? [String: Any] else {
            return nil
        }
        return UsageSnapshot.parseNASConsumptionHistory(history)
    }

    /// Re-serializes only the validated contract fields — no raw response,
    /// account, path, cookie, or error text is ever written.
    private func persistNASHistory(_ reading: NASConsumptionHistory) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func samples(_ points: [UsageConsumptionPoint]) -> [[String: Any]] {
            points.map { ["at": formatter.string(from: $0.at), "amount": $0.amount] }
        }
        let history: [String: Any] = [
            "schemaVersion": 1,
            "source": "nas",
            "intervalSeconds": UsageSnapshot.nasHistoryIntervalSeconds,
            "slotCount": UsageSnapshot.nasHistoryMaxSamples,
            "collectedAt": formatter.string(from: reading.collectedAt),
            "codexUnit": reading.codexUsesCredits ? "credits" : "percent",
            "consumptionHistory": [
                "codex": samples(reading.codex),
                "codexCredits": samples(reading.codexCredits),
                "claude": samples(reading.claude),
                "claudeFable": samples(reading.claudeFable),
                "gemini": samples(reading.gemini)
            ] as [String: Any]
        ]
        let sanitized: [String: Any] = [
            "history": history,
            "baseURLOrigin": NASConfig.baseURL.absoluteString
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized) else { return }
        try? data.write(to: nasHistoryCacheURL(), options: [.atomic, .completeFileProtection])
    }

    /// Best-effort fetch of the NAS's own 5-minute consumption history,
    /// independent of the Gemini online fetch. A missing file, invalid contract, network
    /// failure, or a source/generation switch while in flight leaves the
    /// displayed snapshot and the last good cached history untouched.
    private func refreshNASHistory(generation myGeneration: Int) {
        Task {
            let outcome: Result<NASConsumptionHistory, NASFetchError>
            do {
                let data = try await nasHistoryClient.fetchStoredHistory()
                if let reading = UsageSnapshot.parseNASConsumptionHistoryFile(data) {
                    outcome = .success(reading)
                } else {
                    outcome = .failure(.unreadableResponse)
                }
            } catch let error as NASFetchError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.network)
            }

            guard myGeneration == generation, preferredSource == .nas, displayedSource == .nas else { return }

            switch outcome {
            case .success(let reading):
                // A late or older copy must never replace a newer one that
                // is already cached/displayed.
                if let current = loadCachedNASHistory(), current.collectedAt >= reading.collectedAt {
                    nasHistoryIssue = nil
                    return
                }
                persistNASHistory(reading)
                if case .loaded(let snapshot) = state {
                    state = .loaded(snapshot.applyingNASHistory(reading))
                }
                nasHistoryIssue = nil
            case .failure(let error):
                nasHistoryIssue = Self.nasHistoryIssueLabel(for: error)
            }
        }
    }

    /// A missing history file is the normal state until the NAS has taken
    /// its first readings, so it is not reported as a problem at all.
    private static func nasHistoryIssueLabel(for error: NASFetchError) -> String? {
        if case .serverError(let message) = error, message.contains("404") { return nil }
        return geminiOnlineIssueLabel(for: error)
    }

    private static func geminiOnlineIssueLabel(for error: NASFetchError) -> String {
        switch error {
        case .notAuthenticated:
            return "NAS 로그인 필요"
        case .network, .timeout:
            return "네트워크 오류"
        case .serverError(let message) where message.contains("404"):
            return "Mac에서 NAS 저장 대기"
        case .serverError, .invalidAddress:
            return "읽기 실패"
        case .unreadableResponse:
            return "잘못된 데이터"
        }
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
