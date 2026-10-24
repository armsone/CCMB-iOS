import SwiftUI

/// 승인된 대시보드의 전폭 계정 카드 한 장(Codex / Claude / Gemini 계정별).
/// 왼쪽 위 아이콘·이름·계정 ID, 오른쪽 위 한도(색 큰 숫자 + 개별 초기화 시각 + 얇은 막대),
/// 아래 전폭 24시간 선+면적 그래프. 카드 전체가 해당 서비스의 ServiceDetailView로 이어진다.
struct AccountCardView: View {
    @EnvironmentObject private var store: SnapshotStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var accessibilityScale: CGFloat = 1

    let usage: ServiceUsage
    let history: DashboardHistory
    /// 기준 높이. nil이면 내용 높이(큰 글자 크기)로 늘어나 스크롤에 맡긴다.
    let height: CGFloat?

    // MARK: Reference geometry

    /// 승인 이미지의 카드 비율(Codex 173 : Claude 139 : Gemini 132).
    static func referenceHeight(for service: Service) -> CGFloat {
        switch service {
        case .codex: return 173
        case .claude: return 139
        default: return 132
        }
    }

    /// 그래프가 최소한 읽히도록 지키는 카드 높이.
    static func minimumHeight(for service: Service) -> CGFloat {
        service == .codex ? 159 : 114
    }

    private static let quotaRowHeight: CGFloat = 51
    private static let barHeight: CGFloat = 7
    private static let barWidth: CGFloat = 176

