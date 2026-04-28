import Foundation
import Observation
import os
import SmartTubeIOSCore

private let authLog = CrashlyticsLogger(category: "Auth")
private let keychainService = "com.smarttube.auth"

// MARK: - AuthService
//
// Google OAuth 2.0 **Device Authorization Grant** flow (RFC 8628).
//
// Mirrors exactly how the Android SmartTube app authenticates:
//  1. Fetch client_id / client_secret by scraping YouTube's own base.js
//     (see YouTubeClientCredentialsFetcher in SmartTubeIOSCore).
//  2. POST to https://oauth2.googleapis.com/device/code → get user_code +
//     verification_url (youtube.com/activate).
//  3. Show the user_code on-screen so the user can enter it at
//     https://youtube.com/activate on any device.
//  4. Poll https://oauth2.googleapis.com/token every `interval` seconds until
//     the user approves or cancels.
//
// No redirect URI, no registered client ID, no ASWebAuthenticationSession.

@MainActor
@Observable
public final class AuthService {

    // MARK: - Observable state

    public private(set) var isSignedIn: Bool = false
    public private(set) var accountName: String?
    public private(set) var accountAvatarURL: URL?
    public var error: Error?

    /// Non-nil while waiting for the user to enter the code at youtube.com/activate.
    public private(set) var pendingActivation: ActivationInfo?

    // MARK: - ActivationInfo

    public struct ActivationInfo: Sendable {
        /// The short code the user types at youtube.com/activate (e.g. "ABCD-1234").
        public let userCode: String
        /// Typically https://yt.be/activate (as used by the Android SmartTube client).
        public let verificationURL: URL
        /// When this activation attempt expires.
        public let expiresAt: Date
    }

    // MARK: - Private state

    public private(set) var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var pollTask: Task<Void, Never>?

    private let credentialsFetcher = YouTubeClientCredentialsFetcher()
    private let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    private var tokenRefreshTask: Task<Void, Never>?

    // State persisted across foreground/background transitions so that the
    // poll loop can be restarted without re-requesting a device code.
    private var currentDeviceCode: String?
    private var currentInterval: TimeInterval = 5
    private var currentCreds: YouTubeClientCredentials?

    private let tokenKey   = "st_access_token"
    private let refreshKey = "st_refresh_token"
    private let expiryKey  = "st_token_expiry"
    private let accountKey = "st_account_name"
    private let avatarKey  = "st_avatar_url"

    // MARK: - Static endpoint URLs (known-valid literals)

    private static let deviceCodeURL      = URL(string: "https://oauth2.googleapis.com/device/code")!
    private static let tokenURL           = URL(string: "https://oauth2.googleapis.com/token")!
    private static let accountsListURL    = URL(string: "https://www.youtube.com/youtubei/v1/account/accounts_list")!

    public init() {
        loadFromKeychain()
        // If already signed in but no account info (e.g. stored before the
        // fetchUserInfo fix), refresh it silently in the background.
        if isSignedIn && accountName == nil {
            Task {
                do { try await fetchUserInfo() }
                catch { authLog.error("fetchUserInfo on init failed: \(String(describing: error))") }
            }
        }
    }

    // MARK: - Public API

