import SwiftUI

/// Visual identity carried over from the Mac app: large neutral surfaces,
/// charcoal ink instead of pure black, and the signal red reserved for small
/// structural accents (경고, 활성 표시) — never decoration.
enum CCMBTheme {
    /// #E41E25 — the Mac app's structural accent.
    static let signalRed = Color(red: 0xE4 / 255, green: 0x1E / 255, blue: 0x25 / 255)

    /// Charcoal ink for gauges and emphasized values; follows dark mode.
    static let charcoal = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.86, green: 0.87, blue: 0.88, alpha: 1)
            : UIColor(red: 0.19, green: 0.20, blue: 0.22, alpha: 1)
    })

    /// Remaining percentages below this switch the gauge to signal red.
    static let lowRemainingThreshold: Double = 10

    static func gaugeTint(remainingPercent: Double?) -> Color {
        guard let remainingPercent else { return .secondary }
        return remainingPercent < lowRemainingThreshold ? signalRed : charcoal
    }

    /// Google 브랜드 네 번째 색(#34A853). 현재 계정은 3개라 예비 팔레트로만 둔다.
    static let geminiReserveGreen = Color(.sRGB, red: 52/255.0, green: 168/255.0, blue: 83/255.0, opacity: 1)

    static func serviceTint(_ service: Service, windowID: String? = nil) -> Color {
        switch service {
        case .codex:
            return Color(.sRGB, red: 16/255.0, green: 163/255.0, blue: 127/255.0, opacity: 1)
        case .claude:
            switch windowID {
            case "fableWeekly": return Color(.sRGB, red: 230/255.0, green: 154/255.0, blue: 127/255.0, opacity: 1)
            case "weekly": return Color(.sRGB, red: 196/255.0, green: 93/255.0, blue: 66/255.0, opacity: 1)
            default: return Color(.sRGB, red: 217/255.0, green: 119/255.0, blue: 87/255.0, opacity: 1)
            }
        // Gemini 계정 대표색: Google 브랜드 순서(파랑·빨강·노랑), 네 번째 초록은 예비.
        // 홈 쿼터 행, 24시간 그래프, 상세 화면이 모두 이 값을 따른다.
        case .gemini:
            return Color(.sRGB, red: 66/255.0, green: 133/255.0, blue: 244/255.0, opacity: 1)
        case .gemini2:
            return Color(.sRGB, red: 234/255.0, green: 67/255.0, blue: 53/255.0, opacity: 1)
        case .gemini3:
            return Color(.sRGB, red: 251/255.0, green: 188/255.0, blue: 5/255.0, opacity: 1)
        case .grok:
            return charcoal
        }
    }
}

enum CCMBFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "정보 없음" }
        return String(format: "%.1f%%", value)
    }

    static func credits(_ value: Double?) -> String {
        guard let value else { return "정보 없음" }
        return String(format: "%.0f", value)
    }

    /// "9/3(목) 14:00" 형태의 요일 포함 24시간 초기화 시각.
    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "정보 없음" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M/d(EEEEE) HH:mm"
        return formatter.string(from: date)
    }

    private enum ParsedResetText {
        case date(Date)
        case timeOnly(String)
        case raw(String?)
    }

    private static func parseResetText(_ source: String?, referenceDate: Date) -> ParsedResetText {
        guard var text = source?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .raw(nil)
        }
        for suffix in ["에 초기화", "에 재설정", " resets"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }

        let calendar = Calendar.autoupdatingCurrent
        let year = calendar.component(.year, from: referenceDate)
        let datedInputs: [(String, String, String)] = [
            ("ko_KR", "yyyy년 M월 d일 a h:mm", "\(year)년 \(text)"),
            ("en_US_POSIX", "yyyy MMM d 'at' h:mm a", "\(year) \(text)"),
            ("en_US_POSIX", "yyyy MMM d, 'at' h:mm a", "\(year) \(text)")
        ]
        for (localeID, format, input) in datedInputs {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeID)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            if let date = formatter.date(from: input) {
                return .date(date)
            }
        }

        for (localeID, format) in [("ko_KR", "a h:mm"), ("en_US_POSIX", "h:mm a")] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeID)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                let output = DateFormatter()
                output.locale = Locale(identifier: "ko_KR")
                output.timeZone = .autoupdatingCurrent
                output.dateFormat = "HH:mm"
                return .timeOnly(output.string(from: date))
            }
        }
        return .raw(source)
    }

    /// Gemini 온라인처럼 날짜 대신 화면 문구로 전달된 초기화 시각도
    /// 앱의 공통 날짜·시간 표기로 정규화한다.
    static func resetText(_ source: String?, referenceDate: Date = Date()) -> String? {
        switch parseResetText(source, referenceDate: referenceDate) {
        case .date(let date): return resetTime(date)
        case .timeOnly(let time): return time
        case .raw(let raw): return raw
        }
    }

    /// 카드용: 같은 문구를 오늘 HH:mm / 내일 / 모레 / MM/dd 표기로 정규화한다.
    static func quotaResetText(_ source: String?, now: Date = Date()) -> String? {
        switch parseResetText(source, referenceDate: now) {
        case .date(let date): return quotaTime(date, now: now)
        case .timeOnly(let time): return time
        case .raw(let raw): return raw
        }
    }

    /// "3분 전" 형태의 데이터 나이.
    static func relativeAge(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "시각 정보 없음" }
        // CloudKit의 서버 시각과 기기 시각은 몇 초 어긋날 수 있다. 갓 읽은
        // 데이터가 "0초 후"로 보이지 않도록 1분 이내와 미래값을 방금으로 묶는다.
        if now.timeIntervalSince(date) < 60 {
            return "방금"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Mac이 마지막으로 사용량을 수집한 시각.
    /// 오늘은 시각만, 어제·그제는 한글 날짜, 그 이전은 월/일과 24시간 시각을 표시한다.
    static func macCollectionTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "시각 정보 없음" }

        let calendar = Calendar.autoupdatingCurrent
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .autoupdatingCurrent

        switch dayDifference {
        case 0:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        case 1:
            formatter.dateFormat = "HH:mm"
            return "어제 \(formatter.string(from: date))"
        case 2:
            formatter.dateFormat = "HH:mm"
            return "그제 \(formatter.string(from: date))"
        default:
            formatter.dateFormat = "M/d HH:mm"
            return formatter.string(from: date)
        }
    }
}

