import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Stream Format / HLS Quality Selection

extension PlaybackViewModel {

    /// Switch to a specific quality. Pass `nil` to return to Auto (no resolution cap).
    ///
    /// All quality switching reloads the HLS item with `preferredMaximumResolution` set
    /// on the new `AVPlayerItem` before it starts loading. Direct CDN adaptive URLs
    /// (both c=IOS and c=ANDROID) return HTTP 403 because YouTube's CDN now requires
    /// Proof-of-Origin tokens (`id=o-*`) that AVURLAsset cannot provide. The HLS path
    /// through `manifest.googlevideo.com` is the only reliable stream path.
    public func selectFormat(_ format: VideoFormat?) {
        selectedFormat = format
        qualityTask?.cancel()
        qualityTask = nil
        let savedTime = currentTime
        qualityTask = Task { [weak self] in
            await self?.reloadHLSItem(seekTo: savedTime, qualityCap: format?.height)
        }
    }

    /// Rebuilds the HLS player item from the stored `playerInfo`.
    /// Sets `preferredMaximumResolution` on the new item before loading so AVPlayer
    /// respects the cap from the first variant-selection pass — setting it on an
    /// already-playing item after ABR has settled does not trigger a quality switch.
    func reloadHLSItem(seekTo time: TimeInterval, qualityCap: Int?) async {
        guard let hlsURL = playerInfo?.hlsURL else { return }
        guard !Task.isCancelled else { return }
        let uaOpts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]
        ]
        // Use the specific single-quality variant playlist URL when available.
        // This eliminates AVPlayer's ABR algorithm — the player has only one quality
        // to choose from and cannot switch to a higher variant.
        // For Auto mode (nil cap) or unknown heights, fall back to the master URL.
        let streamURL: URL
        if let cap = qualityCap, let variantURL = hlsVariantURLs[cap] {
            streamURL = variantURL
            playerLog.notice("Quality → \(cap)p via direct variant playlist")
        } else {
            streamURL = hlsURL
            playerLog.notice("Quality → \(qualityCap.map { "\($0)p" } ?? "Auto") via HLS master (reloaded)")
        }
        itemObserverTask?.cancel()
        let asset = AVURLAsset(url: streamURL, options: uaOpts)
        let item = AVPlayerItem(asset: asset)
        if let cap = qualityCap, hlsVariantURLs[cap] == nil {
            // No direct variant URL — fall back to preferredMaximumResolution hint.
            let h = CGFloat(cap)
            item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
        }
        itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                if status == .readyToPlay, time > 0 {
                    self.seek(to: time)
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    /// Fetches the HLS master manifest and returns a map of stream height → variant playlist URL.
    /// Parses consecutive `#EXT-X-STREAM-INF` / URI pairs. Uses the iOS User-Agent so
    /// YouTube's manifest server responds correctly.
    /// Returns an empty dict on network or parse failure — callers treat that as
    /// "manifest unavailable, show all formats" rather than "manifest has no variants".
    func fetchHLSVariantURLs(url: URL) async -> [Int: URL] {
        var request = URLRequest(url: url)
        request.setValue(InnerTubeClients.iOS.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            playerLog.notice("HLS manifest fetch failed — showing all quality options")
            return [:]
        }
        var variants: [Int: URL] = [:]
        // Track whether the stored URL for each height is an avc1 (H.264) variant.
        var variantIsH264: [Int: Bool] = [:]
        let baseURL = url.deletingLastPathComponent()
        let lines = text.components(separatedBy: .newlines)
        var pendingHeight: Int? = nil
        var pendingIsH264: Bool = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                // Lines look like: #EXT-X-STREAM-INF:BANDWIDTH=...,RESOLUTION=1920x1080,CODECS="avc1...",...
                pendingHeight = nil
                pendingIsH264 = false
                if let range = trimmed.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                    let match = String(trimmed[range])
                    if let xIdx = match.firstIndex(of: "x"),
                       let height = Int(match[match.index(after: xIdx)...]) {
                        pendingHeight = height
                    }
                }
                // Detect H.264 by looking for avc1 in the CODECS attribute.
                if let codecsRange = trimmed.range(of: #"CODECS="[^"]*""#, options: .regularExpression) {
                    pendingIsH264 = trimmed[codecsRange].contains("avc1")
                }
            } else if !trimmed.hasPrefix("#"), !trimmed.isEmpty, let height = pendingHeight {
                // The line immediately after #EXT-X-STREAM-INF is the variant URI.
                let variantURL: URL?
                if trimmed.hasPrefix("http") {
                    variantURL = URL(string: trimmed)
                } else {
                    variantURL = URL(string: trimmed, relativeTo: baseURL).map { URL(string: $0.absoluteString) } ?? nil
                }
                if let resolvedURL = variantURL {
                    // Prefer avc1 (H.264) variants — store this URL if we don't have one yet,
                    // or if what we have is non-H.264 and this one is H.264.
                    let existingIsH264 = variantIsH264[height] ?? false
                    if variants[height] == nil || (!existingIsH264 && pendingIsH264) {
                        variants[height] = resolvedURL
                        variantIsH264[height] = pendingIsH264
                    }
                }
                pendingHeight = nil
                pendingIsH264 = false
            } else if trimmed.hasPrefix("#") {
                // Any other directive between #EXT-X-STREAM-INF and its URI resets the pending state.
                if pendingHeight != nil, !trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                    pendingHeight = nil
                    pendingIsH264 = false
                }
            }
        }
        playerLog.notice("HLS manifest parsed: heights=\(variants.keys.sorted().reversed())")
        return variants
    }

    static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        let candidates = formats.filter { $0.url != nil && $0.height > 0 }
        var seen = Set<String>()
        var result: [VideoFormat] = []
        for fmt in candidates.sorted(by: {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            // Prefer mp4 over webm for the same height+fps — AVPlayer plays mp4 natively.
            let lhsMp4 = $0.mimeType.hasPrefix("video/mp4")
            let rhsMp4 = $1.mimeType.hasPrefix("video/mp4")
            if lhsMp4 != rhsMp4 { return lhsMp4 }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }) {
            let key = "\(fmt.height):\(fmt.fps)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(fmt)
            }
        }
        return result
    }
}
