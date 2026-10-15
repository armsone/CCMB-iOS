import Foundation

// Standalone fixture harness compiled directly against the real
// CCMB/Models/UsageSnapshot.swift, CCMB/Store/NASClient.swift and
// CCMB/Store/NASCacheCodec.swift (no mirrored logic) via
// scripts/parser_verify/run.sh. Synthetic fixtures only — no real NAS data,
// no network, no account identifiers.

var failures: [String] = []
var passCount = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passCount += 1
    } else {
        failures.append(name)
    }
}

func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func rejects(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

let origin = "https://nas.example.invalid:5443"
let base = URL(string: origin)!

// MARK: - v2 snapshot fixtures

func v2Service(
    _ name: String,
    ok: Bool = true,
    stale: Bool = false,
    fetchedAt: Any = 1_700_000_000,
    percent: Any = 55.0,
    error: Any = NSNull()
) -> [String: Any] {
    let itemName: String
    switch name {
    case "codex": itemName = "codex"
    case "claude": itemName = "전체"
    default: itemName = "Gemini Models"
    }
    let accountRef: Any
    switch name {
    case "gemini": accountRef = "account1"
    case "gemini2": accountRef = "account2"
    default: accountRef = NSNull()
    }
    return [
        "service": name,
        "provider": name == "gemini2" ? "gemini" : name,
        "account_ref": accountRef,
        "ok": ok,
        "stale": stale,
        "fetched_at": fetchedAt,
        "items": [["name": itemName, "window": "weekly", "window_minutes": 10080, "remaining_percent": percent, "resets_at": 1_700_086_400]],
        "error": error
    ]
}

func failedService(_ name: String, code: String = "timeout", message: Any? = nil) -> [String: Any] {
    var error: [String: Any] = ["code": code]
    if let message { error["message"] = message }
    var service = v2Service(name, ok: false, stale: true, fetchedAt: NSNull(), error: error)
    service["items"] = []
    return service
}

func v2Payload(_ services: [[String: Any]], generatedAt: Any = 1_700_000_100, collection: Any? = nil) -> [String: Any] {
    var out: [String: Any] = ["schema_version": 2, "quota_origin": "nas", "generated_at": generatedAt, "services": services]
    out["collection"] = collection ?? ["state": "idle", "job_id": NSNull(), "retry_at": NSNull()]
    out["execution_hosts"] = []
    out["auto_switch_enabled"] = false
    return out
}

func fourServices(_ transform: (String, [String: Any]) -> [String: Any] = { $1 }) -> [[String: Any]] {
    ["codex", "claude", "gemini", "gemini2"].map { transform($0, v2Service($0)) }
}

func parseV2(_ payload: [String: Any]) throws -> UsageSnapshot {
    try UsageSnapshot.parseNASv2(jsonData(payload))
}

func v2Rejects(_ name: String, _ payload: [String: Any]) {
    check(name, rejects { _ = try parseV2(payload) })
}

func mutate(_ target: String, _ change: @escaping (inout [String: Any]) -> Void) -> [[String: Any]] {
    fourServices { name, service in
        guard name == target else { return service }
        var copy = service
        change(&copy)
        return copy
    }
}

func weekly(_ snapshot: UsageSnapshot?, _ service: Service) -> Double? {
    let id = (service == .gemini || service == .gemini2) ? "cliWeekly" : "weekly"
    return snapshot?.services[service]?.windows.first { $0.id == id }?.remainingPercent
}

do {
    let snapshot = try parseV2(v2Payload(fourServices()))
    check("v2.valid.codex.weekly", weekly(snapshot, .codex) == 55.0)
    check("v2.valid.gemini2.account2.present", weekly(snapshot, .gemini2) == 55.0)
    check("v2.valid.fetchedAt.perService", snapshot.services[.gemini]?.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))
    check("v2.valid.generatedAt", snapshot.generatedAt == Date(timeIntervalSince1970: 1_700_000_100))
    check("v2.valid.status.ok", snapshot.services[.claude]?.status == "ok")
    check("v2.valid.notBusy", snapshot.collectionBusy == false)
} catch {
    failures.append("v2.valid threw: \(error)")
}

do {
    let fraction = try? parseV2(v2Payload(mutate("claude") { $0["items"] = [["name": "전체", "window": "weekly", "remaining_percent": 12.5, "resets_at": NSNull()]] }))
    check("v2.fractionalPercent.kept", weekly(fraction, .claude) == 12.5)
    let busy = try? parseV2(v2Payload(fourServices(), collection: ["state": "running", "job_id": NSNull(), "retry_at": NSNull()]))
    check("v2.collectionRunning.busy", busy?.collectionBusy == true)
    let stale = try? parseV2(v2Payload(mutate("codex") { $0["stale"] = true }))
    check("v2.staleWithItems.statusStale", stale?.services[.codex]?.status == "stale" && stale?.services[.codex]?.stale == true)
    let erroredWithItems = try? parseV2(v2Payload(mutate("gemini") { $0["ok"] = false; $0["stale"] = true; $0["error"] = ["code": "timeout", "message": "응답 시간이 초과되었습니다."] }))
    check("v2.errorWithItems.keepsValues", weekly(erroredWithItems, .gemini) == 55.0)
    check("v2.errorWithItems.stale", erroredWithItems?.services[.gemini]?.status == "stale")
    check("v2.errorWithItems.reason", erroredWithItems?.services[.gemini]?.errorReason == "응답 시간이 초과되었습니다.")
}

// Envelope
v2Rejects("v2.schemaVersion3.rejected", { var p = v2Payload(fourServices()); p["schema_version"] = 3; return p }())
v2Rejects("v2.schemaVersionFraction.rejected", { var p = v2Payload(fourServices()); p["schema_version"] = 2.1; return p }())
v2Rejects("v2.schemaVersionBool.rejected", { var p = v2Payload(fourServices()); p["schema_version"] = true; return p }())
v2Rejects("v2.quotaOriginMac.rejected", { var p = v2Payload(fourServices()); p["quota_origin"] = "mac"; return p }())
v2Rejects("v2.generatedAtMissing.rejected", { var p = v2Payload(fourServices()); p.removeValue(forKey: "generated_at"); return p }())
v2Rejects("v2.generatedAtBool.rejected", v2Payload(fourServices(), generatedAt: true))
v2Rejects("v2.generatedAtString.rejected", v2Payload(fourServices(), generatedAt: "1700000000"))
v2Rejects("v2.generatedAtZero.rejected", v2Payload(fourServices(), generatedAt: 0))
v2Rejects("v2.generatedAtMilliseconds.rejected", v2Payload(fourServices(), generatedAt: 1_700_000_000_000))
v2Rejects("v2.generatedAtNullWhileCollected.rejected", v2Payload(fourServices(), generatedAt: NSNull()))
v2Rejects("v2.collectionNotObject.rejected", v2Payload(fourServices(), collection: "running"))
check("v2.legacyShape.notV2", !UsageSnapshot.isV2Envelope(["report": ["services": [v2Service("codex")]]]))

// Identity
v2Rejects("v2.duplicateService.rejected", v2Payload([v2Service("codex"), v2Service("codex"), v2Service("claude"), v2Service("gemini"), v2Service("gemini2")]))
v2Rejects("v2.missingService.rejected", v2Payload([v2Service("codex"), v2Service("claude"), v2Service("gemini")]))
v2Rejects("v2.unknownExtraService.rejected", v2Payload(fourServices() + [["service": "mystery"]]))
v2Rejects("v2.reordered.rejected", v2Payload([v2Service("claude"), v2Service("codex"), v2Service("gemini"), v2Service("gemini2")]))
v2Rejects("v2.codexAccountRefMissing.rejected", v2Payload(mutate("codex") { $0.removeValue(forKey: "account_ref") }))
v2Rejects("v2.claudeAccountRefWrongType.rejected", v2Payload(mutate("claude") { $0["account_ref"] = 0 }))
v2Rejects("v2.codexAccountRefString.rejected", v2Payload(mutate("codex") { $0["account_ref"] = "account1" }))
v2Rejects("v2.geminiAccountRefMissing.rejected", v2Payload(mutate("gemini") { $0.removeValue(forKey: "account_ref") }))
v2Rejects("v2.geminiAccountRefNull.rejected", v2Payload(mutate("gemini") { $0["account_ref"] = NSNull() }))
v2Rejects("v2.gemini2Account1.rejected", v2Payload(mutate("gemini2") { $0["account_ref"] = "account1" }))
v2Rejects("v2.geminiProviderWrong.rejected", v2Payload(mutate("gemini") { $0["provider"] = "codex" }))
v2Rejects("v2.providerMissing.rejected", v2Payload(mutate("claude") { $0.removeValue(forKey: "provider") }))

