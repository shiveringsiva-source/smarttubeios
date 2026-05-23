@preconcurrency import AVFoundation
import AetherEngine
import os
#if canImport(UIKit)
import UIKit
#endif
import SmartTubeIOSCore

// Disambiguate SmartTubeIOSCore.VideoFormat (stream format: height/bitrate/URL)
// from AetherEngine.VideoFormat (dynamic range: sdr/hdr10/dolbyVision).
// All VideoFormat uses in this file are in private functions, so private typealias is fine.
private typealias VideoFormat = SmartTubeIOSCore.VideoFormat

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Exhaustive Playback Retry

extension PlaybackViewModel {

    // MARK: - Entry Points

    /// Main retry entry point. Called whenever the primary iOS stream fails.
    ///
    /// Strategy:
    ///   Phase 0 — Authenticated TV client: when logged in, the TV client with
    ///             `html5Preference: HTML5_PREF_WANTS` returns `streamingData` including
    ///             an `hlsManifestUrl`. Authenticated HLS URLs bypass rqh=1 CDN enforcement
    ///             and enable quality switching via AVPlayer ABR. Skipped if not logged in.
    ///   Phase 1 — TV embedded (TVHTML5_SIMPLY_EMBEDDED_PLAYER): returns HLS for most
    ///             embeddable videos without pot/rqh=1 restriction.
    ///   Phase 2 — try HLS + adaptive from iOS and Android clients in order.
    ///   Phase 3 — Android VR (Oculus Quest client, nameID=28): per yt-dlp research, this
    ///             client is exempt from the PO-token / rqh=1 requirement on adaptive streams.
    ///             Correct VR headers (nameID=28, Oculus UA on googleapis.com) are required.
    ///   Phase 4 — if all adaptive attempts fail, fall back to the Android muxed 360p stream.
    ///   The entire cycle repeats up to 3 times to survive transient network errors.
    func exhaustiveRetry(video: Video, originalError: Error?) async {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return }
            retryAttempts = attempt
            playerLog.notice("Exhaustive retry \(attempt)/3 for \(video.id)")

