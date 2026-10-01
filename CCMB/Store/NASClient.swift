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
    case network
    case timeout
    case serverError(String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "설정에서 NAS 주소를 다시 확인해 주세요. 올바른 https 주소가 아닙니다."
        case .notAuthenticated:
            return "NAS에 다시 로그인해 주세요. 로그인이 만료되었거나 아직 되어 있지 않습니다."
        case .network:
            return "네트워크 연결을 확인한 뒤 다시 시도해 주세요. NAS에 접속하지 못했습니다."
        case .timeout:
            return "NAS 응답이 오래 걸립니다. 잠시 후 다시 시도해 주세요."
        case .serverError(let message):
            return "잠시 후 다시 시도해 주세요. NAS 오류: \(message)"
        case .unreadableResponse:
            return "NAS 앱을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요. 응답 형식을 읽을 수 없습니다."
        }
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

/// Reads `/api/usage` from the home NAS using only the `hw_session` cookie
/// that the user's own login in the embedded web view already produced. The
/// phone never collects the NAS password itself and never writes anything
/// back to the NAS besides that one login the user performs in the web view.
struct NASSnapshotClient {
    static let sessionCookieName = "hw_session"

    /// `refresh=1` asks the NAS to bypass its own ≤5 minute cache; used only
    /// for user-initiated refreshes, not the automatic timer, since a forced
    /// NAS-side collection can take up to ~65 seconds.
    func fetchUsage(refresh: Bool) async throws -> Data {
        let base = NASConfig.baseURL
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

        guard let cookie = await Self.sessionCookie(for: base) else {
            throw NASFetchError.notAuthenticated
        }

        let (data, response) = try await Self.request(url: url, cookie: cookie)
        guard let http = response as? HTTPURLResponse else { throw NASFetchError.network }
        if http.statusCode == 401 {
            throw NASFetchError.notAuthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NASFetchError.serverError("HTTP \(http.statusCode)")
        }
        return data
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = timeoutIntervalForResource
        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("\(cookie.name)=\(cookie.value)", forHTTPHeaderField: "Cookie")

        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw NASFetchError.timeout
        } catch {
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
/// authorized: the existing private NAS storage project `CCMB-Usage`
/// (`projectID 1a5e36a6ff569127`), via that project's own authenticated
/// download endpoint. This is a read of a file already placed there by the
/// Mac-side relay script — no NAS quota UI, no new server endpoint, no new
/// auth, and the same fixed HTTPS origin / `hw_session` cookie / no-redirect
/// rules as `NASSnapshotClient`.
struct NASGeminiOnlineClient {
    static let projectID = "1a5e36a6ff569127"
    private static let relayFileName = "CCMB-gemini-online-v1.json"
    /// The relay contract caps the file at 8KiB; this stays generous enough
    /// to catch the real file while still rejecting a response that has
    /// become something else entirely.
    private static let maxResponseBytes = 8192

    func fetchStoredOnline() async throws -> Data {
        try await Self.downloadRelayFile(named: Self.relayFileName, maxBytes: Self.maxResponseBytes)
    }

    /// GET-only download of one fixed file name from the `CCMB-Usage`
    /// project, shared by every file read from there (the Mac-relayed Gemini
    /// online file and the NAS's own history file) so they all follow the
    /// same origin/cookie/no-redirect/size rules.
    static func downloadRelayFile(named fileName: String, maxBytes: Int) async throws -> Data {
        let base = NASConfig.baseURL
        guard var components = URLComponents(
            url: base.appendingPathComponent("api/projects/\(projectID)/download"),
            resolvingAgainstBaseURL: false
        ) else {
            throw NASFetchError.invalidAddress
        }
        components.queryItems = [URLQueryItem(name: "path", value: fileName)]
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
        if http.statusCode == 401 { throw NASFetchError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw NASFetchError.serverError("HTTP \(http.statusCode)")
        }
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

    func fetchStoredHistory() async throws -> Data {
        try await NASGeminiOnlineClient.downloadRelayFile(
            named: Self.historyFileName,
            maxBytes: UsageSnapshot.nasHistoryMaxBytes
        )
    }
}
