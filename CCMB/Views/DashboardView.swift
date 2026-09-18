import SwiftUI

/// Mobile-first comparison dashboard, not a copy of the Mac menu. The top
/// card answers the one question worth opening the app for — which limit
/// runs out first — followed by the three primary services and Grok as a
/// compact secondary card. Adapts from one column on iPhone to a grid on
/// iPad via `LazyVGrid`'s adaptive columns.
struct DashboardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let snapshot: UsageSnapshot
    let onPickFile: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 16)]
    private let primaryServices: [Service] = [.codex, .claude, .gemini]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let problem = store.refreshProblem {
                    banner(text: problem, isWarning: true)
                }
                if snapshot.isStale() {
                    banner(
                        text: "오래된 데이터입니다. Mac에서 CCMB가 실행 중이어야 새 값이 올라옵니다.",
                        isWarning: true
                    )
                } else if store.origin == .savedCopy {
                    banner(
                        text: "마지막으로 저장한 사본을 보여 주고 있습니다. 새로 고침하면 최신 값을 다시 불러옵니다.",
                        isWarning: false
                    )
                }

                AutomaticRefreshCard(focus: snapshot.focusLimit, onPickFile: onPickFile)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(primaryServices) { service in
                        if let usage = snapshot.services[service] {
                            NavigationLink {
                                ServiceDetailView(usage: usage)
                            } label: {
                                ServiceCardView(usage: usage)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                PassionSummaryCard(snapshot: snapshot)

                Text(footnoteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(appearanceStore.selection.background.ignoresSafeArea())
        .refreshable { store.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Menu {
                        ForEach(CCMBAppearance.allCases) { appearance in
                            Button {
                                appearanceStore.select(appearance)
                            } label: {
                                Label(
                                    appearance.name,
                                    systemImage: appearanceStore.selection == appearance ? "checkmark" : appearance.symbol
                                )
                            }
                        }
                    } label: {
                        Label("테마와 앱 아이콘", systemImage: "paintpalette.fill")
                    }
                    Button {
                        Task { await store.refreshFromCloud() }
                    } label: {
                        Label("iCloud에서 불러오기", systemImage: "icloud.and.arrow.down")
                    }
                    Button {
                        onPickFile()
                    } label: {
                        Label("Dropbox·Google Drive 파일 선택", systemImage: "folder")
                    }
                } label: {
                    Label("메뉴", systemImage: "line.3.horizontal")
                }
            }
        }
    }

    private var footnoteText: String {
        switch store.preferredSource {
        case .cloud:
            return "Mac CCMB가 iCloud를 통해 사용량을 갱신합니다."
        case .file:
            return "선택한 파일에서 사용량을 불러옵니다."
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(snapshot.isStale() ? CCMBTheme.signalRed : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Mac 수집 \(CCMBFormat.macCollectionTime(snapshot.newestFetchedAt))")
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func banner(text: String, isWarning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "clock.badge.exclamationmark" : "internaldrive")
                .foregroundStyle(isWarning ? CCMBTheme.signalRed : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct PassionSummaryCard: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("나의 AI 열정")
                    .font(.headline)
                Text("최근 40회 갱신 소비")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let history = snapshot.consumptionHistory {
                HStack(spacing: 0) {
                    ForEach(historyColumns(history)) { column in
                        VStack(spacing: 4) {
                            Text(column.caption)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            RefreshConsumptionBars(
                                series: column.series,
                                slotCount: history.slotCount
                            )
                            .frame(height: 56)
                        }
                        .frame(maxWidth: .infinity)
                        if column.service != .gemini {
                            Divider().padding(.horizontal, 5)
                        }
                    }
                }
            } else {
                Text("Mac CCMB가 다음 스냅샷을 올리면 세로형 기록 그래프가 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("나의 AI 열정, 최근 갱신별 소비 기록")
    }

    private func historyColumns(_ history: UsageConsumptionHistory) -> [ConsumptionHistoryColumn] {
        let codexUsesCredits = (snapshot.services[.codex]?.windows.first { $0.id == "weekly" }?.remainingPercent ?? 1) <= 0
            && (snapshot.services[.codex]?.creditBalance ?? 0) > 0
        let codexSeries = codexUsesCredits
            ? [ConsumptionHistorySeries(label: "크레딧", samples: history.codex, color: .mint)]
            : [ConsumptionHistorySeries(label: "주간", samples: history.codex, color: .mint)]
        let claudeSeries = [
            ConsumptionHistorySeries(label: "주간", samples: history.claude, color: .orange),
            ConsumptionHistorySeries(label: "Fable", samples: history.claudeFable, color: .red.opacity(0.7))
        ]
        let geminiSeries = [
            ConsumptionHistorySeries(label: "세션", samples: history.gemini, color: .blue)
        ]
        return [
            ConsumptionHistoryColumn(service: .codex, caption: caption(for: codexSeries, unit: codexUsesCredits ? " cr" : "%"), series: codexSeries),
            ConsumptionHistoryColumn(service: .claude, caption: caption(for: claudeSeries, unit: "%"), series: claudeSeries),
            ConsumptionHistoryColumn(service: .gemini, caption: caption(for: geminiSeries, unit: "%"), series: geminiSeries)
        ]
    }

    private func caption(for series: [ConsumptionHistorySeries], unit: String) -> String {
        let latestDate = series.flatMap(\.samples).map(\.at).max()
        let parts = series.compactMap { item -> String? in
            guard let latestDate,
                  let amount = item.samples.last(where: { $0.at == latestDate })?.amount else { return nil }
            return "\(item.label) \(amountTitle(amount))\(unit)"
        }
        return "갱신당 " + (parts.isEmpty ? "0\(unit)" : parts.joined(separator: " · "))
    }

    private func amountTitle(_ value: Double) -> String {
        let format = value > 0 && value < 0.01 ? "%.4f" : "%.2f"
        return String(format: format, value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

private struct ConsumptionHistoryColumn: Identifiable {
    let service: Service
    let caption: String
    let series: [ConsumptionHistorySeries]
    var id: Service { service }
}

private struct ConsumptionHistorySeries {
    let label: String
    let samples: [UsageConsumptionPoint]
    let color: Color
}

private struct RefreshConsumptionBars: View {
    let series: [ConsumptionHistorySeries]
    let slotCount: Int

    private var slots: [[Double?]] {
        let lookups = series.map { item in
            Dictionary(item.samples.map { ($0.at, $0.amount) }, uniquingKeysWith: { _, newest in newest })
        }
        let dates = Set(lookups.flatMap(\.keys)).sorted().suffix(slotCount).reversed()
        return dates.map { date in lookups.map { $0[date] } }
    }

    var body: some View {
        Canvas { context, size in
            let count = max(1, slotCount)
            let slotWidth = size.width / CGFloat(count)
            let barWidth = max(1, slotWidth - 1)
            let totals = slots.map { $0.compactMap { $0 }.reduce(0, +) }
            let peak = totals.max() ?? 0

            for index in 0..<count {
                let x = CGFloat(index) * slotWidth
                guard index < slots.count else {
                    context.fill(
                        Path(CGRect(x: x, y: size.height - 1, width: barWidth, height: 1)),
                        with: .color(.secondary.opacity(0.12))
                    )
                    continue
                }

                let amounts = slots[index]
                let total = totals[index]
                let fullHeight = peak > 0 ? max(1.5, size.height * total / peak) : 1.5
                var bottom = size.height
                for seriesIndex in amounts.indices {
                    guard let amount = amounts[seriesIndex] else { continue }
                    let height = total > 0 ? fullHeight * amount / total : (seriesIndex == 0 ? fullHeight : 0)
                    guard height > 0 else { continue }
                    bottom -= height
                    context.fill(
                        Path(CGRect(x: x, y: bottom, width: barWidth, height: height)),
                        with: .color(series[seriesIndex].color)
                    )
                }
            }

            context.fill(
                Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
                with: .color(.secondary.opacity(0.25))
            )
        }
    }
}

struct AutomaticRefreshCard: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let focus: UsageSnapshot.FocusLimit?
    let onPickFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                refreshBar(now: context.date)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(SnapshotStore.automaticRefreshOptions, id: \.self) { seconds in
                        Button {
                            store.setAutomaticRefreshInterval(seconds)
                        } label: {
                            if store.automaticRefreshInterval == seconds {
                                Label(intervalLabel(seconds), systemImage: "checkmark")
                            } else {
                                Text(intervalLabel(seconds))
                            }
                        }
                    }
                } label: {
                    settingRow(title: "주기", value: intervalLabel(store.automaticRefreshInterval))
                }
                .frame(width: 118)

                Menu {
                    Button {
                        Task { await store.refreshFromCloud() }
                    } label: {
                        Label("iCloud 개인 영역", systemImage: store.preferredSource == .cloud ? "checkmark.icloud" : "icloud")
                    }
                    if store.hasPickedFile {
                        Button {
                            store.usePickedFile()
                        } label: {
                            Label(
                                store.sourceFileName ?? "선택한 파일",
                                systemImage: store.preferredSource == .file ? "checkmark.circle" : "doc"
                            )
                        }
                    }
                    Divider()
                    Button(action: onPickFile) {
                        Label("Dropbox·Google Drive 파일 선택", systemImage: "folder.badge.plus")
                    }
                } label: {
                    settingRow(title: "불러올 곳", value: sourceLabel)
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            }

            if let focus {
                Divider()
                    .padding(.vertical, 2)
                FocusLimitCardView(focus: focus)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func refreshBar(now: Date) -> some View {
        let remaining = max(0, store.nextAutomaticRefreshAt?.timeIntervalSince(now) ?? 0)
        let progress = min(1, remaining / store.automaticRefreshInterval)
        return Button {
            store.refresh()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView(value: progress)
                    .tint(CCMBTheme.signalRed)
                    .accessibilityHidden(true)
                Text("\(Int(ceil(remaining)))초")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 42, alignment: .trailing)
                Image(systemName: "display")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("지금 새로 고침. 다음 자동 갱신까지 \(Int(ceil(remaining)))초. 항상 켜짐")
    }

    private func settingRow(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sourceLabel: String {
        switch store.preferredSource {
        case .cloud: return "iCloud"
        case .file: return store.sourceFileName ?? "선택한 파일"
        }
    }

    private func intervalLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 30: return "30초"
        case 60: return "1분"
        case 120: return "2분"
        case 300: return "5분"
        case 600: return "10분"
        default: return "\(Int(seconds))초"
        }
    }
}

/// 홈 상단의 가장 큰 카드: 실제 값이 있는 주요 한도 중 남은 비율이 가장
/// 낮은 것 하나. Signal red is reserved for the genuinely low case.
struct FocusLimitCardView: View {
    let focus: UsageSnapshot.FocusLimit

    private var remaining: Double { focus.window.remainingPercent ?? 0 }
    private var tint: Color { CCMBTheme.serviceTint(focus.service, windowID: focus.window.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("소진 임박")
                    .fixedSize()
                Text("\(focus.service.displayName) · \(focus.window.label)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Text(CCMBFormat.percent(focus.window.remainingPercent))
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint.opacity(0.78))
            ProgressView(value: remaining / 100)
                .tint(tint)
            HStack {
                if let resetText = focus.window.resetText {
                    Text("초기화 \(CCMBFormat.resetText(resetText) ?? resetText)")
                } else if let resetsAt = focus.window.resetsAt {
                    Text("초기화 \(CCMBFormat.resetTime(resetsAt))")
                }
                Spacer()
                Text("기준 \(CCMBFormat.relativeAge(focus.fetchedAt))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "소진 임박 한도. \(focus.service.displayName) \(focus.window.label), 남음 \(CCMBFormat.percent(focus.window.remainingPercent))"
        )
    }
}
