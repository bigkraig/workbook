import Foundation
import WebKit

/// Bridges cookies from the in-app `WKWebView` (used for the Sign in with
/// Apple gate) into the shared `HTTPCookieStorage`, so URLSession requests for
/// JSON, illustrations and PDFs all carry the gate's session cookie.
enum CookieBridge {
    /// Copy all cookies from the persistent WebKit store into the shared
    /// HTTPCookieStorage. Call after a login navigation finishes and at launch.
    @MainActor
    static func sync() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    static func clearWebCookies() {
        Task { @MainActor in
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types)
            await store.removeData(ofTypes: types, for: records)
        }
    }
}