    /// Step 1 – request a device code and expose the user_code for display.
    /// Call this when the user taps "Sign in".
    public func beginSignIn() async {
        pollTask?.cancel()
        error = nil
        pendingActivation = nil
        authLog.notice("beginSignIn() — fetching credentials…")

        let creds = await credentialsFetcher.credentials()
        authLog.notice("Using clientId: \(creds.clientId)")

        do {
            let deviceResponse = try await requestDeviceCode(creds: creds)
            authLog.notice("✅ Got device code. userCode=\(deviceResponse.userCode) expiresIn=\(deviceResponse.expiresIn)s interval=\(deviceResponse.interval)s")
            let expiresAt = Date().addingTimeInterval(TimeInterval(deviceResponse.expiresIn))
            // Static fallback URL — safe to use URL(string:) with a known-valid literal
            let fallbackURL = URL(string: "https://yt.be/activate") ?? URL(string: "https://youtube.com/activate")!
            let verURL = URL(string: deviceResponse.verificationURL) ?? fallbackURL

            pendingActivation = ActivationInfo(
                userCode: deviceResponse.userCode,
                verificationURL: verURL,
                expiresAt: expiresAt
            )

            // Step 2 – start polling in the background
            let interval = max(TimeInterval(deviceResponse.interval), 5)
            currentDeviceCode = deviceResponse.deviceCode
            currentInterval   = interval
            currentCreds      = creds
            pollTask = Task { [weak self] in
                await self?.pollForToken(deviceCode: deviceResponse.deviceCode,
                                         interval: interval,
                                         creds: creds)
            }
        } catch {
            authLog.error("❌ beginSignIn error: \(String(describing: error))")
            self.error = error
        }
    }

    /// Cancel an in-progress activation.
    public func cancelSignIn() {
        pollTask?.cancel()
        pollTask = nil
        pendingActivation = nil
        currentDeviceCode = nil
        currentCreds      = nil
    }

    /// Call when the app returns to the foreground while a sign-in is in progress.
    /// Cancels any stale (possibly iOS-suspended) poll task and immediately fires
    /// a new poll so the user is signed in the moment they switch back from Chrome.
    public func handleForeground() {
        // Already signed in (concurrent task may have succeeded) — nothing to do.
        guard !isSignedIn, accessToken == nil else { return }
        guard let pending = pendingActivation, pending.expiresAt > Date() else { return }
        guard let deviceCode = currentDeviceCode, let creds = currentCreds else { return }
        authLog.notice("handleForeground() — restarting poll immediately")
        pollTask?.cancel()
        let interval = currentInterval
        pollTask = Task { [weak self] in
            await self?.pollForToken(deviceCode: deviceCode,
                                     interval: interval,
                                     creds: creds,
                                     pollImmediately: true)
        }
    }

    /// Refreshes the access token now if it has expired or will expire within the next 5 minutes.
    /// Safe to call on every app-active transition. No-op when not signed in.
    public func refreshIfNeeded() async {
        guard isSignedIn, let expiry = tokenExpiry else { return }
        guard expiry.timeIntervalSinceNow < 5 * 60 else { return }
        guard let refresh = refreshToken else { return }
        authLog.notice("refreshIfNeeded() — token expires soon, refreshing")
        let creds = await credentialsFetcher.credentials()
        do {
            try await refreshAccessToken(refreshToken: refresh, creds: creds)
        } catch {
            authLog.error("refreshIfNeeded() failed: \(String(describing: error))")
        }
    }

