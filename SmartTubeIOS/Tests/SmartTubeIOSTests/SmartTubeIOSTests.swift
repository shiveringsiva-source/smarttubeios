import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - VideoModelTests

@Suite("Video Model")
struct VideoModelTests {

    @Test func formattedDurationMinutesSeconds() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 125)
        #expect(video.formattedDuration == "2:05")
    }

    @Test func formattedDurationWithHours() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel", duration: 3661)
        #expect(video.formattedDuration == "1:01:01")
    }

    @Test func formattedDurationNil() {
        let video = Video(id: "test", title: "Test", channelTitle: "Channel")
        #expect(video.formattedDuration == "")
    }

    @Test func formattedViewCountThousands() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 1_500)
        #expect(video.formattedViewCount == "1.5K views")
    }

    @Test func formattedViewCountMillions() {
        let video = Video(id: "v", title: "T", channelTitle: "C", viewCount: 2_000_000)
        #expect(video.formattedViewCount == "2.0M views")
    }

    @Test func highQualityThumbnailURL() {
        let video = Video(id: "dQw4w9WgXcQ", title: "T", channelTitle: "C")
        #expect(video.highQualityThumbnailURL == URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"))
    }

    @Test func videoHashableAndEquatable() {
        let v1 = Video(id: "abc", title: "A", channelTitle: "X")
        let v2 = Video(id: "abc", title: "A", channelTitle: "X")
        let v3 = Video(id: "xyz", title: "B", channelTitle: "Y")
        #expect(v1 == v2)
        #expect(v1 != v3)
    }
}

// MARK: - VideoGroupTests

@Suite("Video Group")
struct VideoGroupTests {

    @Test func defaultSections() {
        let sections = BrowseSection.defaultSections
        #expect(!sections.isEmpty)
        #expect(sections.first?.type == .home)
    }

    @Test func videoGroupAppend() {
        var group = VideoGroup(title: "Home", videos: [
            Video(id: "1", title: "V1", channelTitle: "C"),
        ])
        group.videos.append(Video(id: "2", title: "V2", channelTitle: "C"))
        #expect(group.videos.count == 2)
    }
}

// MARK: - AppSettingsTests

@Suite("App Settings")
struct AppSettingsTests {

    @Test func defaultSettings() {
        let settings = AppSettings()
        #expect(settings.preferredQuality == .auto)
        #expect(settings.playbackSpeed == 1.0)
        #expect(settings.autoplayEnabled)
        #expect(!settings.subtitlesEnabled)
        #expect(settings.sponsorBlockEnabled)
        #expect(!settings.deArrowEnabled)
        #expect(settings.themeName == .system)
    }

    @Test func settingsEncodeDecode() throws {
        var settings = AppSettings()
        settings.preferredQuality    = .q1080
        settings.playbackSpeed       = 1.5
        settings.sponsorBlockEnabled = false

        let data    = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded.preferredQuality == AppSettings.VideoQuality.q1080)
        #expect(decoded.playbackSpeed == 1.5)
        #expect(!decoded.sponsorBlockEnabled)
    }
}

// MARK: - SponsorSegmentTests

@Suite("Sponsor Segment")
struct SponsorSegmentTests {

    @Test func segmentInRange() {
        let seg = SponsorSegment(start: 30.0, end: 60.0, category: .sponsor)
        #expect(45.0 >= seg.start && 45.0 < seg.end)
        #expect(!(25.0 >= seg.start && 25.0 < seg.end))
    }

    @Test func allCategoryRawValuesUnique() {
        let raws = SponsorSegment.Category.allCases.map { $0.rawValue }
        #expect(Set(raws).count == raws.count)
    }
}

// MARK: - VideoFormatTests

@Suite("Video Format")
struct VideoFormatTests {

    @Test func qualityLabel30fps() {
        let f = VideoFormat(label: "720p", width: 1280, height: 720, fps: 30, mimeType: "video/mp4")
        #expect(f.qualityLabel == "720p")
    }

    @Test func qualityLabel60fps() {
        let f = VideoFormat(label: "1080p60", width: 1920, height: 1080, fps: 60, mimeType: "video/mp4")
        #expect(f.qualityLabel == "1080p60")
    }
}

// MARK: - SubscriptionParsingTests
// Validates that the InnerTubeAPI parser handles the gridVideoRenderer format used
// in the YouTube FEsubscriptions response.

@Suite("Subscription Parsing")
struct SubscriptionParsingTests {