// Per-service fields
v2Rejects("v2.okNumber.rejected", v2Payload(mutate("codex") { $0["ok"] = 1 }))
v2Rejects("v2.staleMissing.rejected", v2Payload(mutate("codex") { $0.removeValue(forKey: "stale") }))
v2Rejects("v2.fetchedAtMissing.rejected", v2Payload(mutate("codex") { $0.removeValue(forKey: "fetched_at") }))
v2Rejects("v2.fetchedAtBool.rejected", v2Payload(mutate("codex") { $0["fetched_at"] = true }))
v2Rejects("v2.fetchedAtNegative.rejected", v2Payload(mutate("codex") { $0["fetched_at"] = -5 }))
v2Rejects("v2.fetchedAtString.rejected", v2Payload(mutate("codex") { $0["fetched_at"] = "now" }))
v2Rejects("v2.errorMissing.rejected", v2Payload(mutate("codex") { $0.removeValue(forKey: "error") }))
v2Rejects("v2.errorPlainString.rejected", v2Payload(mutate("codex") { $0["error"] = "raw provider text" }))
v2Rejects("v2.errorExtraKey.rejected", v2Payload(mutate("codex") { $0["error"] = ["code": "timeout", "detail": "x"] }))
v2Rejects("v2.errorEmptyCode.rejected", v2Payload(mutate("codex") { $0["error"] = ["code": ""] }))
v2Rejects("v2.itemsMissing.rejected", v2Payload(mutate("codex") { $0.removeValue(forKey: "items") }))
v2Rejects("v2.percentBool.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": true]] }))
v2Rejects("v2.percentOver100.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": 100.5]] }))
v2Rejects("v2.percentString.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": "50"]] }))
v2Rejects("v2.percentNull.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": NSNull()]] }))
v2Rejects("v2.resetsAtBool.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": 10, "resets_at": false]] }))
v2Rejects("v2.creditsUnlimitedNumber.rejected", v2Payload(mutate("codex") { $0["items"] = [["name": "codex", "window": "weekly", "remaining_percent": 10, "credits": ["balance": 5, "unlimited": 1]]] }))

// All unavailable: valid four cards, no 0, no throw.
do {
    let services = ["codex", "claude", "gemini", "gemini2"].map { failedService($0, code: "not_collected") }
    let snapshot = try parseV2(v2Payload(services, generatedAt: NSNull()))
    check("v2.allUnavailable.fourCards", [Service.codex, .claude, .gemini, .gemini2].allSatisfy { snapshot.services[$0]?.status == "unavailable" })
    check("v2.allUnavailable.noZero", [Service.codex, .claude, .gemini, .gemini2].allSatisfy { snapshot.services[$0]?.measuredWindows.isEmpty == true })
    check("v2.allUnavailable.reasonFromCode", snapshot.services[.gemini2]?.errorReason == "아직 수집된 값이 없습니다.")
    check("v2.allUnavailable.generatedAtNull", snapshot.generatedAt == nil)
} catch {
    failures.append("v2.allUnavailable threw: \(error)")
}

// Partial failure in one parse: the failed card is empty with its reason, others stay.
do {
    let snapshot = try parseV2(v2Payload(fourServices { name, service in name == "codex" ? failedService("codex", code: "collector_new_code") : service }))
    check("v2.partial.codex.unavailable", snapshot.services[.codex]?.status == "unavailable")
    check("v2.partial.codex.unknownCodeReason", snapshot.services[.codex]?.errorReason == "오류 코드 collector_new_code")
    check("v2.partial.claude.good", weekly(snapshot, .claude) == 55.0)
} catch {
    failures.append("v2.partial threw: \(error)")
}

// MARK: - Legacy /api/usage

do {
    let payload: [String: Any] = ["ok": true, "report": ["services": [v2Service("codex"), v2Service("claude"), v2Service("gemini"), v2Service("gemini2")]]]
    let snapshot = try UsageSnapshot.parseNAS(jsonData(payload))
    check("legacy.valid.codex", weekly(snapshot, .codex) == 55.0)
    check("legacy.gemini2.unsupportedNotMixed", weekly(snapshot, .gemini2) == nil && snapshot.services[.gemini2]?.errorCode == "unsupported_server")
    check("legacy.gemini2.reason", snapshot.services[.gemini2]?.errorReason == "NAS 서버가 아직 Gemini 부계정을 지원하지 않습니다.")
} catch {
    failures.append("legacy.valid threw: \(error)")
}
do {
    var codex = v2Service("codex")
    codex["items"] = [["name": "codex", "window": "weekly", "remaining_percent": true]]
    let payload: [String: Any] = ["report": ["services": [codex, v2Service("claude")]]]
    let snapshot = try? UsageSnapshot.parseNAS(jsonData(payload))
    check("legacy.boolPercent.notOnePercent", snapshot != nil && weekly(snapshot, .codex) == nil)
    var stringError = v2Service("claude", ok: false)
    stringError["error"] = "raw text"
    let withString = try? UsageSnapshot.parseNAS(jsonData(["report": ["services": [v2Service("codex"), stringError]]]))
    check("legacy.plainStringError.notShown", withString?.services[.claude]?.errorMessage == nil && withString?.services[.claude]?.status == "stale")
}
check("legacy.rejectsV2Envelope", rejects { _ = try UsageSnapshot.parseNAS(jsonData(v2Payload(fourServices()))) })
check("mac.unknownSchema.rejected", rejects { _ = try UsageSnapshot.parse(jsonData(["schemaVersion": 99])) })

// MARK: - Refresh flow (actual NASSnapshotFlow with scripted transport)

final class Script {
    var responses: [(method: String, path: String, status: Int, body: Any)]
    var log: [String] = []
    var clock: TimeInterval = 0
    var slept: TimeInterval = 0
    var sleepError: Error?

    init(_ responses: [(String, String, Int, Any)]) {
        self.responses = responses.map { (method: $0.0, path: $0.1, status: $0.2, body: $0.3) }
    }

