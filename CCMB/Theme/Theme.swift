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

    static func serviceTint(_ service: Service, windowID: String? = nil) -> Color {
        switch service {
        case .codex:
            return Color(red: 0.08, green: 0.69, blue: 0.55)
        case .claude:
            return Color(red: 0.94, green: 0.43, blue: 0.26)
        case .gemini:
            switch windowID {
            case "cliWeekly": return Color(red: 0.78, green: 0.23, blue: 0.18)
            case "onlineFiveHour": return Color(red: 1.00, green: 0.68, blue: 0.02)
            case "onlineWeekly": return Color(red: 0.16, green: 0.68, blue: 0.32)
            default: return Color(red: 0.20, green: 0.48, blue: 0.98)
            }
        case .grok:
            return charcoal
        }
    }
}

enum CCMBFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "정보 없음" }
        return "\(Int(value.rounded()))%"
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

    /// Gemini 온라인처럼 날짜 대신 화면 문구로 전달된 초기화 시각도
    /// 앱의 공통 날짜·시간 표기로 정규화한다.
    static func resetText(_ source: String?, referenceDate: Date = Date()) -> String? {
        guard var text = source?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
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
                return resetTime(date)
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
                return output.string(from: date)
            }
        }
        return source
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