/// 승인된 라이트 카드 대시보드 전용 색. 전역 테마 선택은 건드리지 않고
/// 대시보드만 이 값을 쓴다(밝은 하늘색 바탕, 흰 카드, 청회색 보조 글자).
enum CCMBDash {
    static let canvasTop = Color(.sRGB, red: 240/255.0, green: 249/255.0, blue: 253/255.0, opacity: 1)
    static let canvasBottom = Color(.sRGB, red: 233/255.0, green: 246/255.0, blue: 254/255.0, opacity: 1)
    static let card = Color.white
    static let ink = Color(.sRGB, red: 0.04, green: 0.05, blue: 0.08, opacity: 1)
    static let muted = Color(.sRGB, red: 0.345, green: 0.424, blue: 0.627, opacity: 1)
    static let track = Color(.sRGB, red: 229/255.0, green: 233/255.0, blue: 238/255.0, opacity: 1)
    static let divider = Color(.sRGB, red: 0.89, green: 0.91, blue: 0.945, opacity: 1)
    static let grid = Color(.sRGB, red: 0.80, green: 0.85, blue: 0.92, opacity: 1)
    static let codexIcon = Color(.sRGB, red: 2/255.0, green: 23/255.0, blue: 44/255.0, opacity: 1)
    /// Claude 산호색(카드 아이콘·수치·막대·24시간 선이 같은 색).
    static let claude = Color(.sRGB, red: 250/255.0, green: 96/255.0, blue: 50/255.0, opacity: 1)
    /// 페이블(Fable) 주간 수치 색.
    static let fable = Color(.sRGB, red: 80/255.0, green: 101/255.0, blue: 158/255.0, opacity: 1)

    static func accent(_ service: Service) -> Color {
        service == .claude ? claude : CCMBTheme.serviceTint(service)
    }

    /// 카드 가로 여백과 둥글기.
    static let cardRadius: CGFloat = 16
}

extension CCMBFormat {
    private static func dashFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    /// 'MM/dd HH:mm' (예: 10/30 03:59).
    static func monthDayTime(_ date: Date) -> String {
        dashFormatter("MM/dd HH:mm").string(from: date)
    }

    /// 'MM/dd(EEE) HH:mm' 한글 요일 (예: 10/25(일) 13:25).
    static func monthDayWeekdayTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MM/dd(EEE) HH:mm"
        return formatter.string(from: date)
    }

    /// 카드 시각: 오늘 'HH:mm', 내일 '내일 HH:mm', 모레 '모레 HH:mm', 글피 이후와 지난 시각 'MM/dd(요일) HH:mm'.
    /// 날짜 경계는 기기 달력의 자정 기준이다.
    static func quotaTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let clock = dashFormatter("HH:mm").string(from: date)
        switch dayDifference {
        case 0: return clock
        case 1: return "내일 \(clock)"
        case 2: return "모레 \(clock)"
        default: return monthDayWeekdayTime(date)
        }
    }

    /// 쉼표와 정수만(예: 88,889). 소수는 올림·반올림 없이 버린다.
    static func groupedInteger(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.roundingMode = .down
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value.rounded(.towardZero))
    }

    /// 실제 계정 표시값에서 이메일 도메인을 뗀 ID. 값이 없으면 nil.
    static func accountID(_ usage: ServiceUsage) -> String? {
        for candidate in [usage.accountDisplay, usage.account] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if let at = raw.firstIndex(of: "@") {
                let local = String(raw[raw.startIndex..<at])
                if !local.isEmpty { return local }
                continue
            }
            return raw
        }
        return nil
    }
}