    func flow() -> NASSnapshotFlow {
        var flow = NASSnapshotFlow(base: base) { method, url, _ in
            var path = url.path
            if let query = url.query { path += "?" + query }
            self.log.append("\(method) \(path)")
            guard !self.responses.isEmpty else { throw NASFetchError.network }
            let next = self.responses.removeFirst()
            guard next.method == method, next.path == path else {
                throw NSError(domain: "script", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected \(method) \(path)"])
            }
            let data = (next.body as? Data) ?? jsonData(next.body)
            return NASHTTPResponse(statusCode: next.status, data: data)
        }
        flow.sleep = { seconds in
            if let error = self.sleepError { throw error }
            self.slept += seconds
            self.clock += seconds
        }
        flow.uptime = { self.clock }
        return flow
    }
}

let jobID = "0f8fad5b-d9cb-469f-a165-70867728950e"
let snapshotPath = "/api/ccmb/v2/snapshot"
let refreshPath = "/api/ccmb/v2/refresh"
let jobPath = "/api/ccmb/v2/refresh/\(jobID)"
let validSnapshot = v2Payload(fourServices())
let accepted: [String: Any] = ["job_id": jobID, "retry_after_seconds": 30]

func isError(_ error: Error?, _ expected: NASFetchError) -> Bool {
    guard let error = error as? NASFetchError else { return false }
    return String(describing: error) == String(describing: expected)
}

func runFlow(_ script: Script, refresh: Bool) async -> (NASSnapshotFetchResult?, Error?) {
    do {
        return (try await script.flow().run(refresh: refresh), nil)
    } catch {
        return (nil, error)
    }
}

do {
    let script = Script([("GET", snapshotPath, 200, validSnapshot)])
    let (result, _) = await runFlow(script, refresh: false)
    check("flow.auto.v2.readOnly", result?.isV2 == true && script.log == ["GET \(snapshotPath)"] && result?.refreshOutcome == nil)
}
do {
    let legacy: [String: Any] = ["report": ["services": [v2Service("codex")]]]
    let script = Script([("GET", snapshotPath, 404, ["error": "x"]), ("GET", "/api/usage?refresh=1", 200, legacy)])
    let (result, error) = await runFlow(script, refresh: true)
    check("flow.refresh.get404.legacyRefresh", error == nil && result?.isV2 == false)
    check("flow.refresh.get404.noPost", !script.log.contains { $0.hasPrefix("POST") })
}
do {
    let script = Script([("GET", snapshotPath, 404, [:]), ("GET", "/api/usage", 200, ["report": ["services": []]])])
    let (result, _) = await runFlow(script, refresh: false)
    check("flow.auto.get404.legacyNoQuery", result?.isV2 == false && script.log.last == "GET /api/usage")
}
for (status, expected) in [(401, NASFetchError.notAuthenticated), (403, .forbidden), (503, .serverUnavailable), (429, .rateLimited)] {
    let script = Script([("GET", snapshotPath, status, [:])])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.get\(status).propagates.noLegacy", isError(error, expected) && script.log.count == 1)
}
for (status, expected) in [(401, NASFetchError.notAuthenticated), (403, .forbidden), (429, .rateLimited), (503, .serverUnavailable), (404, .notFound)] {
    let script = Script([("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, status, [:])])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.post\(status).propagates.noFallback", isError(error, expected) && script.log == ["GET \(snapshotPath)", "POST \(refreshPath)"])
}
do {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot),
        ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 200, ["job_id": jobID, "state": "running"]),
        ("GET", jobPath, 200, ["job_id": jobID, "state": "completed"]),
        ("GET", snapshotPath, 200, validSnapshot)
    ])
    let (result, error) = await runFlow(script, refresh: true)
    check("flow.job.completed", error == nil && result?.refreshOutcome == .completed && result?.isV2 == true)
    check("flow.job.retryAfter", result?.retryAfterSeconds == 30)
    check("flow.job.finalSnapshotRead", script.log.last == "GET \(snapshotPath)" && script.responses.isEmpty)
    check("flow.job.pollSleptBounded", script.slept > 0 && script.slept <= NASSnapshotFlow.refreshWaitBudget)
}
for (state, outcome) in [("deferred", NASRefreshOutcome.deferred), ("failed", .failed)] {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot),
        ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 200, ["job_id": jobID, "state": state]),
        ("GET", snapshotPath, 200, validSnapshot)
    ])
    let (result, _) = await runFlow(script, refresh: true)
    check("flow.job.\(state)", result?.refreshOutcome == outcome)
}
do {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot),
        ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 200, ["job_id": jobID, "phase": "completed"])
    ])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.job.phaseFieldNotAccepted", isError(error, .unreadableResponse))
}
for (label, body) in [("unknownState", ["job_id": jobID, "state": "done"]), ("otherJob", ["job_id": "1f8fad5b-d9cb-469f-a165-70867728950e", "state": "completed"])] {
    let script = Script([("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, accepted), ("GET", jobPath, 200, body)])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.job.\(label).rejected", isError(error, .unreadableResponse))
}
for (label, body) in [
    ("pathTraversalJobID", ["job_id": "../../api/admin", "retry_after_seconds": 30] as [String: Any]),
    ("uppercaseJobID", ["job_id": jobID.uppercased(), "retry_after_seconds": 30]),
    ("retryAfterMissing", ["job_id": jobID]),
    ("retryAfterBool", ["job_id": jobID, "retry_after_seconds": true]),
    ("retryAfterNegative", ["job_id": jobID, "retry_after_seconds": -1])
] {
    let script = Script([("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, body)])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.post.\(label).rejected.noJobGet", isError(error, .unreadableResponse) && script.log.count == 2)
}
do {
    var clock: TimeInterval = 0
    var log: [String] = []
    var flow = NASSnapshotFlow(base: base) { method, url, _ in
        log.append("\(method) \(url.path)")
        if url.path == snapshotPath {
            let body = log.count > 1 ? v2Payload(fourServices(), collection: ["state": "running"]) : validSnapshot
            return NASHTTPResponse(statusCode: 200, data: jsonData(body))
        }
        if method == "POST" { return NASHTTPResponse(statusCode: 202, data: jsonData(accepted)) }
        return NASHTTPResponse(statusCode: 200, data: jsonData(["job_id": jobID, "state": "running"]))
    }
    flow.sleep = { clock += $0 }
    flow.uptime = { clock }
    let result = try? await flow.run(refresh: true)
    check("flow.job.budgetExhausted.stillRunning", result?.refreshOutcome == .stillRunning)
    check("flow.job.budgetBounded", clock <= NASSnapshotFlow.refreshWaitBudget + 0.001 && clock >= NASSnapshotFlow.refreshWaitBudget - 0.001)
    check("flow.job.budgetExhausted.finalRead", log.last == "GET \(snapshotPath)")
    let busy = result.flatMap { try? UsageSnapshot.parseNASv2($0.data) }
    check("flow.job.budgetExhausted.storedSnapshotBusy", busy?.collectionBusy == true)
}
do {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 404, [:]), ("GET", snapshotPath, 200, validSnapshot)
    ])
    let (result, _) = await runFlow(script, refresh: true)
    check("flow.job404.jobUnavailable", result?.refreshOutcome == .jobUnavailable)
}
do {
    let script = Script([("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, accepted), ("GET", jobPath, 401, [:])])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.job401.propagates", isError(error, .notAuthenticated))
}
do {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 200, ["job_id": jobID, "state": "completed"]), ("GET", snapshotPath, 404, [:])
    ])
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.final404.noLegacySwitch", isError(error, .notFound) && !script.log.contains("GET /api/usage"))
}
do {
    let script = Script([
        ("GET", snapshotPath, 200, validSnapshot), ("POST", refreshPath, 202, accepted),
        ("GET", jobPath, 200, ["job_id": jobID, "state": "queued"])
    ])
    script.sleepError = CancellationError()
    let (_, error) = await runFlow(script, refresh: true)
    check("flow.cancelDuringSleep.propagates", error is CancellationError && script.log.last == "GET \(jobPath)")
}
do {
    // Real Task cancellation with the default Task.sleep: the wait stops
    // with CancellationError instead of continuing to poll.
    final class Counter { var polls = 0 }
    let counter = Counter()
    let flow = NASSnapshotFlow(base: base) { method, url, _ in
        if url.path == snapshotPath { return NASHTTPResponse(statusCode: 200, data: jsonData(validSnapshot)) }
        if method == "POST" { return NASHTTPResponse(statusCode: 202, data: jsonData(accepted)) }
        counter.polls += 1
        return NASHTTPResponse(statusCode: 200, data: jsonData(["job_id": jobID, "state": "running"]))
    }
    let task = Task { try await flow.run(refresh: true) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    let outcome = await task.result
    var cancelled = false
    if case .failure(let error) = outcome { cancelled = error is CancellationError }
    check("flow.realTaskCancel.propagates", cancelled && counter.polls <= 2)
}
check("jobID.valid", NASSnapshotFlow.isSafeJobID(jobID))
check("jobID.slashRejected", !NASSnapshotFlow.isSafeJobID("0f8fad5b-d9cb-469f-a165-7086772895/e"))
check("jobID.shortRejected", !NASSnapshotFlow.isSafeJobID("abc"))
check("origin.same", NASSnapshotClient.isSameOrigin(URL(string: origin + "/api/x"), as: base))
check("origin.otherPort", !NASSnapshotClient.isSameOrigin(URL(string: "https://nas.example.invalid:5444/api/x"), as: base))
check("origin.http", !NASSnapshotClient.isSameOrigin(URL(string: "http://nas.example.invalid:5443/api/x"), as: base))
check("origin.otherHost", !NASSnapshotClient.isSameOrigin(URL(string: "https://evil.example.invalid:5443/"), as: base))
check("origin.string", NASSnapshotClient.origin(of: base) == origin)
check("http.404.notFound", { if case .notFound = NASHTTPClassifier.classify(statusCode: 404) { return true }; return false }())
check("http.302.notSuccess", NASHTTPClassifier.classify(statusCode: 302) != nil)

// MARK: - Snapshot cache codec (actual NASCacheCodec)

do {
    var withSecrets = v2Service("gemini2")
    withSecrets["binding_ref"] = "secret-binding"
    withSecrets["items"] = [["name": "Gemini Models", "window": "weekly", "remaining_percent": 55.0, "resets_at": 1_700_086_400, "debug": "secret-debug"]]
    var codex = failedService("codex", code: "timeout", message: "응답 시간이 초과되었습니다.")
    codex["raw"] = "secret-raw"
    let payload = v2Payload([codex, v2Service("claude"), v2Service("gemini"), withSecrets])
    let prepared = try NASCacheCodec.prepareSnapshot(jsonData(payload), isV2: true, previousCache: nil, origin: origin)
    let text = String(decoding: prepared.cacheData, as: UTF8.self)
    check("cache.v2.noSecrets", !text.contains("secret"))
    let cached = NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)
    check("cache.v2.roundTrip.isV2", cached?.isV2 == true)
    check("cache.v2.roundTrip.gemini2", weekly(cached?.snapshot, .gemini2) == 55.0)
    check("cache.v2.roundTrip.errorPreserved", cached?.snapshot.services[.codex]?.errorCode == "timeout" && cached?.snapshot.services[.codex]?.errorMessage == "응답 시간이 초과되었습니다.")
    check("cache.v2.roundTrip.nullRefKept", ((cached?.document["services"] as? [[String: Any]])?[0]["account_ref"]) is NSNull)
    check("cache.v2.roundTrip.generatedAt", cached?.snapshot.generatedAt == Date(timeIntervalSince1970: 1_700_000_100))
    check("cache.v2.otherOrigin.ignored", NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: "https://nas.example.invalid:5444") == nil)
} catch {
    failures.append("cache.v2.roundTrip threw: \(error)")
}
do {
    let services = ["codex", "claude", "gemini", "gemini2"].map { failedService($0, code: "not_collected") }
    let prepared = try NASCacheCodec.prepareSnapshot(jsonData(v2Payload(services, generatedAt: NSNull())), isV2: true, previousCache: nil, origin: origin)
    let cached = NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)
    check("cache.v2.allUnavailable.roundTrip", cached != nil && cached?.snapshot.services[.gemini2]?.status == "unavailable")
} catch {
    failures.append("cache.v2.allUnavailable threw: \(error)")
}
do {
    let busyPayload = v2Payload(fourServices(), collection: ["state": "running"])
    let prepared = try NASCacheCodec.prepareSnapshot(jsonData(busyPayload), isV2: true, previousCache: nil, origin: origin)
    check("cache.liveBusyShown", prepared.snapshot.collectionBusy)
    check("cache.busyNotRestored", NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)?.snapshot.collectionBusy == false)
} catch {
    failures.append("cache.busy threw: \(error)")
}
check("cache.invalidLiveRejected", rejects {
    _ = try NASCacheCodec.prepareSnapshot(jsonData(v2Payload(mutate("codex") { $0.removeValue(forKey: "account_ref") })), isV2: true, previousCache: nil, origin: origin)
})

