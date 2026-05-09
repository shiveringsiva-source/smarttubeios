import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - AuthServiceRetryTests

@Suite("Auth Retry Resilience")
struct AuthServiceRetryTests {

    /// Verifies that InnerTubeAPI is initialised with a URLSession configured for
    /// transient-network resilience: short per-request timeout (20 s) so retries
    /// kick in quickly, a generous resource timeout (60 s), and waitsForConnectivity
    /// so that a momentary offline state does not immediately fail auth requests.
    @Test func innerTubeAPIURLSessionConfiguredForTransientNetworkResilience() async {
        let api = InnerTubeAPI()
        let config = await api.session.configuration
        #expect(config.timeoutIntervalForRequest == 20)
        #expect(config.timeoutIntervalForResource == 60)
        #expect(config.waitsForConnectivity)
    }
}
