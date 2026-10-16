import Foundation

/// Reasons the picked file cannot become a snapshot. Messages lead with what
/// the user should do next; the technical cause comes second.
enum SnapshotError: LocalizedError {
    case unreadable
    case notJSON
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "파일을 다시 선택해 주세요. 선택한 파일을 읽을 수 없습니다."
        case .notJSON:
            return "Mac의 CCMB가 저장한 usage-v1.json을 선택해 주세요. 이 파일은 JSON 형식이 아닙니다."
        case .unsupportedSchema:
            return "Mac의 CCMB를 최신 버전으로 업데이트한 뒤 새 usage-v1.json을 복사해 주세요. 이 파일의 스키마 버전은 지원하지 않습니다."
        }
    }
}

/// Tolerant reader over a JSON dictionary: known keys are interpreted when
/// their types match, everything unknown is ignored, and nothing here ever
/// throws past the top-level schema check.
private struct JSONObject {
    let raw: [String: Any]

    func double(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
    /// A percentage field is only ever a real reading when it is finite and
    /// within `0...100`; anything else (NaN, infinity, a server-side glitch
    /// like a negative or >100 value) must never be shown as a true
    /// remaining amount.
    func percent(_ key: String) -> Double? {
        guard let value = nonBoolDouble(key), value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    /// A JSON number that is not a CFBoolean (`true` bridges to 1.0).
    func nonBoolDouble(_ key: String) -> Double? {
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
    /// Like `int(_:)` but rejects a genuine CFBoolean (`true`/`false`),
    /// which bridges to NSNumber and would otherwise satisfy `== 1` for
    /// `true`; a real integer `1` must still pass.
    func nonBoolInt(_ key: String) -> Int? {
        guard let number = raw[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
    func string(_ key: String) -> String? { raw[key] as? String }
    func bool(_ key: String) -> Bool? { raw[key] as? Bool }
    func date(_ key: String) -> Date? { string(key).flatMap(Self.parseDate) }
    func object(_ key: String) -> JSONObject? { (raw[key] as? [String: Any]).map(JSONObject.init) }
    func objectArray(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
    }

    /// The NAS usage endpoint reports timestamps as epoch seconds rather than
    /// the Mac app's ISO 8601 strings.
    func epochSecondsDate(_ key: String) -> Date? {
        guard let value = nonBoolDouble(key), value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// The Mac app writes fractional-second ISO 8601, but nested reset
    /// times relayed from CLIs may carry whole seconds only.
    static func parseDate(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? wholeSecondFormatter.date(from: string)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum Service: String, CaseIterable, Identifiable {
    case codex, claude, gemini, gemini2, grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .gemini2: return "Gemini 부계정"
        case .grok: return "Grok"
        }
    }
}

/// One labeled quota window (주간, 5시간 세션, 월간…) with a remaining
/// percentage and an optional reset time. A window the Mac data cannot carry
/// at all (Codex 세션 등) stays on screen with `unavailabilityNote` so the
/// card shape never shifts between snapshots.
struct UsageWindow: Identifiable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let resetsAt: Date?
    /// Some authenticated web sources expose only the user-visible reset
    /// caption rather than a machine-readable timestamp.
    var resetText: String? = nil
    var unavailabilityNote: String? = nil
    /// Only set when this window's reading was collected at a different time
    /// (and by a different path) than the surrounding service's own
    /// `fetchedAt` — currently just the Gemini NAS-stored online relay
    /// windows, whose detail screen and card footer must show the Mac's
    /// actual collection time rather than the NAS report time.
    var fetchedAt: Date? = nil
}

struct ClaudeModelWeeklyLimit: Identifiable {
    let id: String
    let modelName: String
    let remainingPercent: Double?
    let resetsAt: Date?
}

/// Per-service usage extracted from the nested `codex`/`claude`/`gemini`/
/// `grok` objects of `usage-v1.json`. All fields are optional: the Mac app
/// writes explicit nulls for anything a source did not report.
struct ServiceUsage {
    let service: Service
    /// `ok` / `partial` / `stale` / `unavailable` as written by the Mac app.
    var status: String?
    let windows: [UsageWindow]
    /// 달러 등 숫자 크레딧 잔액 (Codex 크레딧, Gemini AI 크레딧, Grok 추가 크레딧).
    /// NAS 소스의 Codex는 이 필드에 플레이그라운드가 보고하는 '토큰' 잔액을 담는다
    /// (입력/출력 토큰 소비량이 아니다).
    let creditBalance: Double?
    let creditLabel: String?
    /// NAS의 Codex credits.unlimited. Mac 소스나 다른 서비스는 항상 false.
    var creditUnlimited: Bool = false
    /// Grok의 이번 달 사용 크레딧.
    let monthlyUsedCredits: Double?
    let account: String?
    let organizationName: String?
    let planTitle: String?
    let model: String?
    let modelWeeklyLimits: [ClaudeModelWeeklyLimit]
    let fetchedAt: Date?
    /// NAS v2/legacy structured `error.code`/`error.message`, preserved
    /// independently per service so one service's failure never erases
    /// another's; non-secret only (no raw provider error bodies).
    var errorCode: String? = nil
    var errorMessage: String? = nil
    /// The NAS's own per-service `stale` flag.
    var stale: Bool = false
    /// The values on screen are this service's last good reading, kept
    /// because the latest NAS response for it failed with no items.
    var isLastKnown: Bool = false
    var nasHostStatus: NASHostStatus? = nil

    var executionStatusLines: [String] {
        guard let nasHostStatus else { return [] }
        let accountRef: String
        switch service {
        case .gemini:
            accountRef = "account1"
        case .gemini2:
            accountRef = "account2"
        default:
            return []
        }
        return nasHostStatus.footerLines(accountRef: accountRef, isCached: nasHostStatus.isCached)
    }

    /// The reason to show next to an erroring/unavailable service.
    var errorReason: String? {
        if let errorMessage, !errorMessage.isEmpty { return errorMessage }
        guard let errorCode else { return nil }
        return Self.knownErrorReasons[errorCode] ?? "오류 코드 \(errorCode)"
    }

    private static let knownErrorReasons: [String: String] = [
        "not_collected": "아직 수집된 값이 없습니다.",
        "unknown": "확인할 수 없는 오류가 발생했습니다.",
        "timeout": "응답 시간이 초과되었습니다.",
        "rate_limited": "요청이 제한되었습니다. 잠시 뒤 다시 시도해 주세요.",
        "login_required": "다시 로그인이 필요합니다.",
        "reauth_required": "다시 인증이 필요합니다.",
        "unsupported_server": "NAS 서버가 아직 Gemini 부계정을 지원하지 않습니다."
    ]

    var primaryWindow: UsageWindow? { windows.first }

    /// Windows with a real reading; used by the 홈 상단 focus card so a nil
    /// value can never masquerade as 0% remaining.
    var measuredWindows: [UsageWindow] {
        windows.filter { $0.remainingPercent != nil }
    }

    /// Freshness is recomputed on the phone from `fetchedAt`, because the
    /// file's own `fresh` flag expires seconds after the Mac writes it and a
    /// copied file is always older than that.
    func age(now: Date = Date()) -> TimeInterval? {
        fetchedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    var hasAnyData: Bool {
        windows.contains { $0.remainingPercent != nil } || creditBalance != nil || monthlyUsedCredits != nil || creditUnlimited
    }
}

struct UsageConsumptionPoint: Identifiable {
    let at: Date
    let amount: Double
    /// NAS history v2 only: the baseline segment this delta belongs to and
    /// its unit (`percent`/`credits`). Deltas from different segments are
    /// separate measurements and are never summed together.
    var segmentId: String? = nil
    var unit: String? = nil
    var id: Date { at }
}

struct UsageConsumptionHistory {
    let slotCount: Int
    let codex: [UsageConsumptionPoint]
    let codexSpark: [UsageConsumptionPoint]
    let claude: [UsageConsumptionPoint]
    let claudeFable: [UsageConsumptionPoint]
    let gemini: [UsageConsumptionPoint]
}

/// A fully parsed `usage-v1.json` (schemaVersion 1). Unknown fields are
/// ignored; tokens or upgrade links are never present in the schema and are
/// never looked for.
struct UsageSnapshot {
    let fetchedAt: Date?
    let publishedAt: Date?
    let macAppVersion: String?
    var services: [Service: ServiceUsage]
    let consumptionHistory: UsageConsumptionHistory?
    /// Only ever set on NAS snapshots: the consumption history the NAS
    /// samples on its own every 5 minutes. Kept apart from
    /// `consumptionHistory` because its age and Codex unit come from the
    /// NAS history file, not from this usage report.
    var nasHistory: NASConsumptionHistory? = nil
    /// NAS v2 only: the response's own `generated_at`.
    var generatedAt: Date? = nil
    /// NAS v2 only: `collection.state` was `queued`/`running` in the live
    /// response. Never restored from a cached copy.
    var collectionBusy: Bool = false
    var nasHostStatus: NASHostStatus? = nil

    /// Newest per-service fetch time, used for the "데이터 기준" header and
    /// the stale banner.
    var newestFetchedAt: Date? {
        let candidates = services.values.compactMap(\.fetchedAt) + [fetchedAt].compactMap { $0 }
        return candidates.max()
    }

    /// Data older than this is flagged as 오래된 데이터. A copied file is
    /// never live, so the threshold is generous compared with the Mac app's
    /// own freshness window.
    static let staleAfterSeconds: TimeInterval = 60 * 60

    func isStale(now: Date = Date()) -> Bool {
        guard let newest = newestFetchedAt else { return true }
        return now.timeIntervalSince(newest) > Self.staleAfterSeconds
    }

    /// The single limit the user will run out of first: the lowest remaining
    /// percentage among the primary services' measured windows. Grok is a
    /// secondary card and never claims the top spot.
    struct FocusLimit {
        let service: Service
        let window: UsageWindow
        let fetchedAt: Date?
    }

    var focusLimit: FocusLimit? {
        let candidates: [FocusLimit] = [Service.codex, .claude, .gemini].flatMap { service -> [FocusLimit] in
            guard let usage = services[service] else { return [] }
            return usableFocusWindows(for: usage).map {
                FocusLimit(service: service, window: $0, fetchedAt: usage.fetchedAt)
            }
        }
        return candidates.min { ($0.window.remainingPercent ?? 100) < ($1.window.remainingPercent ?? 100) }
    }

    /// A 0% limit cannot be used and therefore must never be recommended as
    /// the next limit to watch. A depleted parent weekly limit also blocks
    /// the shorter session windows beneath it even when their cached value is
    /// still above zero.
    private func usableFocusWindows(for usage: ServiceUsage) -> [UsageWindow] {
        let positive = usage.measuredWindows.filter { ($0.remainingPercent ?? 0) > 0 }

        switch usage.service {
        case .codex, .claude:
            if let weekly = usage.windows.first(where: { $0.id == "weekly" })?.remainingPercent,
               weekly <= 0 {
                return []
            }
            return positive

        case .gemini:
            let cliWeekly = usage.windows.first(where: { $0.id == "cliWeekly" })?.remainingPercent
            let onlineWeekly = usage.windows.first(where: { $0.id == "onlineWeekly" })?.remainingPercent

            if cliWeekly != nil || onlineWeekly != nil {
                return positive.filter { window in
                    if window.id.hasPrefix("cli") {
                        return (cliWeekly ?? 0) > 0
                    }
                    if window.id.hasPrefix("online") {
                        return (onlineWeekly ?? 0) > 0
                    }
                    return true
                }
            }

            if let weekly = usage.windows.first(where: { $0.id == "weekly" })?.remainingPercent,
               weekly <= 0 {
                return []
            }
            return positive

        case .gemini2:
            if let weekly = usage.windows.first(where: { $0.id == "cliWeekly" })?.remainingPercent,
               weekly <= 0 {
                return []
            }
            return positive

        case .grok:
            return []
        }
    }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SnapshotError.notJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw SnapshotError.notJSON
        }
        let root = JSONObject(raw: dictionary)
        guard root.nonBoolInt("schemaVersion") == 1 else {
            throw SnapshotError.unsupportedSchema
        }

        var services: [Service: ServiceUsage] = [:]
        services[.codex] = parseCodex(root.object("codex"), root: root)
        services[.claude] = parseClaude(root.object("claude"))
        services[.gemini] = parseGemini(root.object("gemini"))
        services[.grok] = parseGrok(root.object("grok"))

        return UsageSnapshot(
            fetchedAt: root.date("fetchedAt"),
            publishedAt: root.date("publishedAt"),
            macAppVersion: root.string("appVersion"),
            services: services,
            consumptionHistory: parseConsumptionHistory(root.object("consumptionHistory"))
        )
    }

    private static func parseConsumptionHistory(_ history: JSONObject?) -> UsageConsumptionHistory? {
        guard let history else { return nil }
        func samples(_ key: String) -> [UsageConsumptionPoint] {
            history.objectArray(key).compactMap { item in
                guard let at = item.date("at"), let amount = item.double("amount") else { return nil }
                return UsageConsumptionPoint(at: at, amount: max(0, amount))
            }
        }
        return UsageConsumptionHistory(
            slotCount: max(1, history.int("slotCount") ?? 40),
            codex: samples("codex"),
            codexSpark: samples("codexSpark"),
            claude: samples("claude"),
            claudeFable: samples("claudeFable"),
            gemini: samples("gemini")
        )
    }

    /// Codex prefers the nested `codex` object; a legacy file carrying only
    /// the top-level backward-compatible fields still shows the same values.
    /// Window order is 세션 → 주간: the Mac's usage-v1.json carries no
    /// Codex session field today, so the session row reads the key anyway (a
    /// future Mac version may add it) and otherwise stays visible with an
    /// honest note instead of silently disappearing.
    private static func parseCodex(_ codex: JSONObject?, root: JSONObject) -> ServiceUsage {
        let source = codex ?? root
        let sessionRemaining = source.double("sessionRemainingPercent")
            ?? source.double("fiveHourRemainingPercent")
        let sessionResetsAt = source.date("sessionResetsAt") ?? source.date("fiveHourResetsAt")
        let windows: [UsageWindow] = [
            UsageWindow(
                id: "session",
                label: "세션",
                remainingPercent: sessionRemaining,
                resetsAt: sessionResetsAt,
                unavailabilityNote: sessionRemaining == nil && sessionResetsAt == nil
                    ? "Mac 데이터에서 제공되지 않음"
                    : nil
            ),
            UsageWindow(
                id: "weekly",
                label: "주간",
                remainingPercent: source.double("weeklyRemainingPercent"),
                resetsAt: source.date(codex == nil ? "resetsAt" : "weeklyResetsAt")
            )
        ]
        return ServiceUsage(
            service: .codex,
            status: codex?.string("status"),
            windows: windows,
            creditBalance: source.double("creditBalance"),
            creditLabel: "크레딧 잔액",
            monthlyUsedCredits: nil,
            account: codex?.string("account"),
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: codex?.date("fetchedAt") ?? root.date("fetchedAt")
        )
    }

    /// Claude's card order is 5시간 세션 → Fable 주간 → 전체 주간. The Fable
    /// row is lifted out of `modelWeeklyLimits` because it is the limit this
    /// user actually exhausts first; when the Mac data carries no Fable entry
    /// the row stays with a note rather than vanishing.
    private static func parseClaude(_ claude: JSONObject?) -> ServiceUsage {
        let account = claude?.object("account")
        let modelWeeklyLimits: [ClaudeModelWeeklyLimit] = (claude?.objectArray("modelWeeklyLimits") ?? []).compactMap { item in
            guard let name = item.string("model"), !name.isEmpty else { return nil }
            return ClaudeModelWeeklyLimit(
                id: name,
                modelName: name,
                remainingPercent: item.double("remainingPercent"),
                resetsAt: item.date("resetsAt")
            )
        }
        let fableLimit = modelWeeklyLimits.first { $0.modelName.localizedCaseInsensitiveContains("fable") }
        return ServiceUsage(
            service: .claude,
            status: claude?.string("status"),
            windows: [
                UsageWindow(
                    id: "fiveHour",
                    label: "5시간 세션",
                    remainingPercent: claude?.double("fiveHourRemainingPercent"),
                    resetsAt: claude?.date("fiveHourResetsAt")
                ),
                UsageWindow(
                    id: "fableWeekly",
                    label: "Fable 주간",
                    remainingPercent: fableLimit?.remainingPercent,
                    resetsAt: fableLimit?.resetsAt,
                    unavailabilityNote: fableLimit == nil ? "Mac 데이터에서 제공되지 않음" : nil
                ),
                UsageWindow(
                    id: "weekly",
                    label: "전체 주간",
                    remainingPercent: claude?.double("weeklyRemainingPercent"),
                    resetsAt: claude?.date("weeklyResetsAt")
                )
            ],
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: account?.string("email"),
            organizationName: account?.string("organizationName"),
            planTitle: nil,
            model: claude?.string("model"),
            modelWeeklyLimits: modelWeeklyLimits,
            fetchedAt: claude?.date("fetchedAt")
        )
    }

    private static func parseGemini(_ gemini: JSONObject?) -> ServiceUsage {
        // Gemini 온라인(웹) 사용량은 더 이상 표시하지 않는다. CLI 세션/주간만 쓴다.
        let fetchedAt = gemini?.date("fetchedAt")
        return ServiceUsage(
            service: .gemini,
            status: gemini?.string("status"),
            windows: [
                UsageWindow(
                    id: "cliFiveHour",
                    label: "C세션",
                    remainingPercent: gemini?.double("fiveHourRemainingPercent"),
                    resetsAt: gemini?.date("fiveHourResetsAt"),
                    resetText: gemini?.date("fiveHourResetsAt") == nil
                        && (gemini?.double("fiveHourRemainingPercent") ?? 0) >= 100
                        ? "사용 시작 후 5시간"
                        : nil,
                    unavailabilityNote: gemini?.double("fiveHourRemainingPercent") == nil ? "미제공" : nil
                ),
                UsageWindow(
                    id: "cliWeekly",
                    label: "C주간",
                    remainingPercent: gemini?.double("weeklyRemainingPercent"),
                    resetsAt: gemini?.date("weeklyResetsAt"),
                    unavailabilityNote: gemini?.double("weeklyRemainingPercent") == nil ? "미제공" : nil
                )
            ],
            creditBalance: gemini?.double("creditBalance"),
            creditLabel: "AI 크레딧 잔액",
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: gemini?.string("planTitle"),
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: fetchedAt
        )
    }

    private static func parseGrok(_ grok: JSONObject?) -> ServiceUsage {
        // The Mac app marks whether the weekly 0% was actually confirmed;
        // an unconfirmed value must not be shown as a real reading.
        let weeklyConfirmed = grok?.bool("weeklyUsageConfirmed") ?? (grok?.double("weeklyUsedPercent").map { $0 != 0 } ?? false)
        return ServiceUsage(
            service: .grok,
            status: grok?.string("status"),
            windows: [
                UsageWindow(
                    id: "monthly",
                    label: "월간",
                    remainingPercent: grok?.double("monthlyRemainingPercent"),
                    resetsAt: grok?.date("monthlyResetsAt")
                ),
                UsageWindow(
                    id: "weekly",
                    label: "주간",
                    remainingPercent: weeklyConfirmed ? grok?.double("weeklyRemainingPercent") : nil,
                    resetsAt: grok?.date("weeklyResetsAt")
                )
            ],
            creditBalance: grok?.double("extraCreditBalance"),
            creditLabel: "추가 크레딧 잔액",
            monthlyUsedCredits: grok?.double("monthlyUsedCredits"),
            account: grok?.string("account"),
            organizationName: nil,
            planTitle: grok?.string("subscriptionTier"),
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: grok?.date("fetchedAt")
        )
    }
}

/// Parses the home NAS's `/api/usage` response, a different wire shape from
/// the Mac's `usage-v1.json`: `{ok, report:{services:[...]}, fetchedAt,
/// cached, error}` where each service carries its own `items` array of named
/// quota windows. The Codex weekly item may additionally carry a nested
/// `credits: {balance, unlimited}` — the same balance the NAS frontend itself
/// labels '토큰' (a playground balance, not input/output token consumption).
/// The NAS reports no Grok here, and its consumption history arrives only via
/// the separate NAS history file (`applyingNASHistory`) — neither is guessed
/// or carried over from another source.
extension UsageSnapshot {
    static func parseNAS(_ data: Data) throws -> UsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SnapshotError.notJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw SnapshotError.notJSON
        }
        let root = JSONObject(raw: dictionary)
        guard let report = root.object("report") else {
            throw SnapshotError.unsupportedSchema
        }
        let serviceObjects = report.objectArray("services")
        func service(named name: String) -> JSONObject? {
            serviceObjects.first { $0.string("service") == name }
        }

        var services: [Service: ServiceUsage] = [:]
        services[.codex] = parseNASCodex(service(named: "codex"))
        services[.claude] = parseNASClaude(service(named: "claude"))
        services[.gemini] = parseNASGemini(service(named: "gemini"))
        // The legacy envelope has no fixed account identity, so even a
        // `gemini2` entry there is never shown as the 부계정 (§10.5): the
        // card states that this server does not support it.
        services[.gemini2] = parseNASUnsupportedGemini2()
        services[.grok] = parseNASUnavailable(.grok)

        // A payload with no measured window and no usable credits/token
        // reading anywhere (every service empty, erroring, or otherwise
        // unusable) is not a readable report at all, even though the JSON
        // itself parsed fine.
        guard services.values.contains(where: {
            !$0.measuredWindows.isEmpty || $0.creditBalance != nil || $0.creditUnlimited
        }) else {
            throw SnapshotError.unsupportedSchema
        }

        return UsageSnapshot(
            // The top-level `fetchedAt` is only the NAS's request time, not
            // when any service was actually collected; using it here would
            // let a stale per-service reading masquerade as fresh. Staleness
            // is instead computed purely from each service's own
            // `fetched_at` via `newestFetchedAt`.
            fetchedAt: nil,
            publishedAt: nil,
            macAppVersion: nil,
            services: services,
            consumptionHistory: nil
        )
    }

    private static func nasItems(_ service: JSONObject?) -> [JSONObject] {
        service?.objectArray("items") ?? []
    }

    /// An erroring service that still carries values is shown as stale
    /// (its last stored reading), not as empty.
    private static func nasStatus(_ service: JSONObject?, hasData: Bool) -> String? {
        guard let service else { return nil }
        if hasStructuredError(service) { return hasData ? "stale" : "unavailable" }
        if service.bool("stale") == true { return "stale" }
        if service.bool("ok") == true { return "ok" }
        return hasData ? "stale" : "unavailable"
    }

    private static func hasData(_ windows: [UsageWindow], balance: Double? = nil, unlimited: Bool = false) -> Bool {
        windows.contains { $0.remainingPercent != nil } || balance != nil || unlimited
    }

    /// The NAS reports a service-level failure either as a plain string
    /// (`error: "..."`, legacy only) or a structured object
    /// (`error: {code, message?}`). `error: null` is not an error at all.
    private static func hasStructuredError(_ service: JSONObject) -> Bool {
        guard let raw = service.raw["error"], !(raw is NSNull) else { return false }
        if raw is String { return true }
        if let object = raw as? [String: Any] { return object["code"] is String }
        return false
    }

    /// Only the structured, non-secret `error.code`/`error.message` is
    /// surfaced. A legacy plain-string error marks the service as failed
    /// but its raw text is never shown or stored.
    private static func serviceError(_ service: JSONObject?) -> (code: String?, message: String?) {
        guard let service, let object = service.raw["error"] as? [String: Any] else { return (nil, nil) }
        return (object["code"] as? String, object["message"] as? String)
    }

    private static func parseNASUnavailable(_ service: Service) -> ServiceUsage {
        ServiceUsage(
            service: service,
            status: nil,
            windows: [],
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: nil
        )
    }

    private static func parseNASUnsupportedGemini2() -> ServiceUsage {
        ServiceUsage(
            service: .gemini2,
            status: "unavailable",
            windows: [],
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: nil,
            errorCode: "unsupported_server",
            errorMessage: nil
        )
    }

    /// The NAS exposes a `gpt-reserve` pool alongside the real weekly quota;
    /// only the item literally named `codex` is the one shown elsewhere as
    /// Codex's weekly limit. `gpt-reserve`'s own credits must never leak into
    /// this card.
    private static func parseNASCodex(_ service: JSONObject?) -> ServiceUsage {
        let weekly = nasItems(service).first { $0.string("name") == "codex" && $0.string("window") == "weekly" }
        let windows: [UsageWindow] = [
            UsageWindow(
                id: "session",
                label: "세션",
                remainingPercent: nil,
                resetsAt: nil,
                unavailabilityNote: "NAS 데이터에서 제공되지 않음"
            ),
            UsageWindow(
                id: "weekly",
                label: "주간",
                remainingPercent: weekly?.percent("remaining_percent"),
                resetsAt: weekly?.epochSecondsDate("resets_at"),
                unavailabilityNote: weekly == nil ? "NAS 데이터에서 제공되지 않음" : nil
            )
        ]
        // Credits are only trusted when the service itself is usable (a live
        // or stale-but-cached reading); an erroring/unavailable service must
        // never surface a stray numeric balance.
        let usable = service?.bool("ok") == true || service?.bool("stale") == true
        let credits = usable ? weekly?.object("credits") : nil
        let balance = credits?.nonBoolDouble("balance").flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let unlimited = credits?.bool("unlimited") ?? false
        let error = serviceError(service)
        return ServiceUsage(
            service: .codex,
            status: nasStatus(service, hasData: hasData(windows, balance: balance, unlimited: unlimited)),
            windows: windows,
            creditBalance: balance,
            creditLabel: usable ? "토큰" : nil,
            creditUnlimited: unlimited,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: service?.epochSecondsDate("fetched_at"),
            errorCode: error.code,
            errorMessage: error.message,
            stale: service?.bool("stale") == true
        )
    }

    /// Card order matches the Mac-sourced parse: 5시간 세션 → Fable 주간 →
    /// 전체 주간.
    private static func parseNASClaude(_ service: JSONObject?) -> ServiceUsage {
        let items = nasItems(service)
        // Matched by exact name ('전체') rather than "first weekly item that
        // isn't Fable", since additional per-model pools (e.g. Opus, Sonnet)
        // could otherwise be mistaken for the overall limit.
        let fiveHour = items.first { $0.string("window") == "session" && $0.string("name") == "전체" }
        let fableItem = items.first {
            $0.string("window") == "weekly" && ($0.string("name")?.localizedCaseInsensitiveContains("fable") ?? false)
        }
        let weekly = items.first {
            $0.string("window") == "weekly" && $0.string("name") == "전체"
        }
        let modelWeeklyLimits: [ClaudeModelWeeklyLimit] = fableItem.map {
            [ClaudeModelWeeklyLimit(
                id: "fable",
                modelName: "Fable",
                remainingPercent: $0.percent("remaining_percent"),
                resetsAt: $0.epochSecondsDate("resets_at")
            )]
        } ?? []
        let windows: [UsageWindow] = [
            UsageWindow(
                id: "fiveHour",
                label: "5시간 세션",
                remainingPercent: fiveHour?.percent("remaining_percent"),
                resetsAt: fiveHour?.epochSecondsDate("resets_at"),
                unavailabilityNote: fiveHour == nil ? "NAS 데이터에서 제공되지 않음" : nil
            ),
            UsageWindow(
                id: "fableWeekly",
                label: "Fable 주간",
                remainingPercent: fableItem?.percent("remaining_percent"),
                resetsAt: fableItem?.epochSecondsDate("resets_at"),
                unavailabilityNote: fableItem == nil ? "NAS 데이터에서 제공되지 않음" : nil
            ),
            UsageWindow(
                id: "weekly",
                label: "전체 주간",
                remainingPercent: weekly?.percent("remaining_percent"),
                resetsAt: weekly?.epochSecondsDate("resets_at"),
                unavailabilityNote: weekly == nil ? "NAS 데이터에서 제공되지 않음" : nil
            )
        ]
        let error = serviceError(service)
        return ServiceUsage(
            service: .claude,
            status: nasStatus(service, hasData: hasData(windows)),
            windows: windows,
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: modelWeeklyLimits,
            fetchedAt: service?.epochSecondsDate("fetched_at"),
            errorCode: error.code,
            errorMessage: error.message,
            stale: service?.bool("stale") == true
        )
    }

    /// Only the "Gemini Models" pool is shown; the NAS's "Claude and GPT
    /// models" pool under the same service belongs to a different quota and
    /// must never be mislabeled as Gemini's own limit. `gemini2`(부계정)
    /// reuses the exact same item shape under its own fixed `account2` entry.
    private static func parseNASGemini(_ service: JSONObject?, identity: Service = .gemini) -> ServiceUsage {
        let items = nasItems(service)
        let fiveHour = items.first {
            ($0.string("name") ?? "").hasPrefix("Gemini Models") && $0.string("window") == "session"
        }
        let weekly = items.first {
            ($0.string("name") ?? "").hasPrefix("Gemini Models") && $0.string("window") == "weekly"
        }
        let windows: [UsageWindow] = [
            UsageWindow(
                id: "cliFiveHour",
                label: "세션",
                remainingPercent: fiveHour?.percent("remaining_percent"),
                resetsAt: fiveHour?.epochSecondsDate("resets_at"),
                unavailabilityNote: fiveHour == nil ? "NAS 데이터에서 제공되지 않음" : nil
            ),
            UsageWindow(
                id: "cliWeekly",
                label: "주간",
                remainingPercent: weekly?.percent("remaining_percent"),
                resetsAt: weekly?.epochSecondsDate("resets_at"),
                unavailabilityNote: weekly == nil ? "NAS 데이터에서 제공되지 않음" : nil
            )
        ]
        let error = serviceError(service)
        // Credits are only trusted when the service itself is usable (a live
        // or stale-but-cached reading), matching the Codex credits rule — an
        // erroring/unavailable entry never surfaces a stray balance. The
        // entry is already the one matched to this exact identity
        // (`gemini`/`gemini2`), so a balance can never be borrowed from the
        // other account.
        let usable = service?.bool("ok") == true || service?.bool("stale") == true
        let details = usable ? service?.object("gemini_details") : nil
        // A confirmed `0` balance is real and shown as 0; `credits_status ==
        // "unavailable"` or an absent field is nil, never guessed as 0.
        // `credits_status` must be exactly "ok" before the balance is
        // trusted, mirroring the Mac NASItemMappingCore.geminiSnapshot guard.
        let creditBalance = details?.string("credits_status") == "ok"
            ? details?.nonBoolInt("credit_balance").flatMap { $0 >= 0 ? Double($0) : nil }
            : nil
        return ServiceUsage(
            service: identity,
            status: nasStatus(service, hasData: hasData(windows)),
            windows: windows,
            creditBalance: creditBalance,
            creditLabel: creditBalance != nil ? "AI 크레딧 잔액" : nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: service?.epochSecondsDate("fetched_at"),
            errorCode: error.code,
            errorMessage: error.message,
            stale: service?.bool("stale") == true
        )
    }
}

/// `GET /api/ccmb/v2/snapshot` (§10.4): a flat envelope with exactly the four
/// fixed services `codex`, `claude`, `gemini`(account1), `gemini2`(account2)
/// in that order, each carrying the legacy `items` shape plus its own
/// `fetched_at`, `stale`, `ok` and structured `error`.
extension UsageSnapshot {
    static let v2SchemaVersion = 2
    static let v2ServiceOrder = ["codex", "claude", "gemini", "gemini2"]

    /// `true` only for a response this client recognizes as v2 at all
    /// (integral, non-boolean `schema_version` 2 and a `services` array of
    /// objects); anything else is rejected outright, never partially parsed.
    static func isV2Envelope(_ dictionary: [String: Any]) -> Bool {
        guard let number = dictionary["schema_version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let value = number.doubleValue
        guard value.isFinite, value == Double(v2SchemaVersion) else { return false }
        return dictionary["services"] is [[String: Any]]
    }

    /// Fixed service identity per §10.4/§11: provider and `account_ref` are
    /// both required keys; codex/claude carry an explicit `null` ref.
    static let v2RequiredIdentity: [String: (provider: String, accountRef: String?)] = [
        "codex": ("codex", nil),
        "claude": ("claude", nil),
        "gemini": ("gemini", "account1"),
        "gemini2": ("gemini", "account2")
    ]

    static func parseNASv2(_ data: Data) throws -> UsageSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SnapshotError.notJSON
        }
        guard let dictionary = object as? [String: Any], isV2Envelope(dictionary),
              let serviceObjects = dictionary["services"] as? [[String: Any]] else {
            throw SnapshotError.unsupportedSchema
        }
        guard dictionary["quota_origin"] as? String == "nas" else {
            throw SnapshotError.unsupportedSchema
        }

        // Exactly four entries in the fixed order; a duplicate, missing,
        // reordered or unknown id is never resolved by guessing.
        guard serviceObjects.map({ $0["service"] as? String }) == v2ServiceOrder.map(Optional.some) else {
            throw SnapshotError.unsupportedSchema
        }
        for entry in serviceObjects {
            try validateV2Service(entry)
        }

        // `generated_at` is a required key: finite positive Unix seconds,
        // or `null` only for the documented never-collected envelope.
        guard let rawGeneratedAt = dictionary["generated_at"] else { throw SnapshotError.unsupportedSchema }
        let generatedAt: Date?
        if rawGeneratedAt is NSNull {
            let neverCollected = serviceObjects.allSatisfy {
                ($0["error"] as? [String: Any])?["code"] as? String == "not_collected"
            }
            guard neverCollected else { throw SnapshotError.unsupportedSchema }
            generatedAt = nil
        } else {
            guard let seconds = epochSeconds(rawGeneratedAt), seconds <= Date().timeIntervalSince1970 + 60 else {
                throw SnapshotError.unsupportedSchema
            }
            generatedAt = Date(timeIntervalSince1970: seconds)
        }

        var collectionBusy = false
        if let rawCollection = dictionary["collection"], !(rawCollection is NSNull) {
            guard let collection = rawCollection as? [String: Any] else { throw SnapshotError.unsupportedSchema }
            if let rawState = collection["state"], !(rawState is NSNull) {
                guard let state = rawState as? String else { throw SnapshotError.unsupportedSchema }
                collectionBusy = state == "running" || state == "queued"
            }
        }

        let entries = serviceObjects.map(JSONObject.init)
        var services: [Service: ServiceUsage] = [:]
        services[.codex] = parseNASCodex(entries[0])
        services[.claude] = parseNASClaude(entries[1])
        services[.gemini] = parseNASGemini(entries[2], identity: .gemini)
        services[.gemini2] = parseNASGemini(entries[3], identity: .gemini2)
        services[.grok] = parseNASUnavailable(.grok)

        let hostStatus = NASHostStatus.parse(
            executionHosts: dictionary["execution_hosts"],
            autoSwitchEnabled: dictionary["auto_switch_enabled"],
            autoSwitchAvailable: dictionary["auto_switch_available"]
        )
        if var gemini = services[.gemini] {
            gemini.nasHostStatus = hostStatus
            services[.gemini] = gemini
        }
        if var gemini2 = services[.gemini2] {
            gemini2.nasHostStatus = hostStatus
            services[.gemini2] = gemini2
        }

        // Unlike legacy `/api/usage`, a valid v2 document whose every
        // service is unavailable (fresh install, nothing collected yet) is
        // still valid: four unavailable cards, never a thrown error or 0%.
        return UsageSnapshot(
            fetchedAt: nil,
            publishedAt: nil,
            macAppVersion: nil,
            services: services,
            consumptionHistory: nil,
            generatedAt: generatedAt,
            collectionBusy: collectionBusy,
            nasHostStatus: hostStatus
        )
    }

    /// Finite, positive, non-boolean Unix seconds (a millisecond value is
    /// rejected rather than shown thousands of years in the future).
    static func epochSeconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds < 100_000_000_000 else { return nil }
        return seconds
    }

