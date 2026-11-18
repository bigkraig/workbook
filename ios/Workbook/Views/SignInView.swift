import AuthenticationServices
import SwiftUI

/// Signs in through the server's Sign in with Apple gate using the system
/// sign-in sheet (ASWebAuthenticationSession).
///
/// The sheet runs in Safari's context, so the Apple ID sheet with Face ID and
/// passkeys work there — they don't in an embedded web view. Its cookies stay
/// in Safari's jar, though, so the flow ends at `/v1/app/session`, which sits
/// behind the gate and redirects to `workbook://session?cookies=…` with the
/// session it was called with. Those cookies are installed for URLSession,
/// which then authenticates every API, illustration and PDF request.
struct SignInView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            WorkbookMark().frame(width: 64, height: 64).foregroundStyle(.white)
            VStack(spacing: 6) {
                Text("WORKBOOK")
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .tracking(7)
                    .foregroundStyle(.white)
                Text("Service reference").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(Theme.ink) } else { Image(systemName: "apple.logo") }
                    Text("Sign in with Apple")
                }
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: 320, minHeight: 52)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(working)
            Text(settings.baseURL.host() ?? "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func signIn() async {
        working = true
        defer { working = false }
        message = nil
        do {
            let handoff = settings.baseURL.appending(path: "v1/app/session")
            let callback = try await webAuthenticationSession.authenticate(
                using: handoff, callback: .customScheme("workbook"),
                preferredBrowserSession: .shared, additionalHeaderFields: [:])
            Self.install(cookiesFrom: callback, for: settings.baseURL)
            // The hand-off only proves the gate let the request through; make
            // sure the session actually works from here.
            _ = try await API(settings: settings).vehicles()
            settings.signedIn()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closed the sheet; stay on this screen.
        } catch APIError.forbidden {
            message = "This Apple ID isn't allowed to use Workbook."
        } catch {
            settings.needsLogin = true
            message = "Sign-in didn't complete. \(error.localizedDescription)"
        }
    }

    /// `workbook://session?cookies=name=value; name2=value2`
    static func install(cookiesFrom callback: URL, for server: URL) {
        guard let host = server.host(),
              let raw = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cookies" })?.value else { return }
        for pair in raw.split(separator: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: String(parts[0]), .value: String(parts[1]),
                .domain: host, .path: "/",
                // Without an expiry the cookie is session-only and is dropped
                // when the app quits. The gate's own session lasts 7 days; when
                // it lapses the next request bounces and this screen returns.
                .expires: Date(timeIntervalSinceNow: 7 * 24 * 3600),
            ]
            if server.scheme == "https" { properties[.secure] = "TRUE" }
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
}
