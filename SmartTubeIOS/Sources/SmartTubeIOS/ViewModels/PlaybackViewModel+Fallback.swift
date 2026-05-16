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
            guard let fallbackURL = fallbackInfo.preferredStreamURL else {
                playerLog.error("❌ Fallback player: no stream URL")
                self.error = originalError
                return
            }
            playerLog.notice("Fallback stream URL: \(fallbackURL.absoluteString.prefix(120))")
            // BUG-002 fix: propagate fetched info so format/caption pickers reflect the fallback response.
            playerInfo = fallbackInfo
            availableFormats = Self.deduplicatedVideoFormats(fallbackInfo.formats)
            availableCaptions = fallbackInfo.captionTracks
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
        guard let videoURL = info.bestAdaptiveVideoURL,
              let audioURL = info.bestAdaptiveAudioURL else {
            playerLog.error("❌ Adaptive composition: no adaptive URLs in player info")
            await retryWithFallbackPlayer(video: video, originalError: originalError)
            return
        }
        // BUG-004 fix: propagate the info that was passed in so format/caption pickers reflect it.
        playerInfo = info
        availableFormats = Self.deduplicatedVideoFormats(info.formats)
        availableCaptions = info.captionTracks
        playerLog.notice("Adaptive composition: video=\(videoURL.absoluteString.prefix(80)) audio=\(audioURL.absoluteString.prefix(80))")

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
                        let err = compositeItem.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ Adaptive composition AVPlayerItem failed: \(err)")
                        await self.retryWithFallbackPlayer(video: video, originalError: compositeItem.error ?? originalError)
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
            playerLog.error("❌ Adaptive composition setup failed: \(error) — falling back to Android client")
            await retryWithFallbackPlayer(video: video, originalError: originalError)
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
            guard let freshURL = freshInfo.preferredStreamURL else {
                playerLog.error("❌ 403 recovery: no stream URL in fresh iOS-client response")
                await retryWithFallbackPlayer(video: video, originalError: originalError)
                return
            }
            playerLog.notice("403 recovery stream URL: \(freshURL.absoluteString.prefix(120))")
            // BUG-003 fix: propagate refreshed info so ViewModel state reflects fresh signed URLs.
            playerInfo = freshInfo
            availableFormats = Self.deduplicatedVideoFormats(freshInfo.formats)
            availableCaptions = freshInfo.captionTracks
            lastAttemptedStreamURL = freshURL
            let recoveryItem = AVPlayerItem(url: freshURL)
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
}