    /// Schedules a background Task that sleeps until 5 minutes before expiry, then refreshes.
    /// Cancelled and rescheduled automatically on each refresh.
    private func scheduleProactiveRefresh() {
        tokenRefreshTask?.cancel()
        guard let expiry = tokenExpiry, refreshToken != nil else { return }
        let delay = max(expiry.timeIntervalSinceNow - 5 * 60, 0)
        authLog.notice("scheduleProactiveRefresh() — refreshing in \(Int(delay))s")
        tokenRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isSignedIn, let refresh = self.refreshToken else { return }
            let creds = await self.credentialsFetcher.credentials()
            do {
                try await self.refreshAccessToken(refreshToken: refresh, creds: creds)
                authLog.notice("scheduleProactiveRefresh() — token refreshed ✅")
                // Re-schedule for the next expiry window
                self.scheduleProactiveRefresh()
            } catch {
                authLog.error("scheduleProactiveRefresh() failed: \(String(describing: error))")
            }
        }
    }

    public func signOut() {
        pollTask?.cancel()
        pollTask = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        isSignedIn       = false
        pendingActivation = nil
        clearKeychain()
    }

    /// Returns a valid access token, refreshing if necessary.
    public func validAccessToken() async throws -> String {
        if let t = accessToken, let exp = tokenExpiry, exp > Date() { return t }
        guard let refresh = refreshToken else { throw AuthError.notSignedIn }
        let creds = await credentialsFetcher.credentials()
        try await refreshAccessToken(refreshToken: refresh, creds: creds)
        guard let t = accessToken else { throw AuthError.notSignedIn }
        return t
    }

    // MARK: - Device Code request

    private struct DeviceCodeResponse {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
    }

    private func requestDeviceCode(creds: YouTubeClientCredentials) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "scope":         scope,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.deviceCodeRequestFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"]       as? String,
              let userCode   = json["user_code"]         as? String,
              let verURL     = json["verification_url"]  as? String,
              let expiresIn  = json["expires_in"]        as? Int
        else { throw AuthError.deviceCodeRequestFailed }

        return DeviceCodeResponse(
            deviceCode:      deviceCode,
            userCode:        userCode,
            verificationURL: verURL,
            expiresIn:       expiresIn,
            interval:        json["interval"] as? Int ?? 5
        )
    }

    // MARK: - Polling

    private func pollForToken(
        deviceCode: String,
        interval: TimeInterval,
        creds: YouTubeClientCredentials,
        pollImmediately: Bool = false
    ) async {
        authLog.notice("Starting poll loop (interval \(Int(interval))s, immediate=\(pollImmediately))")
        var skipInitialSleep = pollImmediately
        while !Task.isCancelled {
            if skipInitialSleep {
                skipInitialSleep = false
            } else {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            do {
                try await exchangeDeviceCode(deviceCode: deviceCode, creds: creds)
                // Success — fetchUserInfo and clean up
                authLog.notice("✅ Token exchanged — fetching user info")
                try await fetchUserInfo()
                authLog.notice("✅ Signed in as \(self.accountName ?? "unknown")")
                pendingActivation = nil
                pollTask = nil
                return
            } catch AuthError.authorizationPending {
                authLog.debug("Polling… (authorization_pending)")
                continue   // user hasn't entered code yet — keep polling
            } catch AuthError.slowDown {
                authLog.notice("slow_down received — waiting extra 5s")
                try? await Task.sleep(nanoseconds: UInt64(5 * 1_000_000_000))
                continue
            } catch let urlError as URLError {
                // Transient network failure — commonly triggered when iOS suspends
                // the in-flight URLSession request after the app is backgrounded
                // (e.g. while the user approves in Chrome).  Keep the loop alive
                // so the next foreground trigger or timer tick can succeed.
                authLog.notice("Network error during poll (transient, retrying): \(urlError.localizedDescription)")
                continue
            } catch {
                authLog.error("❌ Poll error: \(String(describing: error))")
                // If a concurrent poll (e.g. the original suspended task) already signed
                // us in between the HTTP request being sent and the response arriving,
                // the device code will have returned invalid_grant. Silently discard the
                // error rather than flashing a "Failed to exchange code" alert.
                if isSignedIn { return }
                self.error = error
                pendingActivation = nil
                pollTask = nil
                return
            }
        }
        authLog.notice("Poll loop cancelled")
    }

    private func exchangeDeviceCode(deviceCode: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "code":          deviceCode,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "http://oauth.net/grant_type/device/1.0",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed
        }

        // RFC 8628 §3.5 error codes
        if let oauthError = json["error"] as? String {
            switch oauthError {
            case "authorization_pending": throw AuthError.authorizationPending
            case "slow_down":             throw AuthError.slowDown
            case "access_denied":         throw AuthError.cancelled
            case "expired_token":         throw AuthError.deviceCodeExpired
            default:                      throw AuthError.tokenExchangeFailed
            }
        }

        guard (200..<300).contains(statusCode) else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let r = json["refresh_token"] as? String { refreshToken = r }
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
        scheduleProactiveRefresh()
    }

    // MARK: - Token refresh

    private func refreshAccessToken(refreshToken: String, creds: YouTubeClientCredentials) async throws {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "refresh_token": refreshToken,
            "client_id":     creds.clientId,
            "client_secret": creds.clientSecret,
            "grant_type":    "refresh_token",
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Detect permanent refresh-token failures (revoked, expired, invalid credentials).
        // Google returns HTTP 400/401 with {"error":"invalid_grant"} or "invalid_client".
        // These are unrecoverable — sign out so the user isn't stuck with stale tokens.
        if (statusCode == 400 || statusCode == 401),
           let errJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauthError = errJson["error"] as? String,
           ["invalid_grant", "invalid_client", "unauthorized_client"].contains(oauthError) {
            authLog.error("refreshAccessToken: permanent failure (\(oauthError)) — signing out")
            signOut()
            throw AuthError.tokenExchangeFailed
        }

        guard (200..<300).contains(statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AuthError.tokenExchangeFailed }

        accessToken = json["access_token"] as? String
        if let exp = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(exp - 60)
        }
        isSignedIn = accessToken != nil
        saveToKeychain()
        scheduleProactiveRefresh()
    }

    // MARK: - User info

    private func fetchUserInfo() async throws {
        authLog.notice("fetchUserInfo() — calling validAccessToken()")
        let token = try await validAccessToken()
        authLog.notice("fetchUserInfo() — token len=\(token.count), calling InnerTube accounts_list API")
        // Android methodology: POST to www.youtube.com/youtubei/v1/account/accounts_list
        // with TV client context + accountReadMask. Mirrors AuthApi.java @POST accounts_list
        // and AuthApiHelper.getAccountsListQuery() which uses PostDataHelper.createQueryTV().
        // Android alignment: no ?key= when Bearer token is present (RetrofitOkHttpHelper pattern).
        var req = URLRequest(url: Self.accountsListURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Android: PostDataHelper.createQueryTV with accountReadMask
        let body: [String: Any] = [
            "context": [
                "client": [
                    "hl": "en",
                    "gl": "US",
                    "clientName": InnerTubeClients.TV.name,
                    "clientVersion": InnerTubeClients.TV.version,
                ]
            ],
            // Android AuthApiHelper.getAccountsListQuery():
            // "accountReadMask":{"returnOwner":true,"returnBrandAccounts":true,"returnPersonaAccounts":false}
            "accountReadMask": [
                "returnOwner": true,
                "returnBrandAccounts": true,
                "returnPersonaAccounts": false
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        authLog.notice("fetchUserInfo() — HTTP \(statusCode)")
        if let bodyStr = String(data: data, encoding: .utf8) {
            authLog.notice("fetchUserInfo() — response: \(String(bodyStr.prefix(600)))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            authLog.error("fetchUserInfo() — JSON parse failed")
            return
        }
        // Android AccountsList.java JsonPath:
        // $.contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[*].accountItem
        // AccountInt: accountName (TextItem), accountPhoto.thumbnails, accountByline, channelHandle, isSelected
        let accountItem = extractAccountItem(from: json)
        guard let item = accountItem else {
            authLog.error("fetchUserInfo() — could not find accountItem; top-level keys=\(Array(json.keys))")
            return
        }
        // accountName is a TextItem — getText() uses runs[].text joined, or simpleText
        if let nameDict = item["accountName"] as? [String: Any] {
            accountName = (nameDict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                ?? nameDict["simpleText"] as? String
        }
        authLog.notice("fetchUserInfo() — accountName=\(self.accountName ?? "nil")")
        if let photoDict = item["accountPhoto"] as? [String: Any],
           let thumbnails = photoDict["thumbnails"] as? [[String: Any]],
           let last = thumbnails.last,
           let urlStr = last["url"] as? String {
            accountAvatarURL = URL(string: urlStr.hasPrefix("//") ? "https:\(urlStr)" : urlStr)
            authLog.notice("fetchUserInfo() — avatarURL=\(urlStr)")
        }
        saveToKeychain()
    }

    /// Walk Android's AccountsList JSON path:
    /// contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[].accountItem
    /// Returns the first account with isSelected==true, or the first available account.
    private func extractAccountItem(from json: [String: Any]) -> [String: Any]? {
        guard let contents = json["contents"] as? [[String: Any]],
              let firstSection = contents.first,
              let sectionListRenderer = firstSection["accountSectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]],
              let firstItemSection = sectionContents.first,
              let itemSectionRenderer = firstItemSection["accountItemSectionRenderer"] as? [String: Any],
              let items = itemSectionRenderer["contents"] as? [[String: Any]]
        else { return nil }
        // Return selected account first, fallback to first one
        return items.compactMap { $0["accountItem"] as? [String: Any] }
            .first(where: { $0["isSelected"] as? Bool == true })
            ?? items.compactMap { $0["accountItem"] as? [String: Any] }.first
    }

    // MARK: - Persistence (Keychain)

    private func saveToKeychain() {
        keychainSet(key: tokenKey,   value: accessToken)
        keychainSet(key: refreshKey, value: refreshToken)
        keychainSet(key: expiryKey,  value: tokenExpiry.map { ISO8601DateFormatter().string(from: $0) })
        keychainSet(key: accountKey, value: accountName)
        keychainSet(key: avatarKey,  value: accountAvatarURL?.absoluteString)
    }

    private func loadFromKeychain() {
        accessToken      = keychainGet(key: tokenKey)
        refreshToken     = keychainGet(key: refreshKey)
        if let expiryStr = keychainGet(key: expiryKey) {
            tokenExpiry  = ISO8601DateFormatter().date(from: expiryStr)
        }
        accountName      = keychainGet(key: accountKey)
        accountAvatarURL = keychainGet(key: avatarKey).flatMap { URL(string: $0) }
        // If the stored access token has already expired, clear it so that
        // view observers (e.g. HomeView.task(id: auth.accessToken)) don't fire
        // API requests with a stale token. scheduleProactiveRefresh() will
        // obtain a fresh token and set accessToken once it succeeds.
        if let expiry = tokenExpiry, expiry <= Date() {
            accessToken = nil
        }
        isSignedIn       = accessToken != nil || refreshToken != nil
        if isSignedIn { scheduleProactiveRefresh() }
    }

    private func clearKeychain() {
        [tokenKey, refreshKey, expiryKey, accountKey, avatarKey].forEach { keychainDelete(key: $0) }
    }

    // MARK: - Keychain helpers

    private func keychainSet(key: String, value: String?) {
        // Always delete the existing item first to avoid errSecDuplicateItem
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, let valueData = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    key,
            kSecValueData:      valueData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            authLog.error("keychainSet failed for key=\(key) status=\(status)")
        }
    }

    private func keychainGet(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  keychainService,
            kSecAttrAccount:  key,
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private func formEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn
    case configurationError
    case deviceCodeRequestFailed
    case authorizationPending
    case slowDown
    case deviceCodeExpired

    public var errorDescription: String? {
        switch self {
        case .cancelled:              return "Sign-in was cancelled"
        case .missingCode:            return "OAuth code was missing from callback"
        case .tokenExchangeFailed:    return "Failed to exchange code for tokens"
        case .notSignedIn:            return "You are not signed in"
        case .configurationError:     return "OAuth credentials could not be obtained"
        case .deviceCodeRequestFailed:return "Could not start sign-in. Check your internet connection."
        case .authorizationPending:   return "Waiting for authorisation…"
        case .slowDown:               return "Too many requests — slowing down"
        case .deviceCodeExpired:      return "The sign-in code expired. Please try again."
        }
    }
}
