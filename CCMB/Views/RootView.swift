import SwiftUI
import UniformTypeIdentifiers

/// Routes between the four top-level states: 처음(빈 상태), 불러오는 중,
/// 정상 대시보드, 읽기 실패. The file importer lives here so every state
/// can offer the same manual-file fallback action.
struct RootView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var weatherStore: WeatherStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let weather = weatherStore.reading {
                            ZStack {
                                Image(systemName: weather.symbolName)
                                    .foregroundStyle(.orange)
                                    .offset(x: -18)
                                Text("\(Int(weather.temperature.rounded()))°")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .offset(x: 18)
                            }
                            .frame(width: 72, height: 32)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text("CCMB")
                            .font(.headline)
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.json],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        store.importPicked(url: url)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .empty:
            WelcomeView(
                onLoadFromCloud: { Task { await store.refreshFromCloud() } },
                onPickFile: { showImporter = true }
            )
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("사용량을 불러오는 중…")
                    .foregroundStyle(.secondary)
            }
        case .loaded(let snapshot):
            DashboardView(snapshot: snapshot, onPickFile: { showImporter = true })
        case .failed(let message):
            FailureView(
                message: message,
                onLoadFromCloud: { Task { await store.refreshFromCloud() } },
                onPickFile: { showImporter = true }
            )
        }
    }
}

/// Load failure with no earlier snapshot to fall back to. The action comes
/// first; the technical cause is already folded into the message.
struct FailureView: View {
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let message: String
    let onLoadFromCloud: () -> Void
    let onPickFile: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(CCMBTheme.signalRed)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("iCloud에서 다시 불러오기") { onLoadFromCloud() }
                .buttonStyle(.borderedProminent)
                .tint(CCMBTheme.charcoal)
                .controlSize(.large)
            Button("다른 방법: Dropbox·Google Drive 파일 선택") { onPickFile() }
                .buttonStyle(.bordered)
                .tint(CCMBTheme.charcoal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearanceStore.selection.background)
    }
}
