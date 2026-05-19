import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - QualityDelegate

@MainActor
protocol QualityDelegate: AnyObject {
    var playerInfo: PlayerInfo? { get }
    var settings: AppSettings { get }
    var currentVideo: Video? { get }
    var currentTime: TimeInterval { get }
    var error: Error? { get set }
    var toastMessage: String? { get set }
    var isPlaying: Bool { get set }
    var isSwappingItem: Bool { get set }
    var itemObserverTask: Task<Void, Never>? { get set }
    func seek(to seconds: Double)
    func loadAudioTracks(from item: AVPlayerItem)
    func retryWith403Recovery(video: Video, originalError: Error?) async
}

// MARK: - PlaybackQualityManager

/// Owns `selectedFormat`, `availableFormats`, `hlsVariantURLs`, `qualityTask`, and
/// `hasAppliedH264Cap`. Logic migrated from PlaybackViewModel+Quality.swift.
@MainActor
@Observable
final class PlaybackQualityManager {

    // MARK: - State

    var selectedFormat: VideoFormat? = nil
    var availableFormats: [VideoFormat] = []
    var hlsVariantURLs: [Int: URL] = [:]
    var hasAppliedH264Cap: Bool = false
    @ObservationIgnored var qualityTask: Task<Void, Never>? = nil

    // MARK: - Dependencies

    @ObservationIgnored weak var delegate: (any QualityDelegate)?
    let player: AVPlayer

    // MARK: - Init

    init(player: AVPlayer) {
        self.player = player
    }

    // MARK: - Interface

    func reset() {
        selectedFormat = nil
        availableFormats = []
        hlsVariantURLs = [:]
        hasAppliedH264Cap = false
        qualityTask?.cancel()
        qualityTask = nil
    }

    func cancel() {
        qualityTask?.cancel()
        qualityTask = nil
    }

    /// Switch to a specific quality. Pass `nil` to return to Auto (no resolution cap).
    func selectFormat(_ format: VideoFormat?) {
        selectedFormat = format
        delegate?.toastMessage = format.map { "\($0.height)p" } ?? "Auto"
        qualityTask?.cancel()
        qualityTask = nil
        guard let delegate else { return }
        let savedTime = delegate.currentTime
        qualityTask = Task { [weak self] in
            await self?.reloadHLSItem(seekTo: savedTime, qualityCap: format?.height)
        }
    }

