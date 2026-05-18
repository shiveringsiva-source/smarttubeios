import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AVPlayer Error Recovery

extension PlaybackViewModel {

    /// Called when the primary iOS-client HLS stream fails to open.
    /// Re-fetches using the Android InnerTube client, which returns direct CDN videoplayback
    /// URLs instead of an IP-bound HLS manifest. YouTube's iOS-client HLS manifests embed
    /// the requester's IP; on the iOS Simulator AVPlayer's download IP can differ from the
    /// URLSession IP used by InnerTubeAPI, causing a 404. Android-client URLs are signed with
    /// Android credentials and are not subject to the same IP-binding restriction.
    /// Shows the original error if the Android-client fallback also fails.
    func retryWithFallbackPlayer(video: Video, originalError: Error?) async {
        do {
            playerLog.notice("Retrying playback with Android client for \(video.id)")
            let fallbackInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)

            // NW-3-FIX (extended / NW-3-FIX-ANDROID): The Android client sometimes returns a
            // muxed-only response (itag=18, c=ANDROID) with no HLS manifest and no adaptive
            // streams. Attempting to play this URL in AVPlayer results in
            // AVFoundationErrorDomain -11828 / NSOSStatusErrorDomain -12847 — a known
            // YouTube CDN restriction, not an app bug. Detect this before handing the URL to
            // AVPlayer so we never record a spurious non-fatal (issues 0edf6a2f / c54e620).
            // APIError.unavailable is already suppressed from Crashlytics in error.didSet.
            if fallbackInfo.hlsURL == nil,
               fallbackInfo.bestAdaptiveVideoURL == nil,
               fallbackInfo.bestAdaptiveAudioURL == nil {
                // NW-3-FIX-CACHE: Android returned muxed-only, but the upstream iOS-client
                // cache entry may have been stale (hlsURL missing because the preload ran
                // against an expired token / incomplete response). Before giving up, do ONE
                // fresh iOS-client fetch — if it produces an HLS URL we can play that
                // directly. Guard with hasRetriedPlayback to prevent a second cycle.
                playerLog.notice("⚠️ Android muxed-only for \(video.id) — attempting fresh iOS client fetch (hasRetried=\(hasRetriedPlayback))")
                if !hasRetriedPlayback {
                    hasRetriedPlayback = true
                    await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                    await retryWith403Recovery(video: video, originalError: originalError)
                    return
                }
                playerLog.error("❌ Android client returned muxed-only (no HLS/adaptive) — cannot play this video")
                self.error = APIError.unavailable("Unable to play this video")
                return
            }

            // Fix #122: Android client sometimes returns no HLS manifest but adaptive streams
            // are available. Using preferredStreamURL in this case returns the muxed itag=18
            // URL, which fails immediately with AVFoundationErrorDomain -11828
            // ("This media format is not supported"). Delegate to retryWithAdaptiveComposition
            // instead, which composites the video-only and audio-only adaptive streams.
            if fallbackInfo.hlsURL == nil,
               fallbackInfo.bestAdaptiveVideoURL != nil,
               fallbackInfo.bestAdaptiveAudioURL != nil {
                playerLog.notice("Android fallback: no HLS but adaptive streams available — delegating to adaptive composition")
                await retryWithAdaptiveComposition(video: video, info: fallbackInfo, originalError: originalError)
                return
            }

            guard let baseFallbackURL = fallbackInfo.preferredStreamURL else {
                playerLog.error("❌ Fallback player: no stream URL")
                self.error = originalError
                return
            }
            playerLog.notice("Fallback stream URL: \(baseFallbackURL.absoluteString.prefix(120))")
            // BUG-002 fix: propagate fetched info so format/caption pickers reflect the fallback response.
            playerInfo = fallbackInfo
            availableFormats = Self.deduplicatedVideoFormats(fallbackInfo.formats)
            availableCaptions = fallbackInfo.captionTracks
            autoApplyCaptionPreference(tracks: fallbackInfo.captionTracks)
            // Apply quality preference: fetch HLS variants if available, then select the correct stream.
            var fallbackURL = baseFallbackURL
            if let hlsURL = fallbackInfo.hlsURL {
                let variantURLs = await fetchHLSVariantURLs(url: hlsURL)
                if !variantURLs.isEmpty {
                    hlsVariantURLs = variantURLs
                    availableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
                }
                fallbackURL = applyQualityPreference(to: baseFallbackURL)
            }
            lastAttemptedStreamURL = fallbackURL
            let fallbackItem = AVPlayerItem(url: fallbackURL)
            // BUG-009 fix: replace the current item BEFORE setting up the observer so the
            // observer never fires on the old item.
            player.replaceCurrentItem(with: fallbackItem)
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in fallbackItem.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ Fallback AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        self.loadAudioTracks(from: fallbackItem)
                        self.isLoading = false
                    case .failed:
                        let err = fallbackItem.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ Fallback AVPlayerItem failed: \(err)")
                        self.error = fallbackItem.error ?? originalError
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            // BUG-007 fix: launch phase2 so SponsorBlock, tracking URLs, and nextInfo are fetched
            // even when the primary load path fell back to the Android client.
            let p2Video = video
            let p2Info = fallbackInfo
            phase2Task?.cancel()
            phase2Task = Task(priority: .utility) { [weak self] in
                let empty = CachedVideoData(
                    playerInfo: nil, trackingURLs: nil, nextInfo: nil,
                    endCards: nil, sponsorSegments: nil, deArrowBranding: nil,
                    staleFields: []
                )
                await self?.loadAsyncPhase2(
                    video: p2Video, cached: empty, info: p2Info,
                    cachedTrackingURLs: nil, authTrackingTask: nil, sponsorCached: false
                )
            }
        } catch {
            // IP-block errors from the Android fallback are more actionable than the upstream
            // AVFoundation -11828 "Cannot Open". Surface ipBlocked so the user sees the
            // "YouTube is temporarily blocking this network…" banner instead of "Cannot Open".
            if case APIError.ipBlocked = error {
                self.error = error
            } else {
                self.error = originalError
            }
        }
    }

    /// Retries playback by compositing the best H.264 video-only stream and the best AAC
    /// audio-only stream from the existing TV-client player info into an AVMutableComposition.
    ///
    /// Called when the primary muxed-format direct URL (itag=18, 360p) fails with an
    /// AVFoundation error while the TV client returned no HLS manifest. The muxed CDN URL
    /// uses a different CDN route than the adaptive streams and may be rejected by YouTube's
    /// CDN (e.g. missing or invalid pot token for the muxed itag). The adaptive video/audio
    /// URLs (itag=137/140 etc.) typically succeed because they are served by the standard
    /// adaptive CDN path that does not apply the same restriction.
    ///
    /// Falls back to `retryWithFallbackPlayer` (Android client) if composition setup fails.
    func retryWithAdaptiveComposition(video: Video, info: PlayerInfo, originalError: Error?) async {
        guard let videoURL = qualityCapVideoURL(from: info.formats),
              let audioURL = info.bestAdaptiveAudioURL else {
            playerLog.error("❌ Adaptive composition: no adaptive URLs in player info")
            await retryWithFallbackPlayer(video: video, originalError: originalError)
            return
        }
        // BUG-004 fix: propagate the info that was passed in so format/caption pickers reflect it.
        playerInfo = info
        availableFormats = Self.deduplicatedVideoFormats(info.formats)
        availableCaptions = info.captionTracks
        autoApplyCaptionPreference(tracks: info.captionTracks)

        // Extract itag and rqh flag before the do block so they are in scope for the catch.
        let videoItag = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let audioItag = URLComponents(url: audioURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "itag" })?.value ?? "?"
        let videoRqh = videoURL.absoluteString.contains("rqh=1")
        playerLog.notice("Adaptive composition: id=\(video.id) videoItag=\(videoItag) rqh=\(videoRqh) audioItag=\(audioItag)")

        let ua = InnerTubeClients.iOS.userAgent
        let videoAsset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])
        let audioAsset = AVURLAsset(url: audioURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": ua]])

        do {
            // Load track lists from both remote assets concurrently.
            async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
            async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
            let (vTracks, aTracks) = try await (videoTracks, audioTracks)

            guard let sourceVideoTrack = vTracks.first,
                  let sourceAudioTrack = aTracks.first else {
                playerLog.error("❌ Adaptive composition: no video or audio track in remote assets")
                await retryWithFallbackPlayer(video: video, originalError: originalError)
                return
            }

            let videoDuration = try await videoAsset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: videoDuration)

            let composition = AVMutableComposition()
            guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                playerLog.error("❌ Adaptive composition: could not add composition tracks")
                await retryWithFallbackPlayer(video: video, originalError: originalError)
                return
            }

            try compVideo.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            try compAudio.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)

            playerLog.notice("✅ Adaptive composition built — starting playback for \(video.id)")
            lastAttemptedStreamURL = videoURL
            let compositeItem = AVPlayerItem(asset: composition)

            // BUG-009 fix: replace before observing.
            player.replaceCurrentItem(with: compositeItem)
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in compositeItem.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ Adaptive composition AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        self.loadAudioTracks(from: compositeItem)
                        self.isLoading = false
                    case .failed:
                        let nsErr = compositeItem.error as? NSError
                        let underlying = nsErr?.userInfo[NSUnderlyingErrorKey] as? NSError
                        let httpStatus = underlying?.code == -12660 ? 403 : (nsErr?.code ?? -1)
                        let errDomain = nsErr?.domain ?? "?"
                        let errCode = nsErr?.code ?? -1
                        playerLog.error("❌ Adaptive composition AVPlayerItem failed: id=\(video.id) videoItag=\(videoItag) rqh=\(videoRqh) errorDomain=\(errDomain) code=\(errCode) httpStatus=\(httpStatus)")
                        // NW-3-FIX-CACHE-COMP: Before giving up, try a fresh iOS-client fetch.
                        // The cached response had hls=false; a fresh fetch may return hls=true.
                        if !self.hasRetriedPlayback {
                            self.hasRetriedPlayback = true
                            playerLog.notice("⚠️ Adaptive composition AVPlayerItem failed — trying fresh iOS client for \(video.id)")
                            await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                            await self.retryWith403Recovery(video: video, originalError: originalError)
                            return
                        }
                        // Do NOT retry with Android client — same rqh=1 adaptive streams
                        // would 403 again, creating an infinite loop.
                        self.error = APIError.unavailable("Unable to play this video")
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            // BUG-007 fix: launch phase2 so SponsorBlock, tracking URLs, and nextInfo are fetched
            // after the adaptive composition fallback.
            let p2Video = video
            let p2Info = info
            phase2Task?.cancel()
            phase2Task = Task(priority: .utility) { [weak self] in
                let empty = CachedVideoData(
                    playerInfo: nil, trackingURLs: nil, nextInfo: nil,
                    endCards: nil, sponsorSegments: nil, deArrowBranding: nil,
                    staleFields: []
                )
                await self?.loadAsyncPhase2(
                    video: p2Video, cached: empty, info: p2Info,
                    cachedTrackingURLs: nil, authTrackingTask: nil, sponsorCached: false
                )
            }
        } catch {
            let nsErr = error as NSError
            let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError
            let httpStatus = underlying?.code == -12660 ? 403 : nsErr.code
            playerLog.error("❌ Adaptive composition setup failed: id=\(video.id) videoItag=\(videoItag) rqh=\(videoRqh) errorDomain=\(nsErr.domain) code=\(nsErr.code) httpStatus=\(httpStatus) — stopping retry chain")
            // NW-3-FIX-CACHE-COMP: Before giving up, try a fresh iOS-client fetch.
            // The cached iOS response had hls=false; a fresh fetch may return hls=true
            // (confirmed: background prefetch at line 1729 shows hls=true for J6J8vhIzfLo).
            // Guard with hasRetriedPlayback to prevent a second cycle.
            if !hasRetriedPlayback {
                hasRetriedPlayback = true
                playerLog.notice("⚠️ Adaptive composition failed (rqh=\(videoRqh)) — trying fresh iOS client for \(video.id)")
                await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                await retryWith403Recovery(video: video, originalError: originalError)
                return
            }
            // Do NOT call retryWithFallbackPlayer — Android returns the same rqh=1 adaptive
            // streams which 403 again, causing an infinite loop.
            self.error = APIError.unavailable("Unable to play this video")
        }
    }

    /// 403 recovery: re-fetch a fresh iOS-client player info (now that the stale cache entry
    /// is evicted) and retry with the new URL.  Falls through to the Android client if the
    /// fresh iOS-client URL also 403s.
    func retryWith403Recovery(video: Video, originalError: Error?) async {
        do {
            playerLog.notice("403 recovery — re-fetching iOS client player info for \(video.id)")
            let freshInfo = try await api.fetchPlayerInfo(videoId: video.id)
            await VideoPreloadCache.shared.store(playerInfo: freshInfo, for: video.id)
            guard let baseRecoveryURL = freshInfo.preferredStreamURL else {
                playerLog.error("❌ 403 recovery: no stream URL in fresh iOS-client response")
                await retryWithFallbackPlayer(video: video, originalError: originalError)
                return
            }
            playerLog.notice("403 recovery stream URL: \(baseRecoveryURL.absoluteString.prefix(120))")
            // BUG-003 fix: propagate refreshed info so ViewModel state reflects fresh signed URLs.
            playerInfo = freshInfo
            availableFormats = Self.deduplicatedVideoFormats(freshInfo.formats)
            availableCaptions = freshInfo.captionTracks
            autoApplyCaptionPreference(tracks: freshInfo.captionTracks)
            // Apply quality preference: fetch HLS variants if available, then select the correct stream.
            var recoveryURL = baseRecoveryURL
            if let hlsURL = freshInfo.hlsURL {
                let variantURLs = await fetchHLSVariantURLs(url: hlsURL)
                if !variantURLs.isEmpty {
                    hlsVariantURLs = variantURLs
                    availableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
                }
                recoveryURL = applyQualityPreference(to: baseRecoveryURL)
            }
            lastAttemptedStreamURL = recoveryURL
            let recoveryItem = AVPlayerItem(url: recoveryURL)
            // BUG-009 fix: replace before observing.
            player.replaceCurrentItem(with: recoveryItem)
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in recoveryItem.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ 403 recovery AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        self.loadAudioTracks(from: recoveryItem)
                        self.isLoading = false
                    case .failed:
                        let err = recoveryItem.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ 403 recovery AVPlayerItem failed: \(err) — falling back to Android client")
                        await self.retryWithFallbackPlayer(video: video, originalError: originalError)
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            // BUG-007 fix: launch phase2 so SponsorBlock, tracking URLs, and nextInfo are fetched
            // after the 403-recovery fetch.
            let p2Video = video
            let p2Info = freshInfo
            phase2Task?.cancel()
            phase2Task = Task(priority: .utility) { [weak self] in
                let empty = CachedVideoData(
                    playerInfo: nil, trackingURLs: nil, nextInfo: nil,
                    endCards: nil, sponsorSegments: nil, deArrowBranding: nil,
                    staleFields: []
                )
                await self?.loadAsyncPhase2(
                    video: p2Video, cached: empty, info: p2Info,
                    cachedTrackingURLs: nil, authTrackingTask: nil, sponsorCached: false
                )
            }
        } catch {
            playerLog.error("❌ 403 recovery fetch failed: \(String(describing: error)) — falling back to Android client")
            await retryWithFallbackPlayer(video: video, originalError: originalError)
        }
    }

    // MARK: - Helpers

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
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        }
        // Sort key: H.264 (avc1) before AV1/other codecs, then by height desc, then bitrate desc.
        func preferH264(_ lhs: VideoFormat, _ rhs: VideoFormat) -> Bool {
            let lH264 = lhs.mimeType.contains("avc1")
            let rH264 = rhs.mimeType.contains("avc1")
            if lH264 != rH264 { return lH264 }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }
        guard settings.preferredQuality != .auto,
              let maxH = settings.preferredQuality.maxHeight else {
            return videoOnly.sorted(by: preferH264).first?.url
        }
        let capped = videoOnly.filter { $0.height <= maxH }
        return capped.sorted(by: preferH264).first?.url
            ?? videoOnly.sorted(by: preferH264).first?.url
    }
}
