#if !os(tvOS)
import Foundation
import Testing
import SmartTubeIOSCore
@testable import SmartTubeIOS

@MainActor
@Suite("ShortsEmbedPlayerViewModel")
struct ShortsEmbedPlayerViewModelTests {

    @Test("Initial state before any loadShort() call")
    func initialState() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        #expect(vm.playerState == .unstarted)
        #expect(vm.currentTime == 0)
        #expect(vm.duration == 0)
        #expect(vm.isReady == false)
        #expect(vm.playerError == nil)
        #expect(vm.sponsorSegments.isEmpty)
        #expect(vm.currentToastSegment == nil)
        #expect(vm.sleepTimerMinutes == nil)
        #expect(vm.videoId == "")
    }

    @Test("updateSettings stores the new settings")
    func updateSettingsStoresNewSettings() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        var settings = AppSettings()
        settings.loopEnabled = true
        vm.updateSettings(settings)
        #expect(vm.settings.loopEnabled == true)
    }

    @Test("loadShort resets observable state for the new video")
    func loadShortResetsObservableState() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.playerState = .playing
        vm.currentTime = 42
        vm.duration = 60
        vm.isReady = true

        vm.loadShort(video: Video(id: "abc123", title: "Test Short", channelTitle: "Channel"))

        #expect(vm.videoId == "abc123")
        #expect(vm.playerState == .unstarted)
        #expect(vm.currentTime == 0)
        #expect(vm.duration == 0)
        #expect(vm.isReady == false)
    }

    @Test("checkSponsorSkip with no loaded segments does nothing")
    func checkSponsorSkipNoSegments() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.duration = 60

        vm.checkSponsorSkip(at: 5)

        #expect(vm.currentToastSegment == nil)
        #expect(vm.activeSkipEnd == nil)
        #expect(vm.pendingSkipLog == nil)
    }

    @Test("checkSponsorSkip auto-skips a sponsor segment and records a pending skip log")
    func checkSponsorSkipAutoSkipsSponsorSegment() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.duration = 60
        vm.sponsorSegments = [SponsorSegment(start: 5, end: 10, category: .sponsor)]

        vm.checkSponsorSkip(at: 6)

        #expect(vm.activeSkipEnd == 10)
        #expect(vm.currentToastSegment == nil)
        #expect(vm.pendingSkipLog?.category == .sponsor)
        #expect(vm.pendingSkipLog?.targetTime == 10)
    }

    @Test("checkSponsorSkip shows a toast for an intro segment instead of skipping")
    func checkSponsorSkipShowsToastForIntroSegment() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.duration = 60
        vm.sponsorSegments = [SponsorSegment(start: 5, end: 10, category: .intro)]

        vm.checkSponsorSkip(at: 6)

        #expect(vm.currentToastSegment?.category == .intro)
        #expect(vm.activeSkipEnd == nil)
        #expect(vm.pendingSkipLog == nil)
    }

    @Test("logSkipLanding clears the pending log once the seek lands")
    func logSkipLandingClearsPendingLogOnLanding() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.pendingSkipLog = PendingSkipLog(
            category: .sponsor, segmentStart: 5, segmentEnd: 10, beforeTime: 6, targetTime: 10
        )

        vm.logSkipLanding(at: 10)

        #expect(vm.pendingSkipLog == nil)
    }

    @Test("logSkipLanding times out after 16 ticks without landing")
    func logSkipLandingTimesOutWithoutLanding() {
        let vm = ShortsEmbedPlayerViewModel(api: InnerTubeAPI())
        vm.pendingSkipLog = PendingSkipLog(
            category: .sponsor, segmentStart: 5, segmentEnd: 10, beforeTime: 6, targetTime: 10
        )

        for _ in 0..<16 {
            vm.logSkipLanding(at: 6)
            #expect(vm.pendingSkipLog != nil)
        }
        vm.logSkipLanding(at: 6)

        #expect(vm.pendingSkipLog == nil)
    }
}
#endif