    private static func isJSONBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func validateV2Service(_ entry: [String: Any]) throws {
        guard let name = entry["service"] as? String, let expected = v2RequiredIdentity[name],
              entry["provider"] as? String == expected.provider else {
            throw SnapshotError.unsupportedSchema
        }
        // `account_ref` must be present: exact string for Gemini, explicit
        // `null` for codex/claude. Missing or wrong-typed is never `null`.
        guard let rawRef = entry["account_ref"] else { throw SnapshotError.unsupportedSchema }
        if let expectedRef = expected.accountRef {
            guard rawRef as? String == expectedRef else { throw SnapshotError.unsupportedSchema }
        } else {
            guard rawRef is NSNull else { throw SnapshotError.unsupportedSchema }
        }
        guard isJSONBool(entry["ok"]), isJSONBool(entry["stale"]) else { throw SnapshotError.unsupportedSchema }
        guard let rawFetchedAt = entry["fetched_at"],
              rawFetchedAt is NSNull || (epochSeconds(rawFetchedAt).map { $0 <= Date().timeIntervalSince1970 + 60 } ?? false) else {
            throw SnapshotError.unsupportedSchema
        }
        guard let rawError = entry["error"], rawError is NSNull || isValidV2Error(rawError) else {
            throw SnapshotError.unsupportedSchema
        }
        guard let items = entry["items"] as? [Any], items.count <= 16,
              items.allSatisfy(isValidV2Item) else {
            throw SnapshotError.unsupportedSchema
        }
    }

