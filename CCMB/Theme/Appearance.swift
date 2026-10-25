import SwiftUI
import UIKit

/// 병기스타일 팔레트 토큰(저장된 기준표 그대로). 컴포넌트는 `CCMBPalette.current`만 읽는다.
struct CCMBPalette {
    let bg: Color
    let card: Color
    let surface: Color
    let surface2: Color
    let text: Color
    let text2: Color
    let muted: Color
    let border: Color
    let border2: Color
    let accent: Color
    let accentStrong: Color
    let accentSoft: Color
    let onAccent: Color
    let warn: Color
    let warnSoft: Color
    let warnInk: Color
    let danger: Color
    let dangerSoft: Color

    /// 어두운 팔레트(자비스·울트론) 여부.
    var isDark: Bool { bg == Self.jarvis.bg || bg == Self.ultron.bg }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            opacity: 1
        )
    }

    static let light = CCMBPalette(
        bg: hex(0xf5f4f0), card: hex(0xfbfaf7), surface: hex(0xffffff), surface2: hex(0xecebe4),
        text: hex(0x1f211c), text2: hex(0x4a4c44), muted: hex(0x666860),
        border: hex(0xe2dfd5), border2: hex(0xd0cdc0),
        accent: hex(0x5c6b3c), accentStrong: hex(0x46532c), accentSoft: hex(0xe8ebdb), onAccent: hex(0xffffff),
        warn: hex(0x9c5415), warnSoft: hex(0xf7e9d8), warnInk: hex(0x6d3c10),
        danger: hex(0x9c3b2a), dangerSoft: hex(0xf6e3de)
    )

    static let friday = CCMBPalette(
        bg: hex(0xf7efe3), card: hex(0xfffaf1), surface: hex(0xfffdf8), surface2: hex(0xf0e2cc),
        text: hex(0x2a1f16), text2: hex(0x55422f), muted: hex(0x725b45),
        border: hex(0xe8d8c0), border2: hex(0xd3bb98),
        accent: hex(0x9a4a12), accentStrong: hex(0x743508), accentSoft: hex(0xf6dfc0), onAccent: hex(0xffffff),
        warn: hex(0x8a5a00), warnSoft: hex(0xf8e6b8), warnInk: hex(0x6d3c10),
        danger: hex(0xa3204a), dangerSoft: hex(0xf8dce4)
    )

    static let jarvis = CCMBPalette(
        bg: hex(0x0c1420), card: hex(0x121c2b), surface: hex(0x162337), surface2: hex(0x1c2d44),
        text: hex(0xe3edf7), text2: hex(0xb3c4d6), muted: hex(0x8da2b8),
        border: hex(0x20324a), border2: hex(0x2d4663),
        accent: hex(0x4cc2e6), accentStrong: hex(0x8fdcf3), accentSoft: hex(0x12324a), onAccent: hex(0x04202b),
        warn: hex(0xf0b45c), warnSoft: hex(0x3a2d16), warnInk: hex(0xf4cf94),
        danger: hex(0xf28b82), dangerSoft: hex(0x3d2126)
    )

    static let ultron = CCMBPalette(
        bg: hex(0x121316), card: hex(0x1a1c20), surface: hex(0x202328), surface2: hex(0x272a30),
        text: hex(0xe6e7ea), text2: hex(0xb8bbc2), muted: hex(0x8e929b),
        border: hex(0x2b2e34), border2: hex(0x3b3f47),
        accent: hex(0xf2566a), accentStrong: hex(0xff8a95), accentSoft: hex(0x3a1a20), onAccent: hex(0x1a0508),
        warn: hex(0xe8a24f), warnSoft: hex(0x36291a), warnInk: hex(0xf2c27f),
        danger: hex(0xff9a9a), dangerSoft: hex(0x3e1f22)
    )

    /// 현재 선택된 팔레트. `AppearanceStore`가 첫 렌더링 전에 동기적으로 채운다.
    nonisolated(unsafe) static var current: CCMBPalette = .light
}

/// 병기스타일 기본 테마 4종(라이트·프라이데이·자비스·울트론). 순서는 고정이며 마지막 다음은 처음이다.
enum CCMBAppearance: String, CaseIterable, Identifiable {
    case light
    case friday
    case jarvis
    case ultron

    var id: String { rawValue }

