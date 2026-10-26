import SwiftUI

/// `GET /api/ccmb/task-status`: how many playground tasks the signed-in NAS
/// session can see. Strictly validated; anything else is a failure, never 0.
struct NASTaskStatus: Equatable {
    let running: Int
    let preparing: Int
    let waiting: Int
    let capturedAt: Date

    static let maxResponseBytes = 4096
    static let staleAfter: TimeInterval = 240
    static let maxFuture: TimeInterval = 300

    private struct Wire: Decodable {
        let schemaVersion: Int
        let capturedAt: String
        let running: Int
        let preparing: Int
        let waiting: Int
    }

    static func parse(_ data: Data) -> NASTaskStatus? {
        guard data.count <= maxResponseBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.schemaVersion == 1,
              let capturedAt = parseTime(wire.capturedAt),
              capturedAt.timeIntervalSinceNow >= -staleAfter,
              capturedAt.timeIntervalSinceNow <= maxFuture,
              wire.running >= 0, wire.preparing >= 0, wire.waiting >= 0
        else { return nil }
        return NASTaskStatus(running: wire.running, preparing: wire.preparing, waiting: wire.waiting, capturedAt: capturedAt)
    }

    private static func parseTime(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Compact outlined pill shown right after the "CCMB" title.
struct NASTaskStatusPill: View {
    @EnvironmentObject private var store: SnapshotStore

    private static let staleAfter = NASTaskStatus.staleAfter
    private static let green = Color(.sRGB, red: 18.0 / 255, green: 189.0 / 255, blue: 140.0 / 255, opacity: 1)
    private static let blue = Color(.sRGB, red: 59.0 / 255, green: 130.0 / 255, blue: 246.0 / 255, opacity: 1)
    private static let orange = Color(.sRGB, red: 245.0 / 255, green: 158.0 / 255, blue: 11.0 / 255, opacity: 1)

    var body: some View {
        if store.displayedSource == .nas {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let status = store.nasTaskStatus
        let stale = status != nil && (store.nasTaskStatusFailed
            || store.nasTaskStatusAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true)
        HStack(spacing: 3) {
            if let status {
                counts(status)
                if stale { warning }
            } else if store.nasTaskStatusFailed {
                warning
                Text("연결 확인 필요").font(.system(size: 10, weight: .medium)).foregroundStyle(CCMBDash.muted)
            } else {
                Text("확인 중").font(.system(size: 10, weight: .medium)).foregroundStyle(CCMBDash.muted)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(Capsule().stroke(CCMBDash.divider, lineWidth: 1))
        .padding(.leading, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(status, stale: stale))
    }

    private var warning: some View {
        Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(CCMBTheme.signalRed)
    }

    private func counts(_ status: NASTaskStatus) -> some View {
        HStack(spacing: 4) {
            item("실행", status.running, Self.green)
            item("준비", status.preparing, Self.blue)
            item("대기", status.waiting, Self.orange)
        }
    }

    private func item(_ name: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 1) {
            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(CCMBDash.muted)
            Text("\(value)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(color)
        }
    }

    private func label(_ status: NASTaskStatus?, stale: Bool) -> String {
        guard let status else {
            return store.nasTaskStatusFailed ? "플레이그라운드 작업 상태 연결 확인 필요" : "플레이그라운드 작업 상태 확인 중"
        }
        let base = "플레이그라운드 작업 실행 \(status.running)개, 준비 \(status.preparing)개, 대기 \(status.waiting)개"
        return stale ? base + ", 최신 확인 실패 또는 오래된 값" : base
    }
}
