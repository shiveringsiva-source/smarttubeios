import Foundation

// MARK: - InnerTubeClients
//
// Single source of truth for YouTube InnerTube client identifiers and versions.
// Used by InnerTubeAPI (request bodies + headers) and AuthService (TV context body).

package enum InnerTubeClients {

    package enum Web {
        package static let name      = "WEB"
        package static let nameID    = "1"
        package static let version   = "2.20260206.01.00"
        /// Browser UA used by the YouTube web client.
        package static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    package enum iOS {
        package static let name      = "iOS"
        package static let nameID    = "5"
        package static let version   = "21.02.3"
        /// Returns the running iOS version formatted as "MAJOR_MINOR_PATCH" (or "MAJOR_MINOR"
        /// when the patch is 0). Dynamically derived from ProcessInfo so the User-Agent always
        /// reflects the actual device OS — prevents YouTube from rejecting requests sent from
        /// devices running iOS versions newer than the hardcoded string.
        package static var currentOSVersionString: String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return v.patchVersion == 0
                ? "\(v.majorVersion)_\(v.minorVersion)"
                : "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        }
        package static var userAgent: String {
            "com.google.ios.youtube/\(version) (iPhone16,2; U; CPU iOS \(currentOSVersionString) like Mac OS X;)"
        }
    }

    /// Android client — used exclusively for downloads.
    /// CDN URLs signed by the Android client are reliably downloadable using just
    /// the Android UA; no session cookies or PO tokens required.
    /// Exact params from yt-dlp to avoid YouTube bot detection / HTTP 400.
    package enum Android {
        package static let name            = "ANDROID"
        package static let nameID          = "3"
        package static let version         = "21.02.35"
        package static let androidSdkVersion = 30  // Android 11
        package static let userAgent       = "com.google.android.youtube/\(version) (Linux; U; Android 11) gzip"
    }

    package enum TV {
        package static let name      = "TVHTML5"
        package static let nameID    = "7"
        package static let version   = "7.20260311.12.00"
        package static let userAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"
    }

    /// Maximum number of videos fetched per shelf/related-videos request.
    package static let maxVideoResults = 20
}
