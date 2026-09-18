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
    func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
    func string(_ key: String) -> String? { raw[key] as? String }
    func bool(_ key: String) -> Bool? { raw[key] as? Bool }
    func date(_ key: String) -> Date? { string(key).flatMap(Self.parseDate) }
    func object(_ key: String) -> JSONObject? { (raw[key] as? [String: Any]).map(JSONObject.init) }
    func objectArray(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
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
    let creditBalance: Double?
    let creditLabel: String?
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
        windows.contains { $0.remainingPercent != nil } || creditBalance != nil || monthlyUsedCredits != nil
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
        guard root.int("schemaVersion") == 1 else {
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
