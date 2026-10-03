import SwiftUI

struct ServiceCardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let usage: ServiceUsage

    private var tint: Color {
        CCMBTheme.serviceTint(usage.service)
    }

    private var displayedWindows: [UsageWindow] {
        if usage.service == .codex {
            return ["weekly"].compactMap { id in usage.windows.first { $0.id == id } }
        }
        return usage.windows
    }

    /// NAS 소스의 Codex는 값이 없어도("확인 불가") 토큰 칸을 고정으로 보여 준다;
    /// Mac 소스는 기존처럼 실제 크레딧 값이 있을 때만 칸이 나타난다.
    private var showsCodexCreditMetric: Bool {
        guard usage.service == .codex else { return false }
        return usage.creditBalance != nil || usage.creditUnlimited || store.displayedSource == .nas
    }

    private func displayLabel(for window: UsageWindow) -> String {
        guard usage.service == .claude else { return window.label }
        switch window.id {
        case "fiveHour": return "세션"
        case "fableWeekly": return "페블"
        case "weekly": return "주간"
        default: return window.label
        }
    }

    private var codexCreditMetricLabel: String {
        store.displayedSource == .nas ? "토큰" : "크레딧"
    }

    private var columns: [GridItem] {
        let creditColumn = showsCodexCreditMetric ? 1 : 0
        return Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: max(1, displayedWindows.count + creditColumn)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: serviceSymbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(usage.service.displayName)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                statusTag
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(refreshStatus(now: context.date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if usage.hasAnyData {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(displayedWindows) { window in
                        CCMBRingGauge(
                            value: window.remainingPercent,
                            label: displayLabel(for: window),
                            showLabel: usage.service != .codex,
                            unavailableLabel: visibleNoteText(for: window),
                            tint: CCMBTheme.serviceTint(usage.service, windowID: window.id),
                            animationTrigger: store.lastReadAt
                        )
                    }
                    if showsCodexCreditMetric {
                        CCMBCreditMetric(
                            value: usage.creditBalance,
                            unlimited: usage.creditUnlimited,
                            label: codexCreditMetricLabel,
                            showLabel: codexCreditMetricLabel != "토큰",
                            floorDisplay: store.displayedSource == .nas,
                            // NAS never reports credit spend history; if the
                            // displayed snapshot is NAS data (even while
                            // `preferredSource` has since moved on, e.g. a
                            // failed iCloud switch), this must not show a
                            // stale Mac-sourced spend figure.
                            spentLast30Minutes: store.displayedSource == .nas ? nil : store.codexCreditsSpentLast30Minutes,
                            tint: tint
                        )
                    }
                }

                if usage.service != .codex,
                   let credit = usage.creditBalance,
                   let label = usage.creditLabel {
                    HStack {
                        Text(label).foregroundStyle(.secondary)
                        Spacer()
                        Text(CCMBFormat.credits(credit))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            } else {
                Text("정보 없음 — Mac의 CCMB에서 이 서비스가 켜져 있는지 확인하세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("자세한 내용을 보려면 여세요.")
    }

    private var serviceSymbol: String {
        switch usage.service {
        case .codex: return "sparkles"
        case .claude: return "sun.max.fill"
        case .gemini: return "diamond.fill"
        case .grok: return "bolt.fill"
        }
    }

    private var statusTag: some View {
        Group {
            switch usage.status {
            case "ok": EmptyView()
            case "partial": tagText("일부만")
            case "stale": tagText("오래됨")
            case "unavailable", nil: tagText("정보 없음")
            default: tagText(usage.status ?? "")
            }
        }
    }

    private func tagText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// Online Gemini windows (Mac-collected, NAS-stored) show their own
    /// collection time here instead of the generic "미제공"/empty note, so a
    /// fresh CLI reading can never make an actually-old online reading look
    /// current, and a missing relay file stays visibly distinct from a
    /// genuine value.
    private func noteText(for window: UsageWindow) -> String? {
        guard window.id.hasPrefix("online"), let fetchedAt = window.fetchedAt else {
            // No reading has ever landed for this window, so the small
            // actionable relay-fetch issue (if any) is the more useful
            // thing to show than the generic waiting placeholder. Once a
            // reading does exist, the branch below always takes over and
            // this issue label never hides it.
            if window.id.hasPrefix("online"), let issue = store.geminiOnlineIssue {
                return issue
            }
            return window.unavailabilityNote
        }
        let age = CCMBFormat.relativeAge(fetchedAt)
        let isStale = Date().timeIntervalSince(fetchedAt) > UsageSnapshot.staleAfterSeconds
        // The relayed reading only ever actually lives on the NAS when this
        // card is itself showing NAS-sourced data; a Mac-sourced online
        // window must never claim "NAS 저장" for what is really its own
        // freshly-collected value.
        if store.displayedSource == .nas, let issue = store.geminiOnlineIssue {
            return "마지막 저장값 · \(issue) · Mac 수집 \(age)"
        }
        if isStale {
            return "오래된 값 · Mac 수집 \(age)"
        }
        return store.displayedSource == .nas ? "온라인 · Mac 수집 \(age) · NAS 저장" : "온라인 · Mac 수집 \(age)"
    }

    /// Same as `noteText`, but drops the plain collection/origin annotation
    /// under the ONLINE gauges on the card itself (both the fresh "온라인 ·
    /// Mac 수집 ... NAS 저장" line and the stale "오래된 값" variant); VoiceOver
    /// and detail screens still get the full `noteText` with its timestamp,
    /// and a genuine relay-fetch issue still surfaces here.
    private func visibleNoteText(for window: UsageWindow) -> String? {
        guard window.id.hasPrefix("online"), window.fetchedAt != nil else {
            return noteText(for: window)
        }
        let full = noteText(for: window)
        if full?.hasPrefix("마지막 저장값") == true {
            return full
        }
        return nil
    }

    private func refreshStatus(now: Date) -> String {
        let remaining = max(0, store.nextAutomaticRefreshAt?.timeIntervalSince(now) ?? 0)
        return "\(CCMBFormat.relativeAge(usage.fetchedAt, now: now)) · 다음 갱신 \(Int(ceil(remaining)))초"
    }

    private var accessibilitySummary: String {
        var parts = [usage.service.displayName]
        for window in displayedWindows {
            if window.remainingPercent != nil {
                var entry = "\(displayLabel(for: window)) 남음 \(CCMBFormat.percent(window.remainingPercent))"
                if let note = noteText(for: window) { entry += ", \(note)" }
                parts.append(entry)
            } else if let note = window.unavailabilityNote {
                parts.append("\(displayLabel(for: window)) \(note)")
            }
        }
        if showsCodexCreditMetric {
            if usage.creditUnlimited {
                parts.append("\(codexCreditMetricLabel) 무제한")
            } else if let credit = usage.creditBalance {
                parts.append("\(codexCreditMetricLabel) \(CCMBFormat.credits(credit))")
            } else {
                parts.append("\(codexCreditMetricLabel) 확인 불가")
            }
        } else if let credit = usage.creditBalance {
            parts.append("크레딧 \(CCMBFormat.credits(credit))")
        }
        parts.append("가져온 시각 \(CCMBFormat.relativeAge(usage.fetchedAt))")
        return parts.joined(separator: ", ")
    }
}

struct CCMBCreditMetric: View {
    let value: Double?
    var unlimited: Bool = false
    var label: String = "크레딧"
    var showLabel: Bool = true
    /// NAS의 '토큰' 표기는 NAS 프런트엔드처럼 내림(floor) 정수로 보여 준다;
    /// Mac의 크레딧 값은 기존 반올림 표기를 그대로 유지한다.
    var floorDisplay: Bool = false
    let spentLast30Minutes: Double?
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 2)
                VStack(spacing: 1) {
                    Image(systemName: "creditcard.fill")
                        .font(.caption2)
                        .foregroundStyle(tint)
                    Text(valueText)
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 4)
                        .monospacedDigit()
                    if let spendText {
                        Text(spendText)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 3)
                    }
                }
            }
            .frame(width: 64, height: 64)

            if showLabel {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var valueText: String {
        if unlimited { return "무제한" }
        guard let value else { return "확인 불가" }
        guard floorDisplay else { return CCMBFormat.credits(value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: floor(value))) ?? CCMBFormat.credits(value)
    }

    private var spendText: String? {
        guard let spentLast30Minutes else { return nil }
        return "30분 -\(CCMBFormat.credits(spentLast30Minutes))"
    }
}

struct CCMBRingGauge: View {
    let value: Double?
    let label: String
    var showLabel: Bool = true
    let unavailableLabel: String?
    let tint: Color
    let animationTrigger: Date?

    @State private var displayedValue: Double = 0
    @State private var animationTask: Task<Void, Never>?

    private var clampedValue: Double { min(100, max(0, value ?? 0)) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                // Same gauge anatomy as the macOS ring: a uniform halo of
                // radial ticks outside, a track and round-capped progress arc
                // inside, the arc starting at 6 o'clock and sweeping
                // counterclockwise on screen (the horizontal mirror flips
                // SwiftUI's native clockwise trim direction).
                ForEach(0..<36, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: 1, height: 3)
                        .offset(y: -30.5)
                        .rotationEffect(.degrees(Double(index) * 10))
                }
                Circle()
                    .inset(by: 8)
                    .stroke(tint.opacity(0.18), lineWidth: 7)
                Circle()
                    .inset(by: 8)
                    .trim(from: 0, to: displayedValue / 100)
                    .stroke(
                        value == nil ? Color.secondary.opacity(0.35) : tint,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .scaleEffect(x: -1, y: 1)
                Text(value == nil ? "—" : String(format: "%.1f", displayedValue))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .frame(width: 44)
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 1) {
                if showLabel {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let unavailableLabel {
                    Text(unavailableLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear(perform: playEntranceAnimation)
        .onChange(of: animationTrigger) { _, _ in
            playEntranceAnimation()
        }
        .onDisappear {
            animationTask?.cancel()
        }
    }

    private func playEntranceAnimation() {
        animationTask?.cancel()
        displayedValue = value == nil ? 0 : 100
        guard value != nil else { return }
        let target = clampedValue
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                displayedValue = 0
            }
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.65, bounce: 0.18)) {
                displayedValue = target
            }
        }
    }
}
