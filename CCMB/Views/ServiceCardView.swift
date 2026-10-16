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

    private var sharedClaudeWeeklyReset: Date? {
        guard usage.service == .claude,
              let fable = usage.windows.first(where: { $0.id == "fableWeekly" })?.resetsAt,
              let weekly = usage.windows.first(where: { $0.id == "weekly" })?.resetsAt,
              fable == weekly else { return nil }
        return weekly
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: serviceSymbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(usage.service.displayName)
                    .font(.headline)
                    .foregroundStyle(tint)
                if let plan = usage.planTitle {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isBusy {
                    tagText("갱신 중")
                }
                statusTag
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CCMBFormat.relativeAge(usage.fetchedAt, now: context.date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if usage.hasAnyData {
                if let sharedReset = sharedClaudeWeeklyReset {
                    Grid(horizontalSpacing: 8, verticalSpacing: 2) {
                        GridRow {
                            ForEach(displayedWindows) { window in
                                CCMBRingGauge(
                                    value: window.remainingPercent,
                                    label: displayLabel(for: window),
                                    unavailableLabel: visibleNoteText(for: window),
                                    tint: CCMBTheme.serviceTint(usage.service, windowID: window.id),
                                    animationTrigger: store.lastReadAt
                                )
                                .frame(maxWidth: .infinity)
                            }
                        }
                        GridRow {
                            Text(CCMBFormat.resetTime(usage.windows.first(where: { $0.id == "fiveHour" })?.resetsAt))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Text(CCMBFormat.resetTime(sharedReset))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .gridCellColumns(2)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(displayedWindows) { window in
                        VStack(spacing: 2) {
                        CCMBRingGauge(
                            value: window.remainingPercent,
                            label: displayLabel(for: window),
                            showLabel: usage.service != .codex,
                            unavailableLabel: visibleNoteText(for: window),
                            tint: CCMBTheme.serviceTint(usage.service, windowID: window.id),
                            animationTrigger: store.lastReadAt
                        )
                            Text(CCMBFormat.resetTime(window.resetsAt))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
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
                Text(store.displayedSource == .nas
                     ? "정보 없음 — NAS에서 이 계정의 값을 아직 받지 못했습니다."
                     : "정보 없음 — Mac의 CCMB에서 이 서비스가 켜져 있는지 확인하세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let serviceNotice {
                Text(serviceNotice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let accountLine {
                Text(accountLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            resetMetaView
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("자세한 내용을 보려면 여세요.")
    }

    private var isBusy: Bool {
        store.displayedSource == .nas && store.nasRefreshBusy && usage.service != .grok
    }

    /// Why this card's values are old or missing: a preserved last good
    /// reading or stale value with its original collection time, and the
    /// NAS's structured reason.
    private var serviceNotice: String? {
        var parts: [String] = []
        if usage.isLastKnown {
            parts.append("마지막 정상값")
        } else if usage.status == "stale", usage.hasAnyData {
            parts.append("오래된 값")
        }
        if usage.isLastKnown || usage.status == "stale", let fetchedAt = usage.fetchedAt {
            parts.append("원본 \(CCMBFormat.macCollectionTime(fetchedAt)) 조회")
        }
        if let reason = usage.errorReason {
            parts.append(reason)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The NAS's actual `account_display` (display only: a trailing Gmail
    /// domain is dropped, the stored value itself is untouched).
    private var accountLine: String? {
        guard usage.service != .codex, usage.service != .claude,
              let display = usage.accountDisplay, !display.isEmpty else { return nil }
        let stripped = display.hasSuffix("@gmail.com") ? String(display.dropLast("@gmail.com".count)) : display
        return "계정 \(stripped)"
    }

    /// Codex's confirmed reset-voucher count/expiries and Claude's confirmed
    /// limit-reset grant count/expiry, kept on one compact line.
    @ViewBuilder
    private var resetMetaView: some View {
        switch usage.service {
        case .codex:
            if let count = usage.codexResetCreditsAvailable {
                HStack {
                    Text("초기화").foregroundStyle(.secondary)
                    Text("\(count)개").fontWeight(.semibold).monospacedDigit().foregroundStyle(.tertiary)
                    if !usage.codexResetCreditExpirations.isEmpty {
                        Text(usage.codexResetCreditExpirations.sorted().map {
                            CCMBFormat.resetTime($0)
                        }.joined(separator: " · "))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
            }
        case .claude:
            if let count = usage.claudeLimitResetsCount {
                HStack {
                    Text("초기화").foregroundStyle(.secondary)
                    Text("\(count)개").fontWeight(.semibold).monospacedDigit().foregroundStyle(.tertiary)
                    if let expiresAt = usage.claudeLimitResetsExpiresAt {
                        Text(CCMBFormat.resetTime(expiresAt))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
            }
        default:
            EmptyView()
        }
    }

    private var serviceSymbol: String {
        switch usage.service {
        case .codex: return "sparkles"
        case .claude: return "sun.max.fill"
        case .gemini: return "diamond.fill"
        case .gemini2: return "diamond.lefthalf.filled"
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

    private var accessibilitySummary: String {
        let serviceName = (store.displayedSource == .nas && usage.service == .gemini) ? "Gemini 본계정" : usage.service.displayName
        var parts = [serviceName]
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
        if isBusy { parts.append("갱신 중") }
        if let serviceNotice { parts.append(serviceNotice) }
        return parts.joined(separator: ", ")
    }
}

/// Combines the NAS gemini(account1)/gemini2(account2) entries into a single
/// first-page Gemini section: primary 세션/주간 then secondary 세션/주간, no
/// Gemini AI-credit UI and no host/engine diagnostics. Primary plan title
/// only; the secondary account never repeats it.
struct GeminiCombinedCardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let primary: ServiceUsage
    let secondary: ServiceUsage?

    private var tint: Color { CCMBTheme.serviceTint(.gemini) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "diamond.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text("Gemini")
                    .font(.headline)
                    .foregroundStyle(tint)
                if let planTitle = primary.planTitle {
                    Text(planTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(CCMBFormat.relativeAge(primary.fetchedAt, now: context.date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let secondary {
                if dynamicTypeSize.isAccessibilitySize {
                    accountSection(label: "본계정", usage: primary)
                    accountSection(label: "부계정", usage: secondary)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        accountSection(label: "본계정", usage: primary)
                            .frame(maxWidth: .infinity)
                        accountSection(label: "부계정", usage: secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                accountSection(label: "본계정", usage: primary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func accountSection(label: String, usage: ServiceUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let account = accountName(usage) {
                    Text(account)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CCMBFormat.relativeAge(usage.fetchedAt, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if usage.isLastKnown || usage.stale || usage.status == "stale" || usage.errorReason != nil || usage.errorMessage != nil {
                Text([usage.isLastKnown ? "마지막 정상값" : (usage.stale || usage.status == "stale" ? "오래된 값" : nil),
                      usage.errorReason, usage.errorMessage].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if usage.hasAnyData {
                HStack(spacing: 8) {
                    ForEach(usage.windows) { window in
                        VStack(spacing: 2) {
                        CCMBRingGauge(
                            value: window.remainingPercent,
                            label: window.label,
                            unavailableLabel: window.unavailabilityNote,
                            tint: tint,
                            animationTrigger: store.lastReadAt
                        )
                            Text(CCMBFormat.resetTime(window.resetsAt))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.65)
                        }
                    }
                }
            } else {
                Text("정보 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountName(_ usage: ServiceUsage) -> String? {
        guard let display = usage.accountDisplay, !display.isEmpty else { return nil }
        return display.hasSuffix("@gmail.com") ? String(display.dropLast("@gmail.com".count)) : display
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
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            .frame(width: 48, height: 48)

            if showLabel {
                Text(label)
                    .font(.caption2.weight(.semibold))
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
        VStack(spacing: 4) {
            ZStack {
                // Same gauge anatomy as the macOS ring: a uniform halo of
                // radial ticks outside, a track and round-capped progress arc
                // inside, the arc starting at 6 o'clock and sweeping
                // counterclockwise on screen (the horizontal mirror flips
                // SwiftUI's native clockwise trim direction).
                ForEach(0..<36, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: 1, height: 2)
                        .offset(y: -22.5)
                        .rotationEffect(.degrees(Double(index) * 10))
                }
                Circle()
                    .inset(by: 6)
                    .stroke(tint.opacity(0.18), lineWidth: 5)
                Circle()
                    .inset(by: 6)
                    .trim(from: 0, to: displayedValue / 100)
                    .stroke(
                        value == nil ? Color.secondary.opacity(0.35) : tint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .scaleEffect(x: -1, y: 1)
                Text(value == nil ? "—" : String(format: "%.0f", displayedValue))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .frame(width: 32)
                    .monospacedDigit()
            }
            .frame(width: 48, height: 48)

            VStack(spacing: 1) {
                if showLabel {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
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
