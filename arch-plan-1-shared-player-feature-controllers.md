# Plan 1: Shared player-feature controllers (Like/Dislike, Sleep Timer, Comments)

## Goal

Eliminate the near-duplicate Like/Dislike, Sleep Timer, and Comments
implementations between the standard player stack
(`PlaybackViewModel` + `PlayerView`) and the TOS player stack
(`TOSPlayerViewModel` + `TOSPlayerView`) by extracting three small,
independently-testable controller classes plus one shared SwiftUI view.
Each view model becomes a thin adapter that wires environment-specific bits
(video-id resolution, pause action, logger) into the shared controller.

This is "Candidate 1" from the architecture review. Two real adapters
already exist (standard + TOS), so this is a real seam, not a hypothetical
one.

## Current duplication (verified file:line)

| Feature | Standard | TOS |
|---|---|---|
| Like/Dislike | [PlaybackViewModel+LikeDislike.swift](SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+LikeDislike.swift) (48 lines) | [TOSPlayerViewModel+LikeDislike.swift](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+LikeDislike.swift) (56 lines) |
| Sleep Timer | [PlaybackViewModel+SleepTimer.swift](SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+SleepTimer.swift) (26 lines) | [TOSPlayerViewModel+SleepTimer.swift](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+SleepTimer.swift) (36 lines) |
| Comments state+fetch | `PlayerView.swift:40-43` (`@State`) + `PlayerView+Overlays.swift:364-376` (`loadComments`) | `TOSPlayerViewModel.swift` (`videoComments`/`isLoadingComments`) + [TOSPlayerViewModel+Comments.swift](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+Comments.swift) |
| Comments overlay view | `PlayerView+Overlays.swift:308-360` (`commentsOverlay`) | `TOSPlayerView.swift:468-517` (`commentsOverlay`) — already a near-verbatim copy made this session |

Differences between the two adapters today:
- LikeDislike: standard guards on `currentVideo?.id` (optional); TOS uses
  `self.videoId` (always present). Loggers differ (`CrashlyticsLogger` vs
  `os.Logger`).
- SleepTimer: the fire handler differs — standard does
  `player.pause(); isPlaying = false`; TOS calls `self.pause()` (JS bridge)
  and logs a notice.
