@preconcurrency import AVFoundation
import os
#if canImport(UIKit)
import UIKit
#endif
import SmartTubeIOSCore

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

            // --- Android VR client (adaptive only, no PO token required) ---
            // The Oculus Quest client (ANDROID_VR, nameID=28) is exempt from the
            // rqh=1 / pot enforcement that YouTube applies to standard Android and iOS
            // adaptive streams. Correct VR headers (nameID=28, Oculus UA on googleapis.com)
            // are required — sending Web client headers causes bot-detection.
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

            // --- WEB_CREATOR client (adaptive, rqh=1 exempt per yt-dlp docs) ---
            // The YouTube Studio client (WEB_CREATOR, nameID=62) is documented by yt-dlp
            // as not requiring a Proof-of-Origin (POT) token for adaptive streams — its
            // CDN URLs should not carry rqh=1. If this client's adaptive streams load,
            // quality switching via AVMutableComposition works without 403 errors.
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
    ///   the caller can try higher-priority clients (e.g. Android VR adaptive) before
    ///   accepting the 360p muxed last-resort. Defaults to `false`.
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
            playerLog.notice("[\(label)] Trying muxed")
            if await attemptURL(muxedURL, for: video, info: info, label: "\(label)/muxed") { return true }
            playerLog.notice("[\(label)] Muxed failed — no more alternatives for this client")
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
        // Never reduce quality options — preserve the richest availableFormats seen so far.
        // When muxed fallback (360p) plays after adaptive failure, Android formats may have
        // height=0 or url=nil for adaptive entries, giving fewer picker options than the initial
        // iOS-unauth response. Keep whichever set has more entries.
        let maxCurrentHeight = availableFormats.map(\.height).max() ?? 0
        let maxNewHeight = newFormats.map(\.height).max() ?? 0
        if newFormats.count > availableFormats.count || maxNewHeight > maxCurrentHeight || availableFormats.isEmpty {
            availableFormats = newFormats
        }
        playerLog.notice("[\(label)] availableFormats after dedup: input=\(info.formats.count) output=\(newFormats.count) kept=\(availableFormats.count) maxH=\(availableFormats.map(\.height).max() ?? 0)")
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        let effectiveURL = url
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
            } else {
                playerLog.notice("[\(label)] HLS manifest fetch returned 0 variants — using master as-is")
            }
            // Keep the master HLS URL so AVPlayer receives EXT-X-MEDIA alternate audio renditions.
            // Variant playlist URLs strip EXT-X-MEDIA (same reason as primary load path).
            qualityManager.setSelectedFormatForCurrentPreference()
            applyHLSHints = true
        } else {
            playerLog.notice("[\(label)] non-HLS URL — no EXT-X-MEDIA, audio tracks will be unavailable")
        }

        lastAttemptedStreamURL = effectiveURL
        let item = AVPlayerItem(url: effectiveURL)
        if applyHLSHints {
            let maxH: Int
            if settings.preferredQuality != .auto, let h = settings.preferredQuality.maxHeight {
                maxH = h
            } else {
                // Auto: steer ABR toward the display's native resolution so the player
                // never fetches variants it cannot render.
                maxH = Self.displayMaxVideoHeight()
            }
            item.preferredMaximumResolution = CGSize(width: CGFloat(maxH) * 4, height: CGFloat(maxH))
            item.preferredPeakBitRate = peakBitRate(for: maxH)
            playerLog.notice("[\(label)] HLS ABR hints: maxH=\(maxH)p peakBitRate=\(peakBitRate(for: maxH) / 1_000_000)Mbps (master URL preserved)")
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
                playerLog.error("❌ [\(label)] AVPlayerItem failed: \(err)")
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
        playerLog.notice("[\(label)/adaptive] videoItag=\(videoItag) rqh=\(videoRqh) audioItag=\(audioItag)")

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

        let ua = InnerTubeClients.iOS.userAgent
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
                // Apply the 8-second timeout only during the initial load sequence.
                // Quality-switch retries (triggered by qualityItemDidFail after first play)
                // have needsQuickStartup=false and must wait the full CDN time (43-105 s
                // for rqh=1 streams) to complete successfully.
                if needsQuickStartup {
                    Task.detached {
                        try? await Task.sleep(for: .seconds(8))
                        raceCont.yield(nil)
                        raceCont.finish()
                    }
                }

                if let firstOrNil = await raceStream.first(where: { @Sendable _ in true }),
                   let box = firstOrNil {
                    vTracks = box.video
                    aTracks = box.audio
                } else {
                    playerLog.error("❌ [\(label)/adaptive] loadTracks timed out after 8s (rqh=\(videoRqh))")
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
            prefetchTask = Task(priority: .background) { [weak self] in
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
            if vrFormats.count > availableFormats.count || maxVRH > maxCurrentH {
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
                    try? await Task.sleep(for: .seconds(60))
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
                    playerLog.error("❌ [quality/DASH] loadTracks timed out after 60s (rqh CDN hold) — triggering 403 recovery retry")
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
        return Int(min(bounds.width, bounds.height))
        #else
        return 1080  // Conservative fallback for non-UIKit targets
        #endif
    }
}
