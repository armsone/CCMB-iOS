import SwiftUI

struct TabletDashboardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let snapshot: UsageSnapshot

    @State private var weatherRefreshTimerTask: Task<Void, Never>? = nil

    private static let sectionGap: CGFloat = 8

    var body: some View {
        let history = makeHistory()
        let banners = bannerItems(history: history)

        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ScrollView {
                VStack(spacing: Self.sectionGap) {
                    header
                    ForEach(Array(banners.enumerated()), id: \.offset) { _, item in
                        banner(text: item.text, isWarning: item.isWarning)
                    }

                    if isLandscape {
                        landscapeGrid(history: history, totalWidth: geo.size.width - 24, availableHeight: max(600, geo.size.height - 80 - CGFloat(banners.count * 58)))
                    } else {
                        portraitGrid(history: history, totalWidth: geo.size.width - 24, availableHeight: max(750, geo.size.height - 80 - CGFloat(banners.count * 58)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .refreshable {
                store.refresh()
                weatherStore.refresh()
            }
        }
        .onAppear {
            if scenePhase == .active {
                startWeatherTimer()
            }
        }
        .onDisappear {
            stopWeatherTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                startWeatherTimer()
            } else {
                stopWeatherTimer()
            }
        }
    }

    private func startWeatherTimer() {
        stopWeatherTimer()
        weatherRefreshTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000_000) // 180 seconds
                if !Task.isCancelled {
                    await MainActor.run {
                        weatherStore.refresh()
                    }
                }
            }
        }
    }

    private func stopWeatherTimer() {
        weatherRefreshTimerTask?.cancel()
        weatherRefreshTimerTask = nil
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 0) {
            Text("CCMB")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(CCMBDash.ink)
                .lineLimit(1)
                .layoutPriority(1)
            NASTaskStatusPill()
            Spacer(minLength: 16)
            syncView
            Spacer(minLength: 16)
            CompactRefreshControl()
            appearanceMenu
        }
        .frame(height: 40)
        .padding(.horizontal, 4)
    }

    private var syncView: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(snapshot.isStale() ? CCMBTheme.signalRed : Color(.sRGB, red: 0.07, green: 0.74, blue: 0.55, opacity: 1))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("동기화 \(CCMBFormat.macCollectionTime(snapshot.newestFetchedAt))")
                .font(.system(size: 14))
                .foregroundStyle(CCMBDash.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.displayedSource == .nas ? "NAS" : "Mac") 동기화 \(CCMBFormat.macCollectionTime(snapshot.newestFetchedAt))")
    }

    private var appearanceMenu: some View {
        let current = appearanceStore.selection
        return Menu {
            ForEach(CCMBAppearance.allCases) { appearance in
                Button {
                    appearanceStore.select(appearance)
                } label: {
                    if appearance == current {
                        Label(appearance.name, systemImage: "checkmark")
                    } else {
                        Text(appearance.name)
                    }
                }
                .accessibilityAddTraits(appearance == current ? .isSelected : [])
            }
        } label: {
            CCMBThemeIcon(appearance: current)
                .foregroundStyle(CCMBPalette.current.accent)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        } primaryAction: {
            appearanceStore.cycle()
        }
        .background(
            Button("테마 순환") { appearanceStore.cycle() }
                .keyboardShortcut("t", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .accessibilityLabel("병기스타일 테마: \(current.name)")
    }

    // MARK: - Landscape Grid (35% Left, 30% Center, 35% Right)
    @ViewBuilder
    private func landscapeGrid(history: DashboardHistory, totalWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let leftW = totalWidth * 0.35 - 6
        let centerW = totalWidth * 0.30 - 4
        let rightW = totalWidth * 0.35 - 6

        // Available height divided between items
        let leftCellH = max(240, (availableHeight - Self.sectionGap) / 2)
        let rightCellH = max(160, (availableHeight - Self.sectionGap * 2) / 3)
        let centerH = leftCellH * 2 + Self.sectionGap

        HStack(alignment: .top, spacing: Self.sectionGap) {
            // LEFT 35%: Codex (top), Claude (bottom)
            VStack(spacing: Self.sectionGap) {
                if let codex = snapshot.services[.codex] {
                    serviceCardLink(usage: codex, history: history, height: leftCellH)
                }
                if let claude = snapshot.services[.claude] {
                    serviceCardLink(usage: claude, history: history, height: leftCellH)
                }
            }
            .frame(width: leftW)

            // CENTER 30%: Flip clock, Current, Hourly, 7-day
            TabletUtilityCard(isLandscape: true)
                .frame(width: centerW, height: centerH)

            // RIGHT 35%: Gemini 1, Gemini 2, Gemini 3 equal stacked
            VStack(spacing: Self.sectionGap) {
                if let gemini = snapshot.services[.gemini] {
                    serviceCardLink(usage: gemini, history: history, height: rightCellH)
                }
                if let gemini2 = snapshot.services[.gemini2] {
                    serviceCardLink(usage: gemini2, history: history, height: rightCellH)
                }
                if let gemini3 = snapshot.services[.gemini3] {
                    serviceCardLink(usage: gemini3, history: history, height: rightCellH)
                }
            }
            .frame(width: rightW)
        }
    }

    // MARK: - Portrait Grid (2 columns x 3 rows equal cells)
    // Row 1: Weather+Clock / Codex
    // Row 2: Gemini 1 / Claude
    // Row 3: Gemini 2 / Gemini 3
    @ViewBuilder
    private func portraitGrid(history: DashboardHistory, totalWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let colW = (totalWidth - Self.sectionGap) / 2
        let cellH = max(220, (availableHeight - Self.sectionGap * 2) / 3)

        VStack(spacing: Self.sectionGap) {
            // Row 1: Weather+Clock / Codex
            HStack(spacing: Self.sectionGap) {
                TabletUtilityCard(isLandscape: false)
                    .frame(width: colW, height: cellH)

                if let codex = snapshot.services[.codex] {
                    serviceCardLink(usage: codex, history: history, height: cellH)
                        .frame(width: colW)
                } else {
                    Spacer().frame(width: colW, height: cellH)
                }
            }

            // Row 2: Gemini 1 / Claude (Claude sits directly beneath Codex)
            HStack(spacing: Self.sectionGap) {
                if let gemini = snapshot.services[.gemini] {
                    serviceCardLink(usage: gemini, history: history, height: cellH)
                        .frame(width: colW)
                } else {
                    Spacer().frame(width: colW, height: cellH)
                }

                if let claude = snapshot.services[.claude] {
                    serviceCardLink(usage: claude, history: history, height: cellH)
                        .frame(width: colW)
                } else {
                    Spacer().frame(width: colW, height: cellH)
                }
            }

            // Row 3: Gemini 2 / Gemini 3
            HStack(spacing: Self.sectionGap) {
                if let gemini2 = snapshot.services[.gemini2] {
                    serviceCardLink(usage: gemini2, history: history, height: cellH)
                        .frame(width: colW)
                } else {
                    Spacer().frame(width: colW, height: cellH)
                }

                if let gemini3 = snapshot.services[.gemini3] {
                    serviceCardLink(usage: gemini3, history: history, height: cellH)
                        .frame(width: colW)
                } else {
                    Spacer().frame(width: colW, height: cellH)
                }
            }
        }
    }

    private func serviceCardLink(usage: ServiceUsage, history: DashboardHistory, height: CGFloat) -> some View {
        NavigationLink {
            ServiceDetailView(
                usage: usage,
                isNAS: store.displayedSource == .nas,
                isBusy: store.displayedSource == .nas && store.nasRefreshBusy
            )
        } label: {
            AccountCardView(usage: usage, history: history, height: height)
        }
        .buttonStyle(.plain)
    }

    // MARK: - History & Banners
    private func makeHistory() -> DashboardHistory {
        if let live = snapshot.consumptionHistory {
            return DashboardHistory(
                history: live,
                gemini2: live.gemini2,
                gemini3: live.gemini3,
                anchorDate: resolveAnchorDate(explicitDate: snapshot.newestFetchedAt, history: live, gemini2: live.gemini2, gemini3: live.gemini3),
                maxContiguousGap: 30 * 60,
                codexUsesCredits: liveCodexUsesCredits,
                isNAS: false
            )
        }
        if store.displayedSource == .nas {
            if let nas = snapshot.nasHistory, !nas.isEmpty {
                return DashboardHistory(
                    history: nas.history,
                    gemini2: nas.gemini2,
                    gemini3: nas.gemini3,
                    anchorDate: resolveAnchorDate(explicitDate: nas.collectedAt, history: nas.history, gemini2: nas.gemini2, gemini3: nas.gemini3),
                    maxContiguousGap: 15 * 60,
                    codexUsesCredits: nas.codexUsesCredits,
                    isNAS: true,
                    note: nasHistoryNoteText(nas, now: Date())
                )
            }
            var waiting = DashboardHistory()
            let base = "NAS가 기록을 모으는 중입니다."
            waiting.placeholder = store.nasHistoryIssue.map { "\(base) (\($0))" } ?? base
            waiting.isNAS = true
            return waiting
        }
        return DashboardHistory()
    }

    private var liveCodexUsesCredits: Bool {
        (snapshot.services[.codex]?.windows.first { $0.id == "weekly" }?.remainingPercent ?? 1) <= 0
            && (snapshot.services[.codex]?.creditBalance ?? 0) > 0
    }

    private func resolveAnchorDate(
        explicitDate: Date?,
        history: UsageConsumptionHistory,
        gemini2: [UsageConsumptionPoint],
        gemini3: [UsageConsumptionPoint]
    ) -> Date {
        let allDates = (history.codex + history.claude + history.claudeFable + history.gemini + gemini2 + gemini3).map(\.at)
        let newestSample = allDates.max()
        if let explicitDate, let newestSample {
            return max(explicitDate, newestSample)
        }
        return explicitDate ?? newestSample ?? Date()
    }

    private func nasHistoryNoteText(_ nasHistory: NASConsumptionHistory, now: Date) -> String? {
        var parts: [String] = []
        if now.timeIntervalSince(nasHistory.collectedAt) > UsageSnapshot.staleAfterSeconds {
            parts.append("기록이 오래됨 · \(CCMBFormat.macCollectionTime(nasHistory.collectedAt, now: now)) 기준 (\(CCMBFormat.relativeAge(nasHistory.collectedAt, now: now)))")
        }
        if let issue = store.nasHistoryIssue { parts.append("최신 확인 실패: \(issue)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func bannerItems(history: DashboardHistory) -> [(text: String, isWarning: Bool)] {
        var items: [(text: String, isWarning: Bool)] = []
        if let problem = store.refreshProblem { items.append((problem, true)) }
        if let nasError = store.nasConnectError { items.append((nasError, true)) }
        if store.displayedSource == .nas, let notice = store.nasRefreshNotice { items.append((notice, false)) }
        if snapshot.isStale() {
            items.append((staleBannerText, true))
        } else if store.origin == .savedCopy {
            items.append((
                "마지막으로 저장한 사본을 보여 주고 있습니다. 새로 고침하면 최신 값을 다시 불러옵니다.",
                false
            ))
        }
        if let addressChangedText { items.append((addressChangedText, true)) }
        if let note = history.note { items.append((note, true)) }
        return items
    }

    private var staleBannerText: String {
        store.displayedSource == .nas
            ? "오래된 데이터입니다. NAS에 다시 연결하거나 새로 고침해야 새 값이 올라옵니다."
            : "오래된 데이터입니다. Mac에서 CCMB가 실행 중이어야 새 값이 올라옵니다."
    }

    private var addressChangedText: String? {
        guard store.displayedSource == .nas,
              let displayedAddress = store.displayedNASAddress,
              displayedAddress != store.nasBaseURLString else { return nil }
        return "이전 NAS의 데이터입니다. 새 NAS에 다시 연결해 주세요."
    }

    private func banner(text: String, isWarning: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "clock.badge.exclamationmark" : "internaldrive")
                .foregroundStyle(isWarning ? CCMBTheme.signalRed : CCMBDash.muted)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(CCMBDash.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tablet Utility Card (Flip Clock + Weather)
struct TabletUtilityCard: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    let isLandscape: Bool

    var body: some View {
        if isLandscape {
            LandscapeUtilityView()
        } else {
            PortraitUtilityView()
        }
    }
}

// MARK: - Landscape Utility: 4 Distinct Panels
// Clock ~23%, Current ~15%, Hourly ~21%, Daily ~41%
private struct LandscapeUtilityView: View {
    @EnvironmentObject private var weatherStore: WeatherStore

    var body: some View {
        GeometryReader { geo in
            let totalH = geo.size.height
            let spacing: CGFloat = 8
            let availableH = max(0, totalH - spacing * 3)
            let clockH = availableH * 0.23
            let currentH = availableH * 0.15
            let hourlyH = availableH * 0.21
            let dailyH = availableH * 0.41

            VStack(spacing: spacing) {
                // 1. Flip Clock
                VStack(spacing: 4) {
                    FlipClockView(
                        plateWidth: 46,
                        plateHeight: 58,
                        fontSize: 34,
                        dateFontSize: 12,
                        spacing: 3
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: clockH)
                .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Weather Content or Permission placeholder
                if let reading = weatherStore.reading {
                    // 2. Current Weather
                    LandscapeCurrentWeatherView(reading: reading)
                        .frame(maxWidth: .infinity)
                        .frame(height: currentH)
                        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // 3. Hourly
                    LandscapeHourlyWeatherView(reading: reading)
                        .frame(maxWidth: .infinity)
                        .frame(height: hourlyH)
                        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // 4. Daily 7-day
                    LandscapeDailyWeatherView(reading: reading)
                        .frame(maxWidth: .infinity)
                        .frame(height: dailyH)
                        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    let placeholderH = currentH + hourlyH + dailyH + spacing * 2
                    WeatherPermissionPlaceholderView(isCompact: false)
                        .frame(maxWidth: .infinity)
                        .frame(height: placeholderH)
                        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Landscape Subpanels
private struct LandscapeCurrentWeatherView: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    let reading: WeatherStore.Reading

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reading.symbolName)
                .symbolRenderingMode(.palette)
                .foregroundStyle(weatherSymbolColor(reading.symbolName), .secondary)
                .font(.system(size: 32))
                .frame(width: 38)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(reading.temperature.rounded()))°")
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundStyle(CCMBDash.ink)
                    Text(weatherConditionLabel(reading.symbolName))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CCMBDash.muted)
                }
                if let today = reading.daily.first {
                    Text("최고 \(Int(today.maxTemp.rounded()))° · 최저 \(Int(today.minTemp.rounded()))°")
                        .font(.system(size: 11))
                        .foregroundStyle(CCMBDash.muted)
                }
            }

            Spacer(minLength: 4)

            Button {
                weatherStore.refresh()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(reading.isStale ? CCMBTheme.signalRed : Color(.sRGB, red: 0.07, green: 0.74, blue: 0.55, opacity: 1))
                        .frame(width: 6, height: 6)
                    let timeFormatter: DateFormatter = {
                        let df = DateFormatter()
                        df.dateFormat = "HH:mm"
                        return df
                    }()
                    Text(reading.isStale ? "지연" : timeFormatter.string(from: reading.updatedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(CCMBDash.muted)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(CCMBDash.muted)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }
}

private struct LandscapeHourlyWeatherView: View {
    let reading: WeatherStore.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("시간별 예보")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CCMBDash.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            GeometryReader { geo in
                let hourly = Array(reading.hourly.prefix(7))
                let colW = max(32, (geo.size.width - CGFloat(max(0, hourly.count - 1)) * 4) / CGFloat(max(1, hourly.count)))

                HStack(spacing: 4) {
                    ForEach(hourly) { hour in
                        VStack(spacing: 2) {
                            Text(hour.timeLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(CCMBDash.muted)
                                .lineLimit(1)
                            Image(systemName: hour.symbolName)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(weatherSymbolColor(hour.symbolName), .secondary)
                                .font(.system(size: 15))
                            Text("\(Int(hour.temperature.rounded()))°")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CCMBDash.ink)
                            if let precip = hour.precipitationProbability, precip > 0 {
                                Text("\(precip)%")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.9))
                            } else {
                                Text(" ")
                                    .font(.system(size: 9))
                            }
                        }
                        .frame(width: colW)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

private struct LandscapeDailyWeatherView: View {
    let reading: WeatherStore.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("7일간 예보")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CCMBDash.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            let days = Array(reading.daily.prefix(7))
            let allMin = days.map(\.minTemp).min() ?? 0
            let allMax = days.map(\.maxTemp).max() ?? 30
            let span = max(1, allMax - allMin)

            VStack(spacing: 3) {
                ForEach(days) { day in
                    HStack(spacing: 6) {
                        Text(day.dayLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(CCMBDash.ink)
                            .frame(width: 26, alignment: .leading)

                        Image(systemName: day.symbolName)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(weatherSymbolColor(day.symbolName), .secondary)
                            .font(.system(size: 14))
                            .frame(width: 20)

                        if let precip = day.precipitationProbability, precip > 0 {
                            Text("\(precip)%")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.9))
                                .frame(width: 26, alignment: .trailing)
                        } else {
                            Text("")
                                .frame(width: 26)
                        }

                        Text("\(Int(day.minTemp.rounded()))°")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(CCMBDash.muted)
                            .frame(width: 24, alignment: .trailing)

                        // Visual range bar
                        GeometryReader { barGeo in
                            let w = barGeo.size.width
                            let leftOffset = CGFloat(max(0, (day.minTemp - allMin) / span)) * w
                            let rightOffset = CGFloat(max(0, (day.maxTemp - allMin) / span)) * w
                            let barW = max(6, rightOffset - leftOffset)

                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(CCMBDash.divider.opacity(0.4))
                                    .frame(height: 4)

                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [Color(red: 0.2, green: 0.6, blue: 0.9), Color(red: 0.95, green: 0.6, blue: 0.15)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: barW, height: 4)
                                    .offset(x: leftOffset)
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(height: 6)

                        Text("\(Int(day.maxTemp.rounded()))°")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CCMBDash.ink)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Portrait Utility: Fits top-left equal 2x3 cell
private struct PortraitUtilityView: View {
    @EnvironmentObject private var weatherStore: WeatherStore

    var body: some View {
        GeometryReader { geo in
            let totalH = geo.size.height
            let topH = totalH * 0.38
            let hourlyH = totalH * 0.28
            let dailyH = totalH * 0.34

            VStack(spacing: 0) {
                // Top row: Flip Clock 60% + Compact Weather 40%
                HStack(spacing: 6) {
                    FlipClockView(
                        plateWidth: 32,
                        plateHeight: 44,
                        fontSize: 26,
                        dateFontSize: 10,
                        spacing: 2
                    )
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(CCMBDash.divider.opacity(0.6))
                        .frame(width: 1, height: 38)

                    if let reading = weatherStore.reading {
                        PortraitCompactWeatherView(reading: reading)
                            .frame(width: geo.size.width * 0.38)
                    } else {
                        WeatherPermissionPlaceholderView(isCompact: true)
                            .frame(width: geo.size.width * 0.38)
                    }
                }
                .frame(height: topH)
                .padding(.horizontal, 8)

                Divider()
                    .padding(.horizontal, 8)

                // Middle: Hourly 7 columns
                VStack(alignment: .leading, spacing: 1) {
                    Text("시간별")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CCMBDash.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)

                    if let reading = weatherStore.reading {
                        let hourly = Array(reading.hourly.prefix(7))
                        HStack(spacing: 2) {
                            ForEach(hourly) { hour in
                                VStack(spacing: 1) {
                                    Text(hour.timeLabel)
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(CCMBDash.muted)
                                    Image(systemName: hour.symbolName)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(weatherSymbolColor(hour.symbolName), .secondary)
                                        .font(.system(size: 13))
                                    Text("\(Int(hour.temperature.rounded()))°")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CCMBDash.ink)
                                    if let precip = hour.precipitationProbability, precip > 0 {
                                        Text("\(precip)%")
                                            .font(.system(size: 7.5))
                                            .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.9))
                                    } else {
                                        Text(" ").font(.system(size: 7.5))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .frame(height: hourlyH)

                Divider()
                    .padding(.horizontal, 8)

                // Bottom: 7 days columns
                VStack(alignment: .leading, spacing: 1) {
                    Text("7일간 예보")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CCMBDash.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)

                    if let reading = weatherStore.reading {
                        let daily = Array(reading.daily.prefix(7))
                        HStack(spacing: 2) {
                            ForEach(daily) { day in
                                VStack(spacing: 1) {
                                    Text(day.dayLabel)
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(CCMBDash.ink)
                                    Image(systemName: day.symbolName)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(weatherSymbolColor(day.symbolName), .secondary)
                                        .font(.system(size: 13))
                                    Text("\(Int(day.maxTemp.rounded()))°")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(CCMBDash.ink)
                                    Text("\(Int(day.minTemp.rounded()))°")
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(CCMBDash.muted)
                                    if let precip = day.precipitationProbability, precip > 0 {
                                        Text("\(precip)%")
                                            .font(.system(size: 7.5))
                                            .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.9))
                                    } else {
                                        Text(" ").font(.system(size: 7.5))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .frame(height: dailyH)
            }
        }
        .background(CCMBDash.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PortraitCompactWeatherView: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    let reading: WeatherStore.Reading

    var body: some View {
        Button {
            weatherStore.refresh()
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: reading.symbolName)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(weatherSymbolColor(reading.symbolName), .secondary)
                        .font(.system(size: 20))
                    Text("\(Int(reading.temperature.rounded()))°")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(CCMBDash.ink)
                }
                Text(weatherConditionLabel(reading.symbolName))
                    .font(.system(size: 10))
                    .foregroundStyle(CCMBDash.muted)
                    .lineLimit(1)
                if let today = reading.daily.first {
                    Text("\(Int(today.maxTemp.rounded()))° / \(Int(today.minTemp.rounded()))°")
                        .font(.system(size: 9))
                        .foregroundStyle(CCMBDash.muted)
                        .lineLimit(1)
                }
                HStack(spacing: 3) {
                    Circle()
                        .fill(reading.isStale ? CCMBTheme.signalRed : Color(.sRGB, red: 0.07, green: 0.74, blue: 0.55, opacity: 1))
                        .frame(width: 5, height: 5)
                    let timeFormatter: DateFormatter = {
                        let df = DateFormatter()
                        df.dateFormat = "HH:mm"
                        return df
                    }()
                    Text(reading.isStale ? "지연" : timeFormatter.string(from: reading.updatedAt))
                        .font(.system(size: 8.5))
                        .foregroundStyle(CCMBDash.muted)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8.5))
                        .foregroundStyle(CCMBDash.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permission Placeholder
private struct WeatherPermissionPlaceholderView: View {
    @EnvironmentObject private var weatherStore: WeatherStore
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 3 : 6) {
            Image(systemName: "cloud.sun.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color(red: 0.95, green: 0.65, blue: 0.15), CCMBDash.muted)
                .font(.system(size: isCompact ? 20 : 28))

            Button {
                weatherStore.refresh()
            } label: {
                Text("날씨 정보 보기")
                    .font(.system(size: isCompact ? 11 : 13, weight: .semibold))
                    .foregroundStyle(CCMBPalette.current.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(CCMBPalette.current.accentSoft, in: Capsule())
            }
            .buttonStyle(.plain)

            Text("위치 권한을 허용하면 현재, 시간별, 7일 예보가 표시됩니다")
                .font(.system(size: isCompact ? 8.5 : 11))
                .foregroundStyle(CCMBDash.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .padding(6)
    }
}

// MARK: - Mechanical Flip Clock (Four individual digit plates)
private struct FlipClockView: View {
    let plateWidth: CGFloat
    let plateHeight: CGFloat
    let fontSize: CGFloat
    let dateFontSize: CGFloat
    let spacing: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            let date = timeline.date
            let hourStr = String(format: "%02d", Calendar.current.component(.hour, from: date))
            let minStr = String(format: "%02d", Calendar.current.component(.minute, from: date))
            let dateFormatter: DateFormatter = {
                let df = DateFormatter()
                df.locale = Locale(identifier: "ko_KR")
                df.dateFormat = "M월 d일 EEEE"
                return df
            }()

            let h1 = String(hourStr.prefix(1))
            let h2 = String(hourStr.suffix(1))
            let m1 = String(minStr.prefix(1))
            let m2 = String(minStr.suffix(1))

            VStack(spacing: 4) {
                HStack(spacing: spacing) {
                    FlipDigitCard(digit: h1, width: plateWidth, height: plateHeight, fontSize: fontSize)
                    FlipDigitCard(digit: h2, width: plateWidth, height: plateHeight, fontSize: fontSize)

                    Text(":")
                        .font(.system(size: fontSize * 0.85, weight: .bold))
                        .foregroundStyle(Color(red: 0.6, green: 0.65, blue: 0.72))
                        .padding(.horizontal, 1)

                    FlipDigitCard(digit: m1, width: plateWidth, height: plateHeight, fontSize: fontSize)
                    FlipDigitCard(digit: m2, width: plateWidth, height: plateHeight, fontSize: fontSize)
                }

                Text(dateFormatter.string(from: date))
                    .font(.system(size: dateFontSize, weight: .medium))
                    .foregroundStyle(CCMBDash.muted)
                    .lineLimit(1)
            }
        }
    }
}

// Single mechanical dark plate with white glyph, horizontal seam, gray hinge marks, flip animation
private struct FlipDigitCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let digit: String
    let width: CGFloat
    let height: CGFloat
    let fontSize: CGFloat

    @State private var currentDigit: String = ""
    @State private var previousDigit: String = ""
    @State private var flipProgress: Double = 1.0

    var body: some View {
        ZStack {
            // Dark gradient face
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.15, green: 0.17, blue: 0.22), Color(red: 0.08, green: 0.09, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(red: 0.22, green: 0.25, blue: 0.31), lineWidth: 0.75)
                )

            // Digit glyph
            let displayed = (flipProgress < 0.5) ? previousDigit : currentDigit
            Text(displayed.isEmpty ? digit : displayed)
                .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : (flipProgress < 0.5 ? -flipProgress * 180 : (1.0 - flipProgress) * 180)),
                    axis: (x: 1.0, y: 0.0, z: 0.0),
                    perspective: 0.6
                )

            // Center horizontal mechanical seam
            Rectangle()
                .fill(Color(red: 0.04, green: 0.05, blue: 0.07))
                .frame(height: 1)

            // Left hinge mark
            HStack {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.38, green: 0.42, blue: 0.48))
                    .frame(width: 2.5, height: 4.5)
                Spacer()
                // Right hinge mark
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.38, green: 0.42, blue: 0.48))
                    .frame(width: 2.5, height: 4.5)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .onAppear {
            currentDigit = digit
            previousDigit = digit
        }
        .onChange(of: digit) { oldVal, newVal in
            guard oldVal != newVal else { return }
            previousDigit = oldVal
            currentDigit = newVal
            if reduceMotion {
                flipProgress = 1.0
            } else {
                flipProgress = 0.0
                withAnimation(.easeInOut(duration: 0.38)) {
                    flipProgress = 1.0
                }
            }
        }
    }
}

// MARK: - Helpers
private func weatherConditionLabel(_ symbol: String) -> String {
    if symbol.contains("sun.max") || symbol == "sun" { return "맑음" }
    if symbol.contains("sun") { return "구름 조금" }
    if symbol.contains("cloud") && !symbol.contains("rain") && !symbol.contains("drizzle") && !symbol.contains("bolt") { return "흐림" }
    if symbol.contains("fog") { return "안개" }
    if symbol.contains("drizzle") { return "이슬비" }
    if symbol.contains("rain") { return "비" }
    if symbol.contains("snow") || symbol.contains("snowflake") { return "눈" }
    if symbol.contains("bolt") { return "뇌우" }
    return "흐림"
}

private func weatherSymbolColor(_ symbol: String) -> Color {
    if symbol.contains("sun") { return Color(red: 0.98, green: 0.65, blue: 0.12) }
    if symbol.contains("rain") || symbol.contains("drizzle") || symbol.contains("bolt") {
        return Color(red: 0.28, green: 0.58, blue: 0.96)
    }
    if symbol.contains("snow") || symbol.contains("snowflake") {
        return Color(red: 0.45, green: 0.8, blue: 0.98)
    }
    return CCMBDash.muted
}
