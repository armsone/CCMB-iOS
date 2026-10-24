import Foundation

/// Pure encode/decode of the NAS copies the store keeps on disk, kept free
/// of UI and file I/O so the fixture harness exercises the exact same code.
///
/// Every cache names its format explicitly and is read back only by that
/// format's own strict parser — an unknown or missing format is discarded,
/// never retried against another parser. Only allowlisted, non-secret fields
/// are written, stamped with the NAS origin they came from.
enum NASCacheCodec {
    static let snapshotV2Format = "nas-v2"
    static let snapshotLegacyFormat = "nas-legacy"
    static let historyV1Format = "nas-history-v1"
    static let historyV2Format = "nas-history-v2"
    static let historyV3Format = "nas-history-v3"
    static let maxSnapshotCacheBytes = 262_144

    struct PreparedSnapshot {
        let snapshot: UsageSnapshot
        let cacheData: Data
    }

    struct CachedSnapshot {
        let snapshot: UsageSnapshot
        let isV2: Bool
        let document: [String: Any]
        let lastKnown: Set<String>
    }

    // MARK: - Snapshot sanitizing

    private static let serviceKeysV2 = ["service", "provider", "account_ref", "ok", "stale", "fetched_at", "account_display"]
    private static let serviceKeysLegacy = ["service", "ok", "stale", "fetched_at", "account_display"]
    private static let itemKeys = ["name", "window", "window_minutes", "remaining_percent", "resets_at"]