    private var isNatural: Bool { height == nil }
    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }
    private var accent: Color { CCMBDash.accent(usage.service) }

    /// 일반 글자 크기에서는 승인 이미지의 고정 크기, 접근성 크기에서만 비례 확대.
    private func fs(_ base: CGFloat) -> CGFloat {
        isAccessibilitySize ? base * min(accessibilityScale, 2.2) : base
    }

    // MARK: Data

    private struct QuotaItem: Identifiable {
        let id: String
        let label: String
        let window: UsageWindow?
        let color: Color
    }

    private func window(_ id: String) -> UsageWindow? {
        usage.windows.first { $0.id == id }
    }

    private var quotaItems: [QuotaItem] {
        switch usage.service {
        case .codex:
            return [QuotaItem(id: "weekly", label: "주간", window: window("weekly"), color: accent)]
        case .claude:
            return [
                QuotaItem(id: "fiveHour", label: "세션", window: window("fiveHour"), color: CCMBDash.claude),
                QuotaItem(id: "weekly", label: "주간", window: window("weekly"), color: CCMBDash.claude),
                QuotaItem(id: "fableWeekly", label: "페이블", window: window("fableWeekly"), color: CCMBDash.fable)
            ]
        default:
            return [
                QuotaItem(id: "five", label: "5시간", window: geminiSessionWindow, color: accent),
                QuotaItem(id: "weekly", label: "주간", window: geminiWeeklyWindow, color: accent)
            ]
        }
    }

    private var geminiSessionWindow: UsageWindow? {
        usage.windows.first {
            $0.id == "cliFiveHour" || $0.id == "fiveHour" || ($0.id.hasPrefix("cli") && $0.id.contains("FiveHour"))
        } ?? usage.windows.first
    }

    private var geminiWeeklyWindow: UsageWindow? {
        usage.windows.first {
            $0.id == "cliWeekly" || $0.id == "weekly" || ($0.id.hasPrefix("cli") && $0.id.contains("Weekly"))
        } ?? (usage.windows.count > 1 ? usage.windows[1] : nil)
    }

    private var serviceName: String {
        switch usage.service {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini, .gemini2, .gemini3: return "Gemini"
        case .grok: return "Grok"
        }
    }

    /// 실제 계정 표시값에서 이메일 도메인을 뗀 ID. 메타데이터가 없으면 중립 문구.
    private var accountID: String {
        if let id = CCMBFormat.accountID(usage) { return id }
        switch usage.service {
        case .gemini: return "본계정"
        case .gemini2: return "부계정"
        case .gemini3: return "세 번째 계정"
        default: return "계정 정보 없음"
        }
    }

    // MARK: Codex metrics

    private var tokenLabel: String {
        store.displayedSource == .nas ? "토큰" : "크레딧"
    }

    private var tokenText: String {
        if usage.creditUnlimited { return "무제한" }
        guard let value = usage.creditBalance else { return "—" }
        return CCMBFormat.groupedInteger(value)
    }

    private var resetCreditCount: Int? {
        usage.codexResetCreditsAvailable ?? (usage.codexResetCreditExpirations.isEmpty ? nil : usage.codexResetCreditExpirations.count)
    }

    /// 같은 시각에 만료되는 리셋권은 한 줄로 묶고 줄에는 날짜·시각만 둔다. 많으면 앞의 둘만 보이고 '외 N개'.
    private var expiryLines: [String] {
        let dates = usage.codexResetCreditExpirations.sorted()
        guard !dates.isEmpty else { return [] }
        var groups: [(date: Date, count: Int)] = []
        for date in dates {
            let stamp = CCMBFormat.monthDayTime(date)
            if let last = groups.last, CCMBFormat.monthDayTime(last.date) == stamp {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((date, 1))
            }
        }
        var lines = groups.prefix(3).map { CCMBFormat.quotaTime($0.date) }
        if groups.count > 3 {
            let rest = groups.dropFirst(2).reduce(0) { $0 + $1.count }
            lines = Array(lines.prefix(2)) + ["외 \(rest)개"]
        }
        return lines
    }

    private var expiryEmptyText: String {
        resetCreditCount == 0 ? "없음" : "만료정보없음"
    }

    /// 만료 목록이 세 줄이면 Codex 지표 행이 한 줄만큼 늘어난다.
    private var extraExpiryHeight: CGFloat {
        isNatural ? 0 : CGFloat(max(0, expiryLines.count - 2)) * 13
    }

    // MARK: Notice

    private var cardNotice: (text: String, isError: Bool)? {
        var parts: [String] = []
        var isError = false
        if store.displayedSource == .nas, store.nasRefreshBusy, usage.service != .grok {
            parts.append("갱신 중")
        }
        if let reason = usage.errorReason {
            parts.append(reason)
            isError = true
        }
        if usage.isLastKnown {
            parts.append("마지막 정상값")
        } else if usage.status == "stale" || usage.stale, usage.hasAnyData {
            parts.append("오래된 값")
        }
        if usage.isLastKnown || usage.status == "stale", let fetchedAt = usage.fetchedAt {
            parts.append("원본 \(CCMBFormat.macCollectionTime(fetchedAt)) 조회")
        }
        if usage.status == "partial" { parts.append("일부만") }
        if !usage.hasAnyData {
            parts.append(store.displayedSource == .nas
                ? "정보 없음 — NAS에서 이 계정의 값을 아직 받지 못했습니다."
                : "정보 없음 — Mac의 CCMB에서 이 서비스가 켜져 있는지 확인하세요.")
        }
        if [.gemini, .gemini2, .gemini3].contains(usage.service) {
            let online = usage.windows.filter { $0.id.hasPrefix("online") && $0.remainingPercent != nil }
            if store.displayedSource == .nas, !online.isEmpty, let issue = store.geminiOnlineIssue {
                parts.append("온라인 값은 마지막 저장값 · \(issue)")
                isError = true
            } else if online.contains(where: { window in
                guard let fetchedAt = window.fetchedAt else { return false }
                return Date().timeIntervalSince(fetchedAt) > UsageSnapshot.staleAfterSeconds
            }) {
                parts.append("온라인 값 오래됨")
            }
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), isError)
    }

    private func noticeHeight(_ text: String) -> CGFloat {
        let lines = min(3, max(1, Int(ceil(Double(text.count) * 9.5 / 330))))
        return CGFloat(lines) * 13 + 4
    }

    // MARK: Body

    var body: some View {
        let notice = cardNotice
        let model = history.model(for: usage.service)
        let fixedHeight = height.map { $0 + extraExpiryHeight + (notice.map { noticeHeight($0.text) } ?? 0) }

        VStack(alignment: .leading, spacing: 0) {
            if isNatural {
                naturalContent(model: model)
            } else if usage.service == .codex {
                codexContent(model: model)
            } else {
                standardContent(model: model)
            }

            if let notice {
                Text(notice.text)
                    .font(.system(size: fs(10)))
                    .foregroundStyle(notice.isError ? CCMBTheme.signalRed : CCMBDash.muted)
                    .lineLimit(isNatural ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .frame(height: fixedHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: CCMBDash.cardRadius, style: .continuous)
                .fill(CCMBDash.card)
                .shadow(color: Color(.sRGB, red: 0.25, green: 0.45, blue: 0.75, opacity: 0.08), radius: 8, x: 0, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: CCMBDash.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(notice: notice?.text, chart: model?.accessibilityDescription))
        .accessibilityHint("자세한 내용을 보려면 여세요.")
    }

    private func plot(_ model: Account24hModel?, fixedHeight: CGFloat? = nil) -> some View {
        Account24hPlot(
            model: model,
            placeholder: history.placeholder,
            coverage: model == nil ? nil : history.coverageShort,
            fixedHeight: fixedHeight
        )
    }

    // MARK: Layouts

    /// Claude·Gemini: 위 한 줄(아이콘/이름 + 한도), 그 아래 전폭 그래프.
    private func standardContent(model: Account24hModel?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    identityRow
                    Spacer(minLength: 0)
                }
                .layoutPriority(1)
                quotaBlock
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: Self.quotaRowHeight + 2 + Self.barHeight)

            plot(model)
                .padding(.top, 3)
        }
    }

    /// Codex: 위 한 줄(아이콘/이름 + 주간 수치·초기화·남은 막대), 지표 한 줄(토큰·리셋권·만료), 전폭 그래프.
    private func codexContent(model: Account24hModel?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                identityRow
                    .layoutPriority(1)
                quotaBlock
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: Self.quotaRowHeight + 2 + Self.barHeight)

            codexStats
                .frame(height: 40 + extraExpiryHeight)
                .padding(.top, 4)

            plot(model)
                .padding(.top, 3)
        }
    }

    /// 큰 글자 크기: 세로로 쌓고 그래프만 고정 높이로 둔다. 화면이 넘치면 스크롤된다.
    private func naturalContent(model: Account24hModel?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            identityRow
            if usage.service == .codex {
                quotaColumn(quotaItems[0], alignment: .leading)
                DashQuotaBar(remaining: quotaItems[0].window?.remainingPercent, tint: quotaItems[0].color, height: Self.barHeight)
                codexStatsStacked
            } else {
                ForEach(quotaItems) { item in
                    quotaColumn(item, alignment: .leading)
                }
                if let primary = quotaItems.first {
                    DashQuotaBar(remaining: primary.window?.remainingPercent, tint: primary.color, height: Self.barHeight)
                }
            }
            plot(model, fixedHeight: 96)
        }
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(spacing: 10) {
            AccountIconView(service: usage.service, accent: accent, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(serviceName)
                    .font(.system(size: fs(19), weight: .bold))
                    .foregroundStyle(CCMBDash.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(accountID)
                    .font(.system(size: fs(12)))
                    .foregroundStyle(CCMBDash.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(height: 36, alignment: .leading)
        .frame(minHeight: isNatural ? 36 : nil)
    }

    // MARK: Quota

    private var quotaBlock: some View {
        let items = quotaItems
        let blockWidth: CGFloat = usage.service == .claude ? 232 : Self.barWidth
        return VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(CCMBDash.divider)
                            .frame(width: 1, height: 40)
                            .padding(.top, 5)
                    }
                    quotaColumn(item, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.quotaRowHeight)

            DashQuotaBar(
                remaining: items.first?.window?.remainingPercent,
                tint: items.first?.color ?? accent,
                height: Self.barHeight
            )
            .padding(.leading, max(0, blockWidth - Self.barWidth))
        }
        .frame(maxWidth: blockWidth)
    }

    private func quotaColumn(_ item: QuotaItem, alignment: HorizontalAlignment) -> some View {
        let textAlignment: TextAlignment = alignment == .leading ? .leading : .center
        let frameAlignment: Alignment = alignment == .leading ? .leading : .center
        return VStack(alignment: alignment, spacing: 0) {
            Text(item.label)
                .font(.system(size: fs(12)))
                .foregroundStyle(CCMBDash.muted)
                .lineLimit(1)
                .frame(height: isNatural ? nil : 13)
            if let percent = item.window?.remainingPercent {
                Text(String(format: "%.0f%%", percent))
                    .font(.system(size: fs(24), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(item.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: isNatural ? nil : 26)
            } else {
                Text("—")
                    .font(.system(size: fs(20), weight: .bold))
                    .foregroundStyle(CCMBDash.muted)
                    .frame(height: isNatural ? nil : 26)
            }
            Text(resetText(for: item.window))
                .font(.system(size: fs(9.5)))
                .foregroundStyle(CCMBDash.muted)
                .monospacedDigit()
                .multilineTextAlignment(textAlignment)
                .lineLimit(isNatural ? 3 : 1)
                .minimumScaleFactor(0.8)
                .frame(height: isNatural ? nil : 12, alignment: frameAlignment)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    /// 한도마다 자기 초기화 시각: 'HH:mm'(오늘), '내일 HH:mm', '모레 HH:mm', 'MM/dd(요일) HH:mm'.
    private func resetText(for window: UsageWindow?) -> String {
        guard let window else { return "초기화 정보 없음" }
        if let resetsAt = window.resetsAt {
            return resetsAt.timeIntervalSinceNow > 0 ? CCMBFormat.quotaTime(resetsAt) : "갱신 대기"
        }
        if let caption = CCMBFormat.quotaResetText(window.resetText) {
            return caption
        }
        if window.remainingPercent == nil, let note = window.unavailabilityNote {
            return note
        }
        return "초기화 정보 없음"
    }

    // MARK: Codex stats

    private var codexStats: some View {
        HStack(alignment: .top, spacing: 0) {
            statColumn(title: tokenLabel, value: tokenText, color: CCMBDash.ink)
            statDivider
            statColumn(
                title: "리셋권",
                value: resetCreditCount.map { "\($0)개" } ?? "—",
                color: accent
            )
            statDivider
            expiryColumn
        }
    }

    private var codexStatsStacked: some View {
        VStack(alignment: .leading, spacing: 8) {
            statColumn(title: tokenLabel, value: tokenText, color: CCMBDash.ink)
            statColumn(title: "리셋권", value: resetCreditCount.map { "\($0)개" } ?? "—", color: accent)
            expiryColumn
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(CCMBDash.divider)
            .frame(width: 1, height: 38)
            .padding(.top, 2)
    }

    private func statColumn(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: fs(12)))
                .foregroundStyle(CCMBDash.muted)
                .lineLimit(1)
                .frame(height: isNatural ? nil : 14)
            Text(value)
                .font(.system(size: fs(22), weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(height: isNatural ? nil : 26)
        }
        .frame(maxWidth: .infinity)
    }

    private var expiryColumn: some View {
        VStack(spacing: 0) {
            Text("리셋권 만료")
                .font(.system(size: fs(12)))
                .foregroundStyle(CCMBDash.muted)
                .lineLimit(1)
                .frame(height: isNatural ? nil : 14)
            let lines = expiryLines
            if lines.isEmpty {
                Text(expiryEmptyText)
                    .font(.system(size: fs(10.5)))
                    .foregroundStyle(CCMBDash.muted)
                    .lineLimit(1)
                    .frame(height: isNatural ? nil : 13)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: fs(10.5)))
                        .monospacedDigit()
                        .foregroundStyle(CCMBDash.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(height: isNatural ? nil : 13)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Accessibility

    private func accessibilitySummary(notice: String?, chart: String?) -> String {
        var parts = ["\(serviceName) \(accountID)"]
        for item in quotaItems {
            if let percent = item.window?.remainingPercent {
                var entry = "\(item.label) 남음 \(CCMBFormat.percent(percent))"
                if let resetsAt = item.window?.resetsAt { entry += ", 초기화 \(CCMBFormat.resetTime(resetsAt))" }
                parts.append(entry)
            } else {
                parts.append("\(item.label) 정보 없음")
            }
        }
        if usage.service == .codex {
            parts.append("\(tokenLabel) \(tokenText)")
            parts.append("리셋권 \(resetCreditCount.map { "\($0)개" } ?? "정보 없음")")
            parts.append(expiryLines.isEmpty ? "리셋권 만료 \(expiryEmptyText)" : "리셋권 만료 \(expiryLines.joined(separator: ", "))")
        }
        if let notice { parts.append(notice) }
        if let chart { parts.append(chart) }
        return parts.joined(separator: ", ")
    }
}

/// 서비스 아이콘(약 36pt 둥근 사각형): Codex 짙은 남색 + 청록 `>_`, Claude 산호색 + 흰 방사형,
/// Gemini 계정색 + 흰 G. 이미지 자산 없이 SwiftUI 도형으로 그린다.
struct AccountIconView: View {
    let service: Service
    let accent: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(fill)
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        service == .codex ? CCMBDash.codexIcon : accent
    }

    @ViewBuilder
    private var glyph: some View {
        switch service {
        case .codex:
            Canvas { context, canvasSize in
                let w = canvasSize.width, h = canvasSize.height
                var chevron = Path()
                chevron.move(to: CGPoint(x: w * 0.25, y: h * 0.33))
                chevron.addLine(to: CGPoint(x: w * 0.46, y: h * 0.50))
                chevron.addLine(to: CGPoint(x: w * 0.25, y: h * 0.67))
                var underscore = Path()
                underscore.move(to: CGPoint(x: w * 0.54, y: h * 0.68))
                underscore.addLine(to: CGPoint(x: w * 0.76, y: h * 0.68))
                let teal = Color(.sRGB, red: 0.12, green: 0.82, blue: 0.62, opacity: 1)
                let style = StrokeStyle(lineWidth: w * 0.085, lineCap: .round, lineJoin: .round)
                context.stroke(chevron, with: .color(teal), style: style)
                context.stroke(underscore, with: .color(teal), style: style)
            }
        case .claude:
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let unit = canvasSize.width
                let rays = 12
                for index in 0..<rays {
                    let angle = Double(index) / Double(rays) * 2 * .pi
                    let outer = (index % 2 == 0 ? 0.31 : 0.25) * unit
                    let inner = 0.08 * unit
                    var ray = Path()
                    ray.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
                    ray.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer, y: center.y + CGFloat(sin(angle)) * outer))
                    context.stroke(ray, with: .color(.white), style: StrokeStyle(lineWidth: unit * 0.05, lineCap: .round))
                }
            }
        default:
            Text("G")
                .font(.system(size: size * 0.62, weight: .heavy))
                .foregroundStyle(.white)
        }
    }
}

/// 주 한도 막대: 채워진 부분이 표시된 남은 %와 같다. 값이 없으면 0으로 채우지 않고 빈 트랙만 둔다.
struct DashQuotaBar: View {
    let remaining: Double?
    let tint: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CCMBDash.track)
                if let remaining {
                    let fraction = CGFloat(min(100, max(0, remaining.rounded())) / 100)
                    Capsule()
                        .fill(tint)
                        .frame(width: fraction > 0 ? max(height, geo.size.width * fraction) : 0)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
