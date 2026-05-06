import AVFoundation
import os
#if canImport(UIKit)
import UIKit
import MediaPlayer
#endif
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Load Video Lifecycle

extension PlaybackViewModel {

    public func load(video: Video) {
        playerLog.notice("[load] load() called — id=\(video.id) currentVideo=\(self.currentVideo?.id ?? "nil") isLoading=\(self.isLoading)")
        CrashlyticsLogger.setVideoContext(id: video.id, title: video.title)
        // Cancel any previous in-flight load so we never have two concurrent API
        // fetches for the same (or different) video running at the same time.
        loadTask?.cancel()

        // Report watchtime for the video being replaced before tearing it down.
        // This is the only opportunity when switching via load() directly (e.g. autoplay),
        // since stop()/suspend() are not called in that path.
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            let flush = tracker.transition(to: video.id, cpn: InnerTubeAPI.generateCPN(),
                                           flushPosition: pos, flushDuration: dur)
            Task { await flush() }
        } else {
            tracker.transition(to: video.id, cpn: InnerTubeAPI.generateCPN(),
                               flushPosition: 0, flushDuration: 0)
        }

        // Stop and clear the current item immediately so the previous frame
        // is not visible while the next video is loading.
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        wasPlayingBeforeSuspend = false
        currentTime = 0
        duration = 0
        error = nil
        controlsVisible = false
        controlsTimer?.cancel()
        seekDebounceTask?.cancel()
        isScrubbing = false
        chapters = []
        availableCaptions = []
        selectedCaption = nil
        currentCaptionCue = nil
        captionCues = []
        captionFetchTask?.cancel()
        captionFetchTask = nil
        availableAudioTracks = []
        selectedAudioTrack = nil
        audioSelectionGroup = nil
        audioOptionsByID = [:]
        endCards = []

