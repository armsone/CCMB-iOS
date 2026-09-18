import SwiftUI

/// First-run screen. The primary onboarding is the remote path — same Apple
/// ID, Mac uploads, iPhone reads — and it states honestly that the values
/// only move while the Mac is on and publishing. The manual file pick stays
/// as the clearly secondary alternative.
struct WelcomeView: View {
    @EnvironmentObject private var store: SnapshotStore
    @EnvironmentObject private var appearanceStore: AppearanceStore
    let onLoadFromCloud: () -> Void
    let onPickFile: () -> Void

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
                    Text("Mac의 CCMB가 iCloud에 올린 사용량을 어디서든 확인합니다.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 16) {
                    stepRow(
                        number: 1,
                        text: "이 iPhone을 Mac과 같은 Apple ID로 iCloud에 로그인하세요."
                    )
                    stepRow(
                        number: 2,
                        text: "Mac에서 CCMB를 실행하고 메뉴의 ‘iPhone 원격 동기화’가 켜져 있는지 확인하세요."
                    )
                    stepRow(
                        number: 3,
                        text: "아래 버튼으로 불러오세요. 이후에는 앱을 열거나 당겨서 새로 고침할 때마다 최신 값을 읽습니다."
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

                Text("사용량은 내 Apple ID의 iCloud 개인 영역에만 저장되고 전송은 Apple이 보호합니다. Mac이 켜져 있어야 최신 값이 올라옵니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    onLoadFromCloud()
                } label: {
                    Text("iCloud에서 불러오기")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(CCMBTheme.charcoal)
                .padding(.horizontal, 20)
                .accessibilityHint("Mac이 iCloud에 올린 최신 사용량을 읽습니다.")

                Button {
                    onPickFile()
                } label: {
                    Text("다른 방법: Dropbox·Google Drive 파일 선택")
                        .font(.subheadline)
                }
                .tint(CCMBTheme.charcoal)
                .padding(.bottom, 24)
                .accessibilityHint("Mac CCMB가 클라우드 폴더에 자동 저장한 CCMB-usage-v1.json을 파일 앱에서 선택합니다.")
            }
        }
        .background(appearanceStore.selection.background)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
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
