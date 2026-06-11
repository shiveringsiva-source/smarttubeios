# Plan 2: Pure SponsorBlock decision engine

## Goal

Extract the "what should happen at this playback time" decision logic that
is currently duplicated (and subtly diverging) between
[SponsorBlockSkipManager.swift](SmartTubeIOS/Sources/SmartTubeIOSCore/SponsorBlockSkipManager.swift)
(AVPlayer-based, standard player) and
[TOSPlayerViewModel+SponsorBlock.swift](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+SponsorBlock.swift)
(JS-tick-based, TOS player) into one pure, unit-testable function. Each
adapter keeps its own seek mechanism, logging, and async-confirmation
plumbing — only the *decision* moves.

This is "Candidate 2" from the architecture review.

## Current duplication (verified)

Both `checkSponsorSkip(at:)` implementations do the same three things:
1. Find the segment containing `time` (`segments.first(where: { time >=
   $0.start && time < $0.end })`).
2. Switch on `settings.sponsorAction(for: seg.category)` →
   `.skip` / `.showToast` / `.nothing`.
3. For `.skip`: guard against re-triggering while a skip is already in
   flight, and (standard only, today) special-case "segment ends near the
   video's end" → end playback instead of seeking.

Where they've already diverged:
- Standard ([SponsorBlockSkipManager.swift:64-100](SmartTubeIOS/Sources/SmartTubeIOSCore/SponsorBlockSkipManager.swift)) checks
  `seg.end >= effectiveDuration - 2.0` and calls `delegate.handlePlaybackEnd()`
  instead of seeking. TOS
  ([TOSPlayerViewModel+SponsorBlock.swift:142-196](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+SponsorBlock.swift))
  has **no** end-of-video special case at all — a near-end sponsor segment
  on TOS will `seekTo()` past the end with no `handlePlaybackEnd()`
  equivalent. This is exactly the kind of drift the shared decision engine
  prevents.
- "Skip in progress" tracking differs: standard uses `isSkippingSegment:
  Bool` (reset ~200ms after the AVPlayer seek completion fires); TOS uses
  `activeSkipEnd: Double?` (cleared once `time >= activeSkipEnd`).

## Design

New file `Sources/SmartTubeIOSCore/SponsorBlockDecisionEngine.swift`:

```swift
public enum SponsorSkipDecision: Equatable {
    case clearToast
    case showToast(SponsorSegment)
    case skip(to: Double, segment: SponsorSegment)
    case skipToPlaybackEnd(segment: SponsorSegment)
    /// A skip segment is active but a skip is already in flight — do nothing.
    case none
}

public enum SponsorBlockDecisionEngine {
    /// Pure function: given the current time, loaded segments, settings, and
    /// whether a skip is already in flight, decide what should happen.
    /// `duration <= 0` disables the end-of-video special case (treated as
    /// "unknown duration").
    public static func decide(
        at time: Double,
        segments: [SponsorSegment],
        settings: AppSettings,
        isSkipInProgress: Bool,
        duration: Double
    ) -> SponsorSkipDecision {
        guard settings.sponsorBlockEnabled else { return .clearToast }
        guard let seg = segments.first(where: { time >= $0.start && time < $0.end }) else {
            return .clearToast
        }
        switch settings.sponsorAction(for: seg.category) {
        case .skip:
            guard !isSkipInProgress else { return .none }
            if duration > 0 && seg.end >= duration - 2.0 {
                return .skipToPlaybackEnd(segment: seg)
            }
            return .skip(to: seg.end, segment: seg)
        case .showToast:
            return .showToast(seg)
        case .nothing:
            return .clearToast
        }
    }
}
```

## Steps

1. **Create the decision engine**
   - Add `SmartTubeIOSCore/SponsorBlockDecisionEngine.swift` with the type
     above.
   - Build: `swift build --target SmartTubeIOSCore`.

2. **Wire into `SponsorBlockSkipManager`**
   - Replace the body of `checkSponsorSkip(at:)`
     ([SponsorBlockSkipManager.swift:59-100](SmartTubeIOS/Sources/SmartTubeIOSCore/SponsorBlockSkipManager.swift))
     with a call to `SponsorBlockDecisionEngine.decide(...)` passing
     `isSkipInProgress: isSkippingSegment` and
     `duration: player?.currentItem?.duration.seconds ?? delegate.duration`.
   - Switch on the result:
     - `.clearToast` → `currentToastSegment = nil`, return `false`.
     - `.showToast(seg)` → `currentToastSegment = seg`, return `false`.
     - `.skipToPlaybackEnd` → `delegate.handlePlaybackEnd()`, return `true`.
     - `.skip(to:, segment:)` → existing AVPlayer `seek(to:...)` +
       completion-handler block (`isSkippingSegment` true/false dance),
       return `true`.
     - `.none` → return `true` (matches existing
       `guard !isSkippingSegment else { return true }`).
   - Build + run any existing SponsorBlock unit tests.

3. **Wire into `TOSPlayerViewModel+SponsorBlock`**
   - Replace the segment-matching + switch in `checkSponsorSkip(at:)`
     ([TOSPlayerViewModel+SponsorBlock.swift:142-196](SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerViewModel+SponsorBlock.swift))
     with `SponsorBlockDecisionEngine.decide(...)` passing
     `isSkipInProgress: activeSkipEnd != nil` and `duration: duration`.
   - Switch on the result:
     - `.clearToast` → `currentToastSegment = nil` (also clear
       `activeSkipEnd` if `time >= activeSkipEnd`, as today).
     - `.showToast(seg)` → existing transition-logging +
       `currentToastSegment = seg`.
     - `.skip(to:, segment:)` → existing `pendingSkipLog` setup +
       `seekTo(seg.end)` + Darwin notification + `activeSkipEnd = seg.end`.
     - `.skipToPlaybackEnd(segment:)` → **new behavior for TOS** — call
       `pause()` (TOS has no `handlePlaybackEnd()`; confirm during
       implementation whether a TOS equivalent exists or whether `pause()`
       is the right substitute) and log it. This fixes the drift noted
       above.
     - `.none` → no-op (matches existing `guard activeSkipEnd == nil else { return }`).
   - Build: `swift build --target SmartTubeIOS`.

4. **Final verification**
   - Full `swift build`.
   - Re-run the SponsorBlock UI test(s) if present
     (`grep -rln SponsorBlock SmartTubeApp/UITests`) to confirm the
     auto-skip-toast/skip behavior is unchanged on both stacks, and that the
     new TOS end-of-video case doesn't regress normal playback-end handling.

## Open question for implementation

Step 3's `.skipToPlaybackEnd` case is new behavior for TOS (previously
absent). Confirm what "end playback" should mean for TOS — likely `pause()`
plus whatever the standard player's `handlePlaybackEnd()` does that's
meaningful in the TOS context (e.g. marking watch history complete). If TOS
already handles natural end-of-video via the JS bridge's `stateChange`
message reaching `.ended`, the simplest correct fix may be to just **not**
seek (i.e. let natural playback continue to the real end) rather than
synthesizing an early end — decide based on what `handlePlaybackEnd()`
actually does once read.

## Non-goals

- Not changing `PlaybackViewModel+SponsorBlock.swift` (it's a 17-line
  pass-through to `SponsorBlockSkipManager` already — no duplication there).
- Not touching cache (`VideoPreloadCache`/`fetchSponsorSegments`) — that's
  plan-3 territory if anything.