// Partial failure: last known values preserved per service, others update.
do {
    let first = try NASCacheCodec.prepareSnapshot(jsonData(v2Payload(fourServices())), isV2: true, previousCache: nil, origin: origin)
    let second = v2Payload(fourServices { name, service in
        if name == "gemini2" { return failedService("gemini2", code: "timeout") }
        var copy = service
        copy["fetched_at"] = 1_700_000_500
        copy["items"] = [["name": (copy["items"] as! [[String: Any]])[0]["name"]!, "window": "weekly", "remaining_percent": 40.0, "resets_at": NSNull()]]
        return copy
    })
    let merged = try NASCacheCodec.prepareSnapshot(jsonData(second), isV2: true, previousCache: first.cacheData, origin: origin)
    let gemini2 = merged.snapshot.services[.gemini2]
    check("lastKnown.gemini2.valueKept", weekly(merged.snapshot, .gemini2) == 55.0)
    check("lastKnown.gemini2.flag", gemini2?.isLastKnown == true && gemini2?.status == "stale")
    check("lastKnown.gemini2.originalTime", gemini2?.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))
    check("lastKnown.gemini2.newReason", gemini2?.errorCode == "timeout")
    check("lastKnown.others.updated", weekly(merged.snapshot, .codex) == 40.0 && weekly(merged.snapshot, .gemini) == 40.0)
    check("lastKnown.gemini.notMixedWithGemini2", merged.snapshot.services[.gemini]?.isLastKnown == false)
    let relaunch = NASCacheCodec.decodeSnapshotCache(merged.cacheData, origin: origin)
    check("lastKnown.survivesRelaunch", relaunch?.snapshot.services[.gemini2]?.isLastKnown == true && weekly(relaunch?.snapshot, .gemini2) == 55.0)
    let recovered = try NASCacheCodec.prepareSnapshot(jsonData(v2Payload(fourServices())), isV2: true, previousCache: merged.cacheData, origin: origin)
    check("lastKnown.clearedOnRecovery", recovered.snapshot.services[.gemini2]?.isLastKnown == false)

    let legacyPrevious = try NASCacheCodec.prepareSnapshot(
        jsonData(["report": ["services": [v2Service("codex"), v2Service("claude"), v2Service("gemini")]]]),
        isV2: false, previousCache: nil, origin: origin)
    let crossFormat = try NASCacheCodec.prepareSnapshot(jsonData(v2Payload(fourServices { name, service in name == "gemini" ? failedService("gemini") : service })),
        isV2: true, previousCache: legacyPrevious.cacheData, origin: origin)
    check("lastKnown.notAcrossFormats", weekly(crossFormat.snapshot, .gemini) == nil && crossFormat.snapshot.services[.gemini]?.isLastKnown == false)
} catch {
    failures.append("lastKnown threw: \(error)")
}

// Explicit cache dispatch.
do {
    let legacy02x = jsonData(["report": ["services": [["service": "codex", "ok": true, "stale": false, "fetched_at": 1_700_000_000, "items": [["name": "codex", "window": "weekly", "remaining_percent": 33.0]]]]], "baseURLOrigin": origin])
    let decoded = NASCacheCodec.decodeSnapshotCache(legacy02x, origin: origin)
    check("cacheDispatch.legacy02x.offline", decoded?.isV2 == false && weekly(decoded?.snapshot, .codex) == 33.0)
    let unknownFormat = jsonData(["cacheFormat": "nas-v3", "snapshot": v2Payload(fourServices()), "baseURLOrigin": origin])
    check("cacheDispatch.unknownFormat.discarded", NASCacheCodec.decodeSnapshotCache(unknownFormat, origin: origin) == nil)
    let mislabeled = jsonData(["cacheFormat": "nas-v2", "snapshot": ["report": ["services": [v2Service("codex")]]], "baseURLOrigin": origin])
    check("cacheDispatch.v2LabelLegacyBody.noFallback", NASCacheCodec.decodeSnapshotCache(mislabeled, origin: origin) == nil)
    let rootV2NoFormat = jsonData(v2Payload(fourServices()).merging(["baseURLOrigin": origin]) { a, _ in a })
    check("cacheDispatch.unlabeledV2.discarded", NASCacheCodec.decodeSnapshotCache(rootV2NoFormat, origin: origin) == nil)
    let legacyString = try NASCacheCodec.prepareSnapshot(jsonData(["report": ["services": [v2Service("codex"), { var c = v2Service("claude", ok: false); c["error"] = "raw secret text"; return c }()]]]),
        isV2: false, previousCache: nil, origin: origin)
    check("cache.legacy.rawErrorNotStored", !String(decoding: legacyString.cacheData, as: UTF8.self).contains("raw secret"))
} catch {
    failures.append("cacheDispatch threw: \(error)")
}

