import Foundation
import CoreFoundation

/// Host status reported by NAS v2 execution host backend.
public struct NASExecutionHost: Equatable, Sendable {
    public let hostId: String
    public let runId: String?
    public let executionAccount: String?
    public let phase: String
    public let stateChangedAt: Date?
    public let lastHeartbeatAt: Date?
    public let returnState: String?

    public init(
        hostId: String,
        runId: String? = nil,
        executionAccount: String? = nil,
        phase: String,
        stateChangedAt: Date? = nil,
        lastHeartbeatAt: Date? = nil,
        returnState: String? = nil
    ) {
        self.hostId = hostId
        self.runId = runId
        self.executionAccount = executionAccount
        self.phase = phase
        self.stateChangedAt = stateChangedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.returnState = returnState
    }
}

public struct NASHostStatus: Equatable, Sendable {
    public let hosts: [NASExecutionHost]
    public let autoSwitchEnabled: Bool?
    public var isCached: Bool

    public init(
        hosts: [NASExecutionHost],
        autoSwitchEnabled: Bool? = nil,
        isCached: Bool = false
    ) {
        self.hosts = hosts
        self.autoSwitchEnabled = autoSwitchEnabled
        self.isCached = isCached
    }

    private static let maxHosts = 8
    private static let maxIdLength = 64

    private static let canonicalReturnStates: Set<String> = [
        "pending", "confirmed", "not_required", "failed"
    ]

    private static let knownUppercasePhases: [String: String] = [
        "RUNNING": "running",
        "PREPARED": "prepared",
        "READY": "ready",
        "FINISHING": "finishing",
        "COMMITTED": "committed",
        "REJECTED": "rejected",
        "ABORTED": "aborted"
    ]

    private static let knownLowercasePhases: Set<String> = [
        "idle", "running", "active", "prepared", "ready", "finishing", "committed", "rejected", "aborted", "waiting"
    ]