            // Evict the stale cache entry so each attempt gets fresh signed URLs.
            await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)

            // --- Phase 0: Authenticated TV client (logged-in users only) ---
            // With `html5Preference: HTML5_PREF_WANTS` the TV client returns streamingData
            // including an HLS manifest URL. Authenticated HLS manifests do not have rqh=1
            // on their segment/variant URLs, so quality switching works via AVPlayer ABR.
            // Skip when no auth token is present (unauthenticated flow continues to Phase 1).
            if hasAuthToken {
                do {
                    let tvAuthInfo = try await api.fetchPlayerInfoAuthenticated(videoId: video.id)
                    if await tryAllStreams(video: video, info: tvAuthInfo,
                                          label: "TVAuth[\(attempt)]", skipMuxed: true) {
                        return
                    }
                } catch {
                    playerLog.error("TV auth client fetch failed (attempt \(attempt)): \(error)")
                }
                guard !Task.isCancelled else { return }
            }

            // --- Phase 1: TV Embedded client ---
            // TVHTML5_SIMPLY_EMBEDDED_PLAYER (client ID 85) returns an HLS manifest
            // for most embeddable videos. HLS streams bypass the rqh=1/pot CDN enforcement
            // that causes HTTP 403 on adaptive streams. If HLS loads, quality switching
            // works via AVPlayer ABR (preferredMaximumResolution) — no composition needed.
            // Videos with embedding disabled will fail this phase and continue to Phase 2.
            do {
                let tvEmbedInfo = try await api.fetchPlayerInfoTVEmbedded(videoId: video.id)
                if await tryAllStreams(video: video, info: tvEmbedInfo,
                                      label: "TVEmbedded[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                playerLog.error("TV embedded client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- WebSafari client (WEB nameID=1 + macOS Safari UA) ---
            // yt-dlp's `web_safari` client returns `hlsManifestUrl` for non-embeddable
            // videos where TVEmbedded fails. manifest.googlevideo.com HLS URLs don't need
            // pot= tokens. This is the primary HLS path for embedding-disabled content.
            do {
                let wsiInfo = try await api.fetchPlayerInfoWebSafari(videoId: video.id)
                if await tryAllStreams(video: video, info: wsiInfo,
                                      label: "WebSafari[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                playerLog.error("WebSafari client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- MWEB client (HLS, no embed restriction) ---
            // The mobile web client (m.youtube.com, iPad Safari UA, nameID=2) is not
            // subject to the embedding restriction that gates WEB_EMBEDDED_PLAYER.
            // Per yt-dlp, MWEB does not require a PO Token for HLS (required=False) and
            // may return `hlsManifestUrl` for videos TVEmbedded cannot serve.
            do {
                let mwebInfo = try await api.fetchPlayerInfoMWEB(videoId: video.id)
                if await tryAllStreams(video: video, info: mwebInfo,
                                      label: "MWEB[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                playerLog.error("MWEB client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- iOS client (fresh network fetch) ---
            // When logged in, use the authenticated iOS client. Auth tokens cause YouTube
            // to return adaptive stream URLs without rqh=1 CDN enforcement, enabling
            // DASH composition. The unauthenticated iOS client always returns rqh=1 URLs
            // that 403 at the CDN. Tries HLS + adaptive only (muxed fallback happens below).
            var androidInfoForMuxed: PlayerInfo? = nil
            do {
                let iosInfo = hasAuthToken
                    ? try await api.fetchPlayerInfoiOSAuthenticated(videoId: video.id)
                    : try await api.fetchPlayerInfo(videoId: video.id)
                await VideoPreloadCache.shared.store(playerInfo: iosInfo, for: video.id)
                if await tryAllStreams(video: video, info: iosInfo, label: "iOS[\(attempt)]",
                                      skipMuxed: true) {
                    return
                }
            } catch {
                if case APIError.ipBlocked = error {
                    playerLog.error("❌ iOS client: IP blocked — \(error)")
                    self.error = error
                    return
                }
                playerLog.error("iOS client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- Android client (HLS + adaptive only; muxed reserved for phase 3) ---
            do {
                let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                androidInfoForMuxed = androidInfo  // save for muxed fallback below
                if await tryAllStreams(video: video, info: androidInfo,
                                      label: "Android[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                if case APIError.ipBlocked = error {
                    playerLog.error("❌ Android client: IP blocked — \(error)")
                    self.error = error
                    return
                }
                playerLog.error("Android client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- Android VR client (adaptive) ---
            do {
                let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
                if await tryAllStreams(video: video, info: vrInfo,
                                      label: "AndroidVR[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                playerLog.error("Android VR client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- WEB_CREATOR client (adaptive) ---
            do {
                let wcInfo = try await api.fetchPlayerInfoWebCreator(videoId: video.id)
                if await tryAllStreams(video: video, info: wcInfo,
                                      label: "WebCreator[\(attempt)]", skipMuxed: true) {
                    return
                }
            } catch {
                playerLog.error("WebCreator client fetch failed (attempt \(attempt)): \(error)")
            }

            guard !Task.isCancelled else { return }

            // --- Phase 2: muxed direct MP4 (360p last resort) ---
            // Only reached when ALL adaptive attempts above failed.
            if let androidInfo = androidInfoForMuxed, androidInfo.bestMuxedDownloadURL != nil {
                playerLog.notice("[Android[\(attempt)]] All adaptive failed — trying muxed fallback")
                if await tryAllStreams(video: video, info: androidInfo,
                                      label: "Android[\(attempt)]/muxed") {
                    return
                }
                // Android muxed failed (possibly AVF -11828 "Cannot Open" on SABR/long-video URLs,
                // or URL expiry). Try the Web/iOS client muxed URL as a final rescue path.
                // fetchPlayerInfo() returns iOS-client playerInfo whose muxed URL is
                // CDN-signed with standard MP4 headers, avoiding the TVHTML5 SABR issue.
                playerLog.notice("[Android[\(attempt)]] Muxed failed — trying Web client muxed fallback")
                do {
                    let webInfo = try await api.fetchPlayerInfo(videoId: video.id)
                    if webInfo.bestMuxedDownloadURL != nil {
                        if await tryAllStreams(video: video, info: webInfo,
                                              label: "Web[\(attempt)]/muxed") {
                            return
                        }
                    }
                } catch {
                    playerLog.error("Web client muxed fallback fetch failed (attempt \(attempt)): \(error)")
                }
            }
        }

        guard !Task.isCancelled else { return }
        playerLog.error("❌ All 3 retry attempts exhausted for \(video.id)")
        error = APIError.unavailable("Unable to play this video")
    }

    /// Kept for the `PlaybackQualityManagerDelegate` protocol.
    /// Quality-switch 403 errors start a fresh 3-attempt exhaustive cycle.
    func retryWith403Recovery(video: Video, originalError: Error?) async {
        playerLog.notice("403 recovery (quality switch) — exhaustive retry for \(video.id)")
        // Capture the current playback position so the new stream resumes from here.
        // Without this, attemptComposition / attemptURL have no seekTo target and the
        // new item starts from t=0 — causing the position-preservation assertion to fail.
        let pos = currentTime
        if pos > 0 {
            savedPositionToRestore = pos
        }
        retryAttempts = 0
        await exhaustiveRetry(video: video, originalError: originalError)
    }

    // MARK: - Stream Exhaustion

    /// Tries HLS → adaptive composition → (optionally) muxed direct from one PlayerInfo.
    /// Returns true if any stream starts playing successfully.
    /// - Parameter skipMuxed: When `true`, the muxed direct-MP4 fallback is skipped so that
    ///   the caller can try higher-priority clients before accepting the 360p muxed last-resort.
    private func tryAllStreams(video: Video, info: PlayerInfo, label: String,
                               skipMuxed: Bool = false) async -> Bool {
        let hasHLS = info.hlsURL != nil
        let hasDASH = info.dashURL != nil
        let hasAdaptiveVideo = qualityCapVideoURL(from: info.formats) != nil
        let hasAdaptiveAudio = info.bestAdaptiveAudioURL != nil
        let hasMuxed = info.bestMuxedDownloadURL != nil
        // Diagnostic: show first adaptive video URL prefix to detect SABR (c=TVHTML5) vs standard
        let firstAdaptiveURL = info.formats.first(where: {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        })?.url?.absoluteString.prefix(200) ?? "none"
        playerLog.notice("[\(label)] streams: HLS=\(hasHLS) DASH=\(hasDASH) adaptiveVideo=\(hasAdaptiveVideo) adaptiveAudio=\(hasAdaptiveAudio) muxed=\(hasMuxed) skipMuxed=\(skipMuxed) firstAdaptiveURL=\(firstAdaptiveURL)")

        // 1. HLS manifest — best quality, native AVPlayer ABR, alternate audio renditions
        if let hlsURL = info.hlsURL {
            playerLog.notice("[\(label)] Trying HLS")
            if await attemptURL(hlsURL, for: video, info: info, label: "\(label)/HLS") { return true }
            playerLog.notice("[\(label)] HLS failed — trying adaptive composition")
        }

        // 2. Adaptive composition — video-only + audio-only; avoids muxed CDN pot restrictions
        if let videoURL = qualityCapVideoURL(from: info.formats),
           let audioURL = info.bestAdaptiveAudioURL {
            playerLog.notice("[\(label)] Trying adaptive composition")
            if await attemptComposition(videoURL: videoURL, audioURL: audioURL,
                                        for: video, info: info, label: label) {
                return true
            }
            // A background prefetch may have stored an HLS URL in the cache while adaptive
            // was running (confirmed in logs: hls=true stored mid-retry for LSMQ3U1Thzw).
            // Check before falling through to muxed — HLS gives us multi-audio track support.
            let freshCachedInfo = await VideoPreloadCache.shared.consume(videoId: video.id).playerInfo
            if let freshHLSURL = freshCachedInfo?.hlsURL, freshHLSURL != info.hlsURL {
                playerLog.notice("[\(label)] HLS URL appeared in cache after adaptive failed — trying HLS")
                if await attemptURL(freshHLSURL, for: video, info: freshCachedInfo!,
                                    label: "\(label)/HLS-late") { return true }
            }
            playerLog.notice("[\(label)] Adaptive composition failed — trying muxed")
        }

        // 3. Muxed direct MP4 (itag=18, 360p — last resort, skipped when skipMuxed=true)
        if !skipMuxed, let muxedURL = info.bestMuxedDownloadURL {
            // Guard: TVHTML5 SABR-protocol URLs serve binary data, not a standard MP4 container.
            // AVPlayer returns -11828 (AVFoundationErrorDomain "Cannot Open") for these.
            if muxedURL.absoluteString.contains("c=TVHTML5") {
                playerLog.notice("[\(label)] Skipping SABR muxed URL (c=TVHTML5) — not a playable MP4")
            } else {
                playerLog.notice("[\(label)] Trying muxed")
                let muxedItag = muxedURL.absoluteString
                    .components(separatedBy: "&")
                    .first(where: { $0.contains("itag=") })
                    .flatMap { $0.components(separatedBy: "=").last } ?? "?"
                let muxedBitrate = info.formats.first(where: { $0.url == muxedURL })?.bitrate.map { "\($0/1000)kbps" } ?? "?"
                playerLog.notice("[\(label)] muxed candidate: itag=\(muxedItag) bitrate=\(muxedBitrate) url=\(muxedURL.absoluteString.prefix(100))")
                if await attemptURL(muxedURL, for: video, info: info, label: "\(label)/muxed") { return true }
                playerLog.notice("[\(label)] Muxed failed — no more alternatives for this client")
            }
        }

        return false
    }

    // MARK: - Attempt Helpers

    /// Tries a single URL in AVPlayer. Returns true if `.readyToPlay` is received.
    /// `statusStream` finishes after `.readyToPlay` or `.failed`, making it safe to await inline.
    private func attemptURL(_ url: URL, for video: Video, info: PlayerInfo, label: String) async -> Bool {
        playerLog.notice("[\(label)]: \(url.absoluteString.prefix(120))")

        playerInfo = info
        let newFormats = Self.deduplicatedVideoFormats(info.formats)
        // Never reduce quality options for adaptive/HLS streams — preserve the richest set seen.
        // Exception: muxed fallback (label contains "/muxed") always resets availableFormats to
        // the muxed-only formats. This prevents stale rqh=1-blocked adaptive formats from
        // appearing in the quality picker when they can never actually play.
        let maxCurrentHeight = availableFormats.map(\.height).max() ?? 0
        let maxNewHeight = newFormats.map(\.height).max() ?? 0
        let isMuxedFallback = label.contains("/muxed")
        if isMuxedFallback || newFormats.count > availableFormats.count || maxNewHeight > maxCurrentHeight || availableFormats.isEmpty {
            availableFormats = newFormats
        }
        playerLog.notice("[\(label)] availableFormats after dedup: input=\(info.formats.count) output=\(newFormats.count) kept=\(availableFormats.count) maxH=\(availableFormats.map(\.height).max() ?? 0)")
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        var effectiveURL = url
        var applyHLSHints = false
        if let hlsURL = info.hlsURL, url == hlsURL {
            let videoId = video.id
            let variantURLs: [Int: URL]
            if let cached = PlaybackQualityManager.cachedHLSVariants(for: videoId) {
                playerLog.notice("[\(label)] HLS: using cached manifest for \(videoId) variantCount=\(cached.count)")
                variantURLs = cached
            } else {
                variantURLs = await fetchHLSVariantURLs(url: hlsURL)
                if !variantURLs.isEmpty {
                    PlaybackQualityManager.cacheHLSVariants(variantURLs, for: videoId)
                }
            }
            playerLog.notice("[\(label)] HLS: hlsURL=yes variantCount=\(variantURLs.count) preferredQuality=\(settings.preferredQuality)")
            if !variantURLs.isEmpty {
                hlsVariantURLs = variantURLs
                availableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
                // Use a variant playlist URL directly rather than the master manifest URL.
                // The master manifest (hls_variant) stalls AVPlayer on manifest.googlevideo.com
                // because it requires session-level auth that AVPlayer's isolated network stack
                // cannot provide. Variant playlist URLs (hls_playlist) are directly downloadable
                // — yt-dlp confirms 720p in 13 s, 1080p in 29 s for the same video.
                let preferredMaxH = settings.preferredQuality == .auto ? nil : settings.preferredQuality.maxHeight
                let chosen = preferredMaxH
                    .flatMap { h in variantURLs.filter { $0.key <= h }.max(by: { $0.key < $1.key }) }
                    ?? variantURLs.max(by: { $0.key < $1.key })
                if let chosen {
                    let variantURL = chosen.value
                    effectiveURL = variantURL
                    playerLog.notice("[\(label)] HLS: selected variant \(chosen.key)p")
                }
            } else {
                playerLog.notice("[\(label)] HLS manifest fetch returned 0 variants — using master as-is")
            }
            qualityManager.setSelectedFormatForCurrentPreference()
            applyHLSHints = true
        } else {
            playerLog.notice("[\(label)] non-HLS URL — no EXT-X-MEDIA, audio tracks will be unavailable")
        }

        lastAttemptedStreamURL = effectiveURL
        let isHLSManifest = label.contains("/HLS")
        let hlsUA = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)"
        var hlsHeaders: [String: String] = ["User-Agent": hlsUA]
        if isHLSManifest && !label.contains("WebSafari") {
            hlsHeaders["Origin"] = "https://www.youtube.com"
            hlsHeaders["Referer"] = "https://www.youtube.com/"
        }

        let item: AVPlayerItem
        if applyHLSHints {
            // AetherEngine path: proxy HLS through a local HLS-fMP4 server (127.0.0.1) with
            // the iOS YouTube UA on every FFmpeg request. AVPlayer never touches CDN URLs, so
            // CDN signing validation and UA fingerprinting become irrelevant.
            do {
                aetherEngine?.stop()
                let engine = try AetherEngine()
                aetherEngine = engine
                let options = LoadOptions(httpHeaders: hlsHeaders)
                try await engine.load(url: effectiveURL, options: options)
                guard let aep = engine.currentAVPlayer,
                      let localhostAsset = aep.currentItem?.asset as? AVURLAsset else {
                    playerLog.error("❌ [\(label)] AetherEngine loaded but no localhost URL available")
                    return false
                }
                // Pause the engine's internal player — our player drives playback.
                engine.pause()
                playerLog.notice("[\(label)] AetherEngine serving HLS from \(localhostAsset.url.host ?? "?")")
                item = AVPlayerItem(url: localhostAsset.url)
            } catch {
                playerLog.error("❌ [\(label)] AetherEngine load failed: \(error)")
                return false
            }
        } else {
            // Non-HLS (muxed / DASH): direct AVURLAsset with iOS UA headers.
            let uaOpts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": hlsHeaders]
            item = AVPlayerItem(asset: AVURLAsset(url: effectiveURL, options: uaOpts))
        }
        item.audioTimePitchAlgorithm = .spectral
        // Reduce startup latency: begin playback after 2 s of buffered content,
        // then reset to system default so scrubbing has a comfortable forward buffer.
        item.preferredForwardBufferDuration = 2.0
        Task { [weak item] in
            try? await Task.sleep(for: .seconds(5))
            item?.preferredForwardBufferDuration = 0
        }
        if applyHLSHints {
            if settings.preferredQuality != .auto, let maxH = settings.preferredQuality.maxHeight {
                item.preferredMaximumResolution = CGSize(width: CGFloat(maxH) * 4, height: CGFloat(maxH))
                item.preferredPeakBitRate = peakBitRate(for: maxH)
                playerLog.notice("[\(label)] HLS ABR hints: maxH=\(maxH)p peakBitRate=\(peakBitRate(for: maxH) / 1_000_000)Mbps (master URL preserved)")
            } else {
                // Auto: remove all constraints so AVPlayer picks the best available variant.
                item.preferredMaximumResolution = .zero
                item.preferredPeakBitRate = 0
                playerLog.notice("[\(label)] HLS ABR hints cleared (Auto quality, unconstrained)")
            }
        }
        player.replaceCurrentItem(with: item)
        itemObserverTask?.cancel()

        for await status in item.statusStream {
            switch status {
            case .readyToPlay:
                playerLog.notice("✅ [\(label)] readyToPlay")
                let itemDur = item.duration.seconds
                if itemDur.isFinite && itemDur > 0 {
                    let prevDur = self.duration
                    self.duration = itemDur
                    playerLog.notice("[duration] updated from AVPlayerItem: \(String(format: "%.1f", itemDur))s (was \(String(format: "%.1f", prevDur))s from metadata)")
                }
                if let pos = savedPositionToRestore, pos > 0 {
                    savedPositionToRestore = nil
                    seek(to: pos)
                }
                loadAudioTracks(from: item)
                needsQuickStartup = false
                isLoading = false
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                launchPhase2(video: video, info: info)
                return true
            case .failed:
                let err = item.error.map { "\($0)" } ?? "nil"
                let nsErr = item.error as? NSError
                let failURL = nsErr?.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
                    ?? nsErr?.userInfo["NSErrorFailingURLKey"] as? String
                playerLog.error("❌ [\(label)] AVPlayerItem failed: \(err)")
                if let failURL {
                    playerLog.error("❌ [\(label)] failing URL: \(failURL.prefix(200))")
                }
                return false
            case .unknown:
                continue
            @unknown default:
                continue
            }
        }
        return false
    }

    /// Composes a video-only + audio-only adaptive stream pair via `AVMutableComposition`.
    /// Returns true on successful `.readyToPlay`.
    private func attemptComposition(
        videoURL: URL, audioURL: URL,
        for video: Video, info: PlayerInfo, label: String
    ) async -> Bool {
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let videoRqh = videoURL.absoluteString.contains("rqh=1")

        // Skip every rqh=1 stream — no client works without a pot= token.
        // yt-dlp claims TVHTML5 and ANDROID_VR are exempt, but empirically:
        //   TVHTML5    → immediate 403 from CDN (~163 ms)
        //   ANDROID_VR → CDN hangs indefinitely (30 s+, no fast error)
        // Neither reaches readyToPlay without a Proof-of-Origin token.
        // When pot= support is added, remove this guard.
        if videoRqh {
            let clientParam = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "c" })?.value ?? "unknown"
            playerLog.notice("[\(label)/adaptive] skipping rqh=1 (client=\(clientParam)) — no pot= token available")
            return false
        }

        // Use the client UA that matches the URL's signing client.
        let clientParam = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value?.uppercased() ?? ""
        let ua: String
        switch clientParam {
        case "ANDROID_VR":   ua = InnerTubeClients.AndroidVR.userAgent
        case "ANDROID":      ua = InnerTubeClients.Android.userAgent
        case "TVHTML5":      ua = InnerTubeClients.TV.userAgent
        case "MWEB":         ua = InnerTubeClients.MWEB.userAgent
        case "WEB_CREATOR":  ua = InnerTubeClients.Web.userAgent
        default:             ua = InnerTubeClients.iOS.userAgent
        }

        playerLog.notice("[\(label)/adaptive] videoItag=\(videoItag) client=\(clientParam) audioItag=\(audioItag)")

        playerInfo = info
        let newFormats = Self.deduplicatedVideoFormats(info.formats)
        // Never reduce quality options — same policy as attemptURL.
        let maxCurrentHeight = availableFormats.map(\.height).max() ?? 0
        let maxNewHeight = newFormats.map(\.height).max() ?? 0
        if newFormats.count > availableFormats.count || maxNewHeight > maxCurrentHeight || availableFormats.isEmpty {
            availableFormats = newFormats
        }
        playerLog.notice("[\(label)/adaptive] availableFormats after dedup: input=\(info.formats.count) output=\(newFormats.count) kept=\(availableFormats.count) maxH=\(availableFormats.map(\.height).max() ?? 0)")
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            // loadTracks can stall indefinitely when rqh=1 CDN URLs don't fail fast.
            // @MainActor task-group child tasks are subject to main-actor scheduling
            // pressure (XCTest accessibility callbacks), so withThrowingTaskGroup is
            // unreliable here even with Task.detached wrappers.
            //
            // Solution: use AsyncStream as a cross-thread coordination channel.
            // Both the loadTracks work AND the 8-second timeout run in fully-detached
            // tasks (thread pool, no actor isolation). Whichever finishes first yields
            // to the stream. The main-actor consumer resumes when either signal arrives,
            // regardless of main-actor scheduling pressure.
            let vTracks: [AVAssetTrack]
            let aTracks: [AVAssetTrack]
            do {
                // AVAssetTrack is not Sendable in Swift 6 strict mode.
                // Wrap the pair so AsyncStream<TrackBox?> satisfies Sendable.
                // Ownership is transferred atomically through the stream; no concurrent
                // access occurs after the box is read on the main actor.
                struct TrackBox: @unchecked Sendable {
                    let video: [AVAssetTrack]
                    let audio: [AVAssetTrack]
                }
                let (raceStream, raceCont) = AsyncStream<TrackBox?>.makeStream()

                // loadTracks on thread pool — yields result or nil on error
                Task.detached {
                    let box: TrackBox? = try? await { () async throws -> TrackBox in
                        async let v = videoAsset.loadTracks(withMediaType: .video)
                        async let a = audioAsset.loadTracks(withMediaType: .audio)
                        let (vv, aa) = try await (v, a)
                        return TrackBox(video: vv, audio: aa)
                    }()
                    raceCont.yield(box)
                    raceCont.finish()
                }

                if let firstOrNil = await raceStream.first(where: { @Sendable _ in true }),
                   let box = firstOrNil {
                    vTracks = box.video
                    aTracks = box.audio
                } else {
                    let reason = needsQuickStartup ? "timed out after 8s" : "no result"
                    playerLog.error("❌ [\(label)/adaptive] loadTracks \(reason) (rqh=\(videoRqh))")
                    return false
                }
            }

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ [\(label)/adaptive] no tracks in remote assets (rqh=\(videoRqh))")
                return false
            }

            let videoDuration = try await videoAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
            let composition = AVMutableComposition()

            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                playerLog.error("❌ [\(label)/adaptive] could not add composition tracks")
                return false
            }

            try compVideo.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            try compAudio.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)

            playerLog.notice("✅ [\(label)/adaptive] composition built — testing playback for \(video.id)")
            lastAttemptedStreamURL = videoURL
            let compositeItem = AVPlayerItem(asset: composition)
            player.replaceCurrentItem(with: compositeItem)
            itemObserverTask?.cancel()

            for await status in compositeItem.statusStream {
                switch status {
                case .readyToPlay:
                    playerLog.notice("✅ [\(label)/adaptive] readyToPlay")
                    let compDur = compositeItem.duration.seconds
                    if compDur.isFinite && compDur > 0 {
                        let prevDur = self.duration
                        self.duration = compDur
                        playerLog.notice("[duration] updated from composition AVPlayerItem: \(String(format: "%.1f", compDur))s (was \(String(format: "%.1f", prevDur))s from metadata)")
                    }
                    if let pos = savedPositionToRestore, pos > 0 {
                        savedPositionToRestore = nil
                        seek(to: pos)
                    }
                    loadAudioTracks(from: compositeItem)
                    needsQuickStartup = false
                    isLoading = false
                    player.rate = Float(settings.playbackSpeed)
                    isPlaying = true
                    launchPhase2(video: video, info: info)
                    return true
                case .failed:
                    let nsErr = compositeItem.error as? NSError
                    let httpStatus = (nsErr?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -12660 ? 403 : (nsErr?.code ?? -1)
                    playerLog.error("❌ [\(label)/adaptive] AVPlayerItem failed: domain=\(nsErr?.domain ?? "?") code=\(nsErr?.code ?? -1) httpStatus=\(httpStatus)")
                    return false
                case .unknown:
                    continue
                @unknown default:
                    continue
                }
            }
            return false
        } catch {
            let nsErr = error as NSError
            let httpStatus = (nsErr.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == -12660 ? 403 : nsErr.code
            playerLog.error("❌ [\(label)/adaptive] setup failed: domain=\(nsErr.domain) code=\(nsErr.code) httpStatus=\(httpStatus)")
            return false
        }
    }

    private func launchPhase2(video: Video, info: PlayerInfo) {
        phase2Task?.cancel()
        phase2Task = Task(priority: .utility) { [weak self] in
            let empty = CachedVideoData(
                playerInfo: nil, trackingURLs: nil, nextInfo: nil,
                endCards: nil, sponsorSegments: nil, deArrowBranding: nil,
                staleFields: []
            )
            await self?.loadAsyncPhase2(
                video: video, cached: empty, info: info,
                cachedTrackingURLs: nil, authTrackingTask: nil, sponsorCached: false
            )
        }
        // Background pre-warming runs alongside phase2:
        //  • muxed fallback → fetch AndroidVR playerInfo so quality-tap skips 403 recovery
        //  • adaptive playing → pre-warm tracks for the user's preferred quality tier
        prefetchTask?.cancel()
        if info.bestAdaptiveAudioURL == nil {
            prefetchTask = Task(priority: .utility) { [weak self] in
                await self?.fetchAndCacheAdaptivePlayerInfo(video: video, muxedInfo: info)
            }
        } else if settings.preferredQuality != .auto {
            prefetchTask = Task(priority: .utility) { [weak self] in
                await self?.prefetchPreferredQualityTracks(info: info)
            }
        }
    }

    /// Called from `launchPhase2` when muxed 360p is the only available stream
    /// (`info.bestAdaptiveAudioURL == nil`).  Fetches AndroidVR player info in the
    /// background and upgrades `self.playerInfo` so that the first quality-tap skips
    /// the 17-second 403-recovery cycle.
    private func fetchAndCacheAdaptivePlayerInfo(video: Video, muxedInfo: PlayerInfo) async {
        playerLog.notice("[prefetch] muxed fallback — fetching AndroidVR playerInfo in background")
        do {
            let vrInfo = try await api.fetchPlayerInfoAndroidVR(videoId: video.id)
            guard !Task.isCancelled else { return }
            guard vrInfo.bestAdaptiveAudioURL != nil else {
                playerLog.notice("[prefetch] AndroidVR returned no adaptive audio — playerInfo not upgraded")
                return
            }
            guard currentVideo?.id == video.id, playerInfo?.bestAdaptiveAudioURL == nil else {
                playerLog.notice("[prefetch] playerInfo already upgraded or video changed — discarding prefetch result")
                return
            }
            playerInfo = vrInfo
            let vrFormats = Self.deduplicatedVideoFormats(vrInfo.formats)
            let maxCurrentH = availableFormats.map(\.height).max() ?? 0
            let maxVRH = vrFormats.map(\.height).max() ?? 0
            // Only update availableFormats (quality-picker options) when at least one format
            // is rqh-free. rqh=1 formats are immediately reverted by reloadDASHItem's rqh guard
            // and should not appear in the picker.
            let hasRqhFreeFormat = vrFormats.contains { fmt in
                guard let url = fmt.url else { return false }
                return !PlaybackQualityManager.urlHasRqhEnforcement(url)
            }
            if hasRqhFreeFormat && (vrFormats.count > availableFormats.count || maxVRH > maxCurrentH) {
                availableFormats = vrFormats
            }
            playerLog.notice("⚡ [prefetch] playerInfo upgraded to AndroidVR (\(vrFormats.count) formats) — quality switches skip 403 recovery")
            await prefetchPreferredQualityTracks(info: vrInfo)
        } catch {
            playerLog.notice("[prefetch] background AndroidVR fetch failed: \(error)")
        }
    }

    /// Pre-loads `AVAssetTrack` arrays for `settings.preferredQuality` into
    /// `AVAssetTrackCache` so that the first quality-tap after initial playback
    /// is a cache hit rather than a CDN round-trip.
    private func prefetchPreferredQualityTracks(info: PlayerInfo) async {
        guard settings.preferredQuality != .auto,
              let maxH = settings.preferredQuality.maxHeight else { return }
        guard let videoURL = PlaybackQualityManager.selectBestVideoFormat(
                  from: info.formats, preferredMaxHeight: maxH
              )?.url,
              let audioURL = info.bestAdaptiveAudioURL else { return }
        if AVAssetTrackCache.shared.videoTracks(for: videoURL) != nil { return }
        let itag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let ua = InnerTubeClients.iOS.userAgent
        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        playerLog.notice("[prefetch] pre-warming tracks for preferredQuality=\(maxH)p (itag=\(itag))")
        struct PrefetchTrackBox: @unchecked Sendable {
            let video: [AVAssetTrack]; let audio: [AVAssetTrack]
        }
        let (stream, cont) = AsyncStream<PrefetchTrackBox?>.makeStream()
        Task.detached {
            let box: PrefetchTrackBox? = try? await { () async throws -> PrefetchTrackBox in
                async let v = videoAsset.loadTracks(withMediaType: .video)
                async let a = audioAsset.loadTracks(withMediaType: .audio)
                let (vv, aa) = try await (v, a)
                return PrefetchTrackBox(video: vv, audio: aa)
            }()
            cont.yield(box)
            cont.finish()
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
            cont.yield(nil)
            cont.finish()
        }
        if let result = await stream.first(where: { @Sendable _ in true }),
           let box = result, !box.video.isEmpty, !box.audio.isEmpty {
            AVAssetTrackCache.shared.store(videoTracks: box.video, audioTracks: box.audio,
                                            videoURL: videoURL, audioURL: audioURL)
            playerLog.notice("⚡ [prefetch] tracks cached for preferredQuality=\(maxH)p (itag=\(itag))")
        } else {
            playerLog.notice("[prefetch] track prefetch timed out/failed for preferredQuality=\(maxH)p")
        }
    }

    /// Prefetches `AVAssetTrack` metadata for ALL available quality tiers at `.userInitiated`
    /// priority. Call this when the quality picker opens so that by the time the user taps a
    /// quality, the tracks are already cached and the switch completes in < 100ms (Fix 2A).
    func prefetchAllQualityTracks() async {
        guard let info = playerInfo else { return }
        guard info.hlsURL == nil else { return } // HLS doesn't need DASH track prefetch
        guard let audioURL = info.bestAdaptiveAudioURL else { return }
        guard !PlaybackQualityManager.urlHasRqhEnforcement(audioURL) else { return }

        let formats = Self.deduplicatedVideoFormats(info.formats)
        let ua = InnerTubeClients.iOS.userAgent

        // Load audio tracks once — shared across all video qualities.
        let audioTracks: [AVAssetTrack]
        if let cached = AVAssetTrackCache.shared.audioTracks(for: audioURL), !cached.isEmpty {
            audioTracks = cached
        } else {
            let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
            guard let loaded = try? await audioAsset.loadTracks(withMediaType: .audio), !loaded.isEmpty else { return }
            audioTracks = loaded
        }

        for fmt in formats.prefix(6) {
            guard !Task.isCancelled else { return }
            guard let videoURL = fmt.url else { continue }
            guard !PlaybackQualityManager.urlHasRqhEnforcement(videoURL) else { continue }
            guard AVAssetTrackCache.shared.videoTracks(for: videoURL) == nil else { continue }
            let itag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
            let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
            playerLog.notice("[prefetch/picker] pre-warming \(fmt.height)p itag=\(itag)")
            if let vTracks = try? await videoAsset.loadTracks(withMediaType: .video), !vTracks.isEmpty {
                AVAssetTrackCache.shared.store(videoTracks: vTracks, audioTracks: audioTracks,
                                               videoURL: videoURL, audioURL: audioURL)
                playerLog.notice("⚡ [prefetch/picker] cached \(fmt.height)p itag=\(itag)")
            }
        }
    }

    /// Rebuilds the `AVMutableComposition` during a quality switch for DASH/MP4-only videos
    /// (where `hlsURL == nil`). Mirrors `attemptComposition` but does not reset `playerInfo`
    /// or `availableFormats` and does not call `launchPhase2` — this is a mid-playback swap.
    func rebuildCompositionForQuality(videoURL: URL, audioURL: URL, seekTo: TimeInterval) async {
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        // Always use the iOS UA regardless of URL signing (c=ANDROID or c=IOS).
        // The initial attemptComposition path uses iOS UA for all URLs including
        // Android-client-signed ones, and it succeeds. Using Android UA for c=ANDROID
        // URLs was an incorrect assumption — it caused HTTP 403 instead of preventing it.
        let ua = InnerTubeClients.iOS.userAgent
        playerLog.notice("[quality/DASH] rebuilding composition — videoItag=\(videoItag) audioItag=\(audioItag) ua=iOS")

        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            // ── loadTracks with 60-second timeout ────────────────────────────────────
            // Without a timeout, rqh=1 CDN URLs hold the TCP connection open indefinitely,
            // causing quality-switch composition to hang forever (player stays at 360p).
            // The AsyncStream + Task.detached pattern mirrors attemptComposition to avoid
            // @MainActor scheduling pressure on withThrowingTaskGroup child tasks.
            let vTracks: [AVAssetTrack]
            let aTracks: [AVAssetTrack]
            let cachedV = AVAssetTrackCache.shared.videoTracks(for: videoURL)
            let cachedA = AVAssetTrackCache.shared.audioTracks(for: audioURL)
            if let cv = cachedV, let ca = cachedA, !cv.isEmpty, !ca.isEmpty {
                vTracks = cv
                aTracks = ca
                playerLog.notice("⚡ [quality/DASH] loadTracks cache hit (itag=\(videoItag)) — skipping CDN round-trip")
            } else {
            do {
                struct TrackBox: @unchecked Sendable {
                    let video: [AVAssetTrack]
                    let audio: [AVAssetTrack]
                }
                let (raceStream, raceCont) = AsyncStream<TrackBox?>.makeStream()
                Task.detached {
                    let box: TrackBox? = try? await { () async throws -> TrackBox in
                        async let v = videoAsset.loadTracks(withMediaType: .video)
                        async let a = audioAsset.loadTracks(withMediaType: .audio)
                        let (vv, aa) = try await (v, a)
                        return TrackBox(video: vv, audio: aa)
                    }()
                    raceCont.yield(box)
                    raceCont.finish()
                }
                Task.detached {
                    try? await Task.sleep(for: .seconds(10))
                    raceCont.yield(nil)
                    raceCont.finish()
                }
                if let firstOrNil = await raceStream.first(where: { @Sendable _ in true }),
                   let box = firstOrNil {
                    vTracks = box.video
                    aTracks = box.audio
                    AVAssetTrackCache.shared.store(videoTracks: vTracks, audioTracks: aTracks,
                                                    videoURL: videoURL, audioURL: audioURL)
                } else {
                    playerLog.error("❌ [quality/DASH] loadTracks timed out after 10s — triggering 403 recovery retry")
                    selectedFormat = nil
                    if statsForNerdsVisible { updateStatsSnapshot() }
                    if let video = currentVideo {
                        await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                        HLSManifestCache.shared.invalidate(for: video.id)
                        await retryWith403Recovery(video: video, originalError: nil)
                    }
                    return
                }
            }
            } // end cache-miss else
            // ─────────────────────────────────────────────────────────────────────────

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ [quality/DASH] no tracks in remote assets — triggering 403 recovery retry")
                selectedFormat = nil
                if statsForNerdsVisible { updateStatsSnapshot() }
                if let video = currentVideo {
                    await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                    HLSManifestCache.shared.invalidate(for: video.id)
                    await retryWith403Recovery(video: video, originalError: nil)
                }
                return
            }

            let videoDuration = try await videoAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
            let composition = AVMutableComposition()

            guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                playerLog.error("❌ [quality/DASH] could not add composition tracks")
                selectedFormat = nil
                if statsForNerdsVisible { updateStatsSnapshot() }
                return
            }

            try compVideo.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            try compAudio.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            playerLog.notice("✅ [quality/DASH] composition built — swapping item")

            lastAttemptedStreamURL = videoURL
            let compositeItem = AVPlayerItem(asset: composition)
            isSwappingItem = true
            player.replaceCurrentItem(with: compositeItem)
            isSwappingItem = false
            itemObserverTask?.cancel()

            for await status in compositeItem.statusStream {
                switch status {
                case .readyToPlay:
                    let size = compositeItem.presentationSize
                    playerLog.notice("✅ [quality/DASH] readyToPlay — presentationSize=\(Int(size.width))x\(Int(size.height))")
                    if seekTo > 0 { seek(to: seekTo) }
                    loadAudioTracks(from: compositeItem)
                    player.rate = Float(settings.playbackSpeed)
                    isPlaying = true
                    return
                case .failed:
                    let itemError = compositeItem.error
                    let errStr = itemError.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ [quality/DASH] AVPlayerItem failed: \(errStr) — triggering 403 recovery retry")
                    selectedFormat = nil
                    if statsForNerdsVisible { updateStatsSnapshot() }
                    if let video = currentVideo {
                        await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                        HLSManifestCache.shared.invalidate(for: video.id)
                        await retryWith403Recovery(video: video, originalError: itemError)
                    }
                    return
                case .unknown:
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            playerLog.error("❌ [quality/DASH] composition build error: \(error) — triggering 403 recovery retry")
            selectedFormat = nil
            if statsForNerdsVisible { updateStatsSnapshot() }
            if let video = currentVideo {
                await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                HLSManifestCache.shared.invalidate(for: video.id)
                await retryWith403Recovery(video: video, originalError: error)
            }
        }
    }

    // MARK: - Helpers

    /// Returns the AVFoundation User-Agent for `url` based on its `c=` signing parameter.
    /// NOTE: This helper is no longer used by `rebuildCompositionForQuality`, which now always
    /// uses iOS UA. Kept for reference — the original assumption (Android UA needed for
    /// c=ANDROID URLs) was incorrect; the initial `attemptComposition` path proves iOS UA
    /// works for all URL signing variants.
    static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value ?? ""
        return client.hasPrefix("ANDROID") ? InnerTubeClients.Android.userAgent : InnerTubeClients.iOS.userAgent
    }

    /// Returns the best adaptive video-only MP4 URL, respecting the user's quality preference.
    /// When `preferredQuality != .auto`, filters to formats at or below `maxHeight`, sorts
    /// by height descending then bitrate descending. Falls back to highest bitrate when no
    /// format meets the height cap.
    /// When `preferredQuality == .auto`, caps at the display's native resolution so the
    /// player never fetches a resolution higher than the screen can render.
    ///
    /// H.264 (avc1) is preferred over AV1 (av01) at any given resolution because Android-client
    /// AV1 streams require a proof-of-origin token (pot) that the app does not supply, causing
    /// systematic HTTP 403 errors on adaptive composition. H.264 streams are served without
    /// that restriction and are well-supported by AVFoundation.
    private func qualityCapVideoURL(from formats: [VideoFormat]) -> URL? {
        let maxH: Int
        if settings.preferredQuality != .auto, let h = settings.preferredQuality.maxHeight {
            maxH = h
        } else {
            // Auto: cap at the display's native resolution — no benefit loading higher
            // than what the screen can actually render.
            maxH = Self.displayMaxVideoHeight()
        }
        return PlaybackQualityManager.selectBestVideoFormat(
            from: formats,
            preferredMaxHeight: maxH,
            preferH264: true
        )?.url
    }

    /// Returns the maximum video height (pixels) that this display can render for
    /// landscape 16:9 content. Used to cap quality in Auto mode.
    ///
    /// The shorter native-pixel dimension equals the landscape height — the maximum
    /// video height the screen can actually show for standard 16:9 YouTube content.
    static func displayMaxVideoHeight() -> Int {
        #if canImport(UIKit)
        let bounds = UIScreen.main.nativeBounds
        return Int(max(bounds.width, bounds.height))
        #else
        return 1080  // Conservative fallback for non-UIKit targets
        #endif
    }

    // MARK: - HLS n-descrambling (simulator only)

    #if targetEnvironment(simulator)
    /// Probes the first segment of an HLS variant playlist.
    /// Returns `variantURL` unchanged if the segment is already accessible (n is valid).
    /// If the segment returns 403 (scrambled n), applies the JS solver to descramble the n
    /// in `variantURL` and returns the corrected URL. When the CDN receives a request with
    /// the descrambled n, it embeds the descrambled n in all segment URLs it returns, so
    /// AVPlayer can fetch every segment without receiving 403.
    private func descrambledVariantURL(_ variantURL: URL, label: String) async -> (URL, HLSVariantProxy?) {
        let ua = "com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)"

        // 1. Fetch the variant playlist to obtain segment URLs.
        var req = URLRequest(url: variantURL)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let text = String(data: data, encoding: .utf8) else {
            playerLog.notice("[\(label)] n-probe: playlist fetch failed — using original URL")
            return (variantURL, nil)
        }

        // 2. Find the first absolute segment URL in the playlist.
        let lines = text.components(separatedBy: .newlines)
        guard let segStr = lines.first(where: { !$0.hasPrefix("#") && !$0.isEmpty && $0.hasPrefix("http") }),
              let segURL = URL(string: segStr) else {
            playerLog.notice("[\(label)] n-probe: no segment URL found — using original URL")
            return (variantURL, nil)
        }

        // 3. HEAD-probe the segment to detect scrambled n.
        var segReq = URLRequest(url: segURL)
        segReq.httpMethod = "HEAD"
        segReq.setValue(ua, forHTTPHeaderField: "User-Agent")
        segReq.timeoutInterval = 5
        if let (_, resp) = try? await URLSession.shared.data(for: segReq),
           let http = resp as? HTTPURLResponse, http.statusCode == 200 {
            playerLog.notice("[\(label)] n-probe: segment 200 — n is valid, no descrambling needed")
            return (variantURL, nil)
        }

        // 4. Segment inaccessible (403) — extract scrambled n from the SEGMENT URL, not the
        //    variant playlist URL. The segment URLs inside the playlist carry an independent n
        //    that the CDN does NOT change based on the variant URL's n. Descrambling only the
        //    variant URL's n leaves segment n values scrambled → AVPlayer still gets 403.
        //    We must rewrite segment n values in the playlist content itself, then serve the
        //    modified playlist from a local temp file so AVPlayer fetches descrambled segments.
        playerLog.notice("[\(label)] n-probe: segment not 200 — rewriting segment n in playlist")

        // Extract n from segment URL (YouTube HLS uses path-based /n/VALUE/ format).
        let segPathParts = segURL.pathComponents
        let scrambledSegN: String?
        if let idx = segPathParts.firstIndex(of: "n"), idx + 1 < segPathParts.count,
           !segPathParts[idx + 1].isEmpty {
            scrambledSegN = segPathParts[idx + 1]
        } else if let nItem = URLComponents(url: segURL, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "n" }),
                  let val = nItem.value, !val.isEmpty {
            scrambledSegN = val
        } else {
            scrambledSegN = nil
        }

        guard let scrambledN = scrambledSegN else {
            playerLog.notice("[\(label)] n-probe: could not extract n from segment URL — using original")
            return (variantURL, nil)
        }

        // 5. Descramble the segment n via the JS solver.
        //    Build a synthetic path-format URL so YouTubeNDescrambler.extractNParam can locate n.
        guard let syntheticURL = URL(string: "https://googlevideo.com/videoplayback/n/\(scrambledN)/seg.ts") else {
            return (variantURL, nil)
        }
        let descrambledSynthetic = await YouTubeNDescrambler.shared.descrambleURL(syntheticURL)
        guard descrambledSynthetic != syntheticURL else {
            playerLog.notice("[\(label)] n-probe: solver returned unchanged URL for segment n — using original")
            return (variantURL, nil)
        }

        // Extract the descrambled n value from the synthetic result.
        let descParts = descrambledSynthetic.pathComponents
        guard let dIdx = descParts.firstIndex(of: "n"), dIdx + 1 < descParts.count,
              !descParts[dIdx + 1].isEmpty else {
            return (variantURL, nil)
        }
        let descrambledN = descParts[dIdx + 1]
        playerLog.notice("[\(label)] n-probe: segment n: \(scrambledN) → \(descrambledN)")

        // 6. Rewrite ALL n occurrences in the playlist (path + query-string formats).
        //    All segments in a YouTube HLS playlist share the same n value, so a single
        //    replace-all pass covers every segment URL.
        var rewritten = text
        rewritten = rewritten.replacingOccurrences(of: "/n/\(scrambledN)/", with: "/n/\(descrambledN)/")
        // Also handle query-string format (n=OLD covers ?n=OLD& and &n=OLD& and &n=OLD\n)
        rewritten = rewritten.replacingOccurrences(of: "n=\(scrambledN)", with: "n=\(descrambledN)")

        // 6b. Verify the rewrite: probe the first rewritten segment to confirm 200.
        //     If still 403, the descrambled n is wrong (solver/player.js mismatch).
        let rewrittenLines = rewritten.components(separatedBy: .newlines)
        if let firstRewrittenSeg = rewrittenLines.first(where: { !$0.hasPrefix("#") && !$0.isEmpty && $0.hasPrefix("http") }),
           let verifyURL = URL(string: firstRewrittenSeg) {
            playerLog.notice("[\(label)] n-probe: verifying rewritten seg n=\(descrambledN)")
            var verifyReq = URLRequest(url: verifyURL)
            verifyReq.httpMethod = "HEAD"
            verifyReq.setValue(ua, forHTTPHeaderField: "User-Agent")
            verifyReq.timeoutInterval = 5
            if let (_, verifyResp) = try? await URLSession.shared.data(for: verifyReq),
               let verifyHTTP = verifyResp as? HTTPURLResponse {
                playerLog.notice("[\(label)] n-probe: post-rewrite verify → HTTP \(verifyHTTP.statusCode)")
                if verifyHTTP.statusCode == 403 {
                    playerLog.error("[\(label)] n-probe: VERIFY FAILED — descrambled n returns 403; reverting to original URL")
                    return (variantURL, nil)
                }
            } else {
                playerLog.notice("[\(label)] n-probe: post-rewrite verify timed out or failed — proceeding anyway")
            }
        }

        // 7. Serve the rewritten playlist via AVAssetResourceLoader (custom URL scheme).
        //    Using a file:// URL + AVURLAssetHTTPHeaderFieldsKey causes AVPlayer to silently hang
        //    in .unknown status indefinitely on the iOS Simulator — AVFoundation never fires
        //    readyToPlay. The file:// + HTTP-header-options combination appears to suppress the
        //    AVFoundation networking stack that fetches CDN segments, so the item never becomes
        //    ready. Using a custom non-http scheme instead routes the initial playlist request
        //    through AVAssetResourceLoader, which returns our pre-rewritten content. AVPlayer then
        //    fetches CDN segment URLs (https://) via its normal network stack — no file I/O needed.
        let proxy = HLSVariantProxy(playlistContent: rewritten)
        let proxyURL = HLSVariantProxy.makeProxyURL()
        playerLog.notice("[\(label)] n-probe: HLS proxy ready — serving \(rewritten.count) bytes")
        return (proxyURL, proxy)
    }
    #endif
}

#if targetEnvironment(simulator)
/// Minimal `AVAssetResourceLoaderDelegate` that serves a pre-rewritten HLS variant playlist
/// via a custom `smarttubehls://` URL scheme. Simulator-only.
///
/// Background: `AVURLAsset(url: file://)` + `AVURLAssetHTTPHeaderFieldsKey` hangs indefinitely
/// in `.unknown` status — AVFoundation never transitions to `.readyToPlay` on the Simulator.
/// Routing the initial playlist fetch through `AVAssetResourceLoader` avoids the `file://` code
/// path while still letting AVPlayer request CDN segment URLs (`https://`) normally.
private final class HLSVariantProxy: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let playlistData: Data

    init(playlistContent: String) {
        self.playlistData = playlistContent.data(using: .utf8) ?? Data()
    }

    /// Returns a unique `smarttubehls://` URL. Each call produces a new value to prevent caching.
    static func makeProxyURL() -> URL {
        let ts = UInt64(Date().timeIntervalSince1970 * 1_000)
        return URL(string: "smarttubehls://variant/\(ts).m3u8")!
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            // UTI for HLS / M3U8 playlists. AVFoundation uses this to decide how to parse
            // the returned bytes. "public.m3u-playlist" is the registered UTI for .m3u8.
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(playlistData.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: playlistData)
        loadingRequest.finishLoading()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}
}
#endif