// MARK: - History v2 (actual decoder)

let now = Date(timeIntervalSince1970: 1_800_000_000)
let nowMs = 1_800_000_000_000.0

func historySeries(_ key: String, generation: Any = NSNull(), points: [(Double, Double, String)] = []) -> [String: Any] {
    let unit = key == "codexCredits" ? "credits" : "percent"
    return ["identityGeneration": generation, "points": points.map { ["at": $0.0, "consumed": $0.1, "unit": unit, "segmentId": $0.2] }]
}

func historyDoc(_ overrides: [String: [String: Any]] = [:], generatedAt: Any = nowMs) -> [String: Any] {
    var series: [String: Any] = [:]
    for key in UsageSnapshot.nasHistoryV2SeriesKeys { series[key] = overrides[key] ?? historySeries(key) }
    return ["schemaVersion": 2, "generatedAt": generatedAt, "source": "nas", "series": series]
}

func decodeHistory(_ doc: [String: Any]) -> Result<NASConsumptionHistory, NASHistoryParseError> {
    do { return .success(try UsageSnapshot.decodeNASConsumptionHistoryV2(jsonData(doc), now: now)) }
    catch let error as NASHistoryParseError { return .failure(error) }
    catch { return .failure(.invalid) }
}

func historyRejected(_ name: String, _ doc: [String: Any], as expected: NASHistoryParseError = .invalid) {
    if case .failure(let error) = decodeHistory(doc) { check(name, error == expected) } else { check(name, false) }
}

let segmentedDoc = historyDoc([
    "gemini": historySeries("gemini", generation: "gen-a", points: [(nowMs - 540_000, 1.5, "aaaa1111"), (nowMs - 360_000, 2.0, "aaaa1111"), (nowMs - 180_000, 0.5, "bbbb2222")]),
    "codexCredits": historySeries("codexCredits", points: [(nowMs - 180_000, 12.25, "cccc3333")]),
    "codex": historySeries("codex", points: [(nowMs - 360_000, 3, "dddd4444")])
])
do {
    let history = try UsageSnapshot.decodeNASConsumptionHistoryV2(jsonData(segmentedDoc), now: now)
    check("historyV2.valid.schema2", history.schemaVersion == 2)
    check("historyV2.segmentIdPerPoint", history.gemini.map { $0.segmentId ?? "" } == ["aaaa1111", "aaaa1111", "bbbb2222"])
    check("historyV2.unitPerPoint", history.gemini.allSatisfy { $0.unit == "percent" } && history.codexCredits.first?.unit == "credits")
    check("historyV2.individualDeltasNotCumulative", history.gemini.map(\.amount) == [1.5, 2.0, 0.5])
    check("historyV2.generation", history.identityGenerations["gemini"] == .some("gen-a"))
    check("historyV2.generationNullKept", history.identityGenerations.keys.contains("gemini2") && history.identityGenerations["gemini2"] == .some(nil))
    check("historyV2.codexCreditsNewest", history.codexUsesCredits)
    check("historyV2.collectedAt", history.collectedAt == now)

    let cache = NASCacheCodec.encodeHistoryCache(history, origin: origin)
    let restored = cache.flatMap { NASCacheCodec.decodeHistoryCache($0, origin: origin, now: now) }
    check("historyCache.v2.roundTrip.segments", restored?.gemini.map { $0.segmentId ?? "" } == ["aaaa1111", "aaaa1111", "bbbb2222"])
    check("historyCache.v2.roundTrip.units", restored?.codexCredits.first?.unit == "credits" && restored?.schemaVersion == 2)
    check("historyCache.v2.roundTrip.times", restored?.gemini.map(\.at) == history.gemini.map(\.at) && restored?.collectedAt == history.collectedAt)
    check("historyCache.v2.roundTrip.generations", restored?.identityGenerations["gemini"] == .some("gen-a") && restored?.identityGenerations["gemini2"] == .some(nil))
    check("historyCache.v2.otherOrigin", cache.flatMap { NASCacheCodec.decodeHistoryCache($0, origin: "https://other.example.invalid", now: now) } == nil)
} catch {
    failures.append("historyV2.valid threw: \(error)")
}

historyRejected("historyV2.schema3.unknownSchema", { var d = historyDoc(); d["schemaVersion"] = 3; return d }(), as: .unknownSchema)
historyRejected("historyV2.schema1.unknownSchema", { var d = historyDoc(); d["schemaVersion"] = 1; return d }(), as: .unknownSchema)
historyRejected("historyV2.schemaString.invalid", { var d = historyDoc(); d["schemaVersion"] = "2"; return d }())
historyRejected("historyV2.schemaBool.invalid", { var d = historyDoc(); d["schemaVersion"] = true; return d }())
historyRejected("historyV2.extraRootKey", { var d = historyDoc(); d["extra"] = 1; return d }())
historyRejected("historyV2.sourceMac", { var d = historyDoc(); d["source"] = "mac"; return d }())
historyRejected("historyV2.generatedAtBool", historyDoc(generatedAt: true))
historyRejected("historyV2.generatedAtSeconds", historyDoc(generatedAt: 1_800_000_000))
historyRejected("historyV2.generatedAtFuture", historyDoc(generatedAt: nowMs + 600_000))
historyRejected("historyV2.missingSeries", { var d = historyDoc(); var s = d["series"] as! [String: Any]; s.removeValue(forKey: "gemini2"); d["series"] = s; return d }())
historyRejected("historyV2.extraSeries", { var d = historyDoc(); var s = d["series"] as! [String: Any]; s["grok"] = historySeries("grok"); d["series"] = s; return d }())
historyRejected("historyV2.seriesExtraKey", historyDoc(["claude": ["identityGeneration": NSNull(), "points": [], "unit": "percent"]]))
historyRejected("historyV2.generationMissing", historyDoc(["claude": ["points": []]]))
historyRejected("historyV2.generationNumber", historyDoc(["gemini": historySeries("gemini", generation: 3)]))
historyRejected("historyV2.generationEmpty", historyDoc(["gemini": historySeries("gemini", generation: "")]))
historyRejected("historyV2.codexCreditsPercent", historyDoc(["codexCredits": ["identityGeneration": NSNull(), "points": [["at": nowMs - 1000, "consumed": 1, "unit": "percent", "segmentId": "a1"]]]]))
historyRejected("historyV2.codexCredits.unitFixed", historyDoc(["codex": ["identityGeneration": NSNull(), "points": [["at": nowMs - 1000, "consumed": 1, "unit": "credits", "segmentId": "a1"]]]]))
historyRejected("historyV2.gemini2Credits", historyDoc(["gemini2": ["identityGeneration": NSNull(), "points": [["at": nowMs - 1000, "consumed": 1, "unit": "credits", "segmentId": "a1"]]]]))
historyRejected("historyV2.pointExtraKey", historyDoc(["claude": ["identityGeneration": NSNull(), "points": [["at": nowMs - 1000, "consumed": 1, "unit": "percent", "segmentId": "a1", "remaining": 50]]]]))
historyRejected("historyV2.atBool", historyDoc(["claude": historySeries("claude", points: [(0, 1, "a1")])].mapValues { s in var s = s; s["points"] = [["at": true, "consumed": 1, "unit": "percent", "segmentId": "a1"]]; return s }))
historyRejected("historyV2.atSeconds", historyDoc(["claude": historySeries("claude", points: [(1_799_999_000, 1, "a1")])]))
historyRejected("historyV2.atFuture", historyDoc(["claude": historySeries("claude", points: [(nowMs + 600_000, 1, "a1")])]))
historyRejected("historyV2.atNotIncreasing", historyDoc(["claude": historySeries("claude", points: [(nowMs - 1000, 1, "a1"), (nowMs - 1000, 1, "a1")])]))
historyRejected("historyV2.consumedNegative", historyDoc(["claude": historySeries("claude", points: [(nowMs - 1000, -0.1, "a1")])]))
historyRejected("historyV2.consumedBool", historyDoc(["claude": ["identityGeneration": NSNull(), "points": [["at": nowMs - 1000, "consumed": false, "unit": "percent", "segmentId": "a1"]]]]))
historyRejected("historyV2.segmentEmpty", historyDoc(["claude": historySeries("claude", points: [(nowMs - 1000, 1, "")])]))
historyRejected("historyV2.segmentTooLong", historyDoc(["claude": historySeries("claude", points: [(nowMs - 1000, 1, String(repeating: "a", count: 65))])]))
historyRejected("historyV2.segmentSlash", historyDoc(["claude": historySeries("claude", points: [(nowMs - 1000, 1, "a/b")])]))
historyRejected("historyV2.over40", historyDoc(["claude": historySeries("claude", points: (0..<41).map { (nowMs - Double(41 - $0) * 1000, 1, "a1") })]))
check("historyV2.exactly40.ok", { if case .success = decodeHistory(historyDoc(["claude": historySeries("claude", points: (0..<40).map { (nowMs - Double(40 - $0) * 1000, 1, "a1") })])) { return true }; return false }())

