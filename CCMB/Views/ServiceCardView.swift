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

    private var columns: [GridItem] {
        let creditColumn = usage.service == .codex && usage.creditBalance != nil ? 1 : 0
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
                            label: window.label,
                            unavailableLabel: window.unavailabilityNote,
                            tint: CCMBTheme.serviceTint(usage.service, windowID: window.id),
                            animationTrigger: store.lastReadAt
                        )
                    }
                    if usage.service == .codex, let credit = usage.creditBalance {
                        CCMBCreditMetric(
                            value: credit,
                            spentLast30Minutes: store.codexCreditsSpentLast30Minutes,
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

    private func refreshStatus(now: Date) -> String {
        let remaining = max(0, store.nextAutomaticRefreshAt?.timeIntervalSince(now) ?? 0)
        return "\(CCMBFormat.relativeAge(usage.fetchedAt, now: now)) · 다음 갱신 \(Int(ceil(remaining)))초"
    }

    private var accessibilitySummary: String {
        var parts = [usage.service.displayName]
        for window in displayedWindows {
            if let note = window.unavailabilityNote {
                parts.append("\(window.label) \(note)")
            } else if window.remainingPercent != nil {
                parts.append("\(window.label) 남음 \(CCMBFormat.percent(window.remainingPercent))")
            }
        }
        if let credit = usage.creditBalance {
            parts.append("크레딧 \(CCMBFormat.credits(credit))")
        }
        parts.append("가져온 시각 \(CCMBFormat.relativeAge(usage.fetchedAt))")
        return parts.joined(separator: ", ")
    }
}

struct CCMBCreditMetric: View {
    let value: Double
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
                    Text(CCMBFormat.credits(value))
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 4)
                        .monospacedDigit()
                    Text(spendText)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 3)
                }
            }
            .frame(width: 64, height: 64)

            Text("크레딧")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var spendText: String {
        guard let spentLast30Minutes else { return "30분 집계 중" }
        return "30분 -\(CCMBFormat.credits(spentLast30Minutes))"
    }
}

struct CCMBRingGauge: View {
    let value: Double?
    let label: String
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
                Text(value == nil ? "—" : "\(Int(displayedValue.rounded()))")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .frame(width: 36)
                    .monospacedDigit()
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 1) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if value == nil, let unavailableLabel {
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
