# Plan 4: Finish the HLS manifest-parsing extraction

## Goal

[PlaybackViewModel+Fallback.swift](SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Fallback.swift)
is the largest file in the codebase at 2734 lines. A prior task (referenced
in-file as "task #133, SRP-1") already extracted some pure HLS
manifest-parsing helpers into
`SmartTubeIOSCore/HLSManifestParser.swift` and
`SmartTubeIOSCore/HLSAudioLanguageParser.swift` — `parseHLSMasterManifest`,
`parseHLSAudioLanguages`, `extractQuotedHLSAttribute` are already free
functions in Core, called from `Fallback.swift` via thin private wrappers
(e.g. `Fallback.swift:2356-2358`).

This plan **finishes that extraction** for the three remaining pure-ish
manifest-parsing functions still private to `Fallback.swift`, following the
exact pattern already established. This is "Candidate 4" from the
architecture review, scoped down from a full file decomposition (see
Non-goals) to the lowest-risk, highest-value piece: pulling untestable
private parsing logic out of the 2734-line view model into standalone,
unit-testable Core functions.

## What's left to extract (verified file:line, all in `Fallback.swift`)

| Function | Lines | Purity | Called from |
|---|---|---|---|
| `parseHLSVariantURLsForLanguage(_:from:baseURL:)` | 2363-2412 (~50) | pure | `switchHLSLanguage` (line 2258), once |
| `parseHLSAllVariants(from:baseURL:)` | 2423-2463 (~41) | pure | `tryWebViewHLS` (line 2004), once |
| `parseHLSBestVariant(from:baseURL:minHeight:)` | 2467-2513 (~47) | pure + 1 `playerLog.notice` per candidate | `tryWebViewHLS` (lines 2005-2006), twice |

All three are currently `private func` on `PlaybackViewModel`, reachable
only through the 2734-line file, with no unit tests — manifest-parsing edge
cases (relative vs absolute URIs, missing RESOLUTION tags, dubbed-audio
content IDs) can only be exercised by running the full retry/race machinery
end-to-end.

## Design

Move all three into `SmartTubeIOSCore/HLSManifestParser.swift` (alongside
the existing `parseHLSMasterManifest`) as `public func`s with identical
signatures and bodies, with one adjustment:

- `parseHLSBestVariant`: drop the per-candidate
  `playerLog.notice("[webView/HLS] candidate \(height)p: ...")` call (Core
  has no `playerLog`) — it's diagnostic only. The `Fallback.swift` wrapper
  logs once with the final result instead (see Step 3).

`Fallback.swift` keeps thin private wrappers — same pattern as
`parseHLSAudioLanguages`/`extractQuotedHLSAttribute` at lines 2356-2358 and
2415-2417:
```swift
private func parseHLSAllVariants(from manifest: String, baseURL: URL) -> [Int: URL] {
    SmartTubeIOSCore.parseHLSAllVariants(from: manifest, baseURL: baseURL)
}
```
This keeps the two call sites (`tryWebViewHLS`, `switchHLSLanguage`)
unchanged.

## Steps

1. **`parseHLSVariantURLsForLanguage`**
   - Copy the body (2363-2412) verbatim into `HLSManifestParser.swift` as
     `public func parseHLSVariantURLsForLanguage(_ contentID: String?, from manifest: String, baseURL: URL) -> [Int: URL]`.
   - Replace `Fallback.swift`'s version with a thin wrapper.
   - Build: `swift build --target SmartTubeIOSCore && swift build --target SmartTubeIOS`.

2. **`parseHLSAllVariants`**
   - Copy the body (2423-2463) verbatim into `HLSManifestParser.swift` as
     `public func parseHLSAllVariants(from manifest: String, baseURL: URL) -> [Int: URL]`.
   - Replace `Fallback.swift`'s version with a thin wrapper.
   - While here: read `tryWebViewHLS` around line 2004 to note (don't yet
     act on, see Non-goals) whether `parseHLSAllVariants`'s "first entry per
     height, no H.264 preference" duplicates `parseHLSMasterManifest`'s
     "first entry per height, with H.264 upgrade" — if they really do the
     same job for this call site, that's a follow-up simplification, not
     part of this plan.
   - Build.

3. **`parseHLSBestVariant`**
   - Copy the body (2467-2513) into `HLSManifestParser.swift` as
     `public func parseHLSBestVariant(from manifest: String, baseURL: URL, minHeight: Int) -> URL?`,
     dropping the per-candidate `playerLog.notice` line.
   - `Fallback.swift` wrapper logs once with the outcome:
     ```swift
     private func parseHLSBestVariant(from manifest: String, baseURL: URL, minHeight: Int) -> URL? {
         let result = SmartTubeIOSCore.parseHLSBestVariant(from: manifest, baseURL: baseURL, minHeight: minHeight)
         if let result {
             playerLog.notice("[webView/HLS] best variant ≥\(minHeight)p: \(result.absoluteString.prefix(80))")
         }
         return result
     }
     ```
   - Build.

4. **Unit tests**
   - Add tests for the three newly-public functions in
     `SmartTubeIOSCoreTests` (or wherever `parseHLSMasterManifest`/
     `parseHLSAudioLanguages` are tested, if at all — check first). Cover:
     relative vs absolute URI resolution, dubbed-audio content-ID matching
     (`parseHLSVariantURLsForLanguage`), `minHeight` filtering
     (`parseHLSBestVariant`).

5. **Final verification**
   - Full `swift build`.
   - `wc -l` on `Fallback.swift` to confirm the ~138-line reduction.
   - Run the new Core tests.

## Non-goals (explicitly deferred)

The rest of `Fallback.swift` — `exhaustiveRetry`, `racePathA/B/C`,
`attemptURL`, `attemptComposition`, `tryWebViewHLS`,
`rebuildCompositionForQuality`, etc. — is a tightly-coupled
playback-retry/race state machine operating directly on `PlaybackViewModel`
mutable state (`self.player`, `self.currentVideo`, in-flight tasks). Per the
architecture review, this **may be intentionally deep**: it's where
playback-fallback bugs need to be found and fixed together (Locality), and
splitting it without a dedicated design pass risks scattering tightly
related state-machine steps across files without reducing real complexity.
Not recommended for this round — revisit only if a concrete pain point
(e.g. a specific untestable bug, or a recurring merge-conflict hotspot)
makes the cost of further investigation worth it.
