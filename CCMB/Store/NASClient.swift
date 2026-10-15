import Foundation
import WebKit

/// The companion dashboard reads only the user's fixed NAS playground.
enum NASConfig {
    static let baseURLString = "https://hanstree.synology.me:5443"
    static let baseURL = URL(string: baseURLString)!
}

/// Reasons the phone could not read usage from the NAS. Each message leads
/// with the action the user should take.
enum NASFetchError: LocalizedError {
    case invalidAddress
    case notAuthenticated
    case forbidden
    case notFound
    case rateLimited
    case network
    case timeout
    case serverUnavailable
    case serverError(String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "설정에서 NAS 주소를 다시 확인해 주세요. 올바른 https 주소가 아닙니다."
        case .notAuthenticated:
            return "NAS에 다시 로그인해 주세요. 로그인이 만료되었거나 아직 되어 있지 않습니다."
        case .forbidden:
            return "이 계정은 사용량 조회 권한이 없습니다. 권한이 있는 계정으로 다시 로그인해 주세요."
        case .notFound:
            return "NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요. 요청한 항목을 NAS에서 찾을 수 없습니다."
        case .rateLimited:
            return "새로고침 요청이 너무 자주 발생했습니다. 잠시 후 다시 시도해 주세요."
        case .network:
            return "네트워크 연결을 확인한 뒤 다시 시도해 주세요. NAS에 접속하지 못했습니다."
        case .timeout:
            return "NAS 응답이 오래 걸립니다. 잠시 후 다시 시도해 주세요."
        case .serverUnavailable:
            return "NAS 서비스가 잠시 응답하지 않습니다. 잠시 후 다시 시도해 주세요."
        case .serverError(let message):
            return "잠시 후 다시 시도해 주세요. NAS 오류: \(message)"
        case .unreadableResponse:
            return "NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요. 응답 형식을 읽을 수 없습니다."
        }
    }
}

/// `GET /api/ccmb/v2/refresh/{job_id}` → `{job_id, state}` (§10.2; the
/// server's field is `state`, never `phase`).
enum NASRefreshJobState: String {
    case queued, running, completed, failed, deferred
}

/// How a user-requested v2 refresh ended before the final snapshot read.
enum NASRefreshOutcome: Equatable {
    case completed
    case failed
    case deferred
    /// The bounded UI wait ran out while the job was still queued/running;
    /// the stored snapshot is shown while the NAS keeps collecting.
    case stillRunning
    /// The job id is no longer known to the server (restart or superseded).
    case jobUnavailable
}

struct NASSnapshotFetchResult {
    let data: Data
    let isV2: Bool
    let refreshOutcome: NASRefreshOutcome?
    /// The POST's `retry_after_seconds`: no new refresh POST before then.
    let retryAfterSeconds: Double?
}

struct NASHTTPResponse {
    let statusCode: Int
    let data: Data
}

/// Pure HTTP status classification shared by every NAS call, kept free of
/// networking so it can be exercised directly by the fixture harness. A
/// POST-accepted 202 is handled by its caller, never routed through here.
enum NASHTTPClassifier {
    static func classify(statusCode: Int) -> NASFetchError? {
        switch statusCode {
        case 200..<300: return nil
        case 401: return .notAuthenticated
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited
        case 503: return .serverUnavailable
        default: return .serverError("HTTP \(statusCode)")
        }
    }
}

/// The v2 read/refresh sequence (§10.2, §10.5), independent of URLSession so
/// the fixture harness drives the exact same logic with scripted responses:
///
/// 1. `GET /api/ccmb/v2/snapshot` (read-only) decides capability. Only an
///    HTTP 404 here means "no v2 on this server" and switches to legacy
///    `GET /api/usage` (`?refresh=1` only for a user refresh). Any other
///    failure is reported as-is — never hidden behind legacy.
/// 2. With v2 present and a user refresh, `POST /api/ccmb/v2/refresh`
///    (202 `{job_id, retry_after_seconds}`); 401/403/429/503 propagate.
/// 3. Bounded polling of the job, then one more snapshot GET.
struct NASSnapshotFlow {
    typealias Transport = (_ method: String, _ url: URL, _ timeout: TimeInterval) async throws -> NASHTTPResponse

