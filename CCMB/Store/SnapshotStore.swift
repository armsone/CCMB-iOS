import Foundation
import SwiftUI

/// Bounded adaptive cadence for the automatic NAS refresh, mirroring the
/// Mac app's `SmartRefreshPolicy`: a meaningful usage/account/reset change
/// snaps back to 30s; repeated unchanged reads relax to 120s, then 300s.
/// The caller's chosen `automaticRefreshInterval` acts only as a ceiling —
/// it is never exceeded, but idle relaxation never goes past 300s either.
/// Only meaningful values (percentages, credit balances, account identity,
/// reset timestamps) may be passed to `update(values:)`; a poll/fetch clock
/// would always differ and would pin the policy to `active` forever.
private struct AdaptiveRefreshPolicy {
    enum Mode: Equatable {
        case active, idleShort, idleMedium

        var interval: TimeInterval {
            switch self {
            case .active: return 30
            case .idleShort: return 120
            case .idleMedium: return 300
            }
        }

        var unchangedThreshold: Int? {
            switch self {
            case .active: return 3
            case .idleShort: return 6
            case .idleMedium: return nil
            }
        }

        var next: Mode {
            switch self {
            case .active: return .idleShort
            case .idleShort, .idleMedium: return .idleMedium
            }
        }
    }

    private(set) var mode: Mode = .active
    private var unchangedCount = 0
    private var lastValues: [Double?]?
    /// Exact-equality identity tokens (account id/email, reset timestamp as
    /// an unambiguous string), tracked separately from `lastValues` so no
    /// hashing or numeric folding is involved — `hashValue` is per-process
    /// and can collide, so it must never stand in for identity comparison.
    private var lastIdentityTokens: [String?]?

    mutating func update(values: [Double?], identityTokens: [String?] = []) {
        guard let previousValues = lastValues, let previousIdentityTokens = lastIdentityTokens else {
            lastValues = values
            lastIdentityTokens = identityTokens
            return
        }
        let valuesChanged = values.count != previousValues.count || zip(values, previousValues).contains { current, old in
            switch (current, old) {
            case let (current?, old?): return abs(current - old) > 0.01
            case (nil, nil): return false
            default: return true
            }
        }
        let identityChanged = identityTokens != previousIdentityTokens
        lastValues = values
        lastIdentityTokens = identityTokens
        if valuesChanged || identityChanged {
            mode = .active
            unchangedCount = 0
            return
        }
        unchangedCount += 1
        guard let threshold = mode.unchangedThreshold, unchangedCount >= threshold else { return }
        mode = mode.next
        unchangedCount = 0
    }

    func interval(ceiling: TimeInterval) -> TimeInterval {
        min(mode.interval, max(30, ceiling))
    }

    /// Formats a reset timestamp as an exact, unambiguous identity token
    /// (epoch seconds). Never pass a poll/fetch timestamp here — only a
    /// confirmed upstream reset instant.
    static func identityToken(_ date: Date?) -> String? {
        date.map { String($0.timeIntervalSince1970) }
    }