    var name: String {
        switch self {
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    var isDark: Bool { self == .jarvis || self == .ultron }

    var preferredColorScheme: ColorScheme { isDark ? .dark : .light }

    var palette: CCMBPalette {
        switch self {
        case .light: return .light
        case .friday: return .friday
        case .jarvis: return .jarvis
        case .ultron: return .ultron
        }
    }

    var next: CCMBAppearance {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var background: Color { palette.bg }
    var card: Color { palette.card }

    /// 저장된 이전 값을 가장 가까운 새 팔레트로 옮긴다.
    /// daylight·medium → 라이트, casual·vivid → 프라이데이, night·dark → 자비스,
    /// automatic·rings·없음·알 수 없는 값 → 시스템이 어두우면 자비스, 아니면 라이트.
    static func migrated(from raw: String?, systemIsDark: Bool) -> CCMBAppearance {
        switch raw {
        case "light", "daylight", "medium": return .light
        case "friday", "casual", "vivid": return .friday
        case "jarvis", "night", "dark": return .jarvis
        case "ultron": return .ultron
        default: return systemIsDark ? .jarvis : .light
        }
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    @Published private(set) var selection: CCMBAppearance
    private static let defaultsKey = "ccmb.appearance"

    /// 첫 렌더링 전에 저장값을 동기적으로 읽어 팔레트를 적용하고, 이전 값이면 새 값으로 바로 저장한다.
    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let systemIsDark = UITraitCollection.current.userInterfaceStyle == .dark
        let resolved = CCMBAppearance.migrated(from: saved, systemIsDark: systemIsDark)
        selection = resolved
        CCMBPalette.current = resolved.palette
        if saved != resolved.rawValue {
            UserDefaults.standard.set(resolved.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// 선택 즉시 적용하고 저장한다. 앱 아이콘은 테마와 무관하게 건드리지 않는다.
    func select(_ appearance: CCMBAppearance) {
        guard selection != appearance else { return }
        CCMBPalette.current = appearance.palette
        selection = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.defaultsKey)
    }

    func cycle() {
        select(selection.next)
    }
}

/// 24×24 기준 벡터 아이콘(기준표의 SVG 형상). 색은 `foregroundStyle`을 따른다.
struct CCMBThemeIcon: View {
    let appearance: CCMBAppearance

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 24
            let origin = CGPoint(x: (size.width - 24 * s) / 2, y: (size.height - 24 * s) / 2)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: origin.x + (cx - r) * s, y: origin.y + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            func lines(_ segments: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> Path {
                var path = Path()
                for seg in segments {
                    path.move(to: p(seg.0, seg.1))
                    path.addLine(to: p(seg.2, seg.3))
                }
                return path
            }
            func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    if index == 0 { path.move(to: p(point.0, point.1)) } else { path.addLine(to: p(point.0, point.1)) }
                }
                path.closeSubpath()
                return path
            }
            let color = GraphicsContext.Shading.foreground
            let stroke = StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round)
            let thin = StrokeStyle(lineWidth: 1.4 * s, lineCap: .round, lineJoin: .round)

            switch appearance {
            case .light:
                context.stroke(circle(12, 12, 3.8), with: color, style: stroke)
                context.stroke(lines([
                    (12, 3.5, 12, 5.7), (12, 18.3, 12, 20.5), (3.5, 12, 5.7, 12), (18.3, 12, 20.5, 12),
                    (6, 6, 7.6, 7.6), (16.4, 16.4, 18, 18), (6, 18, 7.6, 16.4), (16.4, 7.6, 18, 6)
                ]), with: color, style: stroke)
            case .friday:
                context.stroke(polygon([(12, 3), (19.8, 7.5), (19.8, 16.5), (12, 21), (4.2, 16.5), (4.2, 7.5)]), with: color, style: stroke)
                context.fill(circle(12, 12, 3), with: color)
                context.stroke(lines([(12, 9, 12, 6.5), (12, 17.5, 12, 15), (9, 12, 6.5, 12), (17.5, 12, 15, 12)]), with: color, style: thin)
            case .jarvis:
                let dashed = StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round, dash: [15.4 * s, 3.45 * s])
                var ring = context
                ring.translateBy(x: p(12, 12).x, y: p(12, 12).y)
                ring.rotate(by: .degrees(-80))
                ring.translateBy(x: -p(12, 12).x, y: -p(12, 12).y)
                ring.stroke(circle(12, 12, 9), with: color, style: dashed)
                context.stroke(circle(12, 12, 5), with: color, style: thin)
                context.fill(circle(12, 12, 1.7), with: color)
            case .ultron:
                context.stroke(
                    polygon([(6, 4), (18, 4), (20.5, 9), (20.5, 15), (16.5, 20), (7.5, 20), (3.5, 15), (3.5, 9)]),
                    with: color, style: stroke
                )
                context.fill(polygon([(7.4, 10.4), (11, 11.7), (10.7, 13.1), (7.4, 12.2)]), with: color)
                context.fill(polygon([(16.6, 10.4), (13, 11.7), (13.3, 13.1), (16.6, 12.2)]), with: color)
                context.stroke(lines([(9.5, 16.5, 14.5, 16.5)]), with: color, style: thin)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