    /// The allowlisted copy of a NAS response: identity, freshness, the
    /// structured `{code, message?}` error (never a raw error string) and
    /// the display items. Keys present as `null` stay `null`.
    static func sanitizedDocument(_ data: Data, isV2: Bool) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if isV2 {
            guard UsageSnapshot.isV2Envelope(object), let services = object["services"] as? [[String: Any]] else { return nil }
            let knownServices = services.filter {
                guard let name = $0["service"] as? String else { return false }
                return UsageSnapshot.v2RequiredIdentity[name] != nil
            }
            var out: [String: Any] = [
                "schema_version": UsageSnapshot.v2SchemaVersion,
                "services": knownServices.map { sanitizedService($0, keys: serviceKeysV2) }
            ]
            if let quotaOrigin = object["quota_origin"] as? String { out["quota_origin"] = quotaOrigin }
            if let generatedAt = object["generated_at"], generatedAt is NSNull || generatedAt is NSNumber {
                out["generated_at"] = generatedAt
            }
            if let status = NASHostStatus.parse(
                executionHosts: object["execution_hosts"],
                autoSwitchEnabled: object["auto_switch_enabled"],
                autoSwitchAvailable: object["auto_switch_available"]
            ) {
                for (key, value) in status.jsonObject() {
                    out[key] = value
                }
            }
            return out
        }
        guard let report = object["report"] as? [String: Any],
              let services = report["services"] as? [[String: Any]] else { return nil }
        return ["report": ["services": services.map { sanitizedService($0, keys: serviceKeysLegacy) }]]
    }

    private static func sanitizedService(_ service: [String: Any], keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys {
            if let value = service[key] { out[key] = value }
        }
        switch service["error"] {
        case let object as [String: Any]:
            var error: [String: Any] = [:]
            if let code = object["code"] as? String { error["code"] = code }
            if let message = object["message"] as? String { error["message"] = message }
            out["error"] = error
        case is String:
            // A legacy plain-string error still marks the service as failed,
            // but its raw text is never stored.
            out["error"] = ["code": "unknown"]
        case is NSNull:
            out["error"] = NSNull()
        default:
            break
        }
        out["items"] = ((service["items"] as? [[String: Any]]) ?? []).map { item -> [String: Any] in
            var sanitized: [String: Any] = [:]
            for key in itemKeys {
                if let value = item[key] { sanitized[key] = value }
            }
            // Only the two known credits fields — never the whole nested
            // object, which could otherwise smuggle through other fields.
            if let credits = item["credits"] as? [String: Any] {
                var safe: [String: Any] = [:]
                if let balance = credits["balance"] as? NSNumber, balance.doubleValue.isFinite, balance.doubleValue >= 0 {
                    safe["balance"] = balance
                }
                if let unlimited = credits["unlimited"] as? NSNumber, CFGetTypeID(unlimited) == CFBooleanGetTypeID() {
                    safe["unlimited"] = unlimited
                }
                if !safe.isEmpty { sanitized["credits"] = safe }
            }
            // Codex/Claude reset-voucher metadata: only the known safe
            // sub-fields, never the whole nested object.
            if let details = item["codex_details"] as? [String: Any] {
                var safe: [String: Any] = [:]
                if let planType = details["plan_type"] as? String { safe["plan_type"] = planType }
                if let resetCredits = details["reset_credits_available"] as? NSNumber,
                   CFGetTypeID(resetCredits) != CFBooleanGetTypeID() {
                    safe["reset_credits_available"] = resetCredits
                }
                if let expirations = details["reset_credit_expirations"] as? [Any] {
                    safe["reset_credit_expirations"] = expirations.prefix(16).filter { value in
                        guard let number = value as? NSNumber else { return false }
                        return CFGetTypeID(number) != CFBooleanGetTypeID()
                    }
                }
                if !safe.isEmpty { sanitized["codex_details"] = safe }
            }
            if let details = item["claude_details"] as? [String: Any] {
                var safe: [String: Any] = [:]
                if let planType = details["plan_type"] as? String { safe["plan_type"] = planType }
                if let limitResets = details["limit_resets"] as? [String: Any] {
                    var safeResets: [String: Any] = [:]
                    if let count = limitResets["remaining_count"] as? NSNumber,
                       CFGetTypeID(count) != CFBooleanGetTypeID() {
                        safeResets["remaining_count"] = count
                    }
                    if let expiresAt = limitResets["expires_at"] as? NSNumber,
                       CFGetTypeID(expiresAt) != CFBooleanGetTypeID() {
                        safeResets["expires_at"] = expiresAt
                    }
                    if !safeResets.isEmpty { safe["limit_resets"] = safeResets }
                }
                if !safe.isEmpty { sanitized["claude_details"] = safe }
            }
            return sanitized
        }
        // `gemini_details` (credit_balance/credits_fetched_at/credits_status)
        // and `refresh_policy` (mode/interval_seconds/next_refresh_at) are
        // optional, service-level, non-secret metadata describing NAS's own
        // upstream collection — never the client's independent cached-GET
        // polling. Only the known safe sub-fields are copied through.
        if let details = service["gemini_details"] as? [String: Any] {
            var safe: [String: Any] = [:]
            if let balance = details["credit_balance"] as? NSNumber,
               CFGetTypeID(balance) != CFBooleanGetTypeID(), balance.doubleValue.isFinite, balance.doubleValue >= 0 {
                safe["credit_balance"] = balance
            }
            if let fetchedAt = details["credits_fetched_at"] as? NSNumber,
               CFGetTypeID(fetchedAt) != CFBooleanGetTypeID(), fetchedAt.doubleValue.isFinite, fetchedAt.doubleValue > 0 {
                safe["credits_fetched_at"] = fetchedAt
            }
            if let status = details["credits_status"] as? String, ["ok", "unavailable"].contains(status) {
                safe["credits_status"] = status
            }
            if let planTitle = details["plan_title"] as? String, planTitle.count <= 120 {
                safe["plan_title"] = planTitle
            }
            if !safe.isEmpty { out["gemini_details"] = safe }
        }
        if let policy = service["refresh_policy"] as? [String: Any] {
            var safe: [String: Any] = [:]
            if let mode = policy["mode"] as? String, ["active", "idle", "backoff"].contains(mode) {
                safe["mode"] = mode
            }
            if let interval = policy["interval_seconds"] as? NSNumber,
               CFGetTypeID(interval) != CFBooleanGetTypeID(), interval.doubleValue.isFinite, interval.doubleValue >= 0 {
                safe["interval_seconds"] = interval
            }
            if let nextRefreshAt = policy["next_refresh_at"] as? NSNumber,
               CFGetTypeID(nextRefreshAt) != CFBooleanGetTypeID(), nextRefreshAt.doubleValue.isFinite, nextRefreshAt.doubleValue > 0 {
                safe["next_refresh_at"] = nextRefreshAt
            }
            if !safe.isEmpty { out["refresh_policy"] = safe }
        }
        return out
    }

    // MARK: - Per-service last known values

    private static func services(of document: [String: Any], isV2: Bool) -> [[String: Any]]? {
        isV2
            ? document["services"] as? [[String: Any]]
            : (document["report"] as? [String: Any])?["services"] as? [[String: Any]]
    }

    private static func sameIdentity(_ lhs: [String: Any], _ rhs: [String: Any], isV2: Bool) -> Bool {
        guard let name = lhs["service"] as? String, rhs["service"] as? String == name else { return false }
        guard isV2 else { return true }
        func ref(_ value: Any?) -> String? { value as? String }
        return lhs["provider"] as? String == rhs["provider"] as? String
            && ref(lhs["account_ref"]) == ref(rhs["account_ref"])
            && (lhs["account_ref"] is NSNull) == (rhs["account_ref"] is NSNull)
    }

    /// A service whose new response failed with no items keeps its previous
    /// items and original `fetched_at`, marked stale, with the new error.
    /// Every other service takes the new response as-is, so one failing
    /// account never hides or freezes the others.
    static func mergingLastKnown(
        _ incoming: [String: Any],
        previous: [String: Any]?,
        isV2: Bool
    ) -> (document: [String: Any], lastKnown: Set<String>) {
        guard let previous,
              let incomingServices = services(of: incoming, isV2: isV2),
              let previousServices = services(of: previous, isV2: isV2) else {
            return (incoming, [])
        }
        var lastKnown: Set<String> = []
        let merged = incomingServices.map { service -> [String: Any] in
            let items = service["items"] as? [Any] ?? []
            guard items.isEmpty, (service["ok"] as? Bool) != true,
                  let name = service["service"] as? String,
                  let old = previousServices.first(where: { sameIdentity($0, service, isV2: isV2) }),
                  let oldItems = old["items"] as? [Any], !oldItems.isEmpty else {
                return service
            }
            var out = service
            out["items"] = oldItems
            out["fetched_at"] = old["fetched_at"] ?? NSNull()
            out["ok"] = false
            out["stale"] = true
            lastKnown.insert(name)
            return out
        }
        var document = incoming
        if isV2 {
            document["services"] = merged
        } else {
            document["report"] = ["services": merged]
        }
        return (document, lastKnown)
    }

    // MARK: - Snapshot cache

    /// Validates the live response with its own strict parser, then builds
    /// the cache (sanitized, merged with the previous same-format copy) and
    /// returns the snapshot decoded back from that exact cache, so what is
    /// shown now is what a relaunch will show.
    static func prepareSnapshot(_ data: Data, isV2: Bool, previousCache: Data?, origin: String) throws -> PreparedSnapshot {
        let live = isV2 ? try UsageSnapshot.parseNASv2(data) : try UsageSnapshot.parseNAS(data)
        guard let sanitized = sanitizedDocument(data, isV2: isV2) else { throw SnapshotError.unsupportedSchema }
        let previous = previousCache.flatMap { decodeSnapshotCache($0, origin: origin) }.flatMap { $0.isV2 == isV2 ? $0 : nil }
        let merged = mergingLastKnown(sanitized, previous: previous?.document, isV2: isV2)
        guard let cacheData = encodeSnapshotCache(document: merged.document, isV2: isV2, lastKnown: merged.lastKnown, origin: origin),
              let decoded = decodeSnapshotCache(cacheData, origin: origin) else {
            throw SnapshotError.unsupportedSchema
        }
        var snapshot = decoded.snapshot
        // Live-only collection state is never written to or read from disk.
        snapshot.collectionBusy = live.collectionBusy
        // Decoding the cache marks host metadata as cached; the shown live
        // result must carry the freshest live host metadata instead.
        snapshot.nasHostStatus = live.nasHostStatus
        for service in [Service.gemini, Service.gemini2, Service.gemini3] {
            if var usage = snapshot.services[service] {
                usage.nasHostStatus = live.services[service]?.nasHostStatus
                snapshot.services[service] = usage
            }
        }
        return PreparedSnapshot(snapshot: snapshot, cacheData: cacheData)
    }

    static func encodeSnapshotCache(document: [String: Any], isV2: Bool, lastKnown: Set<String>, origin: String) -> Data? {
        let wrapper: [String: Any] = [
            "cacheFormat": isV2 ? snapshotV2Format : snapshotLegacyFormat,
            "snapshot": document,
            "lastKnown": lastKnown.sorted(),
            "baseURLOrigin": origin
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper), data.count <= maxSnapshotCacheBytes else { return nil }
        return data
    }

    static func decodeSnapshotCache(_ data: Data, origin: String) -> CachedSnapshot? {
        guard data.count <= maxSnapshotCacheBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["baseURLOrigin"] as? String == origin else { return nil }
        let document: [String: Any]
        let isV2: Bool
        if object["cacheFormat"] == nil {
            // Written by 0.2.x before formats were named: legacy only.
            guard let report = object["report"] as? [String: Any] else { return nil }
            document = ["report": report]
            isV2 = false
        } else if let format = object["cacheFormat"] as? String,
                  format == snapshotV2Format || format == snapshotLegacyFormat,
                  let stored = object["snapshot"] as? [String: Any] {
            document = stored
            isV2 = format == snapshotV2Format
        } else {
            return nil
        }
        guard let documentData = try? JSONSerialization.data(withJSONObject: document) else { return nil }
        let parsed = isV2 ? try? UsageSnapshot.parseNASv2(documentData) : try? UsageSnapshot.parseNAS(documentData)
        guard let parsed else { return nil }
        let lastKnown = Set((object["lastKnown"] as? [String] ?? []).filter { UsageSnapshot.v2RequiredIdentity.keys.contains($0) })
        return CachedSnapshot(snapshot: parsed.markingLastKnown(lastKnown).markingNASHostStatusCached(), isV2: isV2, document: document, lastKnown: lastKnown)
    }

    // MARK: - History cache

    static func encodeHistoryCache(_ reading: NASConsumptionHistory, origin: String) -> Data? {
        let wrapper: [String: Any]
        switch reading.schemaVersion {
        case 3:
            guard let document = reading.v3ContractDocument() else { return nil }
            wrapper = ["cacheFormat": historyV3Format, "document": document, "baseURLOrigin": origin]
        case 2:
            guard let document = reading.v2ContractDocument() else { return nil }
            wrapper = ["cacheFormat": historyV2Format, "document": document, "baseURLOrigin": origin]
        case 1:
            guard let document = reading.v1ContractDocument() else { return nil }
            wrapper = ["cacheFormat": historyV1Format, "history": document, "baseURLOrigin": origin]
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: wrapper)
    }

    static func decodeHistoryCache(_ data: Data, origin: String, now: Date = Date()) -> NASConsumptionHistory? {
        guard data.count <= UsageSnapshot.nasHistoryV2MaxBytes * 2,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["baseURLOrigin"] as? String == origin else { return nil }
        if object["cacheFormat"] == nil {
            // 0.2.x cache: `{history: <v1 contract>, baseURLOrigin}`.
            guard let history = object["history"] as? [String: Any] else { return nil }
            return UsageSnapshot.parseNASConsumptionHistory(history, now: now)
        }
        switch object["cacheFormat"] as? String {
        case historyV1Format:
            guard let history = object["history"] as? [String: Any] else { return nil }
            return UsageSnapshot.parseNASConsumptionHistory(history, now: now)
        case historyV2Format:
            guard let document = object["document"] as? [String: Any] else { return nil }
            return try? UsageSnapshot.decodeNASConsumptionHistoryV2(document, now: now)
        case historyV3Format:
            guard let document = object["document"] as? [String: Any] else { return nil }
            return try? UsageSnapshot.decodeNASConsumptionHistoryV3(document, now: now)
        default:
            return nil
        }
    }
}