    /// How long a pull-to-refresh waits for the job before showing the
    /// stored snapshot with a busy note. Deliberately far below the 180 s
    /// management budget (§7.3); the NAS job keeps running regardless.
    static let refreshWaitBudget: TimeInterval = 25
    static let maxRetryAfterSeconds: Double = 3600

    let base: URL
    let send: Transport
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    /// Monotonic; wall-clock changes must not stretch or cut the wait.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func run(refresh: Bool) async throws -> NASSnapshotFetchResult {
        let snapshotURL = base.appendingPathComponent("api/ccmb/v2/snapshot")
        let first = try await send("GET", snapshotURL, 30)
        if first.statusCode == 404 {
            let legacy = try await send("GET", try legacyUsageURL(refresh: refresh), 30)
            if let error = NASHTTPClassifier.classify(statusCode: legacy.statusCode) { throw error }
            return NASSnapshotFetchResult(data: legacy.data, isV2: false, refreshOutcome: nil, retryAfterSeconds: nil)
        }
        if let error = NASHTTPClassifier.classify(statusCode: first.statusCode) { throw error }
        guard refresh else {
            return NASSnapshotFetchResult(data: first.data, isV2: true, refreshOutcome: nil, retryAfterSeconds: nil)
        }

        try Task.checkCancellation()
        let post = try await send("POST", base.appendingPathComponent("api/ccmb/v2/refresh"), 20)
        guard post.statusCode == 202 else {
            throw NASHTTPClassifier.classify(statusCode: post.statusCode) ?? NASFetchError.unreadableResponse
        }
        let accepted = try Self.parseRefreshAccepted(post.data)
        let outcome = try await waitForJob(jobID: accepted.jobID)

        try Task.checkCancellation()
        let final = try await send("GET", snapshotURL, 30)
        // v2 was present a moment ago; a 404 now is an error, not a reason
        // to switch sources mid-refresh.
        if let error = NASHTTPClassifier.classify(statusCode: final.statusCode) { throw error }
        return NASSnapshotFetchResult(
            data: final.data,
            isV2: true,
            refreshOutcome: outcome,
            retryAfterSeconds: accepted.retryAfterSeconds
        )
    }

    private func legacyUsageURL(refresh: Bool) throws -> URL {
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/usage"),
            resolvingAgainstBaseURL: false
        ) else {
            throw NASFetchError.invalidAddress
        }
        if refresh {
            components.queryItems = [URLQueryItem(name: "refresh", value: "1")]
        }
        guard let url = components.url else { throw NASFetchError.invalidAddress }
        return url
    }

    private func waitForJob(jobID: String) async throws -> NASRefreshOutcome {
        let jobURL = base.appendingPathComponent("api/ccmb/v2/refresh").appendingPathComponent(jobID)
        let start = uptime()
        var delay: TimeInterval = 1
        while true {
            try Task.checkCancellation()
            let remaining = Self.refreshWaitBudget - (uptime() - start)
            guard remaining > 0 else { return .stillRunning }
            let response = try await send("GET", jobURL, min(10, remaining))
            if response.statusCode == 404 { return .jobUnavailable }
            if let error = NASHTTPClassifier.classify(statusCode: response.statusCode) { throw error }
            switch try Self.parseJobState(response.data, expectedJobID: jobID) {
            case .completed: return .completed
            case .failed: return .failed
            case .deferred: return .deferred
            case .queued, .running:
                let left = Self.refreshWaitBudget - (uptime() - start)
                guard left > 0 else { return .stillRunning }
                try await sleep(min(delay, left))
                delay = min(delay * 2, 4)
            }
        }
    }

    /// The server issues `crypto.randomUUID()` ids; only that exact
    /// lowercase form may become a URL path segment.
    static func isSafeJobID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar == "-" else { return false }
            } else {
                guard ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) else { return false }
            }
        }
        return true
    }

    static func parseRefreshAccepted(_ data: Data) throws -> (jobID: String, retryAfterSeconds: Double) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobID = object["job_id"] as? String, isSafeJobID(jobID),
              let number = object["retry_after_seconds"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw NASFetchError.unreadableResponse
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds >= 0, seconds <= maxRetryAfterSeconds else {
            throw NASFetchError.unreadableResponse
        }
        return (jobID, seconds)
    }

    static func parseJobState(_ data: Data, expectedJobID: String) throws -> NASRefreshJobState {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["job_id"] as? String == expectedJobID,
              let raw = object["state"] as? String,
              let state = NASRefreshJobState(rawValue: raw) else {
            throw NASFetchError.unreadableResponse
        }
        return state
    }
}

