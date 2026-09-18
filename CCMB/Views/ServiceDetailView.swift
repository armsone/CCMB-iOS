import SwiftUI

/// Everything the snapshot knows about one service, grouped into small
/// sections. Values the file did not carry show as "정보 없음" instead of
/// disappearing, so the screen shape stays predictable.
struct ServiceDetailView: View {
    let usage: ServiceUsage

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
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if usage.creditBalance != nil || usage.monthlyUsedCredits != nil {
                Section("크레딧") {
                    if let label = usage.creditLabel {
                        LabeledContent(label, value: CCMBFormat.credits(usage.creditBalance))
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
                if let status = usage.status {
                    LabeledContent("상태", value: statusDescription(status))
                }
                Text("이 값은 Mac의 CCMB가 기록한 스냅샷(iCloud 또는 파일)에서 읽은 것입니다. iPhone에서 직접 조회한 값이 아닙니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(usage.service.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
