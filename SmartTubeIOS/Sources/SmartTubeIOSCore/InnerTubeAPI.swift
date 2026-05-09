import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - InnerTubeAPI
//
// Implements a subset of the unofficial YouTube InnerTube API used by
// the Android SmartTube client (MediaServiceCore). This layer replaces
// the Java-based youtubeapi module.
//
// References:
//   https://github.com/LuanRT/YouTube.js/blob/main/src/core/clients/Web.ts
//   https://github.com/TeamNewPipe/NewPipeExtractor

public actor InnerTubeAPI {

    // MARK: - Configuration

    let session: URLSession
    var visitorData: String?
    var authToken: String?

    /// The web client context used to fetch home/search/channel feeds.
    let webClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.Web.name,
            "clientVersion": InnerTubeClients.Web.version,
        ]
    ]

    /// The iOS client context used for stream URL retrieval.
    /// Returns c=iOS URLs and an HLS manifest, both playable natively by AVPlayer.
    /// `osVersion` is derived at runtime from ProcessInfo so requests reflect the
    /// actual device OS and are not rejected by YouTube's version validation.
    var iosClientContext: [String: Any] {
        let osVer = InnerTubeClients.iOS.currentOSVersionString.replacingOccurrences(of: "_", with: ".")
        return [
            "client": [
                "hl": "en",
                "gl": "US",
                "clientName": InnerTubeClients.iOS.name,
                "clientVersion": InnerTubeClients.iOS.version,
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": osVer,
                "clientScreen": "WATCH",
            ]
        ]
    }
    let iosUserAgent = InnerTubeClients.iOS.userAgent

    /// The Android client context used for download URL retrieval.
    /// Exact params match yt-dlp's android client to avoid HTTP 400.
    let androidClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.Android.name,
            "clientVersion": InnerTubeClients.Android.version,
            "androidSdkVersion": InnerTubeClients.Android.androidSdkVersion,
            "osName": "Android",
            "osVersion": "11",
        ]
    ]

    /// The TVHTML5 client context required for all authenticated InnerTube requests
    /// (subscriptions, history, playlists, personalised home).
    /// The OAuth token issued by the TV device-code flow is bound to this client.
    /// The WEB client on www.youtube.com rejects Bearer tokens and returns 400.
    let tvClientContext: [String: Any] = [
        "client": [
            "hl": "en",
            "gl": "US",
            "clientName": InnerTubeClients.TV.name,
            "clientVersion": InnerTubeClients.TV.version,
        ]
    ]

    let baseURL = URL(string: "https://www.youtube.com/youtubei/v1")!
    let playerBaseURL = URL(string: "https://youtubei.googleapis.com/youtubei/v1")!
    // Public InnerTube API key embedded in YouTube's own web client JS — not a developer secret.
    // nosec: false positive — this key is published by Google in youtube.com/s/player JS.
    // Used only for unauthenticated requests (aligned to Android RetrofitOkHttpHelper pattern).
    let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8" // gitleaks:allow
    // Note: TV key (AIzaSyDCU8...) is defined in Android as API_KEY_OLD and never used.

    public init(authToken: String? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.authToken = authToken
    }

    // MARK: - Auth

    public func setAuthToken(_ token: String?) {
        let msg = token != nil ? "token(\(token!.prefix(8))…)" : "nil"
        tubeLog.notice("setAuthToken: \(msg, privacy: .public)")

        self.authToken = token
    }
}