    /// `{code, message?}` only: a bounded non-empty code and an optional
    /// bounded message (the server sends fixed, non-secret wording).
    static func isValidV2Error(_ value: Any) -> Bool {
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["code", "message"]),
              let code = object["code"] as? String, (1...64).contains(code.count) else { return false }
        if let message = object["message"] {
            guard let text = message as? String, text.count <= 300 else { return false }
        }
        return true
    }

    /// The legacy item shape: named window with a finite, non-boolean
    /// `remaining_percent` in 0...100 and an optional reset time/credits.
    static func isValidV2Item(_ value: Any) -> Bool {
        guard let item = value as? [String: Any],
              let name = item["name"] as? String, (1...64).contains(name.count),
              let window = item["window"] as? String, (1...32).contains(window.count),
              let percent = item["remaining_percent"] as? NSNumber,
              CFGetTypeID(percent) != CFBooleanGetTypeID(),
              percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue) else { return false }
        if let resetsAt = item["resets_at"], !(resetsAt is NSNull) {
            guard epochSeconds(resetsAt) != nil else { return false }
        }
        if let minutes = item["window_minutes"], !(minutes is NSNull) {
            guard let number = minutes as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0 else { return false }
        }
        if let rawCredits = item["credits"], !(rawCredits is NSNull) {
            guard let credits = rawCredits as? [String: Any] else { return false }
            if let balance = credits["balance"], !(balance is NSNull) {
                guard let number = balance as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0 else { return false }
            }
            if let unlimited = credits["unlimited"], !isJSONBool(unlimited) { return false }
        }
        return true
    }

    /// Flags services whose values are a preserved last good reading.
    func markingLastKnown(_ names: Set<String>) -> UsageSnapshot {
        guard !names.isEmpty else { return self }
        var copy = self
        for (service, usage) in services where names.contains(service.rawValue) {
            var marked = usage
            marked.isLastKnown = true
            marked.status = "stale"
            copy.services[service] = marked
        }
        return copy
    }

    func markingNASHostStatusCached() -> UsageSnapshot {
        var copy = self
        if var status = copy.nasHostStatus {
            status.isCached = true
            copy.nasHostStatus = status
        }
        if var gemini = copy.services[.gemini], var status = gemini.nasHostStatus {
            status.isCached = true
            gemini.nasHostStatus = status
            copy.services[.gemini] = gemini
        }
        if var gemini2 = copy.services[.gemini2], var status = gemini2.nasHostStatus {
            status.isCached = true
            gemini2.nasHostStatus = status
            copy.services[.gemini2] = gemini2
        }
        return copy
    }
}

