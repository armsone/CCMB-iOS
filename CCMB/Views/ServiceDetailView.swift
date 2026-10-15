import SwiftUI

/// Everything the snapshot knows about one service, grouped into small
/// sections. Values the file did not carry show as "정보 없음" instead of
/// disappearing, so the screen shape stays predictable.
struct ServiceDetailView: View {
    let usage: ServiceUsage
    /// Whether this snapshot came from the home NAS rather than the Mac's
    /// iCloud/file snapshot; changes the Codex credit section's label and the
    /// footer's source explanation.
    var isNAS: Bool = false
    /// The NAS is still collecting while these stored values are shown.
    var isBusy: Bool = false

    private var isNASToken: Bool { isNAS && usage.service == .codex }

    var body: some View {
        List {
            Section("남은 사용량 · 초기화") {
                ForEach(detailWindows) { window in
                    if let note = window.unavailabilityNote {
                        LabeledContent(window.label, value: note)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("\(window.label) 남음", value: CCMBFormat.percent(window.remainingPercent))
                            ProgressView(value: (window.remainingPercent ?? 0) / 100)
                                .tint(CCMBTheme.gaugeTint(remainingPercent: window.remainingPercent))
                                .accessibilityHidden(true)
                            HStack {
                                Text("초기화")
                                Spacer()
                                Text(CCMBFormat.resetText(window.resetText) ?? CCMBFormat.resetTime(window.resetsAt))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let note = onlineCollectionNote(for: window) {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if usage.creditBalance != nil || usage.monthlyUsedCredits != nil || usage.creditUnlimited || isNASToken {
                Section(isNASToken ? "토큰" : "크레딧") {
                    if let label = usage.creditLabel ?? (isNASToken ? "남은 토큰" : nil) {
                        if usage.creditUnlimited {
                            LabeledContent(label, value: "무제한")
                        } else if usage.creditBalance != nil {
                            LabeledContent(label, value: CCMBFormat.credits(usage.creditBalance))
                        } else if isNASToken {
                            LabeledContent(label, value: "확인 불가")
                        }
                    }
                    if usage.monthlyUsedCredits != nil {
                        LabeledContent("이번 달 사용 크레딧", value: CCMBFormat.credits(usage.monthlyUsedCredits))
                    }
                }
            }

            if usage.account != nil || usage.organizationName != nil || usage.planTitle != nil || usage.model != nil {
                Section("계정과 요금제") {
                    if let account = usage.account {
                        LabeledContent("계정", value: account)
                    }
                    if let organization = usage.organizationName {
                        LabeledContent("조직", value: organization)
                    }
                    if let plan = usage.planTitle {
                        LabeledContent("요금제", value: plan)
                    }
                    if let model = usage.model {
                        LabeledContent("모델", value: model)
                    }
                }
            }

            if !usage.modelWeeklyLimits.isEmpty {
                Section("모델별 주간 한도") {
                    ForEach(usage.modelWeeklyLimits) { limit in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(limit.modelName, value: CCMBFormat.percent(limit.remainingPercent))
                            if let resetsAt = limit.resetsAt {
                                Text("초기화 \(CCMBFormat.resetTime(resetsAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("데이터 정보") {
                LabeledContent("가져온 시각", value: CCMBFormat.relativeAge(usage.fetchedAt))
                if let fetchedAt = usage.fetchedAt {
                    LabeledContent("원본 조회 시각", value: CCMBFormat.resetTime(fetchedAt))
                }
                if let status = usage.status {
                    LabeledContent("상태", value: statusDescription(status))
                }
                if let reason = usage.errorReason {
                    LabeledContent("사유", value: reason)
                }
                if usage.isLastKnown {
                    Text("최신 조회가 실패해 이 계정의 마지막 정상값을 원본 조회 시각과 함께 표시합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if isBusy {
                    Text("NAS가 지금 수집 중입니다. 끝나면 다음 새로 고침에 반영됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if isNAS {
                    ForEach(usage.executionStatusLines, id: \.self) {
                        Text($0)
                    }
                }
                Text(sourceExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if usage.service == .gemini || usage.service == .gemini2, isNAS {
                    Text("C세션/C주간은 NAS가 Gemini CLI에서 직접 조회한 값입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if usage.service == .gemini2 {
                    Text("Gemini 부계정은 본계정이 1% 이하로 부족할 때만 예비로 쓰이며, 카드의 계정 신원은 고정입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle((isNAS && usage.service == .gemini) ? "Gemini 본계정" : usage.service.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceExplanation: String {
        guard isNAS else {
            return "이 값은 Mac의 CCMB가 기록한 스냅샷(iCloud 또는 파일)에서 읽은 것입니다. iPhone에서 직접 조회한 값이 아닙니다."
        }
        let base = "이 값은 NAS에서 직접 조회한 실시간 사용량입니다."
        guard isNASToken else { return base }
        return base + " 토큰 잔액은 플레이그라운드가 보고하는 잔액이며, 입력/출력 토큰 소비량이 아닙니다."
    }

    /// Gemini's online windows are Mac-collected (via the Gemini web
    /// session) and relayed through NAS storage, a different path and time
    /// than the surrounding Gemini CLI/NAS reading — this must stay visible
    /// even when the CLI data on screen is fresh.
    private func onlineCollectionNote(for window: UsageWindow) -> String? {
        guard window.id.hasPrefix("online"), let fetchedAt = window.fetchedAt else { return nil }
        let isStale = Date().timeIntervalSince(fetchedAt) > UsageSnapshot.staleAfterSeconds
        let prefix = isStale ? "오래된 값" : "온라인"
        return "\(prefix) · Mac 수집 \(CCMBFormat.resetTime(fetchedAt)) · NAS 저장"
    }

    private var detailWindows: [UsageWindow] {
        usage.windows.filter { window in
            !(usage.service == .codex && window.id == "session" && window.remainingPercent == nil)
        }
    }

    private func statusDescription(_ status: String) -> String {
        switch status {
        case "ok": return "정상"
        case "partial": return "일부 값만 있음"
        case "stale": return "저장 당시에도 오래된 값"
        case "unavailable": return "저장 당시 정보 없음"
        default: return status
        }
    }
}
