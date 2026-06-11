# Plan 3: Generic `TTLCache<Key, Value>`

## Goal

Replace the duplicated get/store/TTL/eviction logic in
[HLSManifestCache.swift](SmartTubeIOS/Sources/SmartTubeIOSCore/HLSManifestCache.swift)
and
[LocalSubscriptionFeedCache.swift](SmartTubeIOS/Sources/SmartTubeIOSCore/LocalSubscriptionFeedCache.swift)
with one generic, pure, unit-testable `TTLCache<Key: Hashable, Value>`. Both
existing types become thin wrappers that keep their current public API and
concurrency model (`@MainActor struct` vs `actor`) — **zero call-site
changes** at any of the 6 call sites identified below.

This is "Candidate 3" from the architecture review.

## Current duplication (verified)

| | `HLSManifestCache` | `LocalSubscriptionFeedCache` |
|---|---|---|
| Concurrency | `@MainActor public struct`, `mutating` methods | `public actor` |
| TTL | 30 min | 15 min |
| Storage | `[String: (variants: [Int:URL], fetchedAt: Date)]` | `[String: Entry { videos, fetchedAt }]` |
| Max entries / LRU | 30, oldest-`fetchedAt` eviction | none |
| `invalidateAll()` | no | yes |

Both implement the same shape: "get if present and not expired (else
remove+nil)", "store with timestamp (+ optional LRU eviction)",
"invalidate one key". `VideoPreloadCache.swift` (640 lines) looks related
but is materially more complex (multiple field types, staleness tracking
per-field) — **out of scope** for this plan; worth a follow-up look later
but not folded in here.

## Call-site audit (why the wrapper approach, not a rewrite)

```
PlaybackQualityManager.swift:108,112   HLSManifestCache.shared.variants/store  (sync, MainActor)
PlaybackViewModel.swift:541            HLSManifestCache.shared.invalidate      (sync, MainActor)
PlaybackViewModel+Fallback.swift:1683,1699,1757,1773
                                        HLSManifestCache.shared.invalidate      (sync, MainActor)
```
All 6 `HLSManifestCache` call sites are synchronous, MainActor-isolated
calls. If `TTLCache` were itself `actor`-based (like
`LocalSubscriptionFeedCache`), every one of these would need `await` and —
in `PlaybackQualityManager`/`PlaybackViewModel` — likely force the calling
function to become `async`, a much larger and riskier change for a
mechanical dedup. The wrapper approach avoids this entirely:
`HLSManifestCache` keeps its `@MainActor struct` / `mutating` shape,
`LocalSubscriptionFeedCache` keeps its `actor` shape — both just hold a
`TTLCache` value internally.

## Design

New file `Sources/SmartTubeIOSCore/TTLCache.swift`:

```swift
/// Generic in-memory TTL cache with optional LRU-by-age eviction.
/// Plain value type, not thread-safe by itself — callers provide
/// whatever isolation they need (see HLSManifestCache / LocalSubscriptionFeedCache).
public struct TTLCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let storedAt: Date
    }

    private var store: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int?
    private let now: () -> Date

    /// - Parameters:
    ///   - ttl: entries older than this are treated as missing.
    ///   - maxEntries: if set, `set()` evicts the oldest entry (by `storedAt`)
    ///     once the cache would exceed this size.
    ///   - now: clock injection point for deterministic tests.
    public init(ttl: TimeInterval, maxEntries: Int? = nil, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.now = now
    }

    /// Returns the cached value for `key` if present and within TTL.
    /// Expired entries are removed as a side effect.
    public mutating func get(_ key: Key) -> Value? {
        guard let entry = store[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < ttl else {
            store.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    /// Stores `value` for `key`, stamped with the current time. Evicts the
    /// oldest entry first if `maxEntries` would be exceeded.
    public mutating func set(_ value: Value, for key: Key) {
        if let maxEntries, store.count >= maxEntries, store[key] == nil,
           let oldest = store.min(by: { $0.value.storedAt < $1.value.storedAt }) {
            store.removeValue(forKey: oldest.key)
        }
        store[key] = Entry(value: value, storedAt: now())
    }

    public mutating func invalidate(_ key: Key) {
        store.removeValue(forKey: key)
    }

    public mutating func invalidateAll() {
        store.removeAll()
    }
}
```

## Steps

1. **Create `TTLCache`**
   - Add `SmartTubeIOSCore/TTLCache.swift` per the design above.
   - Build: `swift build --target SmartTubeIOSCore`.

2. **Add unit tests for `TTLCache`** (new — neither existing cache has tests
   today because `Date()` was hardcoded / one is actor-isolated)
   - TTL expiry: inject an advancing `now` closure, confirm `get()` returns
     nil after TTL elapses and the entry is removed.
   - LRU eviction: `maxEntries: 2`, insert 3 keys with increasing `now()`,
     confirm the oldest is evicted.
   - `invalidate`/`invalidateAll`.

3. **Migrate `LocalSubscriptionFeedCache`** (lower risk — already an actor)
   - Replace `private var cache: [String: Entry]` with
     `private var cache = TTLCache<String, [Video]>(ttl: Self.ttl)`.
   - `videos(for:)` → `cache.get(channelId)`.
   - `store(videos:for:)` → `cache.set(videos, for: channelId)`.
   - `invalidate(channelId:)` → `cache.invalidate(channelId)`.
   - `invalidateAll()` → `cache.invalidateAll()`.
   - Remove the now-unused private `Entry` struct.
   - Build: `swift build --target SmartTubeIOSCore`.

4. **Migrate `HLSManifestCache`**
   - Replace `private var store: [String: (variants:..., fetchedAt:...)]`
     with `private var cache = TTLCache<String, [Int: URL]>(ttl: Self.ttl,
     maxEntries: Self.maxEntries)`.
   - `variants(for:)` → `cache.get(videoId)`.
   - `store(_:for:)` → `cache.set(variants, for: videoId)`.
   - `invalidate(for:)` → `cache.invalidate(videoId)`.
   - Build: `swift build --target SmartTubeIOSCore`, then full `swift build`
     (to catch the 6 call sites — should be unaffected, but confirm).

5. **Final verification**
   - Full `swift build`.
   - Run `SmartTubeIOSCoreTests` (or equivalent) including the new
     `TTLCache` tests.

## Non-goals

- `VideoPreloadCache.swift` is explicitly out of scope (more complex,
  per-field staleness — needs its own investigation if ever folded in).
- No change to TTL values, eviction policy, or call-site APIs — this is a
  pure internal-implementation dedup.