// MARK: - History v1 strict + legacy 5-key cache offline

func v1Doc(_ extraSeries: [String: Any] = [:], collectedAt: Date = now) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    var series: [String: Any] = [
        "codex": [["at": formatter.string(from: now.addingTimeInterval(-360)), "amount": 1], ["at": formatter.string(from: now.addingTimeInterval(-180)), "amount": 2]],
        "codexCredits": [], "claude": [], "claudeFable": [], "gemini": []
    ]
    series.merge(extraSeries) { _, new in new }
    return ["schemaVersion": 1, "source": "nas", "intervalSeconds": 180, "slotCount": 40,
            "collectedAt": formatter.string(from: collectedAt), "codexUnit": "percent", "consumptionHistory": series]
}

do {
    let history = UsageSnapshot.parseNASConsumptionHistory(v1Doc(), now: now)
    check("historyV1.valid", history?.codex.count == 2 && history?.schemaVersion == 1 && history?.gemini2.isEmpty == true)
    check("historyV1.gemini2KeyRejected", UsageSnapshot.parseNASConsumptionHistory(v1Doc(["gemini2": []]), now: now) == nil)
    check("historyV1.schemaFractionRejected", UsageSnapshot.parseNASConsumptionHistory(v1Doc().merging(["schemaVersion": 1.5]) { _, n in n }, now: now) == nil)
    check("historyV1.notAcceptedByV2", { if case .failure(.unknownSchema) = decodeHistory(v1Doc()) { return true }; return false }())

    let legacyCache = jsonData(["history": v1Doc(), "baseURLOrigin": origin])
    let offline = NASCacheCodec.decodeHistoryCache(legacyCache, origin: origin, now: now)
    check("historyCache.legacy5key.offline", offline?.codex.map(\.amount) == [1, 2] && offline?.schemaVersion == 1)
    let reencoded = offline.flatMap { NASCacheCodec.encodeHistoryCache($0, origin: origin) }
    let again = reencoded.flatMap { NASCacheCodec.decodeHistoryCache($0, origin: origin, now: now) }
    check("historyCache.v1.roundTrip", again?.codex.map(\.amount) == [1, 2] && again?.schemaVersion == 1)
    let v1InV2Format = jsonData(["cacheFormat": NASCacheCodec.historyV2Format, "document": v1Doc(), "baseURLOrigin": origin])
    check("historyCache.v1BodyInV2Format.noFallback", NASCacheCodec.decodeHistoryCache(v1InV2Format, origin: origin, now: now) == nil)
    let unknown = jsonData(["cacheFormat": "nas-history-v9", "history": v1Doc(), "baseURLOrigin": origin])
    check("historyCache.unknownFormat.discarded", NASCacheCodec.decodeHistoryCache(unknown, origin: origin, now: now) == nil)
    let unreleasedShape = jsonData(["collectedAtMs": nowMs, "series": ["codex": []], "baseURLOrigin": origin])
    check("historyCache.unlabeledOtherShape.discarded", NASCacheCodec.decodeHistoryCache(unreleasedShape, origin: origin, now: now) == nil)
}

// MARK: - Gemini online relay

do {
    let formatter = ISO8601DateFormatter()
    let ok = UsageSnapshot.parseGeminiOnlineRelay(jsonData(["schemaVersion": 1, "gemini": ["online": ["fetchedAt": formatter.string(from: Date()), "fiveHourRemainingPercent": 42.0]]]))
    check("geminiOnline.valid", ok?.fiveHourRemainingPercent == 42.0)
    let bool = UsageSnapshot.parseGeminiOnlineRelay(jsonData(["schemaVersion": 1, "gemini": ["online": ["fetchedAt": formatter.string(from: Date()), "fiveHourRemainingPercent": true]]]))
    check("geminiOnline.boolRejected", bool == nil)
}

// MARK: - Execution host metadata (synthetic, real NASHostStatus)

func hostPayload(_ hosts: [[String: Any]], autoSwitch: Any = false, available: Any? = nil) -> [String: Any] {
    var payload = v2Payload(fourServices())
    payload["execution_hosts"] = hosts
    payload["auto_switch_enabled"] = autoSwitch
    if let available { payload["auto_switch_available"] = available }
    return payload
}

func hostFourQuotaKept(_ snapshot: UsageSnapshot?) -> Bool {
    [Service.codex, .claude, .gemini, .gemini2].allSatisfy { weekly(snapshot, $0) == 55.0 }
}

func hostLines(_ snapshot: UsageSnapshot?, _ service: Service) -> [String] {
    snapshot?.services[service]?.executionStatusLines ?? []
}

func hostLinesMentionRunning(_ lines: [String]) -> Bool {
    lines.contains { $0.contains("실행중") || $0.contains("실행 중") }
}

// Uppercase RUNNING on account2: fixed secondary card owns it, primary card names the opposite account.
do {
    let snapshot = try parseV2(hostPayload([["host_id": "host-a", "run_id": "run-1", "execution_account": "account2", "phase": "RUNNING", "state_changed_at": 1_700_000_050, "last_heartbeat_at": 1_700_000_090, "return_state": NSNull()]]))
    let status = snapshot.nasHostStatus
    let host = status?.hosts.first
    check("host.upperRunning.quotaKept", hostFourQuotaKept(snapshot))
    check("host.upperRunning.singleHost", status?.hosts.count == 1)
    check("host.upperRunning.phaseNormalized", host?.phase == "running")
    check("host.upperRunning.account2", host?.executionAccount == "account2")
    check("host.upperRunning.runId", host?.runId == "run-1")
    check("host.upperRunning.timestamps", host?.stateChangedAt == Date(timeIntervalSince1970: 1_700_000_050) && host?.lastHeartbeatAt == Date(timeIntervalSince1970: 1_700_000_090))
    check("host.upperRunning.liveNotCached", status?.isCached == false)
    check("host.upperRunning.geminiServiceStatus", snapshot.services[.gemini]?.nasHostStatus?.hosts == status?.hosts)
    check("host.upperRunning.gemini2ServiceStatus", snapshot.services[.gemini2]?.nasHostStatus?.hosts == status?.hosts)
    let primary = hostLines(snapshot, .gemini)
    let secondary = hostLines(snapshot, .gemini2)
    check("host.upperRunning.secondaryOwnRunning", secondary.contains("호스트 host-a: 실행중"))
    check("host.upperRunning.secondaryNoOppositeLabel", !secondary.contains { $0.contains("부계정") || $0.contains("주계정") })
    check("host.upperRunning.primaryOppositeLabel", primary.contains("호스트 host-a: 부계정 실행중"))
    check("host.upperRunning.primaryNotOwnRunning", !primary.contains("호스트 host-a: 실행중"))
} catch {
    failures.append("host.upperRunning threw: \(error)")
}

