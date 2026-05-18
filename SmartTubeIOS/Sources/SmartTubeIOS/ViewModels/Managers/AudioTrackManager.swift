import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - AudioTrackDelegate

@MainActor
protocol AudioTrackDelegate: AnyObject {
    var settings: AppSettings { get set }
}

// MARK: - AudioTrackManager

/// Owns `availableAudioTracks`, `selectedAudioTrack`, `audioSelectionGroup`,
/// and `audioOptionsByID`. Logic migrated from PlaybackViewModel+AudioTracks.swift.
@MainActor
@Observable
final class AudioTrackManager {

    // MARK: - State

    var availableAudioTracks: [AudioTrack] = []
    var selectedAudioTrack: AudioTrack? = nil

    // AVMediaSelectionGroup is not Sendable — keep nonisolated(unsafe) on MainActor class
    @ObservationIgnored nonisolated(unsafe) var audioSelectionGroup: AVMediaSelectionGroup? = nil
    @ObservationIgnored var audioOptionsByID: [String: AVMediaSelectionOption] = [:]

    // MARK: - Dependencies

    @ObservationIgnored weak var delegate: (any AudioTrackDelegate)?
    let player: AVPlayer

    // MARK: - Init

    init(player: AVPlayer) {
        self.player = player
    }

    // MARK: - Interface

    func reset() {
        availableAudioTracks = []
        selectedAudioTrack = nil
        audioSelectionGroup = nil
        audioOptionsByID = [:]
    }

    /// Switches to `track`, or resets to the HLS default when `nil`.
    /// Persists the language code in `AppSettings`.
    func selectAudioTrack(_ track: AudioTrack?) {
        selectedAudioTrack = track
        delegate?.settings.preferredAudioLanguage = track?.languageCode
        guard let item = player.currentItem, let group = audioSelectionGroup else { return }
        if let track, let option = audioOptionsByID[track.id] {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
        playerLog.notice("Audio → \(track?.name ?? "Auto (preference cleared)")")
    }

    /// Loads alternate audio renditions from the HLS manifest of `item` and auto-applies
    /// the user's saved language preference.
    func loadAudioTracks(from item: AVPlayerItem) {
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            // Fix #126: HLS variant playlists (loaded when quality changes) expose only
            // one audio rendition. The previous guard `count > 1` silently exited,
            // leaving no audio option selected → silent video after a quality switch.
            // Use `!isEmpty` so a single-track manifest still gets its track applied.
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
                  !group.options.isEmpty else { return }
            var tracks: [AudioTrack] = []
            var optionMap: [String: AVMediaSelectionOption] = [:]
            for (_, option) in group.options.enumerated() {
                let locale = option.locale?.identifier
                    ?? option.extendedLanguageTag
                    ?? "unknown"
                let displayName = option.locale.flatMap { loc -> String? in
                    let name = Locale.current.localizedString(forLanguageCode: loc.identifier)
                    if let name, !name.isEmpty { return name }
                    // Fall back to English locale when the device locale cannot resolve the code.
                    return Locale(identifier: "en_US").localizedString(forLanguageCode: loc.identifier)
                } ?? locale
                // Phase 1: use AVFoundation's authoritative "main program content" characteristic.
                // YouTube sets CHARACTERISTICS="public.main-program-content" on the creator's
                // original audio. AI-dubbed tracks receive DEFAULT=YES for locale matching but
                // typically do NOT carry this characteristic.
                let anyOptionHasMainContent = group.options.contains {
                    $0.hasMediaCharacteristic(.isMainProgramContent)
                }
                let isOriginal: Bool
                if anyOptionHasMainContent {
                    isOriginal = option.hasMediaCharacteristic(.isMainProgramContent)
                } else {
                    // Phase 2: fall back to HLS DEFAULT=YES (existing behaviour for manifests
                    // that do not use CHARACTERISTICS tags — e.g. older YouTube manifests).
                    // Use object identity (===) instead of value equality (==): AVMediaSelectionOption
                    // does not reliably implement Equatable and == can return true for multiple
                    // options in the same group, causing all tracks to display "Original".
                    isOriginal = group.defaultOption.map { $0 === option } ?? false
                }
                let track = AudioTrack(id: locale, name: displayName,
                                       languageCode: locale, isOriginal: isOriginal)
                tracks.append(track)
                optionMap[locale] = option
            }
            self.audioSelectionGroup = group
            self.audioOptionsByID = optionMap

            // Fix #124: When a quality switch loads a variant playlist with fewer
            // audio renditions than the original HLS master (e.g., a variant URL that
            // lacks EXT-X-MEDIA entries for alternate languages), preserve the existing
            // track list so the picker button stays visible. Re-apply the current
            // selection to the new item so audio continues correctly.
            if !self.availableAudioTracks.isEmpty, tracks.count < self.availableAudioTracks.count {
                let selectedID = self.selectedAudioTrack?.id
                if let selectedID, let option = optionMap[selectedID] {
                    item.select(option, in: group)
                } else if let defaultOption = group.defaultOption {
                    item.select(defaultOption, in: group)
                }
                playerLog.notice("Quality variant: \(tracks.count) audio rendition(s) vs \(self.availableAudioTracks.count) known — preserved track list, re-applied selection")
                return
            }

            self.availableAudioTracks = tracks

            let preferred = self.delegate?.settings.preferredAudioLanguage
            let autoSelect: AudioTrack? = {
                if let lang = preferred {
                    if lang == "original" {
                        return tracks.first(where: \.isOriginal) ?? tracks.first
                    }
                    if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
                    let base = lang.components(separatedBy: "-").first ?? lang
                    return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                        ?? tracks.first(where: \.isOriginal)
                }
                for deviceLang in Locale.preferredLanguages {
                    if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
                    let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
                    if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
                }
                if let original = tracks.first(where: \.isOriginal) { return original }
                let englishPrefixes = ["en-", "en_"]
                if let english = tracks.first(where: { $0.languageCode == "en" })
                    ?? tracks.first(where: { lang in englishPrefixes.contains(where: { lang.languageCode.hasPrefix($0) }) }) {
                    return english
                }
                return tracks.first
            }()
            self.selectedAudioTrack = autoSelect
            if let autoSelect, let option = optionMap[autoSelect.id] {
                item.select(option, in: group)
            }
            playerLog.notice("Audio tracks: \(tracks.map(\.name).joined(separator: ", ")) — auto-selected: \(autoSelect?.name ?? "default")")
        }
    }
}
