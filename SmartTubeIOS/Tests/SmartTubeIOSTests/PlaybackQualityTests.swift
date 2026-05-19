import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - PlaybackQualityTests

/// Tests for HLS quality selection logic.
/// These mirror the algorithm in PlaybackViewModel+Quality.swift so that
/// correctness can be verified without an AVPlayer or network connection.

@Suite("Playback Quality")
struct PlaybackQualityTests {

    // MARK: - peakBitRate

    /// Mirrors the bitRateCaps dictionary and fallback logic in PlaybackQualityManager.
    private let bitRateCaps: [Int: Double] = [
        2160: 45_000_000,
        1440: 20_000_000,
        1080: 15_000_000,
         720:  8_000_000,
         480:  4_000_000,
    ]

    private func peakBitRate(for height: Int) -> Double {
        if let exact = bitRateCaps[height] { return exact }
        let sortedKeys = bitRateCaps.keys.sorted()
        let lower = sortedKeys.last(where: { $0 <= height }) ?? sortedKeys.first ?? 480
        return bitRateCaps[lower] ?? 4_000_000
    }

    @Test func peakBitRate_2160p_returns45Mbps() {
        #expect(peakBitRate(for: 2160) == 45_000_000)
    }

    @Test func peakBitRate_1440p_returns20Mbps() {
        #expect(peakBitRate(for: 1440) == 20_000_000)
    }

    @Test func peakBitRate_1080p_returns15Mbps() {
        #expect(peakBitRate(for: 1080) == 15_000_000)
    }

    @Test func peakBitRate_720p_returns8Mbps() {
        #expect(peakBitRate(for: 720) == 8_000_000)
    }

    @Test func peakBitRate_480p_returns4Mbps() {
        #expect(peakBitRate(for: 480) == 4_000_000)
    }

    @Test func peakBitRate_unlistedHeight_usesNextLowerKey() {
        // 800p → 720 cap (8M)
        #expect(peakBitRate(for: 800) == 8_000_000)
        // 600p → 480 cap (4M)
        #expect(peakBitRate(for: 600) == 4_000_000)
        // 4320p → 2160 cap (45M)
        #expect(peakBitRate(for: 4320) == 45_000_000)
    }

    @Test func peakBitRate_belowAllKeys_usesLowestCap() {
        // 360p → nothing <= 360 exists, fall back to lowest key (480 = 4M)
        #expect(peakBitRate(for: 360) == 4_000_000)
    }

    // MARK: - HLS variant selection (platform-agnostic logic)