// Every known uppercase phase normalizes to its lowercase canonical form.
let hostUpperPhases: [(String, String)] = [("RUNNING", "running"), ("PREPARED", "prepared"), ("READY", "ready"), ("FINISHING", "finishing"), ("COMMITTED", "committed"), ("REJECTED", "rejected"), ("ABORTED", "aborted")]
for (raw, expected) in hostUpperPhases {
    do {
        let snapshot = try parseV2(hostPayload([["host_id": "host-p", "run_id": NSNull(), "execution_account": "account1", "phase": raw]]))
        check("host.upperPhase.\(raw).normalized", snapshot.nasHostStatus?.hosts.count == 1 && snapshot.nasHostStatus?.hosts.first?.phase == expected)
        check("host.upperPhase.\(raw).quotaKept", hostFourQuotaKept(snapshot))
    } catch {
        failures.append("host.upperPhase.\(raw) threw: \(error)")
    }
}

// Idle host with null account/run survives parse, cache round trip and footers without implying it runs.
func checkIdleHost(_ label: String, returnState: String, korean: String) {
    let idleLine = "호스트 host-idle: 대기 (\(korean))"
    let payload = hostPayload([["host_id": "host-idle", "run_id": NSNull(), "execution_account": NSNull(), "phase": "idle", "return_state": returnState]])
    do {
        let parsed = try parseV2(payload)
        let host = parsed.nasHostStatus?.hosts.first
        check("host.\(label).parse.kept", parsed.nasHostStatus?.hosts.count == 1 && host?.hostId == "host-idle" && host?.phase == "idle")
        check("host.\(label).parse.nullAccountRun", host?.executionAccount == nil && host?.runId == nil)
        check("host.\(label).parse.returnState", host?.returnState == returnState)
        check("host.\(label).parse.quotaKept", hostFourQuotaKept(parsed))
        for service in [Service.gemini, .gemini2] {
            let footer = hostLines(parsed, service)
            check("host.\(label).footer.\(service).idleLine", footer.contains(idleLine))
            check("host.\(label).footer.\(service).notRunning", !hostLinesMentionRunning(footer))
        }
        let prepared = try NASCacheCodec.prepareSnapshot(jsonData(payload), isV2: true, previousCache: nil, origin: origin)
        check("host.\(label).prepared.hostsMatchParse", prepared.snapshot.nasHostStatus?.hosts == parsed.nasHostStatus?.hosts)
        check("host.\(label).prepared.liveNotCached", prepared.snapshot.nasHostStatus?.isCached == false)
        let cachedStatus = NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)?.snapshot.nasHostStatus
        let cachedHost = cachedStatus?.hosts.first
        check("host.\(label).cache.kept", cachedStatus?.hosts.count == 1 && cachedHost?.hostId == "host-idle" && cachedHost?.phase == "idle")
        check("host.\(label).cache.nullAccountRun", cachedHost?.executionAccount == nil && cachedHost?.runId == nil)
        check("host.\(label).cache.returnState", cachedHost?.returnState == returnState)
        check("host.\(label).cache.isCached", cachedStatus?.isCached == true)
        let cachedFooter = cachedStatus?.footerLines(accountRef: "account1", isCached: true) ?? []
        check("host.\(label).cache.footerIdleLine", cachedFooter.contains("[캐시] " + idleLine))
        check("host.\(label).cache.footerNotRunning", !hostLinesMentionRunning(cachedFooter))
    } catch {
        failures.append("host.\(label) threw: \(error)")
    }
}
checkIdleHost("idleConfirmed", returnState: "confirmed", korean: "복귀확인됨")
checkIdleHost("idlePending", returnState: "pending", korean: "복귀확인대기")

// Invalid host entries are dropped individually; the four quota cards are never rejected.
let hostInvalidCases: [(String, [String: Any])] = [
    ("runningNullAccount", ["host_id": "host-x", "run_id": "run-x", "execution_account": NSNull(), "phase": "running"]),
    ("upperRunningMissingAccount", ["host_id": "host-x", "phase": "RUNNING"]),
    ("runningAlias1", ["host_id": "host-x", "execution_account": "1", "phase": "running"]),
    ("runningAlias2", ["host_id": "host-x", "execution_account": "2", "phase": "running"]),
    ("idleAlias2", ["host_id": "host-x", "execution_account": "2", "phase": "idle"]),
    ("stateChangedAtBool", ["host_id": "host-x", "phase": "idle", "state_changed_at": true]),
    ("heartbeatBool", ["host_id": "host-x", "phase": "idle", "last_heartbeat_at": false])
]
for (label, host) in hostInvalidCases {
    do {
        let snapshot = try parseV2(hostPayload([host]))
        check("host.invalid.\(label).hostDropped", (snapshot.nasHostStatus?.hosts ?? []).isEmpty)
        check("host.invalid.\(label).quotaAccepted", hostFourQuotaKept(snapshot))
    } catch {
        failures.append("host.invalid.\(label) quota rejected: \(error)")
    }
}

do {
    var payload = v2Payload(fourServices())
    payload["execution_hosts"] = "not-a-list"
    let snapshot = try parseV2(payload)
    check("host.malformedList.quotaAccepted", hostFourQuotaKept(snapshot))
    check("host.malformedList.noHosts", (snapshot.nasHostStatus?.hosts ?? []).isEmpty)
} catch {
    failures.append("host.malformedList quota rejected: \(error)")
}

// One bad host next to one good host keeps the good one.
do {
    let snapshot = try parseV2(hostPayload([["host_id": "bad host!", "phase": "idle"], ["host_id": "host-good", "execution_account": "account1", "phase": "PREPARED"]]))
    let hosts = snapshot.nasHostStatus?.hosts ?? []
    check("host.mixed.goodKept", hosts.count == 1 && hosts.first?.hostId == "host-good" && hosts.first?.phase == "prepared")
    check("host.mixed.quotaKept", hostFourQuotaKept(snapshot))
    check("host.mixed.primaryFooter", hostLines(snapshot, .gemini).contains("호스트 host-good: 준비완료"))
    check("host.mixed.secondaryFooterOmits", !hostLines(snapshot, .gemini2).contains { $0.contains("host-good") })
    check("host.mixed.badNeverShown", !hostLines(snapshot, .gemini).contains { $0.contains("bad host") })
} catch {
    failures.append("host.mixed threw: \(error)")
}

// auto_switch: only a genuine JSON bool counts; available=false or non-bool => unknown.
let hostAutoCases: [(String, Any, Any?, Bool?)] = [
    ("enabledTrue", true, nil, true),
    ("enabledFalse", false, nil, false),
    ("enabledNull", NSNull(), nil, nil),
    ("availableFalseEnabledFalse", false, false, nil),
    ("enabledNumericOne", 1, nil, nil)
]
for (label, enabled, available, expected) in hostAutoCases {
    do {
        let snapshot = try parseV2(hostPayload([], autoSwitch: enabled, available: available))
        let footerLabel = expected.map { $0 ? "켜짐" : "꺼짐" } ?? "정보 없음"
        check("host.auto.\(label).value", snapshot.nasHostStatus?.autoSwitchEnabled == expected)
        check("host.auto.\(label).footer", snapshot.nasHostStatus?.footerLines(accountRef: "account1").contains("자동전환: \(footerLabel)") == true)
        check("host.auto.\(label).quotaAccepted", hostFourQuotaKept(snapshot))
    } catch {
        failures.append("host.auto.\(label) threw: \(error)")
    }
}

