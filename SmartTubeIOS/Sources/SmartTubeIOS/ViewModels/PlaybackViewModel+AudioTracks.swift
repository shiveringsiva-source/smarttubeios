import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Audio Track Selection

extension PlaybackViewModel {

    /// Switches to `track`, or resets to the HLS default when `nil`.
    /// Persists the language code in `AppSettings` so subsequent videos auto-apply the preference.
    public func selectAudioTrack(_ track: AudioTrack?) {
        selectedAudioTrack = track
        settings.preferredAudioLanguage = track?.languageCode  // nil clears the preference
        guard let item = player.currentItem, let group = audioSelectionGroup else { return }
        if let track, let option = audioOptionsByID[track.id] {
            item.select(option, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
        playerLog.notice("Audio → \(track?.name ?? "Auto (preference cleared)")")
    }

    /// Loads alternate audio renditions from the HLS manifest of `item` and auto-applies
    /// the user's saved language preference. No-ops when the manifest has ≤ 1 rendition.
    func loadAudioTracks(from item: AVPlayerItem) {
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
                  group.options.count > 1 else { return }
            var tracks: [AudioTrack] = []
            var optionMap: [String: AVMediaSelectionOption] = [:]
            for (index, option) in group.options.enumerated() {
                let locale = option.locale?.identifier
                    ?? option.extendedLanguageTag
                    ?? "unknown"
                let displayName = option.locale.flatMap {
                    Locale.current.localizedString(forLanguageCode: $0.identifier)
                } ?? locale
                // Use the HLS DEFAULT=YES flag to identify the original track — not AVPlayer's
                // automatic selection, which follows device locale and would wrongly mark an
                // AI-dubbed track as "original" on non-English devices.
                // When the manifest has no DEFAULT=YES (group.defaultOption == nil), treat
                // the first rendition as original — YouTube orders originals first.
                let isDefault = group.defaultOption != nil ? group.defaultOption == option : index == 0
                let track = AudioTrack(id: locale, name: displayName,
                                       languageCode: locale, isOriginal: isDefault)
                tracks.append(track)
                optionMap[locale] = option
            }
            self.audioSelectionGroup = group
            self.audioOptionsByID = optionMap
            self.availableAudioTracks = tracks

            // Auto-apply the user's saved language preference (fuzzy-match on base language).
            // When no preference is saved, prefer the device's language order over the HLS
            // DEFAULT track — YouTube sets DEFAULT=YES based on the viewer's account language,
            // not the video's original language, so blind DEFAULT selection gives wrong results
            // (e.g. German for an English video when the account UI is in German).
            let preferred = self.settings.preferredAudioLanguage
            let autoSelect: AudioTrack? = {
                guard let lang = preferred else {
                    for deviceLang in Locale.preferredLanguages {
                        if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
                        let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
                        if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
                    }
                    return tracks.first(where: \.isOriginal)
                }
                if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
                let base = lang.components(separatedBy: "-").first ?? lang
                return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                    ?? tracks.first(where: \.isOriginal)
            }()
            self.selectedAudioTrack = autoSelect
            // Always explicitly select so AVPlayer doesn't override with a locale-based pick.
            if let autoSelect, let option = optionMap[autoSelect.id] {
                item.select(option, in: group)
            }
            playerLog.notice("Audio tracks: \(tracks.map(\.name).joined(separator: ", ")) — auto-selected: \(autoSelect?.name ?? "default")")
        }
    }
}
