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
            for (_, option) in group.options.enumerated() {
                let locale = option.locale?.identifier
                    ?? option.extendedLanguageTag
                    ?? "unknown"
                let displayName = option.locale.flatMap {
                    Locale.current.localizedString(forLanguageCode: $0.identifier)
                } ?? locale
                // Only mark as original when the HLS manifest explicitly sets DEFAULT=YES.
                // When group.defaultOption == nil (no DEFAULT in the manifest), we cannot
                // determine the original track from position alone: YouTube sometimes lists
                // AI-dubbed tracks first, making index-0 an unreliable signal.
                let isOriginal = group.defaultOption != nil && group.defaultOption == option
                let track = AudioTrack(id: locale, name: displayName,
                                       languageCode: locale, isOriginal: isOriginal)
                tracks.append(track)
                optionMap[locale] = option
            }
            self.audioSelectionGroup = group
            self.audioOptionsByID = optionMap
            self.availableAudioTracks = tracks

            // Auto-select priority (highest → lowest):
            //  1. User's saved language preference (respects explicit manual selection).
            //  2. Track marked as original by HLS DEFAULT=YES — this is the authoritative
            //     signal from YouTube's manifest; prefer it over device language.
            //  3. English track ("en", "en-US", etc.) — most YouTube originals are English,
            //     so this is a better fallback than device language for un-marked manifests.
            //  4. Device preferred languages — only as last resort to avoid overriding the
            //     original with an AI-dubbed version for non-English device users.
            //  5. First track in list.
            //
            // Prior behaviour used device language before the DEFAULT track, which caused
            // AI-dubbed tracks to be selected on non-English devices (issue #24).
            let preferred = self.settings.preferredAudioLanguage
            let autoSelect: AudioTrack? = {
                // 1. Saved preference
                if let lang = preferred {
                    if let exact = tracks.first(where: { $0.languageCode == lang }) { return exact }
                    let base = lang.components(separatedBy: "-").first ?? lang
                    return tracks.first(where: { $0.languageCode.hasPrefix(base) })
                        ?? tracks.first(where: \.isOriginal)
                }
                // 2. HLS DEFAULT=YES original
                if let original = tracks.first(where: \.isOriginal) { return original }
                // 3. English track (common original language on YouTube)
                let englishPrefixes = ["en-", "en_"]
                if let english = tracks.first(where: { $0.languageCode == "en" })
                    ?? tracks.first(where: { lang in englishPrefixes.contains(where: { lang.languageCode.hasPrefix($0) }) }) {
                    return english
                }
                // 4. Device preferred languages
                for deviceLang in Locale.preferredLanguages {
                    if let exact = tracks.first(where: { $0.languageCode == deviceLang }) { return exact }
                    let base = deviceLang.components(separatedBy: "-").first ?? deviceLang
                    if let match = tracks.first(where: { $0.languageCode.hasPrefix(base) }) { return match }
                }
                // 5. First track
                return tracks.first
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