    /// Quota-bucket reset identity token. A fully-unused bucket (`usedIsZero`)
    /// rolls its own reset instant forward on every read even with no real
    /// activity, so it must not contribute to the fingerprint at all. A
    /// used bucket's reset instant can jitter by a second between reads of
    /// the same underlying reset, so it is minute-normalized before
    /// comparison.
    static func quotaResetIdentityToken(_ date: Date?, usedIsZero: Bool) -> String? {
        guard !usedIsZero, let date else { return nil }
        let normalizedSeconds = (date.timeIntervalSince1970 / 60).rounded() * 60
        return String(normalizedSeconds)
    }
}

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
    /// The interval actually scheduled for the next automatic tick, which
    /// can be shorter than `automaticRefreshInterval` (recent activity) or
    /// anywhere up to it (idle relaxation, capped at 300s). Views computing
    /// a countdown progress bar must use this, not `automaticRefreshInterval`.
    @Published private(set) var effectiveAutomaticRefreshInterval: TimeInterval = 60
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
    /// How the last user-requested NAS refresh ended (busy, deferred,
    /// failed…) while the stored snapshot stays on screen.
    @Published private(set) var nasRefreshNotice: String?
    /// The NAS is still collecting: the live v2 `collection.state`, or the
    /// bounded refresh wait ran out before the job finished.
    @Published private(set) var nasRefreshBusy = false

    /// Playground task counts; independent of the usage snapshot. The last
    /// successful value is kept when a later read fails.
    @Published private(set) var nasTaskStatus: NASTaskStatus?
    @Published private(set) var nasTaskStatusAt: Date?
    @Published private(set) var nasTaskStatusFailed = false
    private var nasTaskStatusInFlight = false

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
    /// Monotonic time before which no new refresh POST is sent, from the
    /// server's `retry_after_seconds`.
    private var nasRefreshNotBefore: TimeInterval?
    private var automaticRefreshTimer: Timer?
    /// Automatic refresh only ever runs while the scene is in the
    /// foreground; `CCMBApp` toggles this on `scenePhase` changes so a
    /// backgrounded app never keeps firing network requests on a timer.
    private var isSceneActive = true
    private var adaptivePolicy = AdaptiveRefreshPolicy()
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
    /// Set once this one-time migration has run (or the user has explicitly
    /// picked a cadence since it shipped); never reset afterwards.
    private static let adaptiveMigrationDoneDefaultsKey = "automaticRefreshAdaptiveMigrationV1"
    /// The numeric cadence saved before this migration, kept so a future
    /// manual re-selection still has the user's old choice to fall back to;
    /// it is never read as a ceiling on adaptive mode.
    private static let legacyManualIntervalDefaultsKey = "legacyManualRefreshIntervalSecondsV1"
    private static let codexCreditHistoryDefaultsKey = "codexCreditHistoryV1"

    private struct CreditSample: Codable {
        let observedAt: Date
        let balance: Double
    }

    /// Sentinel for "adaptive": relax automatically between 30s and 300s
    /// instead of a fixed manual ceiling. Never confused with `0`, which
    /// would otherwise mean "off" — this app has no "off" option.
    static let adaptiveRefreshSentinel: TimeInterval = -1
    static let automaticRefreshOptions: [TimeInterval] = [adaptiveRefreshSentinel, 30, 60, 120, 300, 600]
    /// The NAS's own collection cadence; the user-facing automatic-refresh
    /// interval picker only ever applied to the retired cloud/file sources.
    static let nasAutomaticRefreshInterval: TimeInterval = 180

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
        // NAS is the only selectable source now. A previously saved cloud or
        // file preference is left untouched on disk (never cleared here) but
        // must no longer cause a cloud/file fetch on startup.
        preferredSource = .nas
        displayedSource = preferredSource
        // `setAutomaticRefreshInterval` is the only other writer of
        // `automaticRefreshDefaultsKey`. Its absence means a fresh install,
        // which starts on adaptive. An existing numeric save from before
        // this migration shipped is moved to adaptive exactly once — the
        // user explicitly requested idle-slow/active-fast by default for
        // everyone — but the old number is preserved separately and never
        // re-migrated once this has run or the user has chosen a cadence
        // since.
        if UserDefaults.standard.object(forKey: Self.automaticRefreshDefaultsKey) == nil {
            automaticRefreshInterval = Self.adaptiveRefreshSentinel
            UserDefaults.standard.set(true, forKey: Self.adaptiveMigrationDoneDefaultsKey)
        } else if UserDefaults.standard.bool(forKey: Self.adaptiveMigrationDoneDefaultsKey) == false {
            let savedInterval = UserDefaults.standard.double(forKey: Self.automaticRefreshDefaultsKey)
            if Self.automaticRefreshOptions.contains(savedInterval), savedInterval != Self.adaptiveRefreshSentinel {
                UserDefaults.standard.set(savedInterval, forKey: Self.legacyManualIntervalDefaultsKey)
            }
            automaticRefreshInterval = Self.adaptiveRefreshSentinel
            UserDefaults.standard.set(Self.adaptiveRefreshSentinel, forKey: Self.automaticRefreshDefaultsKey)
            UserDefaults.standard.set(true, forKey: Self.adaptiveMigrationDoneDefaultsKey)
        } else {
            let savedInterval = UserDefaults.standard.double(forKey: Self.automaticRefreshDefaultsKey)
            automaticRefreshInterval = Self.automaticRefreshOptions.contains(savedInterval) ? savedInterval : Self.adaptiveRefreshSentinel
        }
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
                if let cached = NASCacheCodec.decodeSnapshotCache(data, origin: NASConfig.baseURL.absoluteString) {
                    state = .loaded(applyingCachedNASExtras(to: cached.snapshot))
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
        UserDefaults.standard.set(true, forKey: Self.adaptiveMigrationDoneDefaultsKey)
        adaptivePolicy = AdaptiveRefreshPolicy()
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
            // One-shot timer: this tick's owner re-arms the next one here,
            // mirroring the NAS path's `noteAutomaticRefreshFinished`.
            if isAutomatic { scheduleAutomaticRefresh() }
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
            // A transient failure never accelerates the cadence: only the
            // timer is rescheduled here, never `adaptivePolicy`.
            if isAutomatic { scheduleAutomaticRefresh() }
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
            // One-shot timer: this tick's owner re-arms the next one on
            // every exit, including this early return, or an automatic
            // refresh of a bookmark-less file source would never tick again.
            if isLaunch { scheduleAutomaticRefresh() }
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
            if isLaunch { scheduleAutomaticRefresh() }
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
            if isLaunch { scheduleAutomaticRefresh() }
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
            if isLaunch { scheduleAutomaticRefresh() }
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
        nasRefreshNotice = nil
        nasRefreshBusy = false
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
                let result = try await nasClient.fetchSnapshot(refresh: false)
                let prepared = try prepareNASSnapshot(result)
                guard myGeneration == generation else { return }
                writeNASCache(prepared.cacheData)
                setPreferredSource(.nas)
                state = .loaded(applyingCachedNASExtras(to: prepared.snapshot))
                nasRefreshBusy = prepared.snapshot.collectionBusy
                nasRefreshNotice = nil
                origin = .nas
                displayedSource = .nas
                displayedNASAddress = NASConfig.baseURL.absoluteString
                lastReadAt = Date()
                refreshProblem = nil
                codexCreditsSpentLast30Minutes = nil
                updateAdaptivePolicy(from: prepared.snapshot)
                scheduleAutomaticRefresh()
                // Gemini 온라인 별도 수집은 중단한다.
                refreshNASHistory(generation: myGeneration)
                refreshNASTaskStatus()
            } catch is CancellationError {
                return
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
        refreshNASTaskStatus()
    }

    private func refreshNASTaskStatus() {
        guard preferredSource == .nas, !nasTaskStatusInFlight else { return }
        nasTaskStatusInFlight = true
        Task {
            defer { nasTaskStatusInFlight = false }
            // Captured before the request starts (after any manual refresh
            // queued ahead of us has bumped the generation) so a source
            // switch or reconnect while in flight drops success and failure.
            let myGeneration = generation
            do {
                let status = try await nasClient.fetchTaskStatus()
                guard myGeneration == generation, preferredSource == .nas else { return }
                nasTaskStatus = status
                nasTaskStatusAt = status.capturedAt
                nasTaskStatusFailed = false
            } catch is CancellationError {
                return
            } catch {
                guard myGeneration == generation, preferredSource == .nas else { return }
                nasTaskStatusFailed = true
            }
        }
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

        // A user refresh inside the server's `retry_after_seconds` re-reads
        // the stored snapshot instead of sending another refresh request.
        let throttled = !isAutomatic && (nasRefreshNotBefore.map { ProcessInfo.processInfo.systemUptime < $0 } ?? false)

        do {
            let result = try await nasClient.fetchSnapshot(refresh: !isAutomatic && !throttled)
            if let retryAfter = result.retryAfterSeconds {
                nasRefreshNotBefore = ProcessInfo.processInfo.systemUptime + retryAfter
            }
            let prepared = try prepareNASSnapshot(result)
            guard preferredSource == .nas, myGeneration == generation else { return }
            writeNASCache(prepared.cacheData)
            state = .loaded(applyingCachedNASExtras(to: prepared.snapshot))
            nasRefreshBusy = prepared.snapshot.collectionBusy || result.refreshOutcome == .stillRunning
            if !isAutomatic {
                nasRefreshNotice = Self.refreshNotice(for: result.refreshOutcome, throttled: throttled && result.isV2)
            }
            origin = .nas
            displayedSource = .nas
            displayedNASAddress = NASConfig.baseURL.absoluteString
            lastReadAt = Date()
            refreshProblem = nil
            // Gemini 온라인 별도 수집은 중단한다.
            refreshNASHistory(generation: myGeneration)
            if isAutomatic {
                noteAutomaticRefreshFinished(snapshot: prepared.snapshot)
            } else {
                updateAdaptivePolicy(from: prepared.snapshot)
            }
        } catch is CancellationError {
            return
        } catch {
            guard preferredSource == .nas, myGeneration == generation else { return }
            nasRefreshBusy = false
            nasRefreshNotice = nil
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
            // A transient failure must never accelerate the cadence: only
            // the timer is rescheduled here, never `adaptivePolicy`.
            if isAutomatic {
                scheduleAutomaticRefresh()
            }
        }
    }

    private func prepareNASSnapshot(_ result: NASSnapshotFetchResult) throws -> NASCacheCodec.PreparedSnapshot {
        try NASCacheCodec.prepareSnapshot(
            result.data,
            isV2: result.isV2,
            previousCache: try? Data(contentsOf: cacheURL(for: .nas)),
            origin: NASConfig.baseURL.absoluteString
        )
    }

    private func writeNASCache(_ data: Data) {
        try? data.write(to: cacheURL(for: .nas), options: [.atomic, .completeFileProtection])
    }

    private static func refreshNotice(for outcome: NASRefreshOutcome?, throttled: Bool) -> String? {
        if throttled {
            return "방금 갱신을 요청해서 저장된 값을 다시 읽었습니다. 잠시 후 다시 새로 고칠 수 있습니다."
        }
        switch outcome {
        case .none, .completed?:
            return nil
        case .failed?:
            return "NAS 수집이 실패해 서비스별 마지막 저장값과 오류 사유를 표시합니다."
        case .deferred?:
            return "최근에 갱신되어 NAS가 새 수집을 미뤘습니다. 저장된 값을 표시합니다."
        case .stillRunning?:
            return "NAS가 아직 수집 중입니다. 저장된 값을 먼저 표시합니다."
        case .jobUnavailable?:
            return "갱신 작업 상태를 확인하지 못해 저장된 값을 표시합니다."
        }
    }

    private func setPreferredSource(_ source: PreferredSource) {
        preferredSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.preferredSourceDefaultsKey)
    }

    /// Flat, meaningful-only values and identity tokens for the NAS
    /// snapshot's four live services: remaining percentages and credit
    /// balances as numeric values; account identity and each primary
    /// window's reset time as exact-equality identity tokens (never hashed
    /// into the numeric values). Never includes `fetchedAt` or any other
    /// poll-time clock, which would always differ and would pin the
    /// adaptive policy to `active` forever.
    private func activityValues(from snapshot: UsageSnapshot) -> (values: [Double?], identityTokens: [String?]) {
        var values: [Double?] = []
        var identityTokens: [String?] = []
        for service in [Service.codex, .claude, .gemini, .gemini2, .gemini3] {
            guard let usage = snapshot.services[service] else { continue }
            values += usage.windows.map(\.remainingPercent)
            values.append(usage.creditBalance)
            identityTokens.append(usage.account)
            identityTokens.append(AdaptiveRefreshPolicy.quotaResetIdentityToken(
                usage.primaryWindow?.resetsAt,
                usedIsZero: usage.primaryWindow?.remainingPercent == 100
            ))
        }
        return (values, identityTokens)
    }

    private func updateAdaptivePolicy(from snapshot: UsageSnapshot) {
        let activity = activityValues(from: snapshot)
        adaptivePolicy.update(values: activity.values, identityTokens: activity.identityTokens)
    }

    /// Called from `CCMBApp` on `scenePhase` becoming `.background`/
    /// `.inactive`: stops the automatic timer so a backgrounded app never
    /// keeps polling the NAS.
    func pauseAutomaticRefresh() {
        isSceneActive = false
        automaticRefreshTimer?.invalidate()
        automaticRefreshTimer = nil
    }

    /// Called from `CCMBApp` on `scenePhase` becoming `.active`. The caller
    /// still performs its own immediate `refresh(isAutomatic: true)`; this
    /// only resumes the countdown timer for the ticks after that.
    func resumeAutomaticRefresh() {
        isSceneActive = true
        scheduleAutomaticRefresh()
    }

    private func scheduleAutomaticRefresh() {
        automaticRefreshTimer?.invalidate()
        automaticRefreshTimer = nil
        guard isSceneActive else {
            nextAutomaticRefreshAt = nil
            return
        }
        // NAS is the only selectable source now; its foreground snapshot/
        // history reads are fixed at the NAS's own 3-minute collection
        // cadence, never the adaptive policy or a user-picked ceiling (those
        // still exist on disk for the legacy cloud/file sources below, but
        // are never read for NAS).
        let interval: TimeInterval
        if displayedSource == .nas {
            interval = Self.nasAutomaticRefreshInterval
        } else {
            // Adaptive mode relaxes all the way to 300s; an explicit manual
            // choice (including 60s) is instead an exact ceiling that idle
            // relaxation never exceeds.
            let ceiling = automaticRefreshInterval == Self.adaptiveRefreshSentinel ? 300 : automaticRefreshInterval
            interval = adaptivePolicy.interval(ceiling: ceiling)
        }
        effectiveAutomaticRefreshInterval = interval
        nextAutomaticRefreshAt = Date().addingTimeInterval(interval)
        // One-shot: each tick reschedules itself (via `noteAutomaticRefreshFinished`)
        // once that tick's fetch actually completes, so the next interval always
        // reflects the latest known activity instead of a stale repeating cadence.
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(isAutomatic: true)
            }
        }
        timer.tolerance = min(5, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        automaticRefreshTimer = timer
    }

    /// Ends one automatic refresh tick: feeds a successful snapshot's
    /// meaningful values into the adaptive policy (a failure never does,
    /// so a transient error can never accelerate the cadence), then
    /// reschedules the next one-shot tick.
    private func noteAutomaticRefreshFinished(snapshot: UsageSnapshot?) {
        if let snapshot {
            updateAdaptivePolicy(from: snapshot)
        }
        scheduleAutomaticRefresh()
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

    /// Mac snapshots only; NAS copies go through `NASCacheCodec` so a raw
    /// NAS response is never written to disk.
    private func persistGoodCopy(_ data: Data, source: PreferredSource) {
        guard source != .nas else { return }
        try? data.write(to: cacheURL(for: source), options: [.atomic, .completeFileProtection])
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
        // Gemini 온라인은 캐시에 남아 있어도 다시 표시하지 않는다.
        return loadCachedNASHistory().map(snapshot.applyingNASHistory) ?? snapshot
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
    /// currently configured NAS origin is ever reused; v1 and v2 copies are
    /// each read back only by their own strict parser.
    private func loadCachedNASHistory() -> NASConsumptionHistory? {
        guard let data = try? Data(contentsOf: nasHistoryCacheURL()) else { return nil }
        return NASCacheCodec.decodeHistoryCache(data, origin: NASConfig.baseURL.absoluteString)
    }

    private func persistNASHistory(_ reading: NASConsumptionHistory) {
        guard let data = NASCacheCodec.encodeHistoryCache(reading, origin: NASConfig.baseURL.absoluteString) else { return }
        try? data.write(to: nasHistoryCacheURL(), options: [.atomic, .completeFileProtection])
    }

    private enum NASHistoryIssue: Error {
        case fetch(NASFetchError)
        case unknownSchema
        case invalid
    }

    /// Best-effort fetch of the NAS's own 5-minute consumption history,
    /// independent of the Gemini online fetch. A missing file, invalid contract, network
    /// failure, or a source/generation switch while in flight leaves the
    /// displayed snapshot and the last good cached history untouched.
    private func refreshNASHistory(generation myGeneration: Int) {
        Task {
            let outcome: Result<NASConsumptionHistory, NASHistoryIssue>
            do {
                // The 24-hour v3 file is preferred. Only an HTTP 404 falls back
                // (v3 → v2 → v1); a parse failure or any other HTTP/network
                // error does not.
                if let v3Data = try await nasHistoryClient.fetchStoredHistoryV3() {
                    do {
                        outcome = .success(try UsageSnapshot.decodeNASConsumptionHistoryV3(v3Data))
                    } catch NASHistoryParseError.unknownSchema {
                        outcome = .failure(.unknownSchema)
                    } catch {
                        outcome = .failure(.invalid)
                    }
                } else if let v2Data = try await nasHistoryClient.fetchStoredHistoryV2() {
                    do {
                        outcome = .success(try UsageSnapshot.decodeNASConsumptionHistoryV2(v2Data))
                    } catch NASHistoryParseError.unknownSchema {
                        outcome = .failure(.unknownSchema)
                    } catch {
                        outcome = .failure(.invalid)
                    }
                } else {
                    let data = try await nasHistoryClient.fetchStoredHistory()
                    if let reading = UsageSnapshot.parseNASConsumptionHistoryFile(data) {
                        outcome = .success(reading)
                    } else {
                        outcome = .failure(.invalid)
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as NASFetchError {
                outcome = .failure(.fetch(error))
            } catch {
                outcome = .failure(.fetch(.network))
            }

            guard myGeneration == generation, preferredSource == .nas, displayedSource == .nas else { return }

            switch outcome {
            case .success(let reading):
                // A late or older copy must never replace a newer one that
                // is already cached/displayed, unless the server re-exported
                // the same timestamp with a larger 24h point window.
                if let current = loadCachedNASHistory(),
                   current.schemaVersion == reading.schemaVersion,
                   current.collectedAt > reading.collectedAt
                       || (current.collectedAt == reading.collectedAt && current.totalPointCount >= reading.totalPointCount) {
                    nasHistoryIssue = nil
                    return
                }
                persistNASHistory(reading)
                if case .loaded(let snapshot) = state {
                    state = .loaded(snapshot.applyingNASHistory(reading))
                }
                nasHistoryIssue = nil
            case .failure(.fetch(let error)):
                nasHistoryIssue = Self.nasHistoryIssueLabel(for: error)
            case .failure(.unknownSchema):
                nasHistoryIssue = "지원하지 않는 기록 형식"
            case .failure(.invalid):
                nasHistoryIssue = "잘못된 데이터"
            }
        }
    }

    /// A missing history file is the normal state until the NAS has taken
    /// its first readings, so it is not reported as a problem at all.
    private static func nasHistoryIssueLabel(for error: NASFetchError) -> String? {
        if case .notFound = error { return nil }
        return geminiOnlineIssueLabel(for: error)
    }

    private static func geminiOnlineIssueLabel(for error: NASFetchError) -> String {
        switch error {
        case .notAuthenticated:
            return "NAS 로그인 필요"
        case .forbidden:
            return "권한 없음"
        case .rateLimited:
            return "요청 제한"
        case .network, .timeout, .serverUnavailable:
            return "네트워크 오류"
        case .notFound:
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