    public static func isValidIdentifier(_ str: String) -> Bool {
        guard !str.isEmpty, str.count <= maxIdLength else { return false }
        for scalar in str.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, // 0-9
                 0x41...0x5A, // A-Z
                 0x61...0x7A, // a-z
                 0x2D, // '-'
                 0x2E, // '.'
                 0x3A, // ':'
                 0x5F: // '_'
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func strictJsonBool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        let ref = value as AnyObject
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean))
        }
        return nil
    }

    private static func parseEpochSeconds(_ value: Any?) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        let ref = value as AnyObject
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return nil
        }
        if value is String {
            return nil
        }
        if let num = value as? NSNumber {
            let d = num.doubleValue
            guard d.isFinite, d > 0, d < 1e11, d <= Date().timeIntervalSince1970 + 60 else { return nil }
            return Date(timeIntervalSince1970: d)
        }
        return nil
    }

    public static func parse(
        executionHosts: Any?,
        autoSwitchEnabled: Any?,
        autoSwitchAvailable: Any? = nil
    ) -> NASHostStatus? {
        // Resolve autoSwitchEnabled with strict boolean semantics
        let resolvedAutoSwitch: Bool?
        if let avail = autoSwitchAvailable, !(avail is NSNull) {
            if let isAvail = strictJsonBool(avail) {
                if isAvail {
                    resolvedAutoSwitch = strictJsonBool(autoSwitchEnabled)
                } else {
                    resolvedAutoSwitch = nil
                }
            } else {
                // available invalid => unknown, not false 'off'
                resolvedAutoSwitch = nil
            }
        } else {
            // available absent => use genuine enabled bool | null
            resolvedAutoSwitch = strictJsonBool(autoSwitchEnabled)
        }

        guard let rawList = executionHosts, !(rawList is NSNull) else {
            if resolvedAutoSwitch != nil {
                return NASHostStatus(hosts: [], autoSwitchEnabled: resolvedAutoSwitch)
            }
            return nil
        }

        guard let hostArray = rawList as? [Any] else {
            if resolvedAutoSwitch != nil {
                return NASHostStatus(hosts: [], autoSwitchEnabled: resolvedAutoSwitch)
            }
            return nil
        }

        var parsedHosts: [NASExecutionHost] = []
        for rawElement in hostArray {
            guard parsedHosts.count < maxHosts else { break }
            guard let rawHost = rawElement as? [String: Any] else {
                continue
            }

            guard let hostIdRaw = rawHost["host_id"] as? String,
                  isValidIdentifier(hostIdRaw) else {
                continue
            }

            var runId: String? = nil
            if let r = rawHost["run_id"], !(r is NSNull) {
                guard let rStr = r as? String, isValidIdentifier(rStr) else { continue }
                runId = rStr
            }

            var executionAccount: String? = nil
            if let a = rawHost["execution_account"], !(a is NSNull) {
                guard let aStr = a as? String,
                      (aStr == "account1" || aStr == "account2" || aStr == "account3") else {
                    continue
                }
                executionAccount = aStr
            }

            guard let rawPhase = rawHost["phase"] as? String else { continue }
            let normalizedPhase: String
            if let mapped = knownUppercasePhases[rawPhase] {
                normalizedPhase = mapped
            } else if knownLowercasePhases.contains(rawPhase) {
                normalizedPhase = rawPhase
            } else {
                continue
            }

            // Phase and account validation:
            // running / active MUST have valid account (account1 | account2)
            let isRunning = normalizedPhase == "running" || normalizedPhase == "active"
            if isRunning {
                guard executionAccount != nil else { continue }
            }

            var returnState: String? = nil
            if let ret = rawHost["return_state"], !(ret is NSNull) {
                guard let retStr = ret as? String,
                      canonicalReturnStates.contains(retStr) else {
                    continue
                }
                returnState = retStr
            }

            var stateChangedAt: Date? = nil
            if let sc = rawHost["state_changed_at"], !(sc is NSNull) {
                guard let d = parseEpochSeconds(sc) else { continue }
                stateChangedAt = d
            }

            var lastHeartbeatAt: Date? = nil
            if let hb = rawHost["last_heartbeat_at"], !(hb is NSNull) {
                guard let d = parseEpochSeconds(hb) else { continue }
                lastHeartbeatAt = d
            }

            if parsedHosts.contains(where: { $0.hostId == hostIdRaw }) {
                continue
            }

            parsedHosts.append(NASExecutionHost(
                hostId: hostIdRaw,
                runId: runId,
                executionAccount: executionAccount,
                phase: normalizedPhase,
                stateChangedAt: stateChangedAt,
                lastHeartbeatAt: lastHeartbeatAt,
                returnState: returnState
            ))
        }

        return NASHostStatus(hosts: parsedHosts, autoSwitchEnabled: resolvedAutoSwitch)
    }

    public func jsonObject() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let autoSwitchEnabled {
            dict["auto_switch_enabled"] = autoSwitchEnabled
        } else {
            dict["auto_switch_enabled"] = NSNull()
        }

        let hostList: [[String: Any]] = hosts.map { host in
            var h: [String: Any] = [
                "host_id": host.hostId,
                "phase": host.phase
            ]
            if let runId = host.runId {
                h["run_id"] = runId
            } else {
                h["run_id"] = NSNull()
            }
            if let acct = host.executionAccount {
                h["execution_account"] = acct
            } else {
                h["execution_account"] = NSNull()
            }
            if let sc = host.stateChangedAt {
                h["state_changed_at"] = sc.timeIntervalSince1970
            } else {
                h["state_changed_at"] = NSNull()
            }
            if let hb = host.lastHeartbeatAt {
                h["last_heartbeat_at"] = hb.timeIntervalSince1970
            } else {
                h["last_heartbeat_at"] = NSNull()
            }
            if let rs = host.returnState {
                h["return_state"] = rs
            } else {
                h["return_state"] = NSNull()
            }
            return h
        }
        dict["execution_hosts"] = hostList
        return dict
    }

    public static func returnStateKorean(_ state: String) -> String {
        switch state {
        case "pending": return "복귀확인대기"
        case "confirmed": return "복귀확인됨"
        case "not_required": return "복귀불필요"
        case "failed": return "복귀확인실패"
        default: return state
        }
    }

    private static func isAccountMatch(_ accountValue: String?, target: String) -> Bool {
        guard let accountValue,
              (accountValue == "account1" || accountValue == "account2" || accountValue == "account3"),
              (target == "account1" || target == "account2" || target == "account3") else {
            return false
        }
        return accountValue == target
    }

    private static func isOppositeAccount(_ accountValue: String?, current: String) -> Bool {
        guard let accountValue,
              (accountValue == "account1" || accountValue == "account2" || accountValue == "account3"),
              (current == "account1" || current == "account2" || current == "account3") else {
            return false
        }
        return accountValue != current
    }

    public func footerLines(accountRef: String, isCached: Bool = false) -> [String] {
        var lines: [String] = []
        let cachePrefix = isCached ? "[캐시] " : ""

        // Check running hosts for this account vs opposite account vs idle
        var myRunningHosts: [NASExecutionHost] = []
        var oppositeRunningHosts: [NASExecutionHost] = []
        var idleHosts: [NASExecutionHost] = []
        var otherPhaseHosts: [NASExecutionHost] = []

        for host in hosts {
            let isRun = host.phase == "running" || host.phase == "active"
            if isRun {
                if Self.isAccountMatch(host.executionAccount, target: accountRef) {
                    myRunningHosts.append(host)
                } else if Self.isOppositeAccount(host.executionAccount, current: accountRef) {
                    oppositeRunningHosts.append(host)
                }
            } else if host.phase == "idle" {
                idleHosts.append(host)
            } else {
                if Self.isAccountMatch(host.executionAccount, target: accountRef) || host.executionAccount == nil {
                    otherPhaseHosts.append(host)
                }
            }
        }

        for h in myRunningHosts {
            var desc = "\(cachePrefix)호스트 \(h.hostId): 실행중"
            if let rs = h.returnState {
                desc += " (\(Self.returnStateKorean(rs)))"
            }
            lines.append(desc)
        }

        // For opposite account running, label which account is running
        for h in oppositeRunningHosts {
            let acctLabel: String
            switch h.executionAccount {
            case "account1": acctLabel = "주계정 실행중"
            case "account2": acctLabel = "부계정 실행중"
            case "account3": acctLabel = "세 번째 계정 실행중"
            default: acctLabel = "다른 계정 실행중"
            }
            var desc = "\(cachePrefix)호스트 \(h.hostId): \(acctLabel)"
            if let rs = h.returnState {
                desc += " (\(Self.returnStateKorean(rs)))"
            }
            lines.append(desc)
        }

        for h in otherPhaseHosts {
            let phaseKorean: String
            switch h.phase {
            case "prepared": phaseKorean = "준비완료"
            case "ready": phaseKorean = "준비"
            case "finishing": phaseKorean = "마무리중"
            case "committed": phaseKorean = "최근사용"
            case "rejected": phaseKorean = "거부됨"
            case "aborted": phaseKorean = "중단됨"
            case "waiting": phaseKorean = "대기"
            default: phaseKorean = h.phase
            }
            var desc = "\(cachePrefix)호스트 \(h.hostId): \(phaseKorean)"
            if let rs = h.returnState {
                desc += " (\(Self.returnStateKorean(rs)))"
            }
            lines.append(desc)
        }

        for h in idleHosts {
            var desc = "\(cachePrefix)호스트 \(h.hostId): 대기"
            if let rs = h.returnState {
                desc += " (\(Self.returnStateKorean(rs)))"
            }
            lines.append(desc)
        }

        // Auto switch line
        let autoLine: String
        if let autoSwitch = autoSwitchEnabled {
            autoLine = "\(cachePrefix)자동전환: \(autoSwitch ? "켜짐" : "꺼짐")"
        } else {
            autoLine = "\(cachePrefix)자동전환: 정보 없음"
        }
        lines.append(autoLine)

        return lines
    }
}