/// One validated reading from the private NAS-stored
/// `CCMB-gemini-online-v1.json` relay file: the Mac's own
/// `gemini.online.{fiveHour,weekly}` web-session reading, relayed through the
/// user's existing private NAS storage project rather than read from the NAS
/// quota API (which has no online reading of its own).
struct GeminiOnlineReading: Equatable {
    let fiveHourRemainingPercent: Double?
    let weeklyRemainingPercent: Double?
    let fiveHourResetText: String?
    let weeklyResetText: String?
    let fetchedAt: Date
}

extension UsageSnapshot {
    /// Validates the bounded relay contract: `schemaVersion` 1,
    /// `gemini.online` only, each percentage finite/`0...100`/not-a-boolean,
    /// a real timestamp no more than 5 minutes in the future, and reset
    /// captions trimmed/stripped of control characters and capped at 160
    /// characters. Anything else — wrong shape, an implausible or missing
    /// timestamp, an oversized payload, no usable percentage at all — is
    /// simply absent data, never a guess.
    static func parseGeminiOnlineRelay(_ data: Data, now: Date = Date()) -> GeminiOnlineReading? {
        guard data.count <= 8192 else { return nil }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root = JSONObject(raw: dictionary)
        guard root.nonBoolInt("schemaVersion") == 1 else { return nil }
        guard let gemini = root.object("gemini"), let online = gemini.object("online") else { return nil }
        guard let fetchedAt = online.date("fetchedAt"), fetchedAt <= now.addingTimeInterval(5 * 60) else {
            return nil
        }

        // `NSNumber as? Bool` in Swift succeeds for *any* NSNumber whose
        // value is 0 or 1, not only an actual JSON `true`/`false` — so a
        // genuine 0% or 1% reading must not be screened out that way.
        // CFGetTypeID distinguishes a real CFBoolean from a numeric 0/1.
        func percent(_ key: String) -> Double? {
            guard let raw = online.raw[key] else { return nil }
            guard let number = raw as? NSNumber else { return nil }
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        func resetText(_ key: String) -> String? {
            guard let string = online.string(key) else { return nil }
            let stripped = String(string.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
        }

        let fiveHour = percent("fiveHourRemainingPercent")
        let weekly = percent("weeklyRemainingPercent")
        guard fiveHour != nil || weekly != nil else { return nil }

        return GeminiOnlineReading(
            fiveHourRemainingPercent: fiveHour,
            weeklyRemainingPercent: weekly,
            fiveHourResetText: resetText("fiveHourResetText"),
            weeklyResetText: resetText("weeklyResetText"),
            fetchedAt: fetchedAt
        )
    }

    /// Fills the Gemini `onlineFiveHour`/`onlineWeekly` windows from a
    /// validated relay reading, independent of whichever source (NAS quota
    /// API or Mac snapshot) produced the rest of this snapshot. A window the
    /// reading did not carry a value for is left exactly as the base
    /// snapshot had it (typically "NAS 데이터에서 제공되지 않음"), never
    /// zeroed or guessed.
    func applyingGeminiOnline(_ reading: GeminiOnlineReading) -> UsageSnapshot {
        guard let gemini = services[.gemini] else { return self }
        let windows = gemini.windows.map { window -> UsageWindow in
            switch window.id {
            case "onlineFiveHour":
                guard let percent = reading.fiveHourRemainingPercent else { return window }
                return UsageWindow(
                    id: window.id,
                    label: window.label,
                    remainingPercent: percent,
                    resetsAt: nil,
                    resetText: reading.fiveHourResetText,
                    unavailabilityNote: nil,
                    fetchedAt: reading.fetchedAt
                )
            case "onlineWeekly":
                guard let percent = reading.weeklyRemainingPercent else { return window }
                return UsageWindow(
                    id: window.id,
                    label: window.label,
                    remainingPercent: percent,
                    resetsAt: nil,
                    resetText: reading.weeklyResetText,
                    unavailabilityNote: nil,
                    fetchedAt: reading.fetchedAt
                )
            default:
                return window
            }
        }
        let newGemini = ServiceUsage(
            service: gemini.service,
            status: gemini.status,
            windows: windows,
            creditBalance: gemini.creditBalance,
            creditLabel: gemini.creditLabel,
            creditUnlimited: gemini.creditUnlimited,
            monthlyUsedCredits: gemini.monthlyUsedCredits,
            account: gemini.account,
            organizationName: gemini.organizationName,
            planTitle: gemini.planTitle,
            model: gemini.model,
            modelWeeklyLimits: gemini.modelWeeklyLimits,
            fetchedAt: gemini.fetchedAt
        )
        var services = services
        services[.gemini] = newGemini
        return UsageSnapshot(
            fetchedAt: fetchedAt,
            publishedAt: publishedAt,
            macAppVersion: macAppVersion,
            services: services,
            consumptionHistory: consumptionHistory,
            nasHistory: nasHistory
        )
    }
}

/// One validated copy of the NAS's own consumption history: v1
/// (`CCMB-nas-consumption-history-v1.json`, 5 series) or v2
/// (`CCMB-nas-consumption-history-v2.json`, 6 series with segments). Each
/// sample is the drop in a real reading since the previous real reading; a
/// service that failed or was stale simply has no sample.
struct NASConsumptionHistory {
    /// Codex weekly-percent consumption and Codex credit consumption are
    /// separate series so the two units can never mix; `codexUsesCredits`
    /// says which one the NAS is currently measuring.
    let codex: [UsageConsumptionPoint]
    let codexCredits: [UsageConsumptionPoint]
    let claude: [UsageConsumptionPoint]
    let claudeFable: [UsageConsumptionPoint]
    let gemini: [UsageConsumptionPoint]
    /// Only ever populated from the v2 history file; the strict v1 file has
    /// no gemini2 key at all and must never be made to carry one.
    let gemini2: [UsageConsumptionPoint]
    let codexUsesCredits: Bool
    /// v2 only: each series' `identityGeneration` (Gemini account binding
    /// generation, or null), keyed by series name. Points keep their own
    /// `segmentId`; deltas from different segments/generations are
    /// separate measurements and are never accumulated together.
    var identityGenerations: [String: String?] = [:]
    /// When the NAS last accepted a fresh reading — never the download time.
    let collectedAt: Date
    /// Which wire contract this reading was validated against (1 or 2).
    var schemaVersion: Int = 1

    var history: UsageConsumptionHistory {
        UsageConsumptionHistory(
            slotCount: UsageSnapshot.nasHistoryMaxSamples,
            codex: codexUsesCredits ? codexCredits : codex,
            codexSpark: [],
            claude: claude,
            claudeFable: claudeFable,
            gemini: gemini
        )
    }

    /// True until the NAS has a second fresh reading to compare against its
    /// first (baseline) one.
    var isEmpty: Bool {
        codex.isEmpty && codexCredits.isEmpty && claude.isEmpty && claudeFable.isEmpty && gemini.isEmpty && gemini2.isEmpty
    }

    func points(forSeries key: String) -> [UsageConsumptionPoint] {
        switch key {
        case "codex": return codex
        case "codexCredits": return codexCredits
        case "claude": return claude
        case "claudeFable": return claudeFable
        case "gemini": return gemini
        case "gemini2": return gemini2
        default: return []
        }
    }
}

/// Why a NAS history v2 file was not accepted. A different
/// `schemaVersion` is reported separately from a broken v2 document, and
/// neither ever falls back to v1 (only an HTTP 404 does).
enum NASHistoryParseError: Error, Equatable {
    case unknownSchema
    case invalid
}

extension UsageSnapshot {
    static let nasHistoryMaxBytes = 32768
    static let nasHistoryMaxSamples = 40
    static let nasHistoryIntervalSeconds = 180
    static let nasHistorySeriesKeys = ["codex", "codexCredits", "claude", "claudeFable", "gemini"]

    static func parseNASConsumptionHistoryFile(_ data: Data, now: Date = Date()) -> NASConsumptionHistory? {
        guard data.count <= nasHistoryMaxBytes,
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseNASConsumptionHistory(dictionary, now: now)
    }

    /// Validates the NAS history contract exactly: only the known root keys,
    /// `schemaVersion` 1, `source` "nas", `intervalSeconds` 180, `slotCount`
    /// 40 (none of them booleans), timezone-qualified timestamps no more than
    /// 5 minutes in the future, `codexUnit` `percent`/`credits`, all five
    /// series present with at most 40 `{at, amount}` samples each in strictly
    /// increasing time order, and every amount a finite, non-negative,
    /// non-boolean number. Anything else — including the older Mac-relayed
    /// history shape — rejects the whole file, never a partial guess.
    static func parseNASConsumptionHistory(_ dictionary: [String: Any], now: Date = Date()) -> NASConsumptionHistory? {
        let rootKeys: Set<String> = [
            "schemaVersion", "source", "intervalSeconds", "slotCount", "collectedAt", "codexUnit", "consumptionHistory"
        ]
        guard Set(dictionary.keys) == rootKeys else { return nil }
        guard exactInteger(dictionary["schemaVersion"]) == 1,
              dictionary["source"] as? String == "nas",
              exactInteger(dictionary["intervalSeconds"]) == nasHistoryIntervalSeconds,
              exactInteger(dictionary["slotCount"]) == nasHistoryMaxSamples else { return nil }

        let latestAllowed = now.addingTimeInterval(5 * 60)
        func timestamp(_ value: Any?) -> Date? {
            guard let string = value as? String, !string.isEmpty, string.count <= 64,
                  let date = JSONObject.parseDate(string), date <= latestAllowed else { return nil }
            return date
        }

        guard let collectedAt = timestamp(dictionary["collectedAt"]) else { return nil }
        let codexUsesCredits: Bool
        switch dictionary["codexUnit"] as? String {
        case "percent": codexUsesCredits = false
        case "credits": codexUsesCredits = true
        default: return nil
        }

        guard let history = dictionary["consumptionHistory"] as? [String: Any],
              Set(history.keys) == Set(nasHistorySeriesKeys) else { return nil }

        var series: [String: [UsageConsumptionPoint]] = [:]
        for key in nasHistorySeriesKeys {
            guard let items = history[key] as? [Any], items.count <= nasHistoryMaxSamples else { return nil }
            var points: [UsageConsumptionPoint] = []
            for item in items {
                guard let sample = item as? [String: Any],
                      Set(sample.keys) == ["at", "amount"],
                      let at = timestamp(sample["at"]),
                      let number = sample["amount"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
                if let previous = points.last, at <= previous.at { return nil }
                points.append(UsageConsumptionPoint(at: at, amount: number.doubleValue))
            }
            series[key] = points
        }

        return NASConsumptionHistory(
            codex: series["codex"] ?? [],
            codexCredits: series["codexCredits"] ?? [],
            claude: series["claude"] ?? [],
            claudeFable: series["claudeFable"] ?? [],
            gemini: series["gemini"] ?? [],
            gemini2: [],
            codexUsesCredits: codexUsesCredits,
            collectedAt: collectedAt,
            schemaVersion: 1
        )
    }

    static let nasHistoryV2SeriesKeys = ["codex", "codexCredits", "claude", "claudeFable", "gemini", "gemini2"]
    static let nasHistoryV2MaxBytes = 49152

    /// The fixed unit of each v2 series (§11.2): only `codexCredits` is
    /// credits; every other series is percent.
    static func nasHistoryV2Unit(forSeries key: String) -> String {
        key == "codexCredits" ? "credits" : "percent"
    }

    /// Bounded, non-secret baseline segment id.
    static func isValidSegmentID(_ value: String) -> Bool {
        guard (1...64).contains(value.unicodeScalars.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    static func decodeNASConsumptionHistoryV2(_ data: Data, now: Date = Date()) throws -> NASConsumptionHistory {
        guard data.count <= nasHistoryV2MaxBytes,
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NASHistoryParseError.invalid
        }
        return try decodeNASConsumptionHistoryV2(dictionary, now: now)
    }

    /// Validates the v2 history contract exactly (§11.2): root keys
    /// `schemaVersion`(2)/`generatedAt`(Unix ms)/`source`("nas")/`series`;
    /// the six fixed series, each exactly `{identityGeneration, points}`
    /// with `identityGeneration` a bounded string or null; at most 40 points
    /// of exactly `{at, consumed, unit, segmentId}` with strictly increasing,
    /// non-future Unix-ms `at`, finite non-negative `consumed`, the series'
    /// fixed unit and a bounded `segmentId`. No booleans anywhere a number
    /// is expected. Anything else rejects the whole file.
    static func decodeNASConsumptionHistoryV2(_ dictionary: [String: Any], now: Date = Date()) throws -> NASConsumptionHistory {
        guard let version = exactInteger(dictionary["schemaVersion"]) else { throw NASHistoryParseError.invalid }
        guard version == 2 else { throw NASHistoryParseError.unknownSchema }
        guard Set(dictionary.keys) == ["schemaVersion", "generatedAt", "source", "series"],
              dictionary["source"] as? String == "nas" else { throw NASHistoryParseError.invalid }

        let latestAllowed = now.addingTimeInterval(5 * 60)
        func epochMilliseconds(_ value: Any?) -> Date? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let ms = number.doubleValue
            guard ms.isFinite, ms > 1_000_000_000_000, ms < 4_200_000_000_000 else { return nil }
            let date = Date(timeIntervalSince1970: ms / 1000)
            return date <= latestAllowed ? date : nil
        }

        guard let generatedAt = epochMilliseconds(dictionary["generatedAt"]),
              let seriesDict = dictionary["series"] as? [String: Any],
              Set(seriesDict.keys) == Set(nasHistoryV2SeriesKeys) else { throw NASHistoryParseError.invalid }

        var series: [String: [UsageConsumptionPoint]] = [:]
        var identityGenerations: [String: String?] = [:]
        for key in nasHistoryV2SeriesKeys {
            guard let seriesObject = seriesDict[key] as? [String: Any],
                  Set(seriesObject.keys) == ["identityGeneration", "points"],
                  let rawGeneration = seriesObject["identityGeneration"],
                  let pointsArray = seriesObject["points"] as? [Any],
                  pointsArray.count <= nasHistoryMaxSamples else { throw NASHistoryParseError.invalid }
            // `updateValue` records an explicit null generation; subscript
            // assignment of nil would delete the key instead.
            if rawGeneration is NSNull {
                identityGenerations.updateValue(nil, forKey: key)
            } else if let generation = rawGeneration as? String, (1...128).contains(generation.count) {
                identityGenerations.updateValue(generation, forKey: key)
            } else {
                throw NASHistoryParseError.invalid
            }

            let unit = nasHistoryV2Unit(forSeries: key)
            var points: [UsageConsumptionPoint] = []
            for item in pointsArray {
                guard let point = item as? [String: Any],
                      Set(point.keys) == ["at", "consumed", "unit", "segmentId"],
                      let at = epochMilliseconds(point["at"]),
                      let consumed = point["consumed"] as? NSNumber,
                      CFGetTypeID(consumed) != CFBooleanGetTypeID(),
                      consumed.doubleValue.isFinite, consumed.doubleValue >= 0,
                      point["unit"] as? String == unit,
                      let segmentId = point["segmentId"] as? String, isValidSegmentID(segmentId) else {
                    throw NASHistoryParseError.invalid
                }
                if let previous = points.last, at <= previous.at { throw NASHistoryParseError.invalid }
                points.append(UsageConsumptionPoint(at: at, amount: consumed.doubleValue, segmentId: segmentId, unit: unit))
            }
            series[key] = points
        }

        // v2 has no root `codexUnit`; the Codex series with the newest
        // point is the unit the NAS is measuring now.
        let latestPercent = series["codex"]?.last?.at
        let latestCredits = series["codexCredits"]?.last?.at
        let codexUsesCredits = latestCredits.map { credits in latestPercent.map { credits > $0 } ?? true } ?? false

        return NASConsumptionHistory(
            codex: series["codex"] ?? [],
            codexCredits: series["codexCredits"] ?? [],
            claude: series["claude"] ?? [],
            claudeFable: series["claudeFable"] ?? [],
            gemini: series["gemini"] ?? [],
            gemini2: series["gemini2"] ?? [],
            codexUsesCredits: codexUsesCredits,
            identityGenerations: identityGenerations,
            collectedAt: generatedAt,
            schemaVersion: 2
        )
    }

    /// A whole, non-boolean JSON number, or nil.
    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1_000_000 else { return nil }
        return Int(double)
    }

    func applyingNASHistory(_ reading: NASConsumptionHistory) -> UsageSnapshot {
        var copy = self
        copy.nasHistory = reading
        return copy
    }
}

extension NASConsumptionHistory {
    /// Re-encodes a v1-validated reading as the exact v1 wire contract, so
    /// a cached copy goes back through `parseNASConsumptionHistory`.
    func v1ContractDocument() -> [String: Any]? {
        guard schemaVersion == 1 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func samples(_ points: [UsageConsumptionPoint]) -> [[String: Any]] {
            points.map { ["at": formatter.string(from: $0.at), "amount": $0.amount] }
        }
        return [
            "schemaVersion": 1,
            "source": "nas",
            "intervalSeconds": UsageSnapshot.nasHistoryIntervalSeconds,
            "slotCount": UsageSnapshot.nasHistoryMaxSamples,
            "collectedAt": formatter.string(from: collectedAt),
            "codexUnit": codexUsesCredits ? "credits" : "percent",
            "consumptionHistory": [
                "codex": samples(codex),
                "codexCredits": samples(codexCredits),
                "claude": samples(claude),
                "claudeFable": samples(claudeFable),
                "gemini": samples(gemini)
            ] as [String: Any]
        ]
    }

    /// Re-encodes a v2-validated reading as the exact v2 wire contract
    /// (segment ids, units and identity generations included), so a cached
    /// copy goes back through `decodeNASConsumptionHistoryV2`.
    func v2ContractDocument() -> [String: Any]? {
        guard schemaVersion == 2 else { return nil }
        func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        var series: [String: Any] = [:]
        for key in UsageSnapshot.nasHistoryV2SeriesKeys {
            var points: [[String: Any]] = []
            for point in self.points(forSeries: key) {
                guard let segmentId = point.segmentId, let unit = point.unit else { return nil }
                points.append(["at": milliseconds(point.at), "consumed": point.amount, "unit": unit, "segmentId": segmentId])
            }
            let generation = identityGenerations[key] ?? nil
            series[key] = ["identityGeneration": generation.map { $0 as Any } ?? NSNull(), "points": points]
        }
        return [
            "schemaVersion": 2,
            "generatedAt": milliseconds(collectedAt),
            "source": "nas",
            "series": series
        ]
    }
}
