import Foundation
import Observation

/// Where the Workbook server lives and whether we hold a session for it.
///
/// The server sits behind a Sign in with Apple gate (oauth2-proxy): every
/// unauthenticated request is redirected to Apple, and a host-only session
/// cookie set after login authorizes the API, illustrations and PDFs. The app
/// signs in once through an in-app web view and reuses that cookie natively
/// (see CookieBridge / WebLoginView).
@Observable
final class AppSettings {
    static let defaultServer = "https://workbook.birdstreetexotics.com"

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }
    /// Set when a request bounced off the login gate; RootView presents the
    /// login sheet while this is true.
    var needsLogin = false
    /// Bumped after login/logout so screens reload.
    var sessionGeneration = 0

    init() {
        // `-workbook.serverURL http://localhost:3030` as a launch argument
        // lands in UserDefaults' argument domain, for simulator runs against a
        // local API.
        serverURL = UserDefaults.standard.string(forKey: Keys.serverURL) ?? Self.defaultServer
    }

    var baseURL: URL {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces)) ?? URL(string: Self.defaultServer)!
    }

    func signedIn() {
        needsLogin = false
        sessionGeneration += 1
    }

    func signOut() {
        if let cookies = HTTPCookieStorage.shared.cookies {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
        CookieBridge.clearWebCookies()
        needsLogin = true
        sessionGeneration += 1
    }

    private enum Keys {
        static let serverURL = "workbook.serverURL"
    }
}
