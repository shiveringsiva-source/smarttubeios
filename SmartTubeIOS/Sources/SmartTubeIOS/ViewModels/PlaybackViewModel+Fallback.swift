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
            lastAttemptedStreamURL = fallbackURL
            let fallbackItem = AVPlayerItem(url: fallbackURL)
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
            player.replaceCurrentItem(with: fallbackItem)
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
        } catch {
            playerLog.error("❌ Fallback player fetch failed: \(String(describing: error))")
            self.error = originalError
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
            lastAttemptedStreamURL = freshURL
            let recoveryItem = AVPlayerItem(url: freshURL)
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
            player.replaceCurrentItem(with: recoveryItem)
            player.rate = Float(settings.playbackSpeed)
            isPlaying = true
        } catch {
            playerLog.error("❌ 403 recovery fetch failed: \(String(describing: error)) — falling back to Android client")
            await retryWithFallbackPlayer(video: video, originalError: originalError)
        }
    }
}
