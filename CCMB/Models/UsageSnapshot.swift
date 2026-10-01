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
        guard let value = double(key), value.isFinite, (0...100).contains(value) else { return nil }
        return value
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
        (raw[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
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
    case codex, claude, gemini, grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
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
    let status: String?
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
    let services: [Service: ServiceUsage]
    let consumptionHistory: UsageConsumptionHistory?
    /// Only ever set on NAS snapshots: the consumption history the NAS
    /// samples on its own every 5 minutes. Kept apart from
    /// `consumptionHistory` because its age and Codex unit come from the
    /// NAS history file, not from this usage report.
    var nasHistory: NASConsumptionHistory? = nil

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
        // The Mac keeps authenticated web-page readings under `online` while
        // the CLI-derived fields stay at the service root. Prefer the root
        // contract and fill its gaps from the web reading so the phone still
        // shows Gemini's session and weekly limits when only that source is
        // available. The web source currently exposes reset captions rather
        // than machine-readable dates, so those remain honestly empty.
        let online = gemini?.object("online")
        let fetchedAt = [gemini?.date("fetchedAt"), online?.date("fetchedAt")]
            .compactMap { $0 }
            .max()
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
                ),
                UsageWindow(
                    id: "onlineFiveHour",
                    label: "O세션",
                    remainingPercent: online?.double("fiveHourRemainingPercent"),
                    resetsAt: online?.date("fiveHourResetsAt"),
                    resetText: online?.string("fiveHourResetText"),
                    unavailabilityNote: online?.double("fiveHourRemainingPercent") == nil ? "미제공" : nil
                ),
                UsageWindow(
                    id: "onlineWeekly",
                    label: "O주간",
                    remainingPercent: online?.double("weeklyRemainingPercent"),
                    resetsAt: online?.date("weeklyResetsAt"),
                    resetText: online?.string("weeklyResetText"),
                    unavailabilityNote: online?.double("weeklyRemainingPercent") == nil ? "미제공" : nil
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

    private static func nasStatus(_ service: JSONObject?) -> String? {
        guard let service else { return nil }
        if service.string("error") != nil { return "unavailable" }
        if service.bool("stale") == true { return "stale" }
        if service.bool("ok") == true { return "ok" }
        return "unavailable"
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
        let rawBalance = credits?.double("balance")
        let balance = rawBalance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ServiceUsage(
            service: .codex,
            status: nasStatus(service),
            windows: windows,
            creditBalance: balance,
            creditLabel: usable ? "토큰" : nil,
            creditUnlimited: credits?.bool("unlimited") ?? false,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: service?.epochSecondsDate("fetched_at")
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
        return ServiceUsage(
            service: .claude,
            status: nasStatus(service),
            windows: windows,
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: modelWeeklyLimits,
            fetchedAt: service?.epochSecondsDate("fetched_at")
        )
    }

    /// Only the "Gemini Models" pool is shown; the NAS's "Claude and GPT
    /// models" pool under the same service belongs to a different quota and
    /// must never be mislabeled as Gemini's own limit. The NAS quota API
    /// itself has no authenticated-web ("online") reading — that only
    /// arrives later via `applyingGeminiOnline`, once the Mac-side relay has
    /// actually saved one — so these two placeholder windows start out
    /// waiting rather than claiming the data does not exist at all.
    private static func parseNASGemini(_ service: JSONObject?) -> ServiceUsage {
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
            ),
            UsageWindow(
                id: "onlineFiveHour",
                label: "O세션",
                remainingPercent: nil,
                resetsAt: nil,
                unavailabilityNote: "Mac에서 NAS 저장 대기"
            ),
            UsageWindow(
                id: "onlineWeekly",
                label: "O주간",
                remainingPercent: nil,
                resetsAt: nil,
                unavailabilityNote: "Mac에서 NAS 저장 대기"
            )
        ]
        return ServiceUsage(
            service: .gemini,
            status: nasStatus(service),
            windows: windows,
            creditBalance: nil,
            creditLabel: nil,
            monthlyUsedCredits: nil,
            account: nil,
            organizationName: nil,
            planTitle: nil,
            model: nil,
            modelWeeklyLimits: [],
            fetchedAt: service?.epochSecondsDate("fetched_at")
        )
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

/// One validated copy of the private NAS-stored
/// `CCMB-nas-consumption-history-v1.json` file: consumption the NAS itself
/// samples every 5 minutes from its own usage collector, with no Mac
/// involved. Each sample is the drop in a real reading since the previous
/// real reading; a service that failed or was stale simply has no sample.
struct NASConsumptionHistory {
    /// Codex weekly-percent consumption and Codex credit consumption are
    /// separate series so the two units can never mix; `codexUsesCredits`
    /// says which one the NAS is currently measuring.
    let codex: [UsageConsumptionPoint]
    let codexCredits: [UsageConsumptionPoint]
    let claude: [UsageConsumptionPoint]
    let claudeFable: [UsageConsumptionPoint]
    let gemini: [UsageConsumptionPoint]
    let codexUsesCredits: Bool
    /// When the NAS last accepted a fresh reading — never the download time.
    let collectedAt: Date

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
        codex.isEmpty && codexCredits.isEmpty && claude.isEmpty && claudeFable.isEmpty && gemini.isEmpty
    }
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
        let root = JSONObject(raw: dictionary)
        guard root.nonBoolInt("schemaVersion") == 1,
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
            codexUsesCredits: codexUsesCredits,
            collectedAt: collectedAt
        )
    }

    /// A whole, non-boolean JSON number, or nil.
    private static func exactInteger(_ value: Any?) -> Int? {
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
