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
        playerLog.notice("[load] load() called — id=\(video.id) currentVideo=\(self.currentVideo?.id ?? "nil") isLoading=\(self.isLoading) player.item=\(self.player.currentItem != nil)")
        if currentVideo?.id == video.id, !isLoading {
            playerLog.notice("[load] re-opening same video \(video.id) — stop() may have deactivated AVAudioSession")
        } else if let prev = currentVideo, prev.id != video.id, !isLoading {
            playerLog.notice("[load] switching from \(prev.id) to \(video.id) after stop()")
        }
        // If the exact same video is already being loaded, ignore the duplicate call.
        // SwiftUI can trigger load() multiple times during a single navigation (e.g.
        // selectedVideo binding re-evaluated while a queue autoplay is in flight).
        // Each duplicate spawns its own loadAsync → its own Crashlytics event storm.
        if currentVideo?.id == video.id, isLoading {
            playerLog.notice("[load] already loading \(video.id) — ignoring duplicate call")
            return
        }
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
        videoEnded = false
        wasPlayingBeforeSuspend = false
        currentTime = 0
        duration = 0
        error = nil
        controlsVisible = false
        controlsTimer?.cancel()
        seekDebounceTask?.cancel()
        isScrubbing = false
        chapters = []
        captionsManager.reset()
        audioManager.reset()
        endCards = []

        // Push the currently playing video onto the history stack before switching
        if let prev = currentVideo {
            history.append(prev)
        }
        currentVideo = video
        hasPrevious = !history.isEmpty
        retryAttempts = 0
        exhaustiveRetryTask?.cancel()
        exhaustiveRetryTask = nil
        qualityManager.reset()
        phase2Task?.cancel()
        phase2Task = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        AVAssetTrackCache.shared.clear()

        // UI-testing synchronous inject for related videos.
        // Checked here (before the Task is created) so that hasNext = true is set
        // before the first XCTest accessibility-tree snapshot.  The async path in
        // loadAsync contains the same check and is kept as a belt-and-suspenders
        // guard in case load() is ever called without going through this entry point.
        if let relArg = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--uitesting-inject-related-video-ids=")
        }) {
            let raw = String(relArg.dropFirst("--uitesting-inject-related-video-ids=".count))
            let ids = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !ids.isEmpty {
                relatedVideos = ids.map { Video(id: $0, title: $0, channelTitle: "Test Channel") }
                hasNext = true
                playerLog.notice("UI-testing sync inject: set \(ids.count) related videos before Task")
            }
        }

        loadTask = Task { await loadAsync(video: video) }
    }

    /// User-initiated retry after all automatic fallbacks have been exhausted.
    /// Resets the retry guard and reloads the current video from scratch.
    public func retryLoad() {
        guard let video = currentVideo else { return }
        error = nil
        retryAttempts = 0
        exhaustiveRetryTask?.cancel()
        exhaustiveRetryTask = nil
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
        UIApplication.shared.isIdleTimerDisabled = false
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
        UIApplication.shared.isIdleTimerDisabled = true
        updateNowPlayingPlayback()
        #endif
    }

    func loadAsync(video: Video) async {
        isLoading = true
        needsQuickStartup = true
        // Note: isLoading = false is set in the AVPlayerItem .readyToPlay observer so the
        // spinner stays visible until the first frame is actually ready. It was previously
        // cleared after player.rate was set, which dismissed the spinner before buffering
        // completed on slow networks (GitHub issue #53).
        playerLog.notice("[loadAsync] start id=\(video.id) title=\(video.title) player.rate=\(self.player.rate) timeControlStatus=\(self.player.timeControlStatus.rawValue)")

        // Local-file fast path — bypass all network fetches for downloaded videos.
        // The path must be inside Documents/SmartTubeDownloads/ to prevent path-traversal
        // from a crafted Video object.
        if let localURL = video.localFileURL {
            let downloadsDir = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SmartTubeDownloads").path
            if localURL.path.hasPrefix(downloadsDir),
               FileManager.default.fileExists(atPath: localURL.path) {
                let item = AVPlayerItem(url: localURL)
                item.audioTimePitchAlgorithm = .spectral
                // Wire up observers BEFORE replaceCurrentItem (task-80 rule).
                itemObserverTask?.cancel()
                itemObserverTask = Task { [weak self] in
                    for await status in item.statusStream {
                        guard let self, !Task.isCancelled else { return }
                        switch status {
                        case .readyToPlay:
                            self.loadAudioTracks(from: item)
                            self.isLoading = false
                        case .failed:
                            playerLog.error("❌ local-file AVPlayerItem failed: \(String(describing: item.error))")
                            self.error = item.error
                        case .unknown:
                            break
                        @unknown default:
                            break
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
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
                setupRemoteCommandCenter()
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    playerLog.error("[loadAsync] local: AVAudioSession setActive failed: \(error.localizedDescription)")
                }
                #endif
                player.rate = Float(settings.playbackSpeed)
                isPlaying = true
                #if canImport(UIKit)
                UIApplication.shared.isIdleTimerDisabled = true
                updateNowPlayingInfo()
                #endif
                playerLog.notice("[loadAsync] local-file fast path: playing \(localURL.lastPathComponent)")
                return
            }
            // File missing or path invalid — fall through to network re-stream.
            playerLog.notice("[loadAsync] localFileURL set but file not accessible, falling through: \(localURL.path)")
        }

        do {
            // --- Cache-first load ---
            // Check VideoPreloadCache for all data types. Fresh hits skip the network
            // call entirely; partial hits fill only the missing pieces in parallel.
            let cached = await VideoPreloadCache.shared.consume(videoId: video.id)
            playerLog.notice("cache: playerInfo=\(cached.playerInfo != nil) nextInfo=\(cached.nextInfo != nil) sponsor=\(cached.sponsorSegments != nil) endCards=\(cached.endCards != nil) tracking=\(cached.trackingURLs != nil)")

            // Apply cached DeArrow overrides (community title / thumbnail timestamp).
            // Done immediately after consume() so VideoCardView can show the override
            // as soon as the player screen appears, before Phase 2 completes.
            if settings.deArrowEnabled, let deArrow = cached.deArrowBranding {
                currentVideo?.deArrowTitle = deArrow.title
                currentVideo?.deArrowThumbnailTimestamp = deArrow.thumbnailTimestamp
            }

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
            // TEMP DISABLED: playerInfo cache/coalescing — always fetch fresh
            // if let cachedInfo = cached.playerInfo {
            //     playerLog.notice("cache HIT: playerInfo (skipping network)")
            //     info = cachedInfo
            // } else if let inFlight = await VideoPreloadCache.shared.inFlightPlayerFetch(videoId: video.id),
            //           let coalescedInfo = await inFlight.value {
            //     playerLog.notice("coalescedPrefetch HIT: playerInfo (skipping network)")
            //     info = coalescedInfo
            // } else {
            do {
                info = try await api.fetchPlayerInfo(videoId: video.id)
                } catch {
                    if case APIError.ipBlocked(let reason) = error {
                        // NW-6-FIX: IP-block short-circuit. Every extra /player call from a
                        // blocked IP can extend the block duration — skip ALL retries,
                        // including the TV-authenticated path (an authenticated request
                        // carries the same blocked IP and will fail too). Throw immediately
                        // so the error banner appears with the specific VPN message and
                        // without a "Try Again" button. Suppress Crashlytics recording —
                        // this is a user-side network condition, not an app bug.
                        playerLog.error("⚠️ iOS client detected IP block — reason: \(reason)")
                        throw error
                    } else if case APIError.unavailable = error, hasAuthToken {
                        playerLog.notice("⚠️ iOS client returned unavailable — retrying with authenticated TV client")
                        do {
                            var tvInfo = try await api.fetchPlayerInfoAuthenticated(videoId: video.id)
                            // NW-3-FIX: TV client may return no HLS manifest and no adaptive
                            // streams for DRM/protected or region-locked content
                            // (hlsURL=nil, bestAdaptiveVideoURL=nil). Attempting to play the
                            // TV muxed direct URL (itag=18, c=TVHTML5) fails with
                            // AVFoundationErrorDomain -11828 / NSOSStatusErrorDomain -12847.
                            // Skip the unnecessary AVPlayer attempt and go straight to the
                            // Android client.
                            if tvInfo.hlsURL == nil,
                               tvInfo.bestAdaptiveVideoURL == nil || tvInfo.bestAdaptiveAudioURL == nil {
                                playerLog.notice("⚠️ TV client returned no HLS/adaptive streams — falling through to Android client")
                                tvInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                            }
                            info = tvInfo
                        } catch {
                            if case APIError.unavailable = error {
                                // TV client also returned unavailable / cipher-protected formats.
                                // Fall through to the Android client as a last resort.
                                playerLog.notice("⚠️ TV client also unavailable — retrying with Android client")
                                info = try await api.fetchPlayerInfoAndroid(videoId: video.id)
                            } else {
                                throw error
                            }
                        }
                    } else {
                        throw error
                    }
                }
            await VideoPreloadCache.shared.store(playerInfo: info, for: video.id)
            // BUG-005 fix: guard against rapid navigation — if the user navigated away while we
            // were awaiting the player info, discard this result rather than overwrite ViewModel state.
            guard currentVideo?.id == video.id else {
                playerLog.notice("[loadAsync] superseded: discarding playerInfo for \(video.id)")
                return
            }
            playerInfo = info
            availableFormats = Self.deduplicatedVideoFormats(info.formats)
            availableCaptions = info.captionTracks
            autoApplyCaptionPreference(tracks: info.captionTracks)
            selectedFormat = nil

            playerLog.notice("playerInfo: formats=\(info.formats.count) hlsURL=\(info.hlsURL?.absoluteString ?? "nil") dashURL=\(info.dashURL?.absoluteString ?? "nil")")
            for (i, fmt) in info.formats.enumerated() {
                playerLog.notice("  format[\(i)] mimeType=\(fmt.mimeType) quality=\(fmt.label) url=\(fmt.url?.absoluteString.prefix(80) ?? "nil")")
            }

            let prefURL = info.preferredStreamURL
            playerLog.notice("preferredStreamURL=\(prefURL?.absoluteString.prefix(120) ?? "nil")")

            // --- SponsorBlock ---
            // Segments from the cache are applied inline (fast path, zero network cost).
            // Stale segments are applied immediately and revalidated in Phase 2.
            // When not cached, the fetch is deferred to Phase 2 (runs concurrently with
            // AVPlayer buffering) so it does not block the spinner.
            sponsorSegments = []
            let channelIsExcluded = video.channelId.map {
                settings.sponsorBlockExcludedChannels.keys.contains($0)
            } ?? false
            playerLog.notice("[sponsorBlock] enabled=\(settings.sponsorBlockEnabled) channelExcluded=\(channelIsExcluded) categories=\(settings.activeSponsorCategories.count)")
            var sponsorCached = false
            if settings.sponsorBlockEnabled, !channelIsExcluded {
                if let cachedSegments = cached.sponsorSegments {
                    // Cache hit (fresh or stale) — apply immediately.
                    let isStaleSponsor = cached.staleFields.contains(.sponsorSegments)
                    let minDur = settings.sponsorBlockMinSegmentDuration
                    let filtered = minDur > 0
                        ? cachedSegments.filter { ($0.end - $0.start) >= minDur }
                        : cachedSegments
                    sponsorSegments = filtered
                    let sbCacheLabel = isStaleSponsor ? "STALE" : "HIT"
                    playerLog.notice("[sponsorBlock] cache \(sbCacheLabel): \(cachedSegments.count) raw -> \(filtered.count) applied")
                    // Mark as "not fully cached" only when stale so Phase 2 revalidates.
                    sponsorCached = !isStaleSponsor
                } else {
                    playerLog.notice("[sponsorBlock] cache MISS — will fetch in phase2")
                }
                // Full miss or stale: Phase 2 will fetch or revalidate.
            } else {
                playerLog.notice("[sponsorBlock] skipped (disabled or channel excluded)")
                sponsorCached = true  // disabled/excluded — no fetch needed in Phase 2
            }

            // Restore saved watch position (mirrors VideoStateController)
            let savedState = await VideoStateStore.shared.state(for: video.id)
            if let pos = savedState?.position, pos > 5 {
                savedPositionToRestore = pos
                playerLog.notice("Restoring position \(Int(pos))s for \(video.id)")
            }
            // Filter the quality picker to only heights that the HLS manifest actually
            // offers. The iOS player response lists all adaptive CDN formats at every
            // quality, but the HLS variant playlist may omit qualities the CDN has not
            // encoded for this video. Parsing the manifest prevents the user from
            // selecting a quality tier that AVPlayer's ABR would silently ignore.
            // TEMP DISABLED: HLS variant fetch skipped
            // if let hlsURL = info.hlsURL {
            //     let variantURLs = await fetchHLSVariantURLs(url: hlsURL)
            //     if !variantURLs.isEmpty {
            //         hlsVariantURLs = variantURLs
            //         availableFormats = availableFormats.filter { variantURLs.keys.contains($0.height) }
            //         playerLog.notice("HLS variants: \(variantURLs.keys.sorted().reversed()) — filtered quality picker to \(availableFormats.count) options")
            //         if let sel = selectedFormat, !variantURLs.keys.contains(sel.height) { selectedFormat = nil }
            //     }
            // }
            // Build player item — preferredStreamURL is guaranteed non-nil here because
            // parsePlayerInfo throws APIError.unavailable when streamingData is absent.
            guard let masterStreamURL = info.preferredStreamURL else {
                // iOS client returned adaptive-only formats (no HLS, no muxed stream).
                // This happens for some long-form videos where YouTube does not send itag 18.
                // Android client always returns an HLS manifest — reuse the fallback path.
                if !info.formats.isEmpty {
                    playerLog.notice("⚠️ adaptive-only iOS response — retrying with Android client for HLS")
                    await exhaustiveRetry(video: video, originalError: nil)
                    return
                }
                playerLog.error("❌ No stream URL after successful parse (should not happen)")
                throw APIError.decodingError("No stream URL")
            }
            // For initial load always use the master HLS manifest so that AVPlayer
            // receives EXT-X-MEDIA alternate audio renditions (dubbed tracks, etc.).
            // Variant playlists omit EXT-X-MEDIA entries, which causes AudioTrackManager
            // to exit early and produce silent audio when a non-auto quality is preferred.
            // Quality is steered via AVPlayerItem hints (preferredMaximumResolution /
            // preferredPeakBitRate) which AVPlayer honours during ABR adaptation.
            let initialStreamURL = masterStreamURL
            // Compute effective quality cap: explicit setting, or display-native resolution
            // for Auto so the player never fetches variants the screen cannot render.
            let initialMaxH: Int
            if settings.preferredQuality != .auto, let h = settings.preferredQuality.maxHeight {
                initialMaxH = h
                let matchingFormat = availableFormats.first { $0.height <= h }
                selectedFormat = matchingFormat
                playerLog.notice("Initial quality \(h)p — using master URL with ABR hints")
            } else {
                initialMaxH = PlaybackViewModel.displayMaxVideoHeight()
                playerLog.notice("Initial quality Auto — capping at display resolution \(initialMaxH)p")
            }
            playerLog.notice("Starting AVPlayer with: \(initialStreamURL.absoluteString.prefix(120))")
            lastAttemptedStreamURL = initialStreamURL
            let playerAsset = AVURLAsset(
                url: initialStreamURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]]
            )
            let item = AVPlayerItem(asset: playerAsset)
            // .spectral gives the highest-quality pitch-preserving time-stretch at
            // non-1× speeds, reducing the tinny/phase artefacts audible on AirPods
            // compared to the default .timeDomain algorithm.
            item.audioTimePitchAlgorithm = .spectral
            // Fix 4C: start playback as soon as 2s of content is buffered rather than
            // waiting for the default 30s forward buffer. After 5s, reset to system
            // default so seek/scrubbing has enough buffer for smooth operation.
            item.preferredForwardBufferDuration = 2.0
            Task { [weak item] in
                try? await Task.sleep(for: .seconds(5))
                item?.preferredForwardBufferDuration = 0
            }
            // Apply quality hints when a non-auto preference is set. These steer AVPlayer's
            // ABR algorithm toward the user's preferred resolution without bypassing audio
            // metadata (which variant URLs would lose). Hints are applied unconditionally
            // to the master URL for all HLS streams.
            // Apply ABR hints so AVPlayer selects the right variant immediately.
            // Consistent with the quality-switch path in PlaybackQualityManager.
            if info.hlsURL != nil {
                let h = CGFloat(initialMaxH)
                item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
                item.preferredPeakBitRate = peakBitRate(for: initialMaxH)
                playerLog.notice("Initial quality \(initialMaxH)p hint set (master with ABR)")
            }
            // Observe item status using async/await (withCheckedContinuation is not needed
            // here since we only need to react to status changes, not await them).
            // BUG-009 fix: replaceCurrentItem BEFORE wiring the observer to avoid a race
            // where statusStream fires with stale state before the item is installed.
            // This matches the already-correct ordering in all fallback/audio-only paths.
            player.replaceCurrentItem(with: item)
            duration = info.video.duration ?? 0
            itemObserverTask?.cancel()
            itemObserverTask = Task { [weak self] in
                for await status in item.statusStream {
                    guard let self, !Task.isCancelled else { return }
                    switch status {
                    case .readyToPlay:
                        playerLog.notice("✅ AVPlayerItem readyToPlay — video=\(self.currentVideo?.id ?? "nil") rate=\(self.player.rate) timeControlStatus=\(self.player.timeControlStatus.rawValue) isAudioOnlyMode=\(self.isAudioOnlyMode)")
                        // Refresh duration from the AVPlayerItem now that it is
                        // ready — the API metadata may have been absent (nil) or
                        // inaccurate, which would leave duration=0 and break scrubbing
                        // (every seekBar drag computes fraction*0 = 0).
                        let itemDur = item.duration.seconds
                        if itemDur.isFinite && itemDur > 0 {
                            let prevDur = self.duration
                            self.duration = itemDur
                            playerLog.notice("[duration] updated from AVPlayerItem: \(String(format: "%.1f", itemDur))s (was \(String(format: "%.1f", prevDur))s from metadata)")
                        }
                        if let pos = self.savedPositionToRestore, pos > 0 {
                            self.savedPositionToRestore = nil
                            self.seek(to: pos)
                        }
                        // Load alternate audio renditions (dubbed / translated tracks).
                        self.loadAudioTracks(from: item)                        // Dismiss the spinner: the first frame is ready to display.
                        // Previously this was done after player.rate was set, which
                        // dismissed the spinner before buffering completed on slow
                        // networks (GitHub issue #53).
                        self.isLoading = false                    case .failed:
                        let err = item.error.map { "\($0)" } ?? "nil"
                        playerLog.error("❌ AVPlayerItem failed: \(err)")
                        if let video = self.currentVideo {
                            self.exhaustiveRetryTask?.cancel()
                            self.exhaustiveRetryTask = Task { await self.exhaustiveRetry(video: video, originalError: item.error) }
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

            // Audio-only mode: if enabled, replace the HLS item with an audio-only asset.
            // Falls back to HLS (already in player) on any failure. No-op when disabled.
            await loadAudioOnlyItemIfEnabled()

            #if canImport(UIKit)
            // Re-register lock screen commands before starting playback.
            // Commands are removed in suspend()/stop(); re-registering here
            // ensures they work when load() is called after a stop().
            setupRemoteCommandCenter()
            // Re-activate the audio session. stop() calls setActive(false) to release
            // the session to other apps; without this call on the next load() the player
            // starts silently because AVFoundation cannot acquire the inactive session.
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                playerLog.notice("[loadAsync] AVAudioSession activated before playback")
            } catch {
                playerLog.error("[loadAsync] AVAudioSession setActive(true) failed: \(error.localizedDescription)")
            }
            #endif
            playerLog.notice("[loadAsync] setting rate=\(self.settings.playbackSpeed) — player.timeControlStatus=\(self.player.timeControlStatus.rawValue) isAudioOnlyMode=\(self.isAudioOnlyMode)")
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
            playerLog.notice("[loadAsync] rate set — player.rate=\(self.player.rate) timeControlStatus=\(self.player.timeControlStatus.rawValue)")
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            updateNowPlayingInfo()
            #endif
            // Only reschedule the auto-hide timer when controls are already visible.
            // Calling scheduleControlsHide() unconditionally cancels any timer that
            // was started by a user tap during loading, extending the visible window
            // unexpectedly and breaking UI tests that wait for the auto-hide.
            if controlsVisible { scheduleControlsHide() }

            // Phase 2 as a cancellable utility Task. Cancelled on the next load()
            // or stop() so stale network callbacks never write to a new video's state.
            let p2Cached = cached
            let p2Info = info
            let p2CachedTracking = cachedTrackingURLs
            let p2AuthTask = authTrackingTask
            let p2SponsorCached = sponsorCached
            let p2Video = video
            phase2Task = Task(priority: .utility) { [weak self] in
                await self?.loadAsyncPhase2(
                    video: p2Video,
                    cached: p2Cached,
                    info: p2Info,
                    cachedTrackingURLs: p2CachedTracking,
                    authTrackingTask: p2AuthTask,
                    sponsorCached: p2SponsorCached
                )
            }
        } catch {
            isLoading = false
            // Ignore CancellationError — it is expected when stop() or a new load()
            // cancels an in-flight loadTask. Surfacing it would show a spurious error
            // banner on the next video open.
            guard !(error is CancellationError) else { return }
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
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            playerLog.error("AVAudioSession deactivation failed: \(error.localizedDescription)")
        }
        #endif
        loadTask?.cancel()
        loadTask = nil
        // Reset isLoading immediately so a same-video re-open via play() does not hit
        // the early-return guard in load() before the cancelled task cleans up.
        isLoading = false
        phase2Task?.cancel()
        phase2Task = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        AVAssetTrackCache.shared.clear()
        itemObserverTask?.cancel()
        itemObserverTask = nil
        endObserverTask?.cancel()
        endObserverTask = nil
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
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

    // MARK: - Phase 2: Background enrichment

    /// Runs concurrently with playback after Phase 1 completes.
    /// Fetches data that is not needed to start AVPlayer: related videos, end cards,
    /// SponsorBlock segments (cache miss only), tracking URLs, and neighbour prefetch.
    /// All property assignments happen on @MainActor because PlaybackViewModel is @MainActor.
    func loadAsyncPhase2(
        video: Video,
        cached: CachedVideoData,
        info: PlayerInfo,
        cachedTrackingURLs: PlaybackTrackingURLs?,
        authTrackingTask: Task<PlaybackTrackingURLs?, Never>?,
        sponsorCached: Bool
    ) async {
        guard !Task.isCancelled else { return }

        // --- SponsorBlock cache miss or stale ---
        if !sponsorCached, settings.sponsorBlockEnabled {
            let channelIsExcluded = video.channelId.map {
                settings.sponsorBlockExcludedChannels.keys.contains($0)
            } ?? false
            if !channelIsExcluded {
                let videoId = video.id
                let cats = settings.activeSponsorCategories
                let minDur = settings.sponsorBlockMinSegmentDuration
                if cached.staleFields.contains(.sponsorSegments) {
                    // Stale data was already applied in Phase 1 — revalidate silently.
                    Task(priority: .background) { [weak self] in
                        guard let self else { return }
                        let segments = await self.sponsorBlock.fetchSegments(videoId: videoId, categories: cats)
                        await VideoPreloadCache.shared.store(sponsorSegments: segments, for: videoId)
                    }
                } else {
                    // Full miss — fetch now and apply.
                    var segments = await sponsorBlock.fetchSegments(videoId: videoId, categories: cats)
                    await VideoPreloadCache.shared.store(sponsorSegments: segments, for: videoId)
                    guard !Task.isCancelled else { return }
                    if minDur > 0 { segments = segments.filter { ($0.end - $0.start) >= minDur } }
                    sponsorSegments = segments
                    playerLog.notice("[sponsorBlock] phase2 applied \(segments.count) segments for \(videoId)")
                }
            }
        }

        guard !Task.isCancelled else { return }

        // --- Related videos + like status ---
        // UI testing inject: bypass all network fetches for related videos.
        // Used by testPlayerSwipeRightWorksWhenControlsAreVisible which runs on
        // clone simulators that may lack network access for playerInfo.
        if let relArg = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--uitesting-inject-related-video-ids=")
        }) {
            let raw = String(relArg.dropFirst("--uitesting-inject-related-video-ids=".count))
            let ids = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !ids.isEmpty {
                relatedVideos = ids.map { Video(id: $0, title: $0, channelTitle: "Test Channel") }
                hasNext = true
                playerLog.notice("UI-testing inject: set \(ids.count) related videos synchronously")
                // fall through to remainder of loading (chapters, endCards, etc.)
            }
        } else {

        // Fresh cache hit: use immediately (no network).
        // Stale cache hit: stale data was already returned by consume() — revalidate silently in background.
        // Full miss: live blocking fetch so relatedVideos is populated before the panel opens.
        let nextInfo: NextInfo?
        if let cachedNext = cached.nextInfo, !cached.staleFields.contains(.nextInfo) {
            playerLog.notice("cache HIT: nextInfo chapters=\(cachedNext.chapters.count) (skipping network)")
            nextInfo = cachedNext
        } else if let staleNext = cached.nextInfo, cached.staleFields.contains(.nextInfo) {
            playerLog.notice("SWR: nextInfo stale chapters=\(staleNext.chapters.count) — using cached, revalidating in background")
            nextInfo = staleNext
            let videoId = video.id
            Task(priority: .background) { [api = self.api] in
                if let fresh = try? await api.fetchNextInfo(videoId: videoId) {
                    await VideoPreloadCache.shared.store(nextInfo: fresh, for: videoId)
                }
            }
        } else {
            nextInfo = try? await api.fetchNextInfo(videoId: video.id)
            if let nextInfo { await VideoPreloadCache.shared.store(nextInfo: nextInfo, for: video.id) }
        }

        guard !Task.isCancelled else { return }

        if let nextInfo, !nextInfo.relatedVideos.isEmpty {
            relatedVideos = nextInfo.relatedVideos.filter { $0.id != video.id }
            hasNext = !relatedVideos.isEmpty
        } else {
            let fallbackQuery = video.title.isEmpty ? nil : video.title
            if let query = fallbackQuery {
                let searched = try? await api.search(query: query)
                relatedVideos = searched?.videos.filter { $0.id != video.id }.prefix(InnerTubeClients.maxVideoResults).map { $0 } ?? []
                hasNext = !relatedVideos.isEmpty
            }
        }
        if let status = nextInfo?.likeStatus { likeStatus = status }
        if let ch = nextInfo?.chapters, !ch.isEmpty {
            chapters = ch
            playerLog.notice("[chapters] applied \(ch.count) chapters for \(video.id)")
        } else {
            playerLog.notice("[chapters] none for \(video.id) (nextInfo chapters=\(nextInfo?.chapters.count ?? -1))")
        }

        } // end of non-inject related-videos branch

        guard !Task.isCancelled else { return }

        // --- End cards ---
        if let cachedCards = cached.endCards, !cached.staleFields.contains(.endCards) {
            playerLog.notice("cache HIT: endCards (skipping network)")
            endCards = cachedCards
        } else if let staleCards = cached.endCards, cached.staleFields.contains(.endCards) {
            playerLog.notice("SWR: endCards stale — using cached, revalidating in background")
            endCards = staleCards
            let videoId = video.id
            Task(priority: .background) { [api = self.api] in
                if let fresh = try? await api.fetchEndCards(videoId: videoId) {
                    await VideoPreloadCache.shared.store(endCards: fresh, for: videoId)
                }
            }
        } else if !info.endCards.isEmpty {
            endCards = info.endCards
            playerLog.notice("endCards: \(info.endCards.count) from primary response")
            await VideoPreloadCache.shared.store(endCards: info.endCards, for: video.id)
        } else {
            do {
                let webCards = try await api.fetchEndCards(videoId: video.id)
                guard !Task.isCancelled else { return }
                endCards = webCards
                playerLog.notice("endCards: \(webCards.count) from web client fallback")
                await VideoPreloadCache.shared.store(endCards: webCards, for: video.id)
            } catch {
                playerLog.error("endCards fetch failed: \(error.localizedDescription)")
                endCards = []
            }
        }

        guard !Task.isCancelled else { return }

        // --- Tracking URLs ---
        let resolvedTrackingURLs: PlaybackTrackingURLs?
        if let cachedTracking = cachedTrackingURLs {
            resolvedTrackingURLs = cachedTracking
            playerLog.notice("cache HIT: trackingURLs")
        } else {
            resolvedTrackingURLs = await authTrackingTask?.value ?? info.trackingURLs
            await VideoPreloadCache.shared.store(trackingURLs: resolvedTrackingURLs, for: video.id)
        }
        guard !Task.isCancelled else { return }
        tracker.setTrackingURLs(resolvedTrackingURLs)
        playerLog.notice("activeTrackingURLs resolved: \(resolvedTrackingURLs != nil ? "account-bound" : "none")")

        // BUG-015 fix: read currentAuthToken per-prefetch-call so a token refresh mid-loop
        // uses the fresh token rather than a stale snapshot captured before the loop starts.
        // TEMP DISABLED: neighbour prefetch — forcing fresh playerInfo fetch on every tap
        // let neighbourIds = Array(relatedVideos.prefix(3).map(\.id))
        // let sponsorCats = settings.activeSponsorCategories
        // Task(priority: .background) { [weak self] in
        //     for videoId in neighbourIds {
        //         let token = await MainActor.run { self?.currentAuthToken }
        //         await VideoPreloadCache.shared.prefetch(
        //             videoId: videoId,
        //             sponsorCategories: sponsorCats,
        //             authToken: token,
        //             priority: .speculative
        //         )
        //     }
        // }
    }
}