// Unknown host keys are never persisted; live prepare is not cached, decoded cache is.
do {
    let payload = hostPayload([["host_id": "host-s", "run_id": NSNull(), "execution_account": NSNull(), "phase": "idle", "return_state": "confirmed", "secret_token": "synthetic-secret-do-not-cache", "local_path": "synthetic-local-path-do-not-cache"]], autoSwitch: true)
    let prepared = try NASCacheCodec.prepareSnapshot(jsonData(payload), isV2: true, previousCache: nil, origin: origin)
    let document = String(decoding: prepared.cacheData, as: UTF8.self)
    check("host.cache.secretValueStripped", !document.contains("synthetic-secret-do-not-cache"))
    check("host.cache.secretKeyStripped", !document.contains("secret_token"))
    check("host.cache.extraPathStripped", !document.contains("local_path") && !document.contains("synthetic-local-path-do-not-cache"))
    check("host.cache.whitelistedHostKept", document.contains("host-s"))
    check("host.live.isCachedFalse", prepared.snapshot.nasHostStatus?.isCached == false)
    let cached = NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)
    check("host.cache.isCachedTrue", cached?.snapshot.nasHostStatus?.isCached == true)
    check("host.cache.autoSwitchKept", cached?.snapshot.nasHostStatus?.autoSwitchEnabled == true)
    check("host.cache.hostWhitelistOnly", cached?.snapshot.nasHostStatus?.hosts == [NASExecutionHost(hostId: "host-s", phase: "idle", returnState: "confirmed")])
    check("host.cache.quotaKept", hostFourQuotaKept(cached?.snapshot))
} catch {
    failures.append("host.cache threw: \(error)")
}

// Older v2 payloads without host metadata stay valid; nothing is inferred from quota/reset fields.
do {
    var payload = v2Payload(fourServices())
    payload.removeValue(forKey: "execution_hosts")
    payload.removeValue(forKey: "auto_switch_enabled")
    let snapshot = try parseV2(payload)
    check("host.legacyNoHost.accepted", hostFourQuotaKept(snapshot))
    check("host.legacyNoHost.noGlobalStatus", snapshot.nasHostStatus == nil)
    check("host.legacyNoHost.noServiceStatus", snapshot.services[.gemini]?.nasHostStatus == nil && snapshot.services[.gemini2]?.nasHostStatus == nil)
    check("host.legacyNoHost.noFooterInferred", hostLines(snapshot, .gemini).isEmpty && hostLines(snapshot, .gemini2).isEmpty)
    let prepared = try NASCacheCodec.prepareSnapshot(jsonData(payload), isV2: true, previousCache: nil, origin: origin)
    let cached = NASCacheCodec.decodeSnapshotCache(prepared.cacheData, origin: origin)
    check("host.legacyNoHost.cacheNoStatus", cached != nil && cached?.snapshot.nasHostStatus == nil)
} catch {
    failures.append("host.legacyNoHost threw: \(error)")
}

check("safety.host.valid_host_dict", {
    let status = NASHostStatus.parse(executionHosts: [["host_id": "ok", "execution_account": "account1", "phase": "RUNNING"]], autoSwitchEnabled: nil)
    return status?.hosts.count == 1 && status?.hosts.first?.hostId == "ok"
}())
check("safety.host.duplicate_valid_id_keeps_one", {
    let host1: [String: Any] = ["host_id": "ok", "execution_account": "account1", "phase": "RUNNING"]
    let host2: [String: Any] = ["host_id": "ok", "execution_account": "account2", "phase": "RUNNING"]
    let status = NASHostStatus.parse(executionHosts: [host1, host2], autoSwitchEnabled: nil)
    return status?.hosts.count == 1 && status?.hosts.first?.hostId == "ok"
}())
check("safety.host.first_invalid_future_timestamp_then_valid_same_id_keeps_valid", {
    let now = Date().timeIntervalSince1970
    let badHost: [String: Any] = ["host_id": "ok", "execution_account": "account1", "phase": "RUNNING", "state_changed_at": now + 120]
    let goodHost: [String: Any] = ["host_id": "ok", "execution_account": "account2", "phase": "RUNNING", "state_changed_at": now]
    let status = NASHostStatus.parse(executionHosts: [badHost, goodHost], autoSwitchEnabled: nil)
    return status?.hosts.count == 1 && status?.hosts.first?.hostId == "ok"
}())
for key in ["state_changed_at", "last_heartbeat_at"] {
    let now = Date().timeIntervalSince1970
    let validHost: [String: Any] = ["host_id": "ok", "execution_account": "account1", "phase": "RUNNING", key: now]
    let futureHost120: [String: Any] = ["host_id": "bad", "execution_account": "account2", "phase": "RUNNING", key: now + 120]
    let status120 = NASHostStatus.parse(executionHosts: [validHost, futureHost120], autoSwitchEnabled: nil)
    check("safety.host.\(key)_plus120_only_ok", status120?.hosts.count == 1 && status120?.hosts.first?.hostId == "ok")

    let futureHost30: [String: Any] = ["host_id": "bad", "execution_account": "account2", "phase": "RUNNING", key: now + 30]
    let status30 = NASHostStatus.parse(executionHosts: [validHost, futureHost30], autoSwitchEnabled: nil)
    let ids = Set(status30?.hosts.map { $0.hostId } ?? [])
    check("safety.host.\(key)_plus30_both_accepted", status30?.hosts.count == 2 && ids == Set(["ok", "bad"]))
}
do {
    let actualDateNow = Date().timeIntervalSince1970

    // 1. generated_at: now + 120s rejects, now + 30s accepted
    let payloadGenFuture120 = v2Payload(fourServices(), generatedAt: actualDateNow + 120)
    check("actualDate: generated_at now+120 rejects", (try? parseV2(payloadGenFuture120)) == nil)

    let payloadGenFuture30 = v2Payload(fourServices(), generatedAt: actualDateNow + 30)
    check("actualDate: generated_at now+30 accepted", (try? parseV2(payloadGenFuture30)) != nil)

    // 2. mutateGemini2 fetched_at: now + 120s rejects, now + 30s accepted
    var servicesFuture120 = fourServices()
    servicesFuture120[3]["fetched_at"] = actualDateNow + 120
    let payloadFetchedFuture120 = v2Payload(servicesFuture120)
    check("actualDate: fetched_at now+120 rejects", (try? parseV2(payloadFetchedFuture120)) == nil)

    var servicesFuture30 = fourServices()
    servicesFuture30[3]["fetched_at"] = actualDateNow + 30
    let payloadFetchedFuture30 = v2Payload(servicesFuture30)
    check("actualDate: fetched_at now+30 accepted", (try? parseV2(payloadFetchedFuture30)) != nil)

    // 3. future resets_at now+86400 inside services[2].items[0] ACCEPTED
    var servicesResetFuture = fourServices()
    if var items = servicesResetFuture[2]["items"] as? [[String: Any]], !items.isEmpty {
        items[0]["resets_at"] = actualDateNow + 86400
        servicesResetFuture[2]["items"] = items
    }
    let payloadResetFuture = v2Payload(servicesResetFuture)
    check("actualDate: resets_at now+86400 accepted", (try? parseV2(payloadResetFuture)) != nil)
}

print("PASS: \(passCount)")
if failures.isEmpty {
    print("ALL PARSER FIXTURES PASSED")
    exit(0)
} else {
    print("FAILURES (\(failures.count)):")
    for failure in failures { print(" - \(failure)") }
    exit(1)
}
