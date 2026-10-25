import SwiftUI

/// 승인된 라이트 카드 대시보드:
/// - 왼쪽 큰 CCMB, 오른쪽 새로 고침·메뉴, 아래 줄에 날씨와 동기화 시각.
/// - Codex / Claude / Gemini 계정 카드가 전폭으로 쌓이고, 카드마다 자기 24시간 선+면적 그래프를 가진다.
/// - 경고(새로 고침·NAS·오래됨·주소)는 카드 위에 그대로 남고, 예외 상태에서만 세로로 스크롤된다.
struct DashboardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: UsageSnapshot

    private static let windowSeconds: TimeInterval = UsageSnapshot.nasHistory24hWindowSeconds
    private static let headerHeight: CGFloat = 62
    private static let sectionGap: CGFloat = 8
    private static let estimatedBannerHeight: CGFloat = 58
    /// 카드 높이는 안전 영역을 기준으로 비율로 줄이되 이 아래로는 줄이지 않는다(그 아래는 스크롤).
    private static let minimumCardScale: CGFloat = 0.82
    private static let maximumCardScale: CGFloat = 1.12

    private var cardServices: [Service] {
        [Service.codex, .claude, .gemini, .gemini2, .gemini3].filter { snapshot.services[$0] != nil }
    }

    var body: some View {
        GeometryReader { outerGeo in
            if UIDevice.current.userInterfaceIdiom == .pad && outerGeo.size.width >= 600 {
                TabletDashboardView(snapshot: snapshot)
            } else {
                phoneDashboard(outerHeight: outerGeo.size.height)
            }
        }
        .background(
            LinearGradient(colors: [CCMBDash.canvasTop, CCMBDash.canvasBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        // 선택된 병기스타일 테마의 밝음/어두움을 따른다.
        .environment(\.colorScheme, appearanceStore.selection.preferredColorScheme)
        .preferredColorScheme(appearanceStore.selection.preferredColorScheme)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func phoneDashboard(outerHeight: CGFloat) -> some View {
        let history = makeHistory()
        let banners = bannerItems(history: history)
        return ScrollView {
            VStack(spacing: Self.sectionGap) {
                header
                ForEach(Array(banners.enumerated()), id: \.offset) { _, item in
                    banner(text: item.text, isWarning: item.isWarning)
                }
                cardsStack(history: history, availableHeight: outerHeight, bannerCount: banners.count)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .refreshable { store.refresh() }
    }

    // MARK: Cards

    @ViewBuilder
    private func cardsStack(history: DashboardHistory, availableHeight: CGFloat, bannerCount: Int) -> some View {
        let services = cardServices
        let heights = cardHeights(services: services, availableHeight: availableHeight, bannerCount: bannerCount)
        VStack(spacing: Self.sectionGap) {
            ForEach(Array(services.enumerated()), id: \.element) { index, service in
                if let usage = snapshot.services[service] {
                    NavigationLink {
                        ServiceDetailView(
                            usage: usage,
                            isNAS: store.displayedSource == .nas,
                            isBusy: store.displayedSource == .nas && store.nasRefreshBusy
                        )
                    } label: {
                        AccountCardView(usage: usage, history: history, height: heights?[index])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 안전 영역 높이를 카드 비율(Codex 173 : Claude 139 : Gemini 132)로 나눈다.
    /// 큰 글자 크기에서는 nil(자연 높이)로 두어 내용이 스크롤되게 한다.
    private func cardHeights(services: [Service], availableHeight: CGFloat, bannerCount: Int) -> [CGFloat]? {
        guard !dynamicTypeSize.isAccessibilitySize, !services.isEmpty else { return nil }
        let weights = services.map { AccountCardView.referenceHeight(for: $0) }
        let overhead = Self.headerHeight
            + Self.sectionGap * CGFloat(services.count + bannerCount)
            + CGFloat(bannerCount) * Self.estimatedBannerHeight
            + 10
        // iPhone은 남는 세로 공간을 모두 카드(=그래프) 높이로 나눠 하단 빈 공간을 없앤다. 헤더 영역은 고정이다.
        let fit = max(Self.minimumCardScale, (availableHeight - overhead) / max(1, weights.reduce(0, +)))
        let scale = UIDevice.current.userInterfaceIdiom == .phone ? fit : min(Self.maximumCardScale, fit)
        return zip(services, weights).map { service, weight in
            max(weight * scale, AccountCardView.minimumHeight(for: service))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("CCMB")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(CCMBDash.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                CompactRefreshControl()
                appearanceMenu
            }
            .frame(height: 36)

            ZStack {
                HStack(spacing: 0) {
                    weatherView
                    Spacer(minLength: 0)
                }
                syncView
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: Self.headerHeight - 4)
    }

    @ViewBuilder
    private var weatherView: some View {
        if let weather = weatherStore.reading {
            HStack(spacing: 4) {
                Image(systemName: weather.symbolName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(weatherPrimary(weather.symbolName), weatherSecondary(weather.symbolName), weatherTertiary)
                    .font(.system(size: 20))
                Text("\(Int(weather.temperature.rounded()))°")
                    .font(.system(size: 19))
                    .monospacedDigit()
                    .foregroundStyle(CCMBDash.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("현재 기온 \(Int(weather.temperature.rounded()))도")
        }
    }

    private static let weatherSlate = Color(.sRGB, red: 0.45, green: 0.52, blue: 0.66, opacity: 1)
    private static let weatherGold = Color(.sRGB, red: 0.96, green: 0.70, blue: 0.10, opacity: 1)

    private func weatherPrimary(_ symbol: String) -> Color {
        symbol.contains("cloud") || symbol.contains("fog") || symbol.contains("wind") ? Self.weatherSlate : Self.weatherGold
    }

    private func weatherSecondary(_ symbol: String) -> Color {
        symbol.contains("sun") || symbol.contains("moon") ? Self.weatherGold : Self.weatherSlate
    }

    private var weatherTertiary: Color { Color(.sRGB, red: 0.26, green: 0.52, blue: 0.96, opacity: 1) }

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
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collectionLabel) 동기화 \(CCMBFormat.macCollectionTime(snapshot.newestFetchedAt))")
    }

    private var collectionLabel: String {
        store.displayedSource == .nas ? "NAS" : "Mac"
    }

    /// 병기스타일 테마 버튼: 짧게 누르면 다음 테마, 길게 누르면 4개 선택 메뉴(시스템 Menu 기본 동작).
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
            // 외장 키보드: ⌘T 순환(화면에는 보이지 않는 단축키 버튼).
            Button("테마 순환") { appearanceStore.cycle() }
                .keyboardShortcut("t", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .accessibilityLabel("병기스타일 테마: \(current.name) (누르면 \(current.next.name), 길게 누르면 목록)")
        .accessibilityValue(current.name)
    }

    // MARK: Warnings

    func bannerItems(history: DashboardHistory) -> [(text: String, isWarning: Bool)] {
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

    func banner(text: String, isWarning: Bool) -> some View {
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

    // MARK: History source

    /// 라이브(Mac) 기록이 있으면 그것을, NAS 소스면 NAS가 모은 기록을 쓴다. 둘 다 없으면 빈 그래프.
    func makeHistory() -> DashboardHistory {
        if let live = snapshot.consumptionHistory {
            return DashboardHistory(
                history: live,
                gemini2: live.gemini2,
                gemini3: live.gemini3,
                anchorDate: Self.resolveAnchorDate(explicitDate: snapshot.newestFetchedAt, history: live, gemini2: live.gemini2, gemini3: live.gemini3),
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
                    anchorDate: Self.resolveAnchorDate(explicitDate: nas.collectedAt, history: nas.history, gemini2: nas.gemini2, gemini3: nas.gemini3),
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

    private static func resolveAnchorDate(
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

    /// 기록 자체의 오래됨·갱신 실패만 알린다.
    private func nasHistoryNoteText(_ nasHistory: NASConsumptionHistory, now: Date) -> String? {
        var parts: [String] = []
        if now.timeIntervalSince(nasHistory.collectedAt) > UsageSnapshot.staleAfterSeconds {
            parts.append("기록이 오래됨 · \(CCMBFormat.macCollectionTime(nasHistory.collectedAt, now: now)) 기준 (\(CCMBFormat.relativeAge(nasHistory.collectedAt, now: now)))")
        }
        if let issue = store.nasHistoryIssue { parts.append("최신 확인 실패: \(issue)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 카드 24시간 그래프가 함께 쓰는 기록 문맥: 같은 기준 시각·같은 빈틈 규칙·제공자별 단위.
struct DashboardHistory {
    var history: UsageConsumptionHistory? = nil
    var gemini2: [UsageConsumptionPoint] = []
    var gemini3: [UsageConsumptionPoint] = []
    var anchorDate: Date = Date()
    var maxContiguousGap: TimeInterval = 30 * 60
    var codexUsesCredits = false
    var isNAS = false
    var note: String? = nil
    var placeholder = "24시간 기록을 기다리는 중입니다."

    private static let windowSeconds: TimeInterval = UsageSnapshot.nasHistory24hWindowSeconds

    /// 제공자별 실제 단위: Codex가 크레딧(토큰)을 쓰는 중이면 그 단위, 나머지는 %.
    func unit(for service: Service) -> String {
        guard service == .codex, codexUsesCredits else { return "%" }
        return isNAS ? "토큰" : "크레딧"
    }

    func samples(for service: Service) -> [UsageConsumptionPoint]? {
        guard let history else { return nil }
        switch service {
        case .codex: return history.codex
        case .claude: return history.claude
        case .gemini: return history.gemini
        case .gemini2: return gemini2
        case .gemini3: return gemini3
        case .grok: return []
        }
    }

    func model(for service: Service) -> Account24hModel? {
        guard let samples = samples(for: service) else { return nil }
        return Account24hModel(
            samples: samples,
            anchorDate: anchorDate,
            windowSeconds: Self.windowSeconds,
            maxContiguousGap: maxContiguousGap,
            usesCreditsScale: service == .codex && codexUsesCredits,
            unit: unit(for: service),
            color: CCMBDash.accent(service)
        )
    }

    /// 기록이 24시간보다 짧을 때만 채워지는 '기록 N시간' 짧은 표기.
    var coverageShort: String? {
        guard let history else { return nil }
        let windowStart = anchorDate.addingTimeInterval(-Self.windowSeconds)
        let dates = (history.codex + history.claude + history.claudeFable + history.gemini + gemini2 + gemini3)
            .map(\.at)
            .filter { $0 >= windowStart && $0 <= anchorDate.addingTimeInterval(60) }
        guard let earliest = dates.min(), let latest = dates.max() else { return "기록 없음" }
        let span = max(0, latest.timeIntervalSince(earliest))
        if Set(dates).count == 1 || span < 60 { return "기록 1건" }
        guard span < Self.windowSeconds - 30 * 60 else { return nil }
        let hours = Int(span) / 3600
        return hours > 0 ? "\(hours)h/24h" : "\(max(1, (Int(span) % 3600) / 60))분/24h"
    }
}

/// One 30-minute, wall-clock aligned stretch of one series: the measured
/// consumption of every refresh recorded inside that half hour, summed. These
/// buckets are the only thing the chart plots, so a 3-minute cadence reads as
/// a trend instead of a forest of needles. A half hour with no sample has no
/// bucket (unknown, never zero); a real zero reading sums to zero.
struct ConsumptionBucket {
    let start: Date
    /// The part of that half hour that is on the chart (clipped to the window,
    /// to the anchor and to the first recorded sample).
    let from: Date
    let to: Date
    let amount: Double
    let sampleCount: Int
    let firstAt: Date
    let lastAt: Date
    let segmentId: String?
    /// The half hour that is still running (left edge).
    let isInProgress: Bool
    /// Cut short at the older edge by the window or by the first recording.
    var isClipped: Bool
    /// Refreshes inside it are further apart than the source's own gap.
    let hasGap: Bool

    var isEdge: Bool { isInProgress || isClipped }
    var midpoint: Date { Date(timeIntervalSince1970: (from.timeIntervalSince1970 + to.timeIntervalSince1970) / 2) }
}

enum ConsumptionBucketing {
    static let bucketSeconds: TimeInterval = 30 * 60

    static func boundary(for date: Date) -> Date {
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        return Date(timeIntervalSince1970: floor(local / bucketSeconds) * bucketSeconds - offset)
    }

    private struct Key: Hashable {
        let start: TimeInterval
        let segmentId: String?
    }

    /// Newest first. Deltas of different baseline segments never share a
    /// bucket, and points outside `windowStart ... anchor` are not used.
    static func buckets(
        _ points: [UsageConsumptionPoint],
        gap: TimeInterval,
        anchor: Date,
        windowStart: Date,
        earliest: Date
    ) -> [ConsumptionBucket] {
        var groups: [Key: [(at: Date, amount: Double)]] = [:]
        for point in points where point.at >= windowStart {
            let at = min(point.at, anchor)
            groups[Key(start: boundary(for: at).timeIntervalSince1970, segmentId: point.segmentId), default: []]
                .append((at, point.amount))
        }
        let lowerBound = max(windowStart, earliest)
        var result: [ConsumptionBucket] = []
        for (key, entries) in groups {
            let ordered = entries.sorted { $0.at < $1.at }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let start = Date(timeIntervalSince1970: key.start)
            let end = start.addingTimeInterval(bucketSeconds)
            let from = max(start, lowerBound)
            var hasGap = false
            for (older, newer) in zip(ordered, ordered.dropFirst()) where newer.at.timeIntervalSince(older.at) > gap {
                hasGap = true
            }
            result.append(ConsumptionBucket(
                start: start,
                from: from,
                to: max(from, min(end, anchor)),
                amount: ordered.reduce(0) { $0 + max(0, $1.amount) },
                sampleCount: ordered.count,
                firstAt: first.at,
                lastAt: last.at,
                segmentId: key.segmentId,
                isInProgress: end > anchor,
                isClipped: start < lowerBound,
                hasGap: hasGap
            ))
        }
        result.sort { $0.start != $1.start ? $0.start > $1.start : $0.lastAt > $1.lastAt }
        // A series that began recording part-way into its oldest half hour
        // has only covered part of it.
        if let oldest = result.last, oldest.firstAt.timeIntervalSince(oldest.from) > gap {
            result[result.count - 1].isClipped = true
        }
        return result
    }

    /// Buckets (newest first) stay on one line only when they are neighbouring
    /// half hours of the same baseline segment and the source did not stop
    /// reporting between them. An empty half hour is never bridged.
    static func runs(_ buckets: [ConsumptionBucket], gap: TimeInterval) -> [[ConsumptionBucket]] {
        var result: [[ConsumptionBucket]] = []
        var current: [ConsumptionBucket] = []
        for bucket in buckets {
            if let newer = current.last {
                let neighbours = Int((newer.start.timeIntervalSince(bucket.start) / bucketSeconds).rounded()) == 1
                let sameSegment: Bool = {
                    guard let s1 = newer.segmentId, let s2 = bucket.segmentId else { return true }
                    return s1 == s2
                }()
                if !neighbours || !sameSegment || newer.firstAt.timeIntervalSince(bucket.lastAt) > gap {
                    result.append(current)
                    current = []
                }
            }
            current.append(bucket)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}


/// 카드 하나의 24시간 그래프 데이터: 이 계정의 30분 소모 버킷과 실제 표본 크기에 맞춘 y축.
struct Account24hModel {
    let buckets: [ConsumptionBucket]
    let earliest: Date?
    let yMax: Double
    let usesCreditsScale: Bool
    let unit: String
    let color: Color
    let anchorDate: Date
    let windowSeconds: TimeInterval
    let maxContiguousGap: TimeInterval

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(
        samples: [UsageConsumptionPoint],
        anchorDate: Date,
        windowSeconds: TimeInterval,
        maxContiguousGap: TimeInterval,
        usesCreditsScale: Bool,
        unit: String,
        color: Color
    ) {
        let windowStart = anchorDate.addingTimeInterval(-windowSeconds)
        let filtered = samples
            .filter { $0.at >= windowStart && $0.at <= anchorDate.addingTimeInterval(60) }
            .sorted { $0.at > $1.at } // 최신(왼쪽) → 오래된(오른쪽)
        let earliest = filtered.map(\.at).min()
        let buckets = ConsumptionBucketing.buckets(
            filtered,
            gap: maxContiguousGap,
            anchor: anchorDate,
            windowStart: windowStart,
            earliest: earliest ?? windowStart
        )
        let peak = buckets.map(\.amount).filter { $0.isFinite && $0 > 0 }.max() ?? 0
        self.buckets = buckets
        self.earliest = earliest
        self.usesCreditsScale = usesCreditsScale
        self.unit = unit
        self.color = color
        self.anchorDate = anchorDate
        self.windowSeconds = windowSeconds
        self.maxContiguousGap = maxContiguousGap
        self.yMax = Self.axisMax(peak: peak, usesCreditsScale: usesCreditsScale)
    }

    /// 실제 관찰된 표본 최대치(peak)를 그대로 상한으로 사용한다.
    /// peak가 양의 유한수가 아니면 fallback(퍼센트 5, 크레딧 10) 적용.
    private static func axisMax(peak: Double, usesCreditsScale: Bool) -> Double {
        if peak.isFinite && peak > 0 {
            return peak
        }
        return usesCreditsScale ? 10 : 5
    }

    var hasData: Bool { !buckets.isEmpty }

    func axisText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value) < 1e-9 { return "0" }
        if usesCreditsScale {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        }
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        // 소수점 유효숫자 최대 2자리까지 표기하되 불필요한 뒷자리 0 제거
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func amountText(_ value: Double) -> String {
        usesCreditsScale ? "\(axisText(value.rounded()))\(unit)" : String(format: "%.1f%%", value)
    }

    var accessibilityDescription: String {
        let head = "24시간 사용 추이, 왼쪽 최신 \(Self.clockFormatter.string(from: anchorDate)), 오른쪽 24시간 전"
        guard let latest = buckets.first, let peak = buckets.map(\.amount).max() else {
            return "\(head), 기록 없음"
        }
        let running = latest.isInProgress ? "진행 중인 30분 " : "최근 30분 "
        return "\(head), \(buckets.count)개 구간, \(running)소모 \(amountText(latest.amount)), 30분 최대 소모 \(amountText(peak))"
    }
}

/// 카드 하단 전폭 24시간 차트: 왼쪽 y 눈금(최대·절반·0), 옅은 점선 격자 위 선+면적, 아래 '지금'/'24시간 전'.
/// 모델이 없거나 기록이 비면 선을 그리지 않고 빈 격자만 둔다(가짜 0 없음).
struct Account24hPlot: View {
    let model: Account24hModel?
    let placeholder: String
    /// 기록이 24시간보다 짧을 때만 있는 '기록 N시간' 표기(가운데).
    var coverage: String? = nil
    /// nil이면 위에서 준 높이를 모두 채운다.
    var fixedHeight: CGFloat? = nil

    static let gutter: CGFloat = 34
    private static let topPad: CGFloat = 5
    private static let bottomPad: CGFloat = 3

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                axisLabels
                    .frame(width: Self.gutter)
                ZStack {
                    Restrained24hLineAreaCanvas(
                        series: model.map { [(color: $0.color, buckets: $0.buckets)] } ?? [],
                        anchorDate: model?.anchorDate ?? Date(),
                        windowSeconds: model?.windowSeconds ?? UsageSnapshot.nasHistory24hWindowSeconds,
                        maxContiguousGap: model?.maxContiguousGap ?? 30 * 60,
                        yMax: model?.yMax ?? 100,
                        earliestDate: model?.earliest,
                        areaTopOpacity: 0.40,
                        compact: true,
                        topPad: Self.topPad,
                        bottomPad: Self.bottomPad
                    )
                    if model == nil {
                        emptyCaption(placeholder)
                    } else if model?.hasData == false {
                        emptyCaption("최근 24시간 기록 없음")
                    }
                }
            }
            .frame(minHeight: 20, maxHeight: fixedHeight == nil ? .infinity : nil)
            .frame(height: fixedHeight)

            HStack(spacing: 0) {
                Text("지금")
                Spacer(minLength: 2)
                if let coverage {
                    Text(coverage)
                    Spacer(minLength: 2)
                }
                Text("24시간 전")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(CCMBDash.muted)
            .lineLimit(1)
            .padding(.leading, Self.gutter + 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model?.accessibilityDescription ?? "24시간 사용 추이, \(placeholder)")
    }

    private func emptyCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(CCMBDash.muted)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 8)
    }

    private var axisLabels: some View {
        GeometryReader { geo in
            if let model, model.hasData {
                let usable = max(1, geo.size.height - Self.topPad - Self.bottomPad)
                ForEach(Array([(1.0, model.yMax), (0.5, model.yMax / 2), (0.0, 0.0)].enumerated()), id: \.offset) { _, tick in
                    Text(model.axisText(tick.1))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(CCMBDash.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: geo.size.width, alignment: .trailing)
                        .position(x: geo.size.width / 2, y: Self.topPad + CGFloat(1 - tick.0) * usable)
                }
            }
        }
    }
}

/// Draws restrained line + subtle area curves of 30-minute consumption on a fixed 24-hour axis:
/// - `x = 0` (left edge) is `anchorDate` (latest/current, the running half hour).
/// - `x = size.width` (right edge) is `anchorDate - 24h` (24 hours ago).
/// - Contiguous runs break on empty half hours, collection gaps (`> maxContiguousGap`) or segment ID changes.
/// - Uncollected time ranges remain honestly empty without fabricated zero lines.
/// - A running or cut-short half hour is drawn hollow and linked with a dashed stroke.
struct Restrained24hLineAreaCanvas: View {
    let series: [(color: Color, buckets: [ConsumptionBucket])]
    let anchorDate: Date
    let windowSeconds: TimeInterval
    let maxContiguousGap: TimeInterval
    let yMax: Double
    let earliestDate: Date?
    let areaTopOpacity: Double
    /// 카드용 모양: 바탕 틀·세로 격자 없이 옅은 점선 가로 격자만 둔다.
    var compact: Bool = false
    var topPad: CGFloat = 6
    var bottomPad: CGFloat = 4

    private struct Node {
        let point: CGPoint
        let isEdge: Bool
    }

    private func xPosition(for date: Date, width: CGFloat) -> CGFloat {
        let age = max(0, min(windowSeconds, anchorDate.timeIntervalSince(date)))
        return CGFloat(age / max(1, windowSeconds)) * width
    }

    private func yPosition(for amount: Double, usableHeight: CGFloat, baselineY: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, amount / max(0.0001, yMax)))
        return baselineY - CGFloat(clamped) * usableHeight
    }

    var body: some View {
        Canvas { context, size in
            let usableHeight = max(1, size.height - topPad - bottomPad)
            let baselineY = size.height - bottomPad

            // 1. Subtle background frame
            if !compact {
                let plotRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                context.fill(
                    Path(roundedRect: plotRect, cornerRadius: 8),
                    with: .color(.secondary.opacity(0.05))
                )
            }

            // 2. If coverage is partial (< 23.5h), subtly shade the uncollected older region on the right
            if let earliestDate {
                let earliestX = xPosition(for: earliestDate, width: size.width)
                if earliestX < size.width - 6 {
                    let uncollectedRect = CGRect(
                        x: earliestX,
                        y: 0,
                        width: size.width - earliestX,
                        height: size.height
                    )
                    context.fill(
                        Path(uncollectedRect),
                        with: .color(.secondary.opacity(0.04))
                    )
                    var boundary = Path()
                    boundary.move(to: CGPoint(x: earliestX, y: topPad))
                    boundary.addLine(to: CGPoint(x: earliestX, y: baselineY))
                    context.stroke(
                        boundary,
                        with: .color(.secondary.opacity(0.28)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                }
            }

            // 3. Horizontal reference grid lines (top, 50%, baseline)
            for fraction in [0.0, 0.5, 1.0] {
                let y = topPad + CGFloat(fraction) * usableHeight
                var hLine = Path()
                hLine.move(to: CGPoint(x: 0, y: y))
                hLine.addLine(to: CGPoint(x: size.width, y: y))
                if compact {
                    context.stroke(
                        hLine,
                        with: .color(CCMBDash.grid.opacity(fraction == 1.0 ? 0.9 : 0.7)),
                        style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
                    )
                } else {
                    context.stroke(
                        hLine,
                        with: .color(.secondary.opacity(fraction == 1.0 ? 0.26 : 0.14)),
                        style: StrokeStyle(lineWidth: fraction == 1.0 ? 1.0 : 0.75)
                    )
                }
            }

            // 4. Vertical 6-hour grid lines (0h left, -6h, -12h, -18h, -24h right)
            for quarter in 1...3 where !compact {
                let x = size.width * CGFloat(quarter) / 4.0
                var vLine = Path()
                vLine.move(to: CGPoint(x: x, y: topPad))
                vLine.addLine(to: CGPoint(x: x, y: baselineY))
                context.stroke(
                    vLine,
                    with: .color(.secondary.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 0.75, dash: [2, 3])
                )
            }

            // 5. Each series' runs: area under complete half hours, thin angular line, hollow marker on partial ones
            for entry in series.reversed() {
                for run in ConsumptionBucketing.runs(entry.buckets, gap: maxContiguousGap) {
                    let nodes = run.map { bucket in
                        Node(
                            point: CGPoint(
                                x: xPosition(for: bucket.midpoint, width: size.width),
                                y: yPosition(for: bucket.amount, usableHeight: usableHeight, baselineY: baselineY)
                            ),
                            isEdge: bucket.isEdge
                        )
                    }
                    let complete = nodes.filter { !$0.isEdge }.map(\.point)
                    if complete.count >= 2, let head = complete.first, let tail = complete.last {
                        var areaPath = Path()
                        areaPath.move(to: CGPoint(x: head.x, y: baselineY))
                        for pt in complete {
                            areaPath.addLine(to: pt)
                        }
                        areaPath.addLine(to: CGPoint(x: tail.x, y: baselineY))
                        areaPath.closeSubpath()
                        // 실제 값이 낮아도 보이도록 그라데이션은 이 구간의 가장 높은 점에서 시작한다.
                        let areaTopY = min(complete.map(\.y).min() ?? baselineY, baselineY - 1)
                        context.fill(
                            areaPath,
                            with: .linearGradient(
                                Gradient(colors: [
                                    entry.color.opacity(areaTopOpacity),
                                    entry.color.opacity(0.12)
                                ]),
                                startPoint: CGPoint(x: 0, y: areaTopY),
                                endPoint: CGPoint(x: 0, y: baselineY)
                            )
                        )
                    }
                    for (newer, older) in zip(nodes, nodes.dropFirst()) {
                        var link = Path()
                        link.move(to: newer.point)
                        link.addLine(to: older.point)
                        let partial = newer.isEdge || older.isEdge
                        context.stroke(
                            link,
                            with: .color(entry.color),
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                lineCap: .butt,
                                lineJoin: .miter,
                                dash: partial ? [3, 2.5] : []
                            )
                        )
                    }
                    for node in nodes where node.isEdge || nodes.count == 1 {
                        let dotRect = CGRect(x: node.point.x - 2.5, y: node.point.y - 2.5, width: 5, height: 5)
                        if node.isEdge {
                            context.stroke(Path(ellipseIn: dotRect), with: .color(entry.color), lineWidth: 1.2)
                        } else {
                            context.fill(Path(ellipseIn: dotRect), with: .color(entry.color))
                        }
                    }
                }
            }
        }
    }
}

struct CompactRefreshControl: View {
    @EnvironmentObject private var store: SnapshotStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            refreshButton(now: context.date)
        }
    }

    private func refreshButton(now: Date) -> some View {
        let remaining = max(0, store.nextAutomaticRefreshAt?.timeIntervalSince(now) ?? 0)
        return Button {
            store.refresh()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(CCMBDash.ink)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("지금 새로 고침. 다음 자동 갱신까지 \(Int(ceil(remaining)))초")
    }
}