/// Denies every redirect: a redirect could point at a different host
/// entirely, and this client must never carry the `hw_session` cookie
/// anywhere but the exact configured NAS address.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Reads usage from the home NAS using only the `hw_session` cookie that the
/// user's own login in this app's embedded web view already produced. The
/// phone never collects the NAS password itself; the only write is the v2
/// refresh request, which carries the exact NAS `Origin` for the server's
/// existing CSRF check.
struct NASSnapshotClient {
    static let sessionCookieName = "hw_session"

    /// `GET /api/ccmb/v2/snapshot` first, legacy `/api/usage` only on its
    /// 404; see `NASSnapshotFlow`. The automatic timer never refreshes.
    func fetchSnapshot(refresh: Bool) async throws -> NASSnapshotFetchResult {
        let base = NASConfig.baseURL
        guard let cookie = await Self.sessionCookie(for: base) else {
            throw NASFetchError.notAuthenticated
        }
        let flow = NASSnapshotFlow(base: base) { method, url, timeout in
            let (data, response) = method == "POST"
                ? try await Self.post(url: url, cookie: cookie, timeoutIntervalForRequest: timeout, timeoutIntervalForResource: timeout)
                : try await Self.request(url: url, cookie: cookie, timeoutIntervalForRequest: timeout, timeoutIntervalForResource: timeout)
            guard let http = response as? HTTPURLResponse, Self.isSameOrigin(http.url, as: base) else {
                throw NASFetchError.network
            }
            return NASHTTPResponse(statusCode: http.statusCode, data: data)
        }
        return try await flow.run(refresh: refresh)
    }

    /// `scheme://host[:port]` of the configured NAS, exactly as the server
    /// compares it against `Origin`.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    static func isSameOrigin(_ url: URL?, as base: URL) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return origin(of: url) == origin(of: base)
    }

    /// Same no-redirect/no-cache/cookie-only session as `request`, but a
    /// `POST` with an empty JSON object body, used only for
    /// `/api/ccmb/v2/refresh`. The server requires `Content-Type:
    /// application/json` and an exact `Origin`; no other credential
    /// (Bearer token, copied browser cookie) is ever sent.
    static func post(
        url: URL,
        cookie: HTTPCookie,
        timeoutIntervalForRequest: TimeInterval = 20,
        timeoutIntervalForResource: TimeInterval = 20
    ) async throws -> (Data, URLResponse) {
        guard let origin = origin(of: NASConfig.baseURL), isSameOrigin(url, as: NASConfig.baseURL) else {
            throw NASFetchError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        return try await perform(request, cookie: cookie, timeoutIntervalForRequest: timeoutIntervalForRequest, timeoutIntervalForResource: timeoutIntervalForResource)
    }

    /// Whether the NAS actually still considers this phone logged in, by
    /// asking the server rather than trusting that a same-named cookie is
    /// merely present (an expired or otherwise invalid cookie would
    /// otherwise cause a permanent 401 loop with no way to reach the login
    /// sheet again).
    func checkSession() async -> Bool {
        let base = NASConfig.baseURL
        guard let cookie = await Self.sessionCookie(for: base) else { return false }
        guard let url = URLComponents(
            url: base.appendingPathComponent("api/session"),
            resolvingAgainstBaseURL: false
        )?.url else { return false }
        guard let (data, response) = try? await Self.request(url: url, cookie: cookie),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["authenticated"] as? Bool) == true
        else {
            return false
        }
        return true
    }

    static func request(
        url: URL,
        cookie: HTTPCookie,
        timeoutIntervalForRequest: TimeInterval = 85,
        timeoutIntervalForResource: TimeInterval = 90
    ) async throws -> (Data, URLResponse) {
        guard isSameOrigin(url, as: NASConfig.baseURL) else { throw NASFetchError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await perform(request, cookie: cookie, timeoutIntervalForRequest: timeoutIntervalForRequest, timeoutIntervalForResource: timeoutIntervalForResource)
    }

    private static func perform(
        _ request: URLRequest,
        cookie: HTTPCookie,
        timeoutIntervalForRequest: TimeInterval,
        timeoutIntervalForResource: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = timeoutIntervalForResource
        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")

        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw NASFetchError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw NASFetchError.network
        }
    }

    /// Only the unexpired `hw_session` cookie whose canonical domain is
    /// exactly the configured host (no subdomain/suffix matching), whose
    /// path covers the API root, and which is marked `Secure`. The cookie
    /// is read live from WebKit's store each time and never copied into any
    /// persistent storage.
    @MainActor
    static func sessionCookie(for url: URL) async -> HTTPCookie? {
        guard let host = url.host else { return nil }
        let all = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let now = Date()
        return all.first { matches(cookie: $0, host: host, now: now) }
    }

    private static func matches(cookie: HTTPCookie, host: String, now: Date) -> Bool {
        guard cookie.name == sessionCookieName, cookie.isSecure else { return false }
        if let expires = cookie.expiresDate, expires <= now { return false }
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        guard domain == host else { return false }
        return cookie.path == "/" || cookie.path == "/api" || cookie.path == "/api/"
    }
}

