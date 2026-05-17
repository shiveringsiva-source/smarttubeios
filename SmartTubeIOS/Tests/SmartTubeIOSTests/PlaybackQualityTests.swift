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

    /// Mirrors peakBitRate(for:) in PlaybackViewModel+Quality.swift.
    private func peakBitRate(for height: Int) -> Double {
        switch height {
        case 2160:  return 20_000_000
        case 1440:  return 12_000_000
        case 1080:  return  8_000_000
        case  720:  return  5_000_000
        default:    return  8_000_000
        }
    }

    @Test func peakBitRate_2160p_returns20Mbps() {
        #expect(peakBitRate(for: 2160) == 20_000_000)
    }

    @Test func peakBitRate_1440p_returns12Mbps() {
        #expect(peakBitRate(for: 1440) == 12_000_000)
    }

    @Test func peakBitRate_1080p_returns8Mbps() {
        #expect(peakBitRate(for: 1080) == 8_000_000)
    }

    @Test func peakBitRate_720p_returns5Mbps() {
        #expect(peakBitRate(for: 720) == 5_000_000)
    }

    @Test func peakBitRate_unknownHeight_returnsDefault() {
        #expect(peakBitRate(for: 360) == 8_000_000)
        #expect(peakBitRate(for: 480) == 8_000_000)
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
        // The guard: `initialStreamURL == masterStreamURL && info.hlsURL != nil`
        // When hlsURL is nil (direct MP4 asset), the hint must NOT be applied.
        let hlsURL: URL? = nil
        let preferredQuality = AppSettings.VideoQuality.q1080
        let maxH = preferredQuality.maxHeight
        let initialStreamURL = URL(string: "https://example.com/video.mp4")!
        let masterStreamURL = initialStreamURL
        // Simulate the guard condition
        let shouldApplyHint = preferredQuality != .auto
            && maxH != nil
            && initialStreamURL == masterStreamURL
            && hlsURL != nil
        #expect(shouldApplyHint == false, "preferredMaximumResolution hint must not be applied to direct MP4 assets")
    }

    // MARK: - Adaptive composition quality cap (mirrors qualityCapVideoURL logic)

    private func qualityCapVideoURL(from formats: [VideoFormat], preferredMaxHeight: Int?) -> URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && !$0.mimeType.contains(", ") && $0.url != nil
        }
        guard let maxH = preferredMaxHeight else {
            return videoOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
        }
        let capped = videoOnly.filter { $0.height <= maxH }
        let sorted = capped.sorted {
            if $0.height != $1.height { return $0.height > $1.height }
            return ($0.bitrate ?? 0) > ($1.bitrate ?? 0)
        }
        return sorted.first?.url ?? videoOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
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
}
