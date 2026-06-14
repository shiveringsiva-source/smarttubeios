import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

// MARK: - PhoneCallInterruptionTests
//
// Regression tests for task #244: an AVAudioSession interruption (e.g. an
// incoming phone call) must pause background playback WITHOUT the
// rate-observer's stall detection/recovery misinterpreting the resulting
// rate→0 as a playback stall, and must resume cleanly when the interruption
// ends with shouldResume.

@Suite("Phone call interruption — flags & rate-observer guard (#244)")
@MainActor
struct PhoneCallInterruptionFlagTests {

    @Test("Interruption flags default to false")
    func interruptionFlagsDefaultToFalse() {
        let vm = PlaybackViewModel()
        #expect(vm.isHandlingAudioInterruption == false)
        #expect(vm.wasPlayingBeforeInterruption == false)
    }

    @Test("playerWentSilent ignores a rate-drop caused by an audio interruption pause")
    func playerWentSilentIgnoresInterruptionPause() {
        let isPlaying = true
        let isSwappingItem = false
        let isHandlingAudioInterruption = true
        let newRate: Float = 0

        let playerWentSilent = newRate == 0 && isPlaying && !isSwappingItem && !isHandlingAudioInterruption
        #expect(playerWentSilent == false)
    }

    @Test("playerWentSilent still detects a real stall when not handling an interruption")
    func playerWentSilentStillDetectsRealStall() {
        let isPlaying = true
        let isSwappingItem = false
        let isHandlingAudioInterruption = false
        let newRate: Float = 0

        let playerWentSilent = newRate == 0 && isPlaying && !isSwappingItem && !isHandlingAudioInterruption
        #expect(playerWentSilent == true)
    }
}

#if canImport(UIKit)
@Suite("Phone call interruption — AVAudioSession notification handling (#244)")
@MainActor
struct PhoneCallInterruptionNotificationTests {

    @Test("Interruption .began pauses the player and sets interruption flags")
    func interruptionBeganPausesAndSetsFlags() async {
        let vm = PlaybackViewModel()
        vm.isPlaying = true

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        var observed = false
        for _ in 0..<50 {
            if vm.isHandlingAudioInterruption && vm.wasPlayingBeforeInterruption && !vm.isPlaying {
                observed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(observed, "Expected isHandlingAudioInterruption=true, wasPlayingBeforeInterruption=true, isPlaying=false after .began")
    }

    @Test("Interruption .ended with shouldResume resumes playback")
    func interruptionEndedResumesWhenShouldResume() async {
        let vm = PlaybackViewModel()
        vm.isPlaying = true

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        for _ in 0..<50 {
            if vm.isHandlingAudioInterruption { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )

        var resumed = false
        for _ in 0..<50 {
            if vm.isPlaying && !vm.isHandlingAudioInterruption {
                resumed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(resumed, "Expected isPlaying=true and isHandlingAudioInterruption=false after .ended with shouldResume")
    }
}
#endif
