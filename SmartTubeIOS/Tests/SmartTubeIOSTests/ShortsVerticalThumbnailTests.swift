import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - Shorts Vertical Thumbnail Misclassification Tests
//
// Regression tests for task #201: regular videos with portrait-oriented thumbnails
// were incorrectly classified as Shorts because the vertical-thumbnail detection
// signal in parseVideoRenderer and parseTileRenderer had no duration guard.
//
// Fix: added `&& (duration.map { $0 <= 180 } ?? true)` to the vertical-thumbnail
// signal in both parsers, matching the guard already applied to the other three signals.

// MARK: - Helpers (same shape as QPBPhase3RegressionTests.swift)

private func makeVideoRendererResponse(_ renderer: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["videoRenderer": renderer]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

private func makeTileRendererResponse(_ tile: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["tileRenderer": tile]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

// MARK: - Tests

@Suite("Shorts vertical-thumbnail misclassification regression (#201)")
struct ShortsVerticalThumbnailTests {

    // MARK: - parseVideoRenderer

    /// A long-form video (>3 min) with a portrait thumbnail must NOT be classified as Short.
    /// Before the fix, this returned isShort = true.
    @Test("videoRenderer: portrait thumbnail + long duration → isShort = false")
    func videoRendererPortraitThumbnailLongDuration() async throws {
        let renderer: [String: Any] = [
            "videoId": "longFormPortrait",
            "title": ["runs": [["text": "Long Movie Trailer"]]],
            "longBylineText": ["runs": [["text": "Movie Channel"]]],
            "lengthText": ["simpleText": "10:05"],  // 605 seconds
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/thumb.jpg", "width": 180, "height": 320]  // portrait 9:16
                ]
            ],
            "navigationEndpoint": [
                "watchEndpoint": ["videoId": "longFormPortrait"]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            makeVideoRendererResponse(renderer), title: "Search"
        )
        let video = try #require(group.videos.first)
        #expect(
            video.isShort == false,
            """
            A 605-second video with a portrait thumbnail must NOT be tagged isShort.
            The vertical-thumbnail signal must be gated on duration ≤ 180 s.
            """
        )
    }

    /// A genuine Short (≤60s) with a portrait thumbnail must still be classified as Short.
    @Test("videoRenderer: portrait thumbnail + short duration → isShort = true")
    func videoRendererPortraitThumbnailShortDuration() async throws {
        let renderer: [String: Any] = [
            "videoId": "genuineShort",
            "title": ["runs": [["text": "A Genuine Short"]]],
            "longBylineText": ["runs": [["text": "Creator"]]],
            "lengthText": ["simpleText": "0:45"],  // 45 seconds
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/thumb.jpg", "width": 180, "height": 320]  // portrait 9:16
                ]
            ],
            "navigationEndpoint": [
                "watchEndpoint": ["videoId": "genuineShort"]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            makeVideoRendererResponse(renderer), title: "Search"
        )
        let video = try #require(group.videos.first)
        #expect(
            video.isShort == true,
            "A 45-second video with a portrait thumbnail should be classified as Short"
        )
    }

    /// When duration is unknown (no lengthText), a portrait thumbnail should conservatively
    /// still trigger the Short classification (mirrors all other signal guards' default).
    @Test("videoRenderer: portrait thumbnail + unknown duration → isShort = true (conservative)")
    func videoRendererPortraitThumbnailNoDuration() async throws {
        let renderer: [String: Any] = [
            "videoId": "unknownDuration",
            "title": ["runs": [["text": "Upcoming Live"]]],
            "longBylineText": ["runs": [["text": "News Channel"]]],
            // No lengthText → duration = nil
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/thumb.jpg", "width": 180, "height": 320]
                ]
            ],
            "navigationEndpoint": [
                "watchEndpoint": ["videoId": "unknownDuration"]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            makeVideoRendererResponse(renderer), title: "Search"
        )
        let video = try #require(group.videos.first)
        #expect(
            video.isShort == true,
            "With unknown duration a portrait thumbnail conservatively triggers Short classification"
        )
    }

    // MARK: - parseTileRenderer

    /// A long-form video tile (TVHTML5) with a portrait thumbnail must NOT be classified as Short.
    @Test("tileRenderer: portrait thumbnail + long duration → isShort = false")
    func tileRendererPortraitThumbnailLongDuration() async throws {
        let tile: [String: Any] = [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "contentId": "tileLong",
            "onSelectCommand": [
                "watchEndpoint": ["videoId": "tileLong"]
            ],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "Long Documentary"],
                    "lines": [
                        ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "Docs Channel"]]]]]],
                        ["lineRenderer": ["items": [["lineItemRenderer": ["text": ["simpleText": "1:35:20"]]]]]],
                    ]
                ]
            ],
            "thumbnail": [
                "thumbnails": [
                    ["url": "https://example.com/thumb.jpg", "width": 180, "height": 320]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(
            makeTileRendererResponse(tile), title: "History"
        )
        let video = try #require(group.videos.first)
        #expect(
            video.isShort == false,
            "A 95-minute tile with portrait thumbnail must NOT be tagged isShort"
        )
    }
}