    /// Minimal mock of the `onResponseReceivedActions` structure returned
    /// by a successfully authenticated `POST /browse?browseId=FEsubscriptions` call.
    @Test func gridVideoRendererParsed() async throws {
        let mockSubscriptionsResponse: [String: Any] = [
            "responseContext": ["visitorData": "abc"],
            "trackingParams": "xyz",
            "onResponseReceivedActions": [
                [
                    "appendContinuationItemsAction": [
                        "continuationItems": [
                            [
                                "gridVideoRenderer": [
                                    "videoId": "dQw4w9WgXcQ",
                                    "title": ["runs": [["text": "Rick Astley - Never Gonna Give You Up"]]],
                                    "shortBylineText": [
                                        "runs": [
                                            [
                                                "text": "Rick Astley",
                                                "navigationEndpoint": [
                                                    "browseEndpoint": [
                                                        "browseId": "UCuAXFkgsw1L7xaCfnd5JJOw"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ],
                                    "thumbnail": [
                                        "thumbnails": [
                                            ["url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", "width": 480, "height": 360]
                                        ]
                                    ],
                                    "thumbnailOverlays": [
                                        [
                                            "thumbnailOverlayTimeStatusRenderer": [
                                                "text": ["simpleText": "3:33"],
                                                "style": "DEFAULT"
                                            ]
                                        ]
                                    ],
                                    "viewCountText": ["simpleText": "1,604,532,756 views"],
                                    "navigationEndpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ"]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockSubscriptionsResponse, title: "Subscriptions")

        #expect(group.videos.count == 1, "Should parse one gridVideoRenderer item")
        let video = try #require(group.videos.first)
        #expect(video.id == "dQw4w9WgXcQ")
        #expect(video.title == "Rick Astley - Never Gonna Give You Up")
        #expect(video.channelTitle == "Rick Astley")
        #expect(video.channelId == "UCuAXFkgsw1L7xaCfnd5JJOw")
        #expect(video.duration == 213)   // 3m 33s
    }

    @Test func videoRendererStillParsed() async throws {
        let mockHomeResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [
                        [
                            "tabRenderer": [
                                "content": [
                                    "richGridRenderer": [
                                        "contents": [
                                            [
                                                "richItemRenderer": [
                                                    "content": [
                                                        "videoRenderer": [
                                                            "videoId": "abc123",
                                                            "title": ["runs": [["text": "Test Video"]]],
                                                            "ownerText": ["runs": [["text": "Test Channel"]]],
                                                            "thumbnail": ["thumbnails": [
                                                                ["url": "https://i.ytimg.com/vi/abc123/hqdefault.jpg"]
                                                            ]],
                                                            "lengthText": ["simpleText": "10:00"]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockHomeResponse, title: "Home")
        #expect(group.videos.count == 1, "richItemRenderer->videoRenderer should still parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "abc123")
        #expect(video.duration == 600)  // 10:00 = 600s
    }
}

// MARK: - HistoryParsingTests
// Reproduces the "history shows only shorts" bug:
// TVHTML5 FEhistory tileRenderers can use either
//   onSelectCommand.watchEndpoint.videoId  (classic path)
//   onSelectCommand.innertubeCommand.watchEndpoint.videoId  (newer TV variant)
//   navigationEndpoint.watchEndpoint.videoId  (another TVHTML5 variant)
// Previously only the classic path was tried, causing all regular-video tiles
// to be silently dropped — leaving only reelItemRenderer (Shorts) visible.

@Suite("History Parsing")
struct HistoryParsingTests {

    // Mock that mirrors the classic TVHTML5 tileRenderer path
    // (onSelectCommand → watchEndpoint → videoId).
    @Test func tileRendererClassicPath() async throws {
        let mockResponse = makeTileResponse(videoId: "classic1", useInnertubeWrapper: false, useNavigation: false)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "Classic onSelectCommand.watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "classic1")
        #expect(!video.isShort)
    }

    // Mock that mirrors the newer TVHTML5 variant where watchEndpoint is nested
    // under onSelectCommand → innertubeCommand → watchEndpoint → videoId.
    @Test func tileRendererInnertubeCommandPath() async throws {
        let mockResponse = makeTileResponse(videoId: "inner1", useInnertubeWrapper: true, useNavigation: false)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "innertubeCommand-wrapped watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "inner1")
        #expect(!video.isShort)
    }

    // Mock that mirrors the TVHTML5 variant using navigationEndpoint instead of onSelectCommand.
    @Test func tileRendererNavigationEndpointPath() async throws {
        let mockResponse = makeTileResponse(videoId: "nav1", useInnertubeWrapper: false, useNavigation: true)
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "navigationEndpoint.watchEndpoint path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "nav1")
        #expect(!video.isShort)
    }

    // Shorts in TVHTML5 history come back as reelItemRenderer — verify they still parse
    // and are correctly tagged isShort = true.
    @Test func reelItemRendererParsedAsShort() async throws {
        let mockResponse: [String: Any] = [
            "contents": [
                "reelShelfRenderer": [
                    "items": [
                        [
                            "reelItemRenderer": [
                                "videoId": "reel1",
                                "headline": ["simpleText": "My Short"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1)
        let video = try #require(group.videos.first)
        #expect(video.id == "reel1")
        #expect(video.isShort)
    }

    // Mixed response: one regular tileRenderer (via innertubeCommand path) + one reelItemRenderer.
    // Before the fix history would only return 1 video (the Short); after the fix it returns 2.
    @Test func mixedHistoryBothRegularAndShort() async throws {
        let reelItem: [String: Any] = [
            "reelItemRenderer": [
                "videoId": "short1",
                "headline": ["simpleText": "A Short"]
            ]
        ]
        let tileItem: [String: Any] = [
            "tileRenderer": [
                "contentType": "TILE_CONTENT_TYPE_VIDEO",
                "onSelectCommand": [
                    "innertubeCommand": [
                        "watchEndpoint": ["videoId": "regular1"]
                    ]
                ],
                "metadata": [
                    "tileMetadataRenderer": [
                        "title": ["simpleText": "A Regular Video"]
                    ]
                ]
            ]
        ]
        let mockResponse: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [
                        ["itemSectionRenderer": ["contents": [tileItem]]],
                        ["itemSectionRenderer": ["contents": [reelItem]]]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 2, "Both regular tile and Short should appear in history")
        let ids = Set(group.videos.map { $0.id })
        #expect(ids.contains("regular1"))
        #expect(ids.contains("short1"))
        let regular = group.videos.first { $0.id == "regular1" }
        let short   = group.videos.first { $0.id == "short1" }
        #expect(regular?.isShort == false)
        #expect(short?.isShort == true)
    }

    // Reproduces the confirmed live-API path: tileRenderer carries videoId in tile.contentId
    // and onSelectCommand uses commandExecutorCommand (no watchEndpoint anywhere).
    // Shape confirmed by live fetchHistory log on 2026-04-03.
    @Test func tileRendererContentIdPath() async throws {
        let tileRenderer: [String: Any] = [
            "contentId": "RoLKhzJG3nc",
            "style": "TILE_STYLE_YTLR_DEFAULT",
            "onSelectCommand": [
                "clickTrackingParams": "abc",
                "commandExecutorCommand": ["commands": []]   // no watchEndpoint
            ],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "Test via contentId"]
                ]
            ]
        ]
        let mockResponse: [String: Any] = [
            "contents": [
                "tvBrowseRenderer": [
                    "content": [
                        "tvSurfaceContentRenderer": [
                            "content": [
                                "gridRenderer": [
                                    "items": [["tileRenderer": tileRenderer]]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(mockResponse, title: "History")
        #expect(group.videos.count == 1, "tileRenderer.contentId path should parse")
        let video = try #require(group.videos.first)
        #expect(video.id == "RoLKhzJG3nc")
        #expect(!video.isShort)
    }
}


// MARK: - Home Row Parsing Tests

@Suite("Home Row Parsing")
struct HomeRowParsingTests {

    // reelShelfRenderer at the top level of the home feed response should produce
    // a VideoGroup containing isShort == true videos.
    @Test func reelShelfRendererProducesShorts() async {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richSectionRenderer": [
                                                "content": [
                                                    "reelShelfRenderer": [
                                                        "title": ["simpleText": "Shorts"],
                                                        "items": [
                                                            [
                                                                "reelItemRenderer": [
                                                                    "videoId": "short1",
                                                                    "headline": ["simpleText": "A Short"]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let rows = await api.parseVideoGroupRowsForTesting(mockResponse)
        let shortsRow = rows.first { $0.videos.contains { $0.id == "short1" } }
        #expect(shortsRow != nil, "reelShelfRenderer should produce a row with shorts")
        #expect(shortsRow?.videos.first?.isShort == true)
    }

    // richShelfRenderer containing richItemRenderer wrapping a reelItemRenderer
    // (Shorts embedded inside a regular topic shelf) should surface the short.
    @Test func richShelfRendererWithEmbeddedReelItem() async {
        let mockResponse: [String: Any] = [
            "contents": [
                "twoColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "richGridRenderer": [
                                    "contents": [
                                        [
                                            "richShelfRenderer": [
                                                "title": ["simpleText": "Trending"],
                                                "contents": [
                                                    [
                                                        "richItemRenderer": [
                                                            "content": [
                                                                "reelItemRenderer": [
                                                                    "videoId": "embeddedShort1",
                                                                    "headline": ["simpleText": "Embedded Short"]
                                                                ]
                                                            ]
                                                        ]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let api = InnerTubeAPI()
        let rows = await api.parseVideoGroupRowsForTesting(mockResponse)
        let row = rows.first { $0.videos.contains { $0.id == "embeddedShort1" } }
        #expect(row != nil, "richShelfRenderer with embedded reelItemRenderer should produce a row")
        #expect(row?.videos.first?.isShort == true)
    }
}

// MARK: - Helpers


private func makeTileResponse(
    videoId: String,
    useInnertubeWrapper: Bool,
    useNavigation: Bool
) -> [String: Any] {
    let onSelectCommand: [String: Any]
    if useInnertubeWrapper {
        onSelectCommand = ["innertubeCommand": ["watchEndpoint": ["videoId": videoId]]]
    } else if !useNavigation {
        onSelectCommand = ["watchEndpoint": ["videoId": videoId]]
    } else {
        onSelectCommand = [:]
    }

    var tileRenderer: [String: Any] = [
        "contentType": "TILE_CONTENT_TYPE_VIDEO",
        "onSelectCommand": onSelectCommand,
        "metadata": ["tileMetadataRenderer": ["title": ["simpleText": "Test Video"]]]
    ]
    if useNavigation {
        tileRenderer["navigationEndpoint"] = ["watchEndpoint": ["videoId": videoId]]
    }

    return [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [
                                ["tileRenderer": tileRenderer]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    ]
}
