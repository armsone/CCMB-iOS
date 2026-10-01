import SwiftUI
import WebKit

/// The NAS's own website login page, unmodified. The app never collects the
/// NAS password itself. The login is a SPA: it `POST`s `/api/login` and
/// calls `enterApp()` without a page navigation, so detection cannot rely on
/// `WKNavigationDelegate.didFinish` — instead this observes WebKit's cookie
/// store for the session cookie appearing, then the sheet verifies the
/// session with the server before closing. Navigation inside the sheet is
/// restricted to the configured NAS origin so the login page cannot be used
/// to browse elsewhere.
private struct NASLoginWebView: UIViewRepresentable {
    let url: URL
    let allowedOrigin: NASLoginSheetView.Origin
    let onBlockedNavigation: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(allowedOrigin: allowedOrigin, onBlockedNavigation: onBlockedNavigation)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let allowedOrigin: NASLoginSheetView.Origin
        private let onBlockedNavigation: () -> Void

        init(allowedOrigin: NASLoginSheetView.Origin, onBlockedNavigation: @escaping () -> Void) {
            self.allowedOrigin = allowedOrigin
            self.onBlockedNavigation = onBlockedNavigation
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  NASLoginSheetView.Origin(url: url) == allowedOrigin
            else {
                onBlockedNavigation()
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Watches WebKit's shared cookie store for the NAS session cookie set by
/// the SPA login, without any page navigation to hook into.
@MainActor
private final class NASCookieObserver: NSObject, WKHTTPCookieStoreObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

    func stop() {
        WKWebsiteDataStore.default().httpCookieStore.remove(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.onChange() }
    }
}

/// Presented modally so the user can log into the NAS website exactly as in
/// a browser. Closes itself once the server confirms the new session is
/// actually authenticated; cancelling leaves everything exactly as it was.
struct NASLoginSheetView: View {
    /// Exact scheme + host + effective port the login page — and nothing
    /// else — is allowed to navigate within.
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host else { return nil }
            self.scheme = scheme
            self.host = host.lowercased()
            self.port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    @EnvironmentObject private var store: SnapshotStore
    @Environment(\.dismiss) private var dismiss
    @State private var observer: NASCookieObserver?
    @State private var pollTask: Task<Void, Never>?
    @State private var isVerifying = false
    @State private var verifyFailed = false
    @State private var blockedNavigation = false
    /// Set false on disappear/cancel so a verification already past its
    /// await point can never dismiss, connect, or flip the failure flag
    /// after the user has left the sheet.
    @State private var isActive = true

    private var baseURL: URL { NASConfig.baseURL }
    private var origin: Origin? { Origin(url: baseURL) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let origin {
                    NASLoginWebView(url: baseURL, allowedOrigin: origin, onBlockedNavigation: {
                        blockedNavigation = true
                    })
                } else {
                    Text("NAS 주소가 올바르지 않습니다. 설정에서 다시 확인해 주세요.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
                if blockedNavigation {
                    Text("NAS 로그인 페이지 밖으로는 이동할 수 없습니다. 로그인 페이지로 돌아가 다시 시도해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }
                VStack(spacing: 8) {
                    if verifyFailed {
                        Text("로그인 확인에 실패했습니다. 로그인을 마친 뒤 다시 시도해 주세요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        verifyFailed = false
                        verifyNow()
                    } label: {
                        if isVerifying {
                            ProgressView()
                        } else {
                            Text("로그인 후 불러오기")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isVerifying)
                }
                .padding()
            }
            .navigationTitle("NAS 로그인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
        .onAppear {
            isActive = true
            observer = NASCookieObserver { [self] in verifyNow() }
            // A valid session cookie could already exist from before the
            // sheet was shown (e.g. it became valid between the precheck
            // and the sheet's presentation), so verify right away rather
            // than waiting for a cookie-store change that may never come.
            verifyNow()
        }
        .onDisappear {
            isActive = false
            observer?.stop()
            observer = nil
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Debounced verification: a cookie-store change fires before the
    /// server necessarily considers the session usable, so this polls the
    /// real `/api/session` check briefly rather than trusting the cookie's
    /// mere presence.
    private func verifyNow() {
        pollTask?.cancel()
        isVerifying = true
        verifyFailed = false
        pollTask = Task { @MainActor in
            defer { isVerifying = false }
            for attempt in 0..<6 {
                if Task.isCancelled || !isActive { return }
                if await store.hasNASSession() {
                    guard !Task.isCancelled, isActive else { return }
                    store.connectNAS()
                    dismiss()
                    return
                }
                if attempt < 5 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
            if !Task.isCancelled, isActive {
                verifyFailed = true
            }
        }
    }
}
