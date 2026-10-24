import SwiftUI

/// Routes between the four top-level states: 처음(빈 상태), 불러오는 중,
/// 정상 대시보드, 읽기 실패.
struct RootView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text("CCMB")
                            .font(.headline)
                    }
                }
                .sheet(isPresented: $store.isNASLoginPresented) {
                    NASLoginSheetView()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .empty:
            WelcomeView()
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("사용량을 불러오는 중…")
                    .foregroundStyle(.secondary)
            }
        case .loaded(let snapshot):
            DashboardView(snapshot: snapshot)
        case .failed(let message):
            FailureView(message: message)
        }
    }
}

/// Load failure with no earlier snapshot to fall back to. The action comes
/// first; the technical cause is already folded into the message.
struct FailureView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(CCMBTheme.signalRed)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                store.requestNASLogin()
            } label: {
                if store.nasConnecting {
                    ProgressView()
                } else {
                    Text("NAS에서 다시 불러오기")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(CCMBTheme.charcoal)
            .controlSize(.large)
            .disabled(store.nasConnecting)
            if let nasError = store.nasConnectError {
                Text(nasError)
                    .font(.footnote)
                    .foregroundStyle(CCMBTheme.signalRed)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearanceStore.selection.background)
    }
}
