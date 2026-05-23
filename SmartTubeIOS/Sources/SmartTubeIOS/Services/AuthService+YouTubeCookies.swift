import Foundation
import os

// MARK: - YouTube Web Session Cookie Exchange
//
// Converts our OAuth2 access token into a YouTube.com SAPISID cookie so that
// WEB_CREATOR player requests can use SAPISIDHASH Authorization (the only auth
// scheme www.youtube.com accepts for web-client nameIDs).
//
// Flow (mirrors yt-dlp's web_client auth and Chromium's identity_util.cc):
//   1. GET accounts.google.com/accounts/OAuthLogin?issueuberauth=1
//      → HTTP 302 redirect, uberauth token in Location URL
//   2. GET accounts.google.com/MergeSession?uberauth=…&continue=https://www.youtube.com/
//      → follows redirects, sets SAPISID cookie in HTTPCookieStorage.shared
//   3. Read SAPISID value, store on AuthService.sapisid
//
// This must be called after a successful sign-in (step 5 of the device-code
// flow, after fetchUserInfo returns). It is a best-effort operation: failure
// is logged but does not affect sign-in state (the app degrades gracefully to
// unauthenticated WEB_CREATOR or a different client).

extension AuthService {

    /// Exchanges the current OAuth2 access token for a YouTube.com SAPISID cookie.
    /// On success, sets `self.sapisid` to the extracted value.
    /// All errors are caught internally; this method never throws.
    func fetchYouTubeWebCookies() async {
        guard let token = accessToken else {
            authLog.notice("[cookies] fetchYouTubeWebCookies: no access token — skipping")
            return
        }

        authLog.notice("[cookies] Fetching YouTube web session cookies for SAPISIDHASH auth")

        // Step 1 — get uberauth via OAuthLogin endpoint (no-redirect session)
        let oauthLoginURL = URL(string: "https://accounts.google.com/accounts/OAuthLogin?source=SmartTubeIOS&issueuberauth=1")!
        var req1 = URLRequest(url: oauthLoginURL)
        req1.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        let noRedirectSession = URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)

        let response1: URLResponse
        do {
            (_, response1) = try await noRedirectSession.data(for: req1)
        } catch {
            authLog.notice("[cookies] OAuthLogin request failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let http1 = response1 as? HTTPURLResponse,
              (300..<400).contains(http1.statusCode),
              let location = http1.value(forHTTPHeaderField: "Location"),
              let mergeURL = URL(string: location) else {
            let code = (response1 as? HTTPURLResponse)?.statusCode ?? 0
            authLog.notice("[cookies] OAuthLogin did not redirect (HTTP \(code, privacy: .public)) — SAPISID unavailable")
            return
        }

        authLog.notice("[cookies] OAuthLogin redirect received — loading MergeSession")

        // Step 2 — load MergeSession URL via shared session (sets SAPISID cookie)
        // URLSession.shared uses HTTPCookieStorage.shared and follows redirects by default.
        do {
            let (_, _) = try await URLSession.shared.data(from: mergeURL)
        } catch {
            authLog.notice("[cookies] MergeSession request failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Step 3 — read SAPISID from shared cookie storage
        let ytURL = URL(string: "https://www.youtube.com")!
        let cookies = HTTPCookieStorage.shared.cookies(for: ytURL) ?? []
        guard let sapisidCookie = cookies.first(where: { $0.name == "SAPISID" }) else {
            authLog.notice("[cookies] SAPISID cookie not found after MergeSession — SAPISID unavailable")
            return
        }

        authLog.notice("[cookies] ✅ SAPISID obtained — WEB_CREATOR SAPISIDHASH auth enabled")
        sapisid = sapisidCookie.value
    }
}

// MARK: - No-redirect URLSession delegate

/// URLSession task delegate that prevents automatic redirect following.
/// Used for the OAuthLogin step where we need the 302 Location header.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Pass nil to prevent the redirect — the 302 response is returned as-is.
        completionHandler(nil)
    }
}
