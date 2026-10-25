import SwiftUI

/// First-run screen. The primary (and only) onboarding path is connecting to
/// the home NAS.
struct WelcomeView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                AppIconArtView()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Codex · Claude · Gemini")
                        .font(.headline)
                    Text("집 NAS에 모인 사용량을 어디서든 확인합니다.")
                        .foregroundStyle(CCMBDash.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 16) {
                    stepRow(
                        number: 1,
                        text: "아래 버튼으로 NAS에 로그인하세요."
                    )
                    stepRow(
                        number: 2,
                        text: "이후에는 앱을 열거나 당겨서 새로 고침할 때마다 최신 값을 읽습니다."
                    )
                }
                .padding(20)
                .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)

                if let problem = store.refreshProblem {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(CCMBTheme.signalRed)
                            .accessibilityHidden(true)
                        Text(problem)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(appearanceStore.selection.card, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .accessibilityElement(children: .combine)
                }

                Text("사용량은 집 NAS에서 직접 읽어 옵니다.")
                    .font(.footnote)
                    .foregroundStyle(CCMBDash.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    store.requestNASLogin()
                } label: {
                    if store.nasConnecting {
                        ProgressView()
                    } else {
                        Text("NAS에서 불러오기")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(CCMBTheme.charcoal)
                .disabled(store.nasConnecting)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .accessibilityHint("NAS 웹사이트에 로그인한 뒤 남은 사용량을 읽습니다.")

                if let nasError = store.nasConnectError {
                    Text(nasError)
                        .font(.footnote)
                        .foregroundStyle(CCMBTheme.signalRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(appearanceStore.selection.background)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CCMBPalette.current.bg)
                .frame(width: 24, height: 24)
                .background(CCMBTheme.charcoal, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)단계. \(text)")
    }
}
