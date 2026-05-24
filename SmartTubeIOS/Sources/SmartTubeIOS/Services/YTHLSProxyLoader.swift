/// YTHLSProxyLoader.swift
/// Proxies HLS playlist and segment requests through URLSession so the correct
/// User-Agent (desktop Safari) is sent to manifest.googlevideo.com.
/// AVURLAssetHTTPHeaderFieldsKey does not reliably propagate User-Agent through
/// CoreMedia's internal HLS stack — this resource loader fills that gap.

#if canImport(WebKit)
import AVFoundation
import Foundation
import os.log

private let proxyScheme = "ytwebhls"
private let proxyLog = Logger(subsystem: "com.void.smarttube.app", category: "HLSProxy")

// MARK: - URL scheme helpers

extension URL {
    /// Converts an https:// URL to ytwebhls:// for routing through the proxy.
    var proxyURL: URL? {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = proxyScheme
        return c.url
    }
    /// Converts a ytwebhls:// URL back to https:// for the actual network request.
    var realURL: URL? {
        guard scheme == proxyScheme,
              var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        return c.url
    }
}

// MARK: - YTHLSProxyLoader

/// `AVAssetResourceLoaderDelegate` that forwards every HLS request through
/// `URLSession.shared` with a desktop-Safari User-Agent header.
/// Holds a strong reference to itself via the asset to keep it alive.
final class YTHLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let ua: String
    /// When non-nil, the proxy rewrites all `/n/{unsolved}/` occurrences to `/n/{solved}/`
    /// in HLS playlist text before serving it to AVPlayer. This makes segment URLs carry
    /// the solved n-challenge so the video CDN accepts them (HTTP 200 instead of 403).
    let nSolver: (unsolved: String, solved: String)?
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(ua: String, nSolver: (unsolved: String, solved: String)? = nil) {
        self.ua = ua
        self.nSolver = nSolver
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              let realURL   = proxyURL.realURL else {
            proxyLog.error("[HLSProxy] unexpected scheme: \(loadingRequest.request.url?.scheme ?? "nil")")
            return false
        }

        var request = URLRequest(url: realURL, timeoutInterval: 30)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        // All googlevideo.com requests (both manifest and segment CDN) need Origin/Referer
        // matching youtube.com so the CDN accepts the cross-origin request.
        if let host = realURL.host, host.contains("googlevideo.com") {
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        }
        // For googlevideo.com segment CDN requests, attach the youtube.com session cookies
        // that were synced from the WKWebView during HLS extraction.  The CDN validates the
        // per-segment /bui/ token against VISITOR_INFO1_LIVE (and possibly YSC/PREF).
        // Without these cookies the CDN returns HTTP 403 for pfa=1 content.
        if let host = realURL.host, host.contains("googlevideo.com"),
           let ytCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.youtube.com")!),
           !ytCookies.isEmpty {
            let cookieHeader = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            proxyLog.notice("[HLSProxy] attaching \(ytCookies.count) yt cookies to segment request")
        }
        proxyLog.notice("[HLSProxy] GET \(realURL.absoluteString.prefix(200))")

        let key = ObjectIdentifier(loadingRequest)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.activeTasks.removeValue(forKey: key)
                self.lock.unlock()
            }

            if let error {
                proxyLog.error("[HLSProxy] URLSession error: \(error.localizedDescription)")
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let httpResp = response as? HTTPURLResponse, let data else {
                loadingRequest.finishLoading(with: NSError(domain: "YTHLSProxy", code: -1))
                return
            }

            proxyLog.notice("[HLSProxy] \(realURL.lastPathComponent) HTTP=\(httpResp.statusCode) bytes=\(data.count)")
            // Log response body for 4xx/5xx to diagnose CDN rejections (n-challenge, auth, etc.)
            if httpResp.statusCode >= 400 {
                let errBody = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                proxyLog.error("[HLSProxy] ERROR body: \(errBody as NSString)")
            }

            // Determine whether this resource is an HLS playlist.
            // IMPORTANT: YouTube segment URLs embed "/playlist/index.m3u8/" in their path
            // (e.g. ".../playlist/index.m3u8/govp/.../file/seg.ts"), so a simple path.contains
            // check erroneously treats segments as playlists — corrupting binary TS data.
            // We use the MIME type first, then fall back to whether the path *ends* with m3u8
            // (last path component), which correctly excludes segment URLs.
            let mimeTypeLower = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let isPlaylist = mimeTypeLower.contains("mpegurl")
                          || realURL.pathExtension.lowercased() == "m3u8"
                          || realURL.lastPathComponent.lowercased() == "index.m3u8"
            proxyLog.notice("[HLSProxy] Content-Type=\(httpResp.value(forHTTPHeaderField: "Content-Type") ?? "nil") isPlaylist=\(isPlaylist)")

            // For HLS playlists, rewrite segment/sub-playlist URIs to our proxy scheme.
            var responseData = data
            if isPlaylist {
                if let text = String(data: data, encoding: .utf8) {
                    let rewritten = self.rewritePlaylist(text, baseURL: realURL)
                    responseData = rewritten.data(using: .utf8) ?? data
                }
            }

            // Populate content information AFTER computing responseData so contentLength is accurate.
            // AVAssetResourceLoadingContentInformationRequest.contentType requires a UTI string
            // (Uniform Type Identifier), NOT a raw MIME type. Supplying a MIME type causes
            // AVFoundation to misidentify the resource and fail with CoreMediaErrorDomain -12881.
            if let infoReq = loadingRequest.contentInformationRequest {
                let uti = isPlaylist ? "public.m3u-playlist" : "public.mpeg-2-transport-stream"
                infoReq.contentType = uti
                infoReq.contentLength = Int64(responseData.count)
                infoReq.isByteRangeAccessSupported = false
                proxyLog.notice("[HLSProxy] contentInfo: UTI=\(uti) length=\(responseData.count)")
            }

            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }

        lock.lock()
        activeTasks[key] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = activeTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    // MARK: Playlist rewriting

    /// Rewrites all URI lines in an HLS M3U8 to use our proxy scheme so that
    /// AVPlayer routes segment/sub-playlist requests through this delegate.
    /// Also rewrites the n-challenge in all segment/playlist URLs if `nSolver` is set.
    private func rewritePlaylist(_ m3u8: String, baseURL: URL) -> String {
        // Step 1: Replace unsolved n-challenge across the entire playlist text.
        // The n-value is identical in all URLs for a given session, so a global
        // string replacement is safe and avoids per-URL regex overhead.
        var text = m3u8
        if let (unsolved, solved) = nSolver, !unsolved.isEmpty, unsolved != solved {
            let oldN = "/n/\(unsolved)/"
            let newN = "/n/\(solved)/"
            let before = text
            text = text.replacingOccurrences(of: oldN, with: newN)
            if text != before {
                proxyLog.notice("[HLSProxy] n-challenge rewritten: \(unsolved as NSString) -> \(solved as NSString)")
            } else {
                proxyLog.notice("[HLSProxy] n-challenge NOT found in playlist (unsolved=\(unsolved as NSString))")
            }
        }

        // Step 1.5: Synthesize missing #EXTINF tags for YouTube's non-standard per-quality
        // playlists. YouTube sometimes returns a playlist that starts with #EXTM3U followed
        // directly by segment URLs (no #EXTINF duration tags). AVPlayer rejects such playlists
        // with CoreMediaErrorDomain -12881. We reconstruct a conformant HLS playlist by
        // extracting the segment duration from the /len/{ms}/ path component of each URL.
        if !text.contains("#EXTINF") {
            let rawLines = text.components(separatedBy: "\n")
            var fixedLines: [String] = []
            var maxDurationSecs: Double = 4.0
            var segmentCount = 0
            var hasEndlist = false

            for rawLine in rawLines {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed == "#EXTM3U" {
                    fixedLines.append(rawLine)
                    // Inject required header tags immediately after #EXTM3U.
                    // We'll fill in EXT-X-TARGETDURATION after the first pass.
                    fixedLines.append("__TARGETDURATION_PLACEHOLDER__")
                    fixedLines.append("#EXT-X-VERSION:3")
                    fixedLines.append("#EXT-X-MEDIA-SEQUENCE:0")
                    fixedLines.append("#EXT-X-ALLOW-CACHE:NO")
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    if trimmed == "#EXT-X-ENDLIST" { hasEndlist = true }
                    fixedLines.append(rawLine)
                } else {
                    // URL line — extract segment duration from /len/{ms}/ path component.
                    var durationSecs: Double = 4.0
                    if let lenStart = trimmed.range(of: "/len/") {
                        let after = trimmed[lenStart.upperBound...]
                        if let lenEnd = after.firstIndex(of: "/") {
                            let msString = String(after[after.startIndex..<lenEnd])
                            if let ms = Double(msString), ms > 0 {
                                durationSecs = ms / 1000.0
                            }
                        }
                    }
                    maxDurationSecs = max(maxDurationSecs, durationSecs)
                    fixedLines.append("#EXTINF:\(String(format: "%.6f", durationSecs)),")
                    fixedLines.append(rawLine)
                    segmentCount += 1
                }
            }

            if !hasEndlist {
                fixedLines.append("#EXT-X-ENDLIST")
            }

            let targetDurationTag = "#EXT-X-TARGETDURATION:\(Int(ceil(maxDurationSecs)))"
            let result = fixedLines
                .map { $0 == "__TARGETDURATION_PLACEHOLDER__" ? targetDurationTag : $0 }
                .joined(separator: "\n")
            text = result
            proxyLog.notice("[HLSProxy] synthesized #EXTINF for \(segmentCount) segments; targetDuration=\(Int(ceil(maxDurationSecs)))s")
        }

        // Step 2: Keep segment URLs as https:// — AVPlayer loads them natively.
        // The n-challenge is already solved in Step 1, so CDN auth is embedded in
        // the URL. AVPlayer's built-in HTTP stack handles MPEG-TS segments directly.
        // Routing segments through the ytwebhls:// delegate causes CoreMediaErrorDomain
        // -12881 because AVFoundation does not support serving binary media data through
        // AVAssetResourceLoaderDelegate for standard HLS segments.
        return text
    }
}
#endif
