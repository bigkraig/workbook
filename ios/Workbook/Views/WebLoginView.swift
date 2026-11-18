import SwiftUI
import WebKit

/// A `WKWebView` that walks the server's Sign in with Apple gate. After each
/// navigation the web view's cookies are mirrored into shared storage so the
/// rest of the app can use the session natively.
struct WebLoginView: UIViewRepresentable {
    let url: URL
    /// Called on the main actor after cookies have been synced.
    var onCookiesSynced: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookiesSynced: onCookiesSynced) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persistent cookie store
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCookiesSynced: () -> Void
        init(onCookiesSynced: @escaping () -> Void) { self.onCookiesSynced = onCookiesSynced }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                await CookieBridge.sync()
                onCookiesSynced()
            }
        }
    }
}

/// Sheet hosting the login web view. Dismisses itself once an API probe
/// succeeds, i.e. the whole sign-in chain is complete.
struct LoginSheet: View {
    @Environment(AppSettings.self) private var settings
    @State private var checking = false
    @State private var denied = false

    var body: some View {
        NavigationStack {
            WebLoginView(url: settings.baseURL, onCookiesSynced: probe)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if denied {
                        banner("This Apple ID isn't allowed to use Workbook.", systemImage: "hand.raised")
                    } else if checking {
                        banner("Checking sign-in…", systemImage: nil)
                    }
                }
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func banner(_ text: String, systemImage: String?) -> some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) } else { ProgressView() }
            Text(text).font(.footnote)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 8)
    }

    private func probe() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                _ = try await API(settings: settings).vehicles()
                settings.signedIn()
            } catch APIError.forbidden {
                denied = true
            } catch {
                // Still on the way through the gate; wait for the next navigation.
                settings.needsLogin = true
            }
        }
    }
}
