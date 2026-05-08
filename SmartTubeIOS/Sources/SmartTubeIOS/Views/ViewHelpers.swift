import SwiftUI
import SmartTubeIOSCore

// MARK: - ShortsPresentation
//
// Shared Identifiable wrapper used by BrowseView and ChannelView to present
// ShortsPlayerView via .fullScreenCover(item:).

struct ShortsPresentation: Identifiable {
    let id = UUID()
    let videos: [Video]
    let startIndex: Int
}

// MARK: - ChannelDestination
//
// Identifiable wrapper used to drive navigationDestination(item:) for channel navigation
// triggered by the .openChannel NotificationCenter event.

struct ChannelDestination: Identifiable, Hashable {
    let channelId: String
    var id: String { channelId }
}

// MARK: - Shared layout constants

/// Adaptive grid columns used for video grids across Browse and Channel views.
/// tvOS: fixed 4 columns (flexible) — predictable across all TV sizes.
/// iOS: adaptive, ~2 columns on iPhone.
#if os(tvOS)
let videoGridColumns = [
    GridItem(.flexible(), spacing: 40),
    GridItem(.flexible(), spacing: 40),
    GridItem(.flexible(), spacing: 40),
    GridItem(.flexible(), spacing: 40)
]
let videoGridRowSpacing: CGFloat = 40
#else
let videoGridColumns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]
let videoGridRowSpacing: CGFloat = 12
#endif

// MARK: - DownloadAlertItem

/// Shared alert payload used by views that trigger video downloads.
struct DownloadAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - AppSymbol
//
// Single source of truth for SF Symbol names used across the app.
// Use these constants instead of raw strings in Image(systemName:) and Label(..., systemImage:).

enum AppSymbol {
    // MARK: - Navigation tabs
    static let home     = "house.fill"
    static let search   = "magnifyingglass"
    static let library  = "square.stack.fill"
    static let settings = "gearshape.fill"

    // MARK: - Navigation / chevrons
    static let chevronLeft  = "chevron.left"
    static let chevronUp    = "chevron.up"
    static let chevronDown  = "chevron.down"

    // MARK: - Playback controls
    static let previousTrack    = "backward.end.fill"
    static let nextTrack        = "forward.end.fill"
    static let previousChapter  = "backward.end.alt.fill"
    static let nextChapter      = "forward.end.alt.fill"
    static let thumbsUp      = "hand.thumbsup"
    static let thumbsDown    = "hand.thumbsdown"

    // MARK: - Actions
    static let checkmark       = "checkmark"
    static let xmark           = "xmark"
    static let xmarkCircle     = "xmark.circle.fill"
    static let share           = "square.and.arrow.up"
    static let copyDoc         = "doc.on.doc"
    static let download        = "arrow.down.to.line"
    static let watchLater      = "clock.badge"

    // MARK: - Status / info
    static let warning         = "exclamationmark.triangle.fill"
    static let clock           = "clock"
    static let questionCircle  = "questionmark.circle"
    static let qrcode          = "qrcode"

    // MARK: - People / account
    static let personCircle            = "person.crop.circle"
    static let personRectangle         = "person.crop.rectangle"
    static let personCircleQuestion    = "person.crop.circle.badge.questionmark"
    static let personCircleWarning     = "person.crop.circle.badge.exclamationmark"

    // MARK: - Content
    static let stackLayers    = "square.stack"
    static let tvMediabox     = "tv.and.mediabox"
    static let tvPlay         = "play.tv"
}
