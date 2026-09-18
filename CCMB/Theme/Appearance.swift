import SwiftUI
import UIKit

enum CCMBAppearance: String, CaseIterable, Identifiable {
    case automatic
    case daylight
    case night
    case casual

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: return "자동"
        case .daylight: return "주간"
        case .night: return "야간"
        case .casual: return "캐주얼"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .daylight: return "sun.max.fill"
        case .night: return "moon.stars.fill"
        case .casual: return "scribble.variable"
        }
    }

    var alternateIconName: String? {
        switch self {
        case .automatic: return nil
        case .daylight: return "AppIconDay"
        case .night: return "AppIconNight"
        case .casual: return "AppIconCasual"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .daylight, .casual: return .light
        case .night: return .dark
        }
    }

    var background: Color {
        switch self {
        case .automatic:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
                    : UIColor(red: 0.93, green: 0.98, blue: 1.00, alpha: 1)
            })
        case .daylight:
            return Color(red: 0.93, green: 0.98, blue: 1.00)
        case .night:
            return Color(red: 0.025, green: 0.035, blue: 0.055)
        case .casual:
            return Color(red: 0.05, green: 0.66, blue: 0.93)
        }
    }

    var card: Color {
        switch self {
        case .automatic:
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.075, green: 0.085, blue: 0.11, alpha: 0.98)
                    : UIColor.white.withAlphaComponent(0.92)
            })
        case .daylight:
            return Color.white.opacity(0.92)
        case .night:
            return Color(red: 0.075, green: 0.085, blue: 0.11).opacity(0.98)
        case .casual:
            return Color(red: 1.00, green: 0.985, blue: 0.91).opacity(0.98)
        }
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var selection: CCMBAppearance
    private let defaultsKey = "ccmb.appearance"

    init() {
        let saved = UserDefaults.standard.string(forKey: defaultsKey)
        switch saved {
        case "rings": selection = .automatic
        case "vivid": selection = .casual
        default: selection = CCMBAppearance(rawValue: saved ?? "") ?? .automatic
        }
    }

    func select(_ appearance: CCMBAppearance) {
        guard selection != appearance else { return }
        selection = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: defaultsKey)

        guard UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(appearance.alternateIconName) { error in
            if let error {
                print("CCMB alternate icon update failed: \(error.localizedDescription)")
            }
        }
    }
}