- Comments: standard keeps `videoComments`/`isLoadingComments`/`commentsAPI`
  as `@State` on the **View**; TOS keeps them on the **view model** (this
  session's addition). The video-id resolution also differs: standard uses
  `(vm.playerInfo?.video ?? video).id`, TOS uses `self.videoId`.

## Design

New directory: `Sources/SmartTubeIOS/PlayerFeatures/` containing three
`@MainActor @Observable` controller classes and one shared SwiftUI view.
Each controller's interface is parameterized only by the small bits that
genuinely differ between AVPlayer-based and JS-bridge-based playback —
everything else (the optimistic update/rollback dance, the timer
bookkeeping, the load-once guard) lives in one place.

### `LikeDislikeController`
```swift
@MainActor @Observable
final class LikeDislikeController {
    private(set) var likeStatus: LikeStatus = .none
    init(api: InnerTubeAPI, videoId: @escaping () -> String?, logError: @escaping (String) -> Void)
    func like()
    func dislike()
}
```
`videoId` returns `nil` to no-op (covers standard's `currentVideo?.id`
optionality; TOS's closure always returns a value).

### `SleepTimerController`
```swift
@MainActor @Observable
final class SleepTimerController {
    private(set) var sleepTimerMinutes: Int? = nil
    init(onFire: @escaping () -> Void)
    func setSleepTimer(minutes: Int?)
}
```
`onFire` is supplied once at init — standard passes
`{ player.pause(); isPlaying = false }`, TOS passes
`{ self.pause(); tosLog.notice(...) }` (preserves the existing log line).

### `CommentsController`
```swift
@MainActor @Observable
final class CommentsController {
    private(set) var comments: [Comment] = []
    private(set) var isLoading = false
    init(api: InnerTubeAPI)
    func load(videoId: String)   // no-op if already loaded or in flight
}
```
`videoId` is passed per-call (not baked into the controller) so each adapter
can keep its own video-id resolution logic at the call site — standard's
`(vm.playerInfo?.video ?? video).id` vs TOS's `self.videoId`.

### `CommentsOverlayView` (shared SwiftUI view)
Extracted from the two near-identical `commentsOverlay` bodies. Lives
outside any `!os(tvOS)` guard (standard `PlayerView` renders it on tvOS
too).
```swift
struct CommentsOverlayView: View {
    let comments: [Comment]
    let isLoading: Bool
    let onDismiss: () -> Void
    #if os(tvOS)
    var focusNamespace: Namespace.ID
    #endif
    var accessibilityId: String? = nil
}
```
tvOS-only `.focusScope`/`.onExitCommand` stay behind `#if os(tvOS)` inside
this view.

## Steps

1. **Like/Dislike**
   - Create `PlayerFeatures/LikeDislikeController.swift` with the design
     above; body is the existing optimistic-update/rollback logic (verbatim
     from either file — they're identical apart from id resolution and
     logger).
   - `PlaybackViewModel`: replace stored `likeStatus` with
     `let likeDislike: LikeDislikeController`, constructed in `init` with
     `videoId: { [weak self] in self?.currentVideo?.id }` and a
     `CrashlyticsLogger`-backed `logError`. Add forwarding
     `public var likeStatus: LikeStatus { likeDislike.likeStatus }`,
     `public func like() { likeDislike.like() }`,
     `public func dislike() { likeDislike.dislike() }`.
   - `TOSPlayerViewModel`: same shape, `videoId: { [weak self] in self?.videoId }`,
     `os.Logger`-backed `logError`.
   - Delete `PlaybackViewModel+LikeDislike.swift` and
     `TOSPlayerViewModel+LikeDislike.swift`.
   - `grep -rn "\.likeStatus\s*=" Sources/` to confirm no other call site
     mutates `likeStatus` directly (only `like()`/`dislike()` should).
   - Build: `swift build --target SmartTubeIOS`.

2. **Sleep Timer**
   - Create `PlayerFeatures/SleepTimerController.swift`.
   - `PlaybackViewModel`: replace `sleepTimerMinutes`/`sleepTimerTask` with
     `let sleepTimer: SleepTimerController`, constructed with
     `onFire: { [weak self] in self?.player.pause(); self?.isPlaying = false }`.
     Add forwarding `sleepTimerMinutes` + `setSleepTimer(minutes:)`.
   - `TOSPlayerViewModel`: same shape,
     `onFire: { [weak self] in self?.pause(); tosLog.notice("[sleepTimer] fired — pausing playback") }`.
   - Delete `PlaybackViewModel+SleepTimer.swift` and
     `TOSPlayerViewModel+SleepTimer.swift`.
   - Build: `swift build --target SmartTubeIOS`.

3. **Comments controller + state migration**
   - Create `PlayerFeatures/CommentsController.swift`.
   - `PlaybackViewModel`: add `let comments: CommentsController`
     (constructed with `api`).
   - `PlayerView.swift`: remove `@State videoComments`, `@State
     isLoadingComments`, `@State commentsAPI` (and the
     `_commentsAPI = State(initialValue: api)` line at `PlayerView.swift:119`).
   - `PlayerView+Overlays.swift`: rewrite `loadComments()` to compute
     `videoId = (vm.playerInfo?.video ?? video).id` and call
     `vm.comments.load(videoId: videoId)`. Update `commentsOverlay` to read
     `vm.comments.comments` / `vm.comments.isLoading`. In
     `moreMenuCommentsRow`, the `if videoComments.isEmpty &&
     !isLoadingComments` guard becomes redundant (the controller
     self-guards) — remove it, just call `loadComments()`.
   - `TOSPlayerViewModel.swift`: remove the `videoComments`/`isLoadingComments`
     stored properties added this session; add
     `let comments: CommentsController`.
   - `TOSPlayerViewModel+Comments.swift`: rewrite `loadComments()` to
     `comments.load(videoId: videoId)`.
   - `TOSPlayerView.swift`: update `commentsOverlay` to read
     `vm.comments.comments` / `vm.comments.isLoading`.
   - Build: `swift build --target SmartTubeIOS`.

4. **Shared `CommentsOverlayView`**
   - Create `PlayerFeatures/CommentsOverlayView.swift` per the design above.
   - Replace `PlayerView+Overlays.commentsOverlay` body with a call to
     `CommentsOverlayView(comments: vm.comments.comments, isLoading:
     vm.comments.isLoading, onDismiss: { showCommentsSheet = false },
     focusNamespace: commentsOverlayNamespace)`.
   - Replace `TOSPlayerView.commentsOverlay` body with
     `CommentsOverlayView(comments: vm.comments.comments, isLoading:
     vm.comments.isLoading, onDismiss: { showCommentsSheet = false },
     accessibilityId: "tosPlayer.commentsOverlay")`.
   - Build: `swift build --target SmartTubeIOS`.

5. **Final verification**
   - Full `swift build`.
   - `grep -rn "videoComments\|isLoadingComments\|commentsAPI\|sleepTimerTask"
     Sources/` to confirm no stale references remain.
   - Smoke-check: launch app, open standard player more-menu → Like, Dislike,
     Sleep Timer, Comments; repeat in TOS player.

## Non-goals

- Not touching `SponsorBlock`, caches, or `PlaybackViewModel+Fallback.swift`
  (separate plans).
- Not changing any user-visible behavior, copy, or accessibility identifiers
  beyond what's required to share the overlay view.