/// Reads the single private, bounded Gemini web-session relay file the user
/// authorized, via the server's own `CCMB-Usage` data store endpoint. This is
/// a read of a file already placed there by the Mac-side relay script — no
/// NAS quota UI, no new auth, and the same fixed HTTPS origin / `hw_session`
/// cookie / no-redirect rules as `NASSnapshotClient`.
struct NASGeminiOnlineClient {
    private static let relayFileName = "CCMB-gemini-online-v1.json"
    /// The relay contract caps the file at 8KiB; this stays generous enough
    /// to catch the real file while still rejecting a response that has
    /// become something else entirely.
    private static let maxResponseBytes = 8192

    func fetchStoredOnline() async throws -> Data {
        try await Self.downloadRelayFile(named: Self.relayFileName, maxBytes: Self.maxResponseBytes)
    }

    /// GET-only download of one fixed file name from the server's
    /// `CCMB-Usage` data store, shared by every file read from there (the
    /// Mac-relayed Gemini online file and the NAS's own history file) so they
    /// all follow the same origin/cookie/no-redirect/size rules.
    static func downloadRelayFile(named fileName: String, maxBytes: Int) async throws -> Data {
        let base = NASConfig.baseURL
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/ccmb/files"),
            resolvingAgainstBaseURL: false
        ) else {
            throw NASFetchError.invalidAddress
        }
        components.queryItems = [URLQueryItem(name: "name", value: fileName)]
        guard let url = components.url else { throw NASFetchError.invalidAddress }

        guard let cookie = await NASSnapshotClient.sessionCookie(for: base) else {
            throw NASFetchError.notAuthenticated
        }

        let (data, response) = try await NASSnapshotClient.request(
            url: url,
            cookie: cookie,
            timeoutIntervalForRequest: 15,
            timeoutIntervalForResource: 15
        )
        guard let http = response as? HTTPURLResponse else { throw NASFetchError.network }
        if let error = NASHTTPClassifier.classify(statusCode: http.statusCode) { throw error }
        guard data.count <= maxBytes else { throw NASFetchError.unreadableResponse }
        return data
    }
}

/// Reads the consumption history the NAS itself records every 5 minutes as
/// `CCMB-nas-consumption-history-v1.json` in the same private `CCMB-Usage`
/// project, through the same download path as the Gemini online relay file.
/// The older Mac-relayed `CCMB-consumption-history-v1.json` is never read.
struct NASConsumptionHistoryClient {
    private static let historyFileName = "CCMB-nas-consumption-history-v1.json"
    private static let historyV2FileName = "CCMB-nas-consumption-history-v2.json"

    func fetchStoredHistory() async throws -> Data {
        try await NASGeminiOnlineClient.downloadRelayFile(
            named: Self.historyFileName,
            maxBytes: UsageSnapshot.nasHistoryMaxBytes
        )
    }

    /// `gemini2`를 포함하는 새 6-시리즈 파일. HTTP 404일 때만 `nil`을 돌려주고
    /// 호출자가 기존 v1을 쓴다. 401/403/네트워크 등은 그대로 던진다.
    func fetchStoredHistoryV2() async throws -> Data? {
        do {
            return try await NASGeminiOnlineClient.downloadRelayFile(
                named: Self.historyV2FileName,
                maxBytes: UsageSnapshot.nasHistoryV2MaxBytes
            )
        } catch NASFetchError.notFound {
            return nil
        }
    }
}
