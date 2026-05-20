import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Exhaustive Playback Retry

extension PlaybackViewModel {

    // MARK: - Entry Points

    /// Main retry entry point. Called whenever the primary iOS stream fails.
    ///
    /// Strategy: exhaust all stream formats (HLS → adaptive composition → muxed direct) from
    /// both iOS and Android clients before giving up; repeat the full cycle up to 3 times to
    /// survive transient network errors and stale cache entries (the hls=false root cause).
    func exhaustiveRetry(video: Video, originalError: Error?) async {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return }
            retryAttempts = attempt
            playerLog.notice("Exhaustive retry \(attempt)/3 for \(video.id)")

            // Evict the stale cache entry so each attempt gets fresh signed URLs.
            await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)

            // --- iOS client (fresh network fetch) ---
            do {
                let iosInfo = try await api.fetchPlayerInfo(videoId: video.id)
                await VideoPreloadCache.shared.store(playerInfo: iosInfo, for: video.id)
                if await tryAllStreams(video: video, info: iosInfo, label: "iOS[\(attempt)]") {
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

            // --- Android client ---
            do {
                let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                if await tryAllStreams(video: video, info: androidInfo, label: "Android[\(attempt)]") {
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
        }

        guard !Task.isCancelled else { return }
        playerLog.error("❌ All 3 retry attempts exhausted for \(video.id)")
        error = APIError.unavailable("Unable to play this video")
    }

    /// Kept for the `PlaybackQualityManagerDelegate` protocol.
    /// Quality-switch 403 errors start a fresh 3-attempt exhaustive cycle.
    func retryWith403Recovery(video: Video, originalError: Error?) async {
        playerLog.notice("403 recovery (quality switch) — exhaustive retry for \(video.id)")
        retryAttempts = 0
        await exhaustiveRetry(video: video, originalError: originalError)
    }

    // MARK: - Stream Exhaustion

    /// Tries HLS → adaptive composition → muxed direct from one PlayerInfo.
    /// Returns true if any stream starts playing successfully.
    private func tryAllStreams(video: Video, info: PlayerInfo, label: String) async -> Bool {
        let hasHLS = info.hlsURL != nil
        let hasAdaptiveVideo = qualityCapVideoURL(from: info.formats) != nil
        let hasAdaptiveAudio = info.bestAdaptiveAudioURL != nil
        let hasMuxed = info.bestMuxedDownloadURL != nil
        playerLog.notice("[\(label)] streams available: HLS=\(hasHLS) adaptiveVideo=\(hasAdaptiveVideo) adaptiveAudio=\(hasAdaptiveAudio) muxed=\(hasMuxed)")

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

        // 3. Muxed direct MP4 (itag=18, 360p — last resort)
        if let muxedURL = info.bestMuxedDownloadURL {
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
        availableFormats = Self.deduplicatedVideoFormats(info.formats)
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
        if applyHLSHints, settings.preferredQuality != .auto,
           let maxH = settings.preferredQuality.maxHeight {
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
        availableFormats = Self.deduplicatedVideoFormats(info.formats)
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        let ua = InnerTubeClients.iOS.userAgent
        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            let (vTracks, aTracks) = try await (videoTracks, audioTracks)

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
    }

    /// Rebuilds the `AVMutableComposition` during a quality switch for DASH/MP4-only videos
    /// (where `hlsURL == nil`). Mirrors `attemptComposition` but does not reset `playerInfo`
    /// or `availableFormats` and does not call `launchPhase2` — this is a mid-playback swap.
    func rebuildCompositionForQuality(videoURL: URL, audioURL: URL, seekTo: TimeInterval) async {
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        // Infer the correct User-Agent from the URL's `c=` parameter so that
        // Android-client-signed URLs (c=ANDROID) are served with the Android UA.
        let ua = Self.userAgent(for: videoURL)
        playerLog.notice("[quality/DASH] rebuilding composition — videoItag=\(videoItag) audioItag=\(audioItag) ua=\(ua == InnerTubeClients.Android.userAgent ? "Android" : "iOS")")

        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            let (vTracks, aTracks) = try await (videoTracks, audioTracks)

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ [quality/DASH] no tracks in remote assets — quality switch failed")
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
                    let err = compositeItem.error.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ [quality/DASH] AVPlayerItem failed: \(err)")
                    return
                case .unknown:
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            playerLog.error("❌ [quality/DASH] composition build error: \(error)")
        }
    }

    // MARK: - Helpers

    /// Returns the AVFoundation User-Agent matching the client that signed `url`.
    /// YouTube adaptive streams are client-signed: an Android-signed URL (`c=ANDROID`)
    /// returns HTTP 403 when requested with an iOS User-Agent, and vice versa.
    static func userAgent(for url: URL) -> String {
        let client = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c" })?.value ?? ""
        return client.hasPrefix("ANDROID") ? InnerTubeClients.Android.userAgent : InnerTubeClients.iOS.userAgent
    }

    /// Returns the best adaptive video-only MP4 URL, respecting the user's quality preference.
    /// When `preferredQuality != .auto`, filters to formats at or below `maxHeight`, sorts
    /// by height descending then bitrate descending. Falls back to highest bitrate when no
    /// format meets the height cap.
    ///
    /// H.264 (avc1) is preferred over AV1 (av01) at any given resolution because Android-client
    /// AV1 streams require a proof-of-origin token (pot) that the app does not supply, causing
    /// systematic HTTP 403 errors on adaptive composition. H.264 streams are served without
    /// that restriction and are well-supported by AVFoundation.
    private func qualityCapVideoURL(from formats: [VideoFormat]) -> URL? {
        let maxH: Int?
        if settings.preferredQuality != .auto, let h = settings.preferredQuality.maxHeight {
            maxH = h
        } else {
            maxH = nil
        }
        return PlaybackQualityManager.selectBestVideoFormat(
            from: formats,
            preferredMaxHeight: maxH,
            preferH264: true
        )?.url
    }
}