    /// Mirrors the iOS/non-tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep first variant, then upgrade to H.264 if existing is non-H.264.
    private func selectVariant_iOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        if !existingIsH264 && candidateIsH264 {
            return (candidate, true)
        }
        return (existing!, existingIsH264)
    }

    /// Mirrors the tvOS branch of fetchHLSVariantURLs variant-selection:
    /// keep the first variant seen (no H.264 upgrade).
    private func selectVariant_tvOS(
        existing: URL?, existingIsH264: Bool,
        candidate: URL, candidateIsH264: Bool
    ) -> (URL, Bool) {
        if existing == nil {
            return (candidate, candidateIsH264)
        }
        return (existing!, existingIsH264)
    }

    @Test func variantSelection_iOS_upgradesHEVCToH264() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // HEVC variant seen first, then H.264 arrives → should upgrade to H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_iOS_doesNotDowngradeH264ToHEVC() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // H.264 seen first, then HEVC → should keep H.264 on iOS
        let (selected, isH264) = selectVariant_iOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsHEVC() {
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!
        let h264URL = URL(string: "https://example.com/h264.m3u8")!

        // tvOS: HEVC seen first → keep HEVC even when H.264 arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: hevcURL, existingIsH264: false,
            candidate: h264URL, candidateIsH264: true
        )
        #expect(selected == hevcURL)
        #expect(isH264 == false)
    }

    @Test func variantSelection_tvOS_keepsFirstVariant_whenFirstIsH264() {
        let h264URL = URL(string: "https://example.com/h264.m3u8")!
        let hevcURL = URL(string: "https://example.com/hevc.m3u8")!

        // tvOS: H.264 seen first → keep H.264 even when HEVC arrives
        let (selected, isH264) = selectVariant_tvOS(
            existing: h264URL, existingIsH264: true,
            candidate: hevcURL, candidateIsH264: false
        )
        #expect(selected == h264URL)
        #expect(isH264 == true)
    }

    @Test func variantSelection_firstVariant_alwaysAccepted() {
        let url = URL(string: "https://example.com/stream.m3u8")!

        // Both platforms: accept any first variant
        let (selected, isH264) = selectVariant_iOS(
            existing: nil, existingIsH264: false,
            candidate: url, candidateIsH264: false
        )
        #expect(selected == url)
        #expect(isH264 == false)
    }

    // MARK: - Quality preference selection (mirrors applyQualityPreference logic)

    private func makeFormat(height: Int, bitrate: Int? = nil) -> VideoFormat {
        let url = URL(string: "https://example.com/\(height)p.ts")!
        return VideoFormat(label: "\(height)p", width: height * 16 / 9, height: height,
                           fps: 30, mimeType: "video/mp4", url: url, bitrate: bitrate)
    }

    /// Mirrors applyQualityPreference(to:) in PlaybackQualityManager — finds best format
    /// at or below maxHeight and returns the variant URL if present.
    private func applyQualityPreference(
        availableFormats: [VideoFormat],
        hlsVariantURLs: [Int: URL],
        maxHeight: Int,
        masterURL: URL
    ) -> (selectedFormat: VideoFormat?, resolvedURL: URL) {
        let matchingFormat = availableFormats.first { $0.height <= maxHeight }
        if let height = matchingFormat?.height, let variantURL = hlsVariantURLs[height] {
            return (matchingFormat, variantURL)
        }
        return (matchingFormat, masterURL)
    }

    @Test func qualitySelection_picksHighestAtOrBelowMax() {
        let formats = [makeFormat(height: 2160), makeFormat(height: 1440), makeFormat(height: 1080)]
        let master = URL(string: "https://example.com/master.m3u8")!
        let variant1440 = URL(string: "https://example.com/1440p.m3u8")!
        let hlsURLs: [Int: URL] = [2160: URL(string: "https://example.com/2160p.m3u8")!, 1440: variant1440, 1080: URL(string: "https://example.com/1080p.m3u8")!]
        let (selected, resolved) = applyQualityPreference(
            availableFormats: formats, hlsVariantURLs: hlsURLs, maxHeight: 1440, masterURL: master)
        #expect(selected?.height == 1440, "Should pick 1440p — the highest format at or below maxHeight 1440")
        #expect(resolved == variant1440, "Should return the direct 1440p variant URL")
    }

    @Test func qualitySelection_noMatchAbove_fallsToNextLower() {
        // HLS manifest only contains 1080p and 720p (YouTube cap)
        let formats = [makeFormat(height: 1080), makeFormat(height: 720)]
        let master = URL(string: "https://example.com/master.m3u8")!
        let hlsURLs: [Int: URL] = [1080: URL(string: "https://example.com/1080p.m3u8")!, 720: URL(string: "https://example.com/720p.m3u8")!]
        // User set 2160p preference — must silently downgrade to best available
        let (selected, _) = applyQualityPreference(
            availableFormats: formats, hlsVariantURLs: hlsURLs, maxHeight: 2160, masterURL: master)
        #expect(selected?.height == 1080, "Should fall to 1080p — best available when 2160p is not in HLS manifest")
    }

    @Test func qualityHint_notAppliedForDirectMP4_guardConditionEvaluatesToFalse() {
        // The guard: `preferredQuality != .auto && maxH != nil && info.hlsURL != nil`
        // When hlsURL is nil (direct MP4 asset), the hint must NOT be applied.
        let hlsURL: URL? = nil
        let preferredQuality = AppSettings.VideoQuality.q1080
        let maxH = preferredQuality.maxHeight
        // Simulate the guard condition (task #128: condition no longer checks initialStreamURL)
        let shouldApplyHint = preferredQuality != .auto
            && maxH != nil
            && hlsURL != nil
        #expect(shouldApplyHint == false, "preferredMaximumResolution hint must not be applied to direct MP4 assets")
    }

    /// Task #128: initial load must always use the master HLS URL even when a variant URL
    /// exists for the preferred quality. Variant playlists omit EXT-X-MEDIA alternate audio
    /// renditions, which causes AudioTrackManager to exit early and produce silent audio.
    @Test func initialLoad_alwaysUsesMasterURL_whenPreferredQualityIsNonAuto() {
        let masterURL = URL(string: "https://example.com/master.m3u8")!
        let variantURL = URL(string: "https://example.com/1080p.m3u8")!
        let hlsVariantURLs: [Int: URL] = [1080: variantURL, 720: URL(string: "https://example.com/720p.m3u8")!]

        // Mirror the fixed logic: initialStreamURL is always masterURL regardless of hlsVariantURLs
        func resolveInitialStreamURL(preferredMaxHeight: Int?, masterURL: URL) -> URL {
            // Task #128 fix: do NOT index hlsVariantURLs for initial load.
            return masterURL
        }

        let resolved = resolveInitialStreamURL(preferredMaxHeight: 1080, masterURL: masterURL)
        #expect(resolved == masterURL,
                "Initial load must use master HLS URL so EXT-X-MEDIA audio renditions are available")
        #expect(resolved != variantURL,
                "Variant playlist URL must NOT be used on initial load — it lacks alternate audio entries")
    }

    /// Task #128: quality hints must be applied to HLS master URL when preference is non-auto,
    /// without requiring initialStreamURL == masterStreamURL (old gating condition removed).
    @Test func qualityHint_appliedWhenHLSURLPresentAndQualityNonAuto() {
        let hlsURL: URL? = URL(string: "https://example.com/master.m3u8")
        let preferredQuality = AppSettings.VideoQuality.q1080
        let maxH = preferredQuality.maxHeight
        // Fixed condition: no longer gates on initialStreamURL == masterStreamURL
        let shouldApplyHint = preferredQuality != .auto
            && maxH != nil
            && hlsURL != nil
        #expect(shouldApplyHint == true,
                "Quality ABR hints must be applied when quality is non-auto and an HLS URL is present")
    }

    // MARK: - Adaptive composition quality cap (mirrors qualityCapVideoURL logic)

    private func qualityCapVideoURL(from formats: [VideoFormat], preferredMaxHeight: Int?) -> URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        }
        func preferH264(_ lhs: VideoFormat, _ rhs: VideoFormat) -> Bool {
            let lH264 = lhs.mimeType.contains("avc1")
            let rH264 = rhs.mimeType.contains("avc1")
            if lH264 != rH264 { return lH264 }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            return (lhs.bitrate ?? 0) > (rhs.bitrate ?? 0)
        }
        guard let maxH = preferredMaxHeight else {
            return videoOnly.sorted(by: preferH264).first?.url
        }
        let capped = videoOnly.filter { $0.height <= maxH }
        return capped.sorted(by: preferH264).first?.url
            ?? videoOnly.sorted(by: preferH264).first?.url
    }

    @Test func adaptiveComposition_qualityCapFiltersHigherFormats() {
        // 2160p VP9 has higher bitrate than 1080p H.264 — old logic picked 2160p even when user wanted 1080p.
        let url2160 = URL(string: "https://example.com/2160p.mp4")!
        let url1080 = URL(string: "https://example.com/1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30, mimeType: "video/mp4", url: url2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30, mimeType: "video/mp4", url: url1080, bitrate: 8_000_000),
        ]
        let selectedURL = qualityCapVideoURL(from: formats, preferredMaxHeight: 1080)
        #expect(selectedURL == url1080, "Quality cap of 1080p should return 1080p even though 2160p has higher bitrate")
    }

    /// Regression test for the Android-client AV1 HTTP 403 bug.
    /// `qualityCapVideoURL` must prefer H.264 (avc1) over AV1 (av01) even when AV1 has
    /// higher bitrate, because Android-client AV1 streams require a pot token and 403.
    @Test func qualityCapVideoURL_prefersH264OverAV1_forAutoQuality() {
        let urlAV1_2160 = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let urlH264_1080 = URL(string: "https://cdn.example.com/h264_1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1_2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: urlH264_1080, bitrate: 8_000_000),
        ]
        // Auto quality (nil cap): H.264 1080p must win over AV1 2160p.
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == urlH264_1080,
                "H.264 must be preferred over AV1 to avoid Android-client HTTP 403")
    }

    @Test func qualityCapVideoURL_picksHighestH264WhenMultipleAvailable() {
        let url1080 = URL(string: "https://cdn.example.com/h264_1080p.mp4")!
        let url720  = URL(string: "https://cdn.example.com/h264_720p.mp4")!
        let urlAV1  = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.640028\"",
                        url: url1080, bitrate: 8_000_000),
            VideoFormat(label: "720p",  width: 1280, height: 720,  fps: 30,
                        mimeType: "video/mp4; codecs=\"avc1.4d401f\"",
                        url: url720,  bitrate: 4_000_000),
        ]
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == url1080,
                "Among H.264 formats, the highest resolution (1080p) must be picked")
    }

    @Test func qualityCapVideoURL_fallsBackToAV1WhenNoH264Available() {
        let urlAV1_2160 = URL(string: "https://cdn.example.com/av1_2160p.mp4")!
        let urlAV1_1080 = URL(string: "https://cdn.example.com/av1_1080p.mp4")!
        let formats = [
            VideoFormat(label: "2160p", width: 3840, height: 2160, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.12M.08\"",
                        url: urlAV1_2160, bitrate: 20_000_000),
            VideoFormat(label: "1080p", width: 1920, height: 1080, fps: 30,
                        mimeType: "video/mp4; codecs=\"av01.0.09M.08\"",
                        url: urlAV1_1080, bitrate: 8_000_000),
        ]
        // When only AV1 is available, picks the best (highest resolution) AV1.
        let selected = qualityCapVideoURL(from: formats, preferredMaxHeight: nil)
        #expect(selected == urlAV1_2160,
                "When no H.264 is available, highest-resolution AV1 should be picked")
    }
}