    /// Rebuilds the HLS player item from the stored `playerInfo`.
    func reloadHLSItem(seekTo time: TimeInterval, qualityCap: Int?) async {
        guard let hlsURL = delegate?.playerInfo?.hlsURL else { return }
        guard !Task.isCancelled else { return }
        let uaOpts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]
        ]
        let streamURL: URL
        if let cap = qualityCap, let variantURL = hlsVariantURLs[cap] {
            streamURL = variantURL
            playerLog.notice("Quality → \(cap)p via direct variant playlist")
        } else {
            streamURL = hlsURL
            playerLog.notice("Quality → \(qualityCap.map { "\($0)p" } ?? "Auto") via HLS master (reloaded)")
        }
        delegate?.itemObserverTask?.cancel()
        let asset = AVURLAsset(url: streamURL, options: uaOpts)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        if let cap = qualityCap, hlsVariantURLs[cap] == nil {
            let h = CGFloat(cap)
            item.preferredMaximumResolution = CGSize(width: h * 4, height: h)
            item.preferredPeakBitRate = peakBitRate(for: cap)
        }
        delegate?.itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    if time > 0 { self.delegate?.seek(to: time) }
                    self.player.rate = Float(self.delegate?.settings.playbackSpeed ?? 1)
                    self.delegate?.isPlaying = true
                    if let delegate = self.delegate {
                        delegate.loadAudioTracks(from: item)
                    }
                case .failed:
                    let err = item.error.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ Quality-switch AVPlayerItem failed: \(err)")
                    let nsErr = item.error as? NSError
                    let is403 = nsErr?.domain == NSURLErrorDomain && nsErr?.code == -1102
                    if is403, let video = self.delegate?.currentVideo {
                        playerLog.notice("Quality-switch 403 — invalidating cache and re-fetching player info")
                        await VideoPreloadCache.shared.invalidatePlayerInfo(for: video.id)
                        self.selectedFormat = nil
                        await self.delegate?.retryWith403Recovery(video: video, originalError: item.error)
                    } else if qualityCap != nil {
                        playerLog.notice("Quality-switch failed — reverting selectedFormat to Auto")
                        self.selectedFormat = nil
                        self.delegate?.toastMessage = "Quality unavailable — reverting to Auto"
                        await self.reloadHLSItem(seekTo: self.delegate?.currentTime ?? 0, qualityCap: nil)
                    } else if !self.hasAppliedH264Cap,
                              nsErr?.domain == AVFoundationErrorDomain,
                              nsErr?.code == -11833 {
                        playerLog.notice("Auto HLS Cannot Decode — retrying with H.264 bitrate cap")
                        self.hasAppliedH264Cap = true
                        self.delegate?.toastMessage = "Adjusting quality for this device…"
                        await self.reloadHLSItemH264Capped(seekTo: self.delegate?.currentTime ?? 0)
                    } else {
                        self.delegate?.error = item.error
                    }
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        delegate?.isSwappingItem = true
        player.replaceCurrentItem(with: item)
        delegate?.isSwappingItem = false
    }

    /// Selects the best stream URL for the current quality preference.
    /// Mutates `selectedFormat` to reflect the chosen format and returns a direct
    /// HLS variant URL when one is available, or `masterURL` otherwise.
    func applyQualityPreference(to masterURL: URL) -> URL {
        guard let settings = delegate?.settings,
              settings.preferredQuality != .auto,
              let maxH = settings.preferredQuality.maxHeight else {
            return masterURL
        }
        let matchingFormat = availableFormats.first { $0.height <= maxH }
        selectedFormat = matchingFormat
        if let height = matchingFormat?.height, let variantURL = hlsVariantURLs[height] {
            playerLog.notice("Quality \(maxH)p via direct variant playlist (fallback path)")
            return variantURL
        }
        playerLog.notice("Quality \(maxH)p — no variant URL, using master (fallback path)")
        return masterURL
    }

    /// Fetches the HLS master manifest and returns a map of stream height → variant playlist URL.
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
        var variantIsH264: [Int: Bool] = [:]
        let baseURL = url.deletingLastPathComponent()
        let lines = text.components(separatedBy: .newlines)
        var pendingHeight: Int? = nil
        var pendingIsH264: Bool = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                pendingHeight = nil
                pendingIsH264 = false
                if let range = trimmed.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                    let match = String(trimmed[range])
                    if let xIdx = match.firstIndex(of: "x"),
                       let height = Int(match[match.index(after: xIdx)...]) {
                        pendingHeight = height
                    }
                }
                if let codecsRange = trimmed.range(of: #"CODECS="[^"]*""#, options: .regularExpression) {
                    pendingIsH264 = trimmed[codecsRange].contains("avc1")
                }
            } else if !trimmed.hasPrefix("#"), !trimmed.isEmpty, let height = pendingHeight {
                let variantURL: URL?
                if trimmed.hasPrefix("http") {
                    variantURL = URL(string: trimmed)
                } else {
                    variantURL = URL(string: trimmed, relativeTo: baseURL).map { URL(string: $0.absoluteString) } ?? nil
                }
                if let resolvedURL = variantURL {
                    if variants[height] == nil {
                        variants[height] = resolvedURL
                        variantIsH264[height] = pendingIsH264
                    } else {
#if !os(tvOS)
                        if !(variantIsH264[height] ?? false) && pendingIsH264 {
                            variants[height] = resolvedURL
                            variantIsH264[height] = true
                        }
#endif
                    }
                }
                pendingHeight = nil
                pendingIsH264 = false
            } else if trimmed.hasPrefix("#") {
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

    static let bitRateCaps: [Int: Double] = [
        2160: 45_000_000,
        1440: 20_000_000,
        1080: 15_000_000,
         720:  8_000_000,
         480:  4_000_000,
    ]

    func peakBitRate(for height: Int) -> Double {
        if let exact = Self.bitRateCaps[height] { return exact }
        let sortedKeys = Self.bitRateCaps.keys.sorted()
        let lower = sortedKeys.last(where: { $0 <= height }) ?? sortedKeys.first ?? 480
        return Self.bitRateCaps[lower] ?? 4_000_000
    }

    func reloadHLSItemH264Capped(seekTo time: TimeInterval) async {
        guard let hlsURL = delegate?.playerInfo?.hlsURL else { return }
        guard !Task.isCancelled else { return }
        let uaOpts: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTubeClients.iOS.userAgent]
        ]
        let asset = AVURLAsset(url: hlsURL, options: uaOpts)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        item.preferredPeakBitRate = peakBitRate(for: 1080)
        delegate?.itemObserverTask?.cancel()
        delegate?.itemObserverTask = Task { [weak self] in
            for await status in item.statusStream {
                guard let self, !Task.isCancelled else { return }
                switch status {
                case .readyToPlay:
                    if time > 0 { self.delegate?.seek(to: time) }
                    self.player.rate = Float(self.delegate?.settings.playbackSpeed ?? 1)
                    self.delegate?.isPlaying = true
                    if let delegate = self.delegate {
                        delegate.loadAudioTracks(from: item)
                    }
                    playerLog.notice("✅ H.264-capped AVPlayerItem readyToPlay")
                case .failed:
                    let err = item.error.map { "\($0)" } ?? "nil"
                    playerLog.error("❌ H.264-capped AVPlayerItem also failed: \(err)")
                    self.delegate?.error = item.error
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
        delegate?.isSwappingItem = true
        player.replaceCurrentItem(with: item)
        delegate?.isSwappingItem = false
    }
}