        // Push the currently playing video onto the history stack before switching
        if let prev = currentVideo {
            history.append(prev)
        }
        currentVideo = video
        hasPrevious = !history.isEmpty
        hasRetriedPlayback = false
        qualityTask?.cancel()
        qualityTask = nil
        hlsVariantURLs = [:]
        loadTask = Task { await loadAsync(video: video) }
    }

    /// User-initiated retry after all automatic fallbacks have been exhausted.
    /// Resets the retry guard and reloads the current video from scratch.
    public func retryLoad() {
        guard let video = currentVideo else { return }
        error = nil
        hasRetriedPlayback = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
            await self.loadAsync(video: video)
        }
    }

    /// Call when the app returns to the foreground and this PlayerView is the visible one.
    /// Reactivates the AVAudioSession and resumes the player if it was playing
    /// before the interruption/background transition.
    public func handleForeground() {
        guard player.currentItem != nil else { return }
        #if canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playerLog.error("AVAudioSession reactivation failed: \(error.localizedDescription)")
        }
        #endif
        // Resume only if we consider ourselves to be in playing state.
        // isPlaying is kept in sync with player.rate via KVO, so this only fires
        // when the player was paused while still intending to play (e.g. background transition).
        if isPlaying && player.rate == 0 {
            player.rate = Float(settings.playbackSpeed)
            playerLog.notice("[handleForeground] resumed player after foreground transition")
        }
    }

    /// Call when the app enters the background.
    /// Pauses playback when the user has disabled background audio.
    public func handleBackground() {
        guard !settings.backgroundPlaybackEnabled else { return }
        guard isPlaying else { return }
        player.pause()
        // isPlaying is synced to false by the rate KVO observer.
        playerLog.notice("[handleBackground] background playback disabled — paused")
    }

    /// Pauses playback and saves the watch position without tearing down the AVPlayerItem.
    /// Called when the PlayerView temporarily disappears (e.g. a sheet slides over it).
    /// Use `resume()` to restart playback, or `load(video:)` to switch videos.
    public func suspend() {
        playerLog.notice("[suspend] suspend() called — currentVideo=\(self.currentVideo?.id ?? "nil") currentTime=\(Int(self.currentTime))s")
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            Task {
                await self.tracker.checkpoint(position: pos, duration: dur)
                playerLog.notice("Saved position \(Int(pos))s for suspend")
            }
        }
        wasPlayingBeforeSuspend = isPlaying
        player.pause()
        isPlaying = false
        controlsTimer?.cancel()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        // Deregister from the global command center so a suspended VM never
        // handles lock screen Play while another VM is the active player.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        #endif
    }

    /// Resumes playback after a `suspend()`. If the player has no current item
    /// (e.g. `stop()` was called), this is a no-op — use `load(video:)` instead.
    public func resume() {
        guard player.currentItem != nil else {
            playerLog.notice("[resume] no item — skipping resume")
            return
        }
        playerLog.notice("[resume] resume() called — currentVideo=\(self.currentVideo?.id ?? "nil")")
        wasPlayingBeforeSuspend = false
        #if canImport(UIKit)
        // Re-register lock screen commands (removed in suspend()).
        setupRemoteCommandCenter()
        #endif
        player.rate = Float(settings.playbackSpeed)
        isPlaying = true
        showControls()
        #if canImport(UIKit)
        updateNowPlayingPlayback()
        #endif
    }

    func loadAsync(video: Video) async {
        isLoading = true
        defer { isLoading = false }
        playerLog.notice("load video id=\(video.id) title=\(video.title)")
        do {
            // --- Cache-first load ---
            // Check VideoPreloadCache for all data types. Fresh hits skip the network
            // call entirely; partial hits fill only the missing pieces in parallel.
            let cached = await VideoPreloadCache.shared.consume(videoId: video.id)
            playerLog.notice("cache: playerInfo=\(cached.playerInfo != nil) nextInfo=\(cached.nextInfo != nil) sponsor=\(cached.sponsorSegments != nil) endCards=\(cached.endCards != nil) tracking=\(cached.trackingURLs != nil)")

            // --- Player info (stream URLs + metadata) ---
            // Kick off an authenticated TV-client player request in parallel with the
            // primary iOS player fetch when the cache doesn't already have tracking URLs.
            // cached.trackingURLs is PlaybackTrackingURLs?? — .some(nil) means the prefetch
            // ran before auth was ready; treat that as a miss so we still get live URLs.
            let cachedTrackingURLs: PlaybackTrackingURLs? = cached.trackingURLs.flatMap { $0 }
            let authTrackingTask: Task<PlaybackTrackingURLs?, Never>?
            if cachedTrackingURLs != nil {
                // Tracking URLs came from the cache; no need for a parallel TV-client call.
                authTrackingTask = nil
            } else {
                authTrackingTask = Task<PlaybackTrackingURLs?, Never> { [api = self.api] in
                    await api.fetchAuthenticatedTrackingURLs(videoId: video.id)
                }
            }

            // Fetch player info using the iOS client (unauthenticated).
            // If YouTube returns UNPLAYABLE/LOGIN_REQUIRED and the user is signed in,
            // automatically retry with the authenticated TV client before showing an error.
            let info: PlayerInfo
            if let cachedInfo = cached.playerInfo {
                playerLog.notice("cache HIT: playerInfo (skipping network)")
                info = cachedInfo
            } else {
                do {
                    info = try await api.fetchPlayerInfo(videoId: video.id)
                } catch {
                    if case APIError.unavailable = error, hasAuthToken {
                        playerLog.notice("⚠️ iOS client returned unavailable — retrying with authenticated TV client")
                        info = try await api.fetchPlayerInfoAuthenticated(videoId: video.id)
                    } else {
                        throw error
                    }
                }
                await VideoPreloadCache.shared.store(playerInfo: info, for: video.id)
            }
            playerInfo = info
            availableFormats = Self.deduplicatedVideoFormats(info.formats)
            availableCaptions = info.captionTracks
            selectedFormat = nil

            playerLog.notice("playerInfo: formats=\(info.formats.count) hlsURL=\(info.hlsURL?.absoluteString ?? "nil") dashURL=\(info.dashURL?.absoluteString ?? "nil")")
            for (i, fmt) in info.formats.enumerated() {
                playerLog.notice("  format[\(i)] mimeType=\(fmt.mimeType) quality=\(fmt.label) url=\(fmt.url?.absoluteString.prefix(80) ?? "nil")")
            }

            let prefURL = info.preferredStreamURL
            playerLog.notice("preferredStreamURL=\(prefURL?.absoluteString.prefix(120) ?? "nil")")

            // --- SponsorBlock ---
            let channelIsExcluded = video.channelId.map {
                settings.sponsorBlockExcludedChannels.keys.contains($0)
            } ?? false
            if settings.sponsorBlockEnabled, !channelIsExcluded {
                var segments: [SponsorSegment]
                if let cachedSegments = cached.sponsorSegments {
                    playerLog.notice("cache HIT: sponsorSegments (skipping network)")
                    segments = cachedSegments
                } else {
                    segments = await sponsorBlock.fetchSegments(
                        videoId: video.id,
                        categories: settings.activeSponsorCategories
                    )
                    await VideoPreloadCache.shared.store(sponsorSegments: segments, for: video.id)
                }
                let minDur = settings.sponsorBlockMinSegmentDuration
                if minDur > 0 {
                    segments = segments.filter { ($0.end - $0.start) >= minDur }
                }
                sponsorSegments = segments
            }

            // --- Related videos + like status ---
            let nextInfo: NextInfo?
            if let cachedNext = cached.nextInfo {
                playerLog.notice("cache HIT: nextInfo (skipping network)")
                nextInfo = cachedNext
            } else {
                nextInfo = try? await api.fetchNextInfo(videoId: video.id)
                if let nextInfo { await VideoPreloadCache.shared.store(nextInfo: nextInfo, for: video.id) }
            }

            if let nextInfo, !nextInfo.relatedVideos.isEmpty {
                relatedVideos = nextInfo.relatedVideos.filter { $0.id != video.id }
                hasNext = !relatedVideos.isEmpty
            } else {
                // Fallback to search if /next returns nothing.
                // Use video.title (from the original Video parameter) — info.video.title
                // can be empty for ads/unplayable content where videoDetails is sparse.
                let fallbackQuery = video.title.isEmpty ? nil : video.title
                if let query = fallbackQuery {
                    let searched = try? await api.search(query: query)
                    relatedVideos = searched?.videos.filter { $0.id != video.id }.prefix(InnerTubeClients.maxVideoResults).map { $0 } ?? []
                    hasNext = !relatedVideos.isEmpty
                }
            }
            // Apply like status returned from the authenticated /next call
            if let status = nextInfo?.likeStatus { likeStatus = status }
            if let ch = nextInfo?.chapters, !ch.isEmpty { chapters = ch }

            // --- End cards ---
            if let cachedCards = cached.endCards {
                playerLog.notice("cache HIT: endCards (skipping network)")
                endCards = cachedCards
            } else if !info.endCards.isEmpty {
                endCards = info.endCards
                playerLog.notice("endCards: \(info.endCards.count) from primary response")
                await VideoPreloadCache.shared.store(endCards: info.endCards, for: video.id)
            } else {
                do {
                    let webCards = try await api.fetchEndCards(videoId: video.id)
                    endCards = webCards
                    playerLog.notice("endCards: \(webCards.count) from web client fallback")
                    await VideoPreloadCache.shared.store(endCards: webCards, for: video.id)
                } catch {
                    playerLog.error("endCards fetch failed: \(error.localizedDescription)")
                    endCards = []
                }
            }

            // --- Kick off neighbour pre-fetch now that relatedVideos is populated ---
            let neighbourIds = Array(relatedVideos.prefix(3).map(\.id))
            let prefetchToken = currentAuthToken
            let sponsorCats = settings.activeSponsorCategories
            Task(priority: .background) {
                for videoId in neighbourIds {
                    await VideoPreloadCache.shared.prefetch(
                        videoId: videoId,
                        sponsorCategories: sponsorCats,
                        authToken: prefetchToken
                    )
                }
            }

            // Restore saved watch position (mirrors VideoStateController)
            let savedState = await VideoStateStore.shared.state(for: video.id)
            if let pos = savedState?.position, pos > 5 {
                savedPositionToRestore = pos
                playerLog.notice("Restoring position \(Int(pos))s for \(video.id)")
            }

            // --- Tracking URLs ---
            // Prefer account-bound TV-client URLs over the anonymous iOS-client URLs.
            // Use the cached value if present; otherwise await the parallel task result.
            let resolvedTrackingURLs: PlaybackTrackingURLs?
            if let cachedTracking = cachedTrackingURLs {
                resolvedTrackingURLs = cachedTracking
                playerLog.notice("cache HIT: trackingURLs")
            } else {
                resolvedTrackingURLs = await authTrackingTask?.value ?? info.trackingURLs
                await VideoPreloadCache.shared.store(trackingURLs: resolvedTrackingURLs, for: video.id)
            }
            tracker.setTrackingURLs(resolvedTrackingURLs)
            playerLog.notice("activeTrackingURLs resolved: \(resolvedTrackingURLs != nil ? "account-bound" : "none")")
            // Filter the quality picker to only heights that the HLS manifest actually
            // offers. The iOS player response lists all adaptive CDN formats at every
            // quality, but the HLS variant playlist may omit qualities the CDN has not
            // encoded for this video. Parsing the manifest prevents the user from
            // selecting a quality tier that AVPlayer's ABR would silently ignore.
            if let hlsURL = info.hlsURL {
                let variantURLs = await fetchHLSVariantURLs(url: hlsURL)
                if !variantURLs.isEmpty {
                    hlsVariantURLs = variantURLs
                    availableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
                    playerLog.notice("HLS variants: \(variantURLs.keys.sorted().reversed()) — filtered quality picker to \(availableFormats.count) options")
                    // If a previously-saved format was filtered out, reset to Auto.
                    if let sel = selectedFormat, !variantURLs.keys.contains(sel.height) {
                        selectedFormat = nil
                    }
                }
            }
            // Build player item — preferredStreamURL is guaranteed non-nil here because
            // parsePlayerInfo throws APIError.unavailable when streamingData is absent.
            guard let masterStreamURL = info.preferredStreamURL else {
                playerLog.error("❌ No stream URL after successful parse (should not happen)")
                throw APIError.decodingError("No stream URL")
            }
            // If a quality preference is saved, use the matching direct variant playlist URL
            // so ABR cannot override the user's choice on fast connections (preferredMaximumResolution
            // is advisory only and is routinely ignored by AVPlayer on the simulator).
            // For Auto mode, use the master URL and let ABR pick the best variant.
            var initialStreamURL = masterStreamURL
            if settings.preferredQuality != .auto, let maxH = settings.preferredQuality.maxHeight {
                let matchingFormat = availableFormats.first { $0.height <= maxH }
                selectedFormat = matchingFormat
                if let height = matchingFormat?.height, let variantURL = hlsVariantURLs[height] {
                    initialStreamURL = variantURL
                    playerLog.notice("Initial quality \(maxH)p via direct variant playlist")
                } else {
                    playerLog.notice("Initial quality \(maxH)p — no variant URL, falling back to master")
                }
            }
            playerLog.notice("Starting AVPlayer with: \(initialStreamURL.absoluteString.prefix(120))")
            lastAttemptedStreamURL = initialStreamURL
            let playerAsset = AVURLAsset(
                url: initialStreamURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]]
            )
            let item = AVPlayerItem(asset: playerAsset)
            // Only use the preferredMaximumResolution hint when no direct variant URL was available.
            if settings.preferredQuality != .auto, let maxH = settings.preferredQuality.maxHeight,
               initialStreamURL == masterStreamURL {
                let h = CGFloat(maxH)
                item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
                playerLog.notice("Initial quality \(maxH)p hint set (no variant URL)")
            }
            // Observe item status using async/await (withCheckedContinuation is not needed
            // here since we only need to react to status changes, not await them).
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in item.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ AVPlayerItem readyToPlay")
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        // Load alternate audio renditions (dubbed / translated tracks).
                        self.loadAudioTracks(from: item)
                    case .failed:
                        let err = item.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ AVPlayerItem failed: \(err)")
                        if !self.hasRetriedPlayback, let video = self.currentVideo {
                            self.hasRetriedPlayback = true
                            // NSURLErrorDomain -1102 = HTTP 403 from a CDN URL that is now IP-bound
                            // to a different network. Invalidate the cached player info so the next
                            // attempt fetches a fresh URL, then try the iOS client first.
                            let nsErr = item.error as? NSError
                            if nsErr?.domain == NSURLErrorDomain && nsErr?.code == -1102 {
                                await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                                Task { await self.retryWith403Recovery(video: video, originalError: item.error) }
                            } else {
                                Task { await self.retryWithFallbackPlayer(video: video, originalError: item.error) }
                            }
                        } else {
                            self.error = item.error
                        }
                    case .unknown:
                        playerLog.notice("AVPlayerItem status: unknown (loading)")
                    @unknown default:
                        break
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            duration = info.video.duration ?? 0

            // Observe end-of-item using NotificationCenter async sequence
            endObserverTask?.cancel()
            endObserverTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item
                )
                for await _ in notifications {
                    guard let self, !Task.isCancelled else { return }
                    self.handlePlaybackEnd()
                }
            }

            #if canImport(UIKit)
            // Re-register lock screen commands before starting playback.
            // Commands are removed in suspend()/stop(); re-registering here
            // ensures they work when load() is called after a stop().
            setupRemoteCommandCenter()
            #endif
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            updateNowPlayingInfo()
            #endif
            scheduleControlsHide()
        } catch {
            playerLog.error("❌ loadAsync error: \(String(describing: error))")
            self.error = error
        }
    }

    // MARK: - Cleanup

    public func stop() {
        playerLog.notice("[stop] stop() called — currentVideo=\(self.currentVideo?.id ?? "nil") currentTime=\(Int(self.currentTime))s isLoading=\(self.isLoading)")
        // Save watch position before stopping (mirrors VideoStateController)
        if settings.historyState == .enabled, duration > 0 {
            let pos = self.currentTime
            let dur = self.duration
            Task {
                await self.tracker.checkpoint(position: pos, duration: dur)
                playerLog.notice("Saved position \(Int(pos))s for stop")
            }
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        controlsTimer?.cancel()
        seekDebounceTask?.cancel()
        #if canImport(UIKit)
        clearNowPlayingInfo()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        #endif
        if let obs = audioSessionObserver {
            NotificationCenter.default.removeObserver(obs)
            audioSessionObserver = nil
        }
    }
}
