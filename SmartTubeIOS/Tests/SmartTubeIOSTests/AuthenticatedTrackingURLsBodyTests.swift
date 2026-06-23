import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - AuthenticatedTrackingURLsBodyTests
//
// Regression test for the #51/#78 follow-up: even with auth correctly attached,
// fetchAuthenticatedTrackingURLs() consistently got back a TV /player response
// with videoDetails/playabilityStatus but no playbackTracking at all — confirmed
// live, every single video. The original request body sent only
// videoId/racyCheckOk/contentCheckOk; fetchPlayerInfoAuthenticated's body (used
// for the actual streaming-data fetch, which DOES get tracking data back in
// practice) additionally sends visitorData, playbackContext.contentPlaybackContext,
// and a poToken attestation — i.e. it looks like a genuine playback session.
//
// These tests verify buildTrackingURLsBody() now matches that richer shape, and
// that fetchAuthenticatedTrackingURLs() still correctly extracts tracking URLs
// when the (mocked) response does include playbackTracking.

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (statusCode: Int, body: Data)] = [:]
    /// Captured request bodies keyed by URL substring match — lets tests inspect
    /// what was actually sent without crossing the actor boundary with a raw
    /// [String: Any] (which isn't Sendable).
    nonisolated(unsafe) static var capturedBodies: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        if let body = request.httpBodyOrAccumulated() {
            for key in Self.responses.keys where url.contains(key) {
                Self.capturedBodies[key] = body
            }
        }
        let match = Self.responses.filter { url.contains($0.key) }.max(by: { $0.key.count < $1.key.count })
        let (statusCode, body) = match.map { ($0.value.statusCode, $0.value.body) } ?? (200, Data("{}".utf8))
        let httpResponse = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// `httpBody` is nil for requests created via `URLSession`'s body-from-Data
    /// path in some configurations; `httpBodyStream` is the alternate path.
    /// Try both so the captured body is reliable across delegate/protocol setups.
    func httpBodyOrAccumulated() -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}

@Suite("Authenticated tracking URLs body shape (#51/#78 follow-up)", .serialized)
struct AuthenticatedTrackingURLsBodyTests {

    private func makeAPI(authToken: String? = "fake-token") -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return InnerTubeAPI(authToken: authToken, session: session)
    }

    @Test("the actual /player request body includes playbackContext.contentPlaybackContext")
    func requestBodyIncludesPlaybackContext() async {
        StubURLProtocol.responses = [
            "youtube.com/": (200, Data("\"STS\":12345".utf8)),
            "att/get": (200, Data("{}".utf8)),
            "player": (200, Data("{}".utf8))
        ]
        StubURLProtocol.capturedBodies = [:]
        let api = makeAPI()
        _ = await api.fetchAuthenticatedTrackingURLs(videoId: "testvid123")

        guard let playerBodyData = StubURLProtocol.capturedBodies["player"],
              let body = try? JSONSerialization.jsonObject(with: playerBodyData) as? [String: Any] else {
            Issue.record("No request body captured for /player")
            return
        }
        let playbackContext = body["playbackContext"] as? [String: Any]
        let cpbc = playbackContext?["contentPlaybackContext"] as? [String: Any]
        #expect(cpbc != nil, "Body must include playbackContext.contentPlaybackContext — its absence is why playbackTracking never came back from YouTube")
        #expect(cpbc?["html5Preference"] as? String == "HTML5_PREF_WANTS")
        #expect(body["videoId"] as? String == "testvid123")
        #expect(body["racyCheckOk"] as? Bool == true)
        #expect(body["contentCheckOk"] as? Bool == true)
    }

    @Test("fetchAuthenticatedTrackingURLs extracts URLs when playbackTracking is present")
    func extractsTrackingURLsWhenPresent() async {
        let playerResponse: [String: Any] = [
            "videoDetails": ["videoId": "testvid123"],
            "playabilityStatus": ["status": "OK"],
            "playbackTracking": [
                "videostatsPlaybackUrl": ["baseUrl": "https://www.youtube.com/api/stats/playback?ns=yt"],
                "videostatsWatchtimeUrl": ["baseUrl": "https://www.youtube.com/api/stats/watchtime?ns=yt"]
            ]
        ]
        let responseData = try! JSONSerialization.data(withJSONObject: playerResponse)
        StubURLProtocol.responses = [
            "youtube.com/": (200, Data("\"STS\":12345".utf8)),
            "att/get": (200, Data("{}".utf8)),
            "player": (200, responseData)
        ]
        let api = makeAPI()
        let result = await api.fetchAuthenticatedTrackingURLs(videoId: "testvid123")

        #expect(result != nil, "Must extract tracking URLs from a response that includes playbackTracking")
        #expect(result?.playbackURL.absoluteString.contains("api/stats/playback") == true)
        #expect(result?.watchtimeURL.absoluteString.contains("api/stats/watchtime") == true)
    }

    @Test("fetchAuthenticatedTrackingURLs returns nil without an auth token")
    func returnsNilWithoutToken() async {
        let api = makeAPI(authToken: nil)
        let result = await api.fetchAuthenticatedTrackingURLs(videoId: "testvid123")
        #expect(result == nil)
    }
}
