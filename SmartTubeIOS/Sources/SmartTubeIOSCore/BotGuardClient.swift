import Foundation
import JavaScriptCore
import os

// MARK: - BotGuardError

public enum BotGuardError: Error, CustomStringConvertible {
    case challengeFailed(String)
    case challengeParseError(String)
    case jsFailed(String)
    case integrityTokenFailed(String)
    case mintFailed(String)

    public var description: String {
        switch self {
        case .challengeFailed(let m):       "BotGuard challenge fetch failed: \(m)"
        case .challengeParseError(let m):   "BotGuard challenge parse error: \(m)"
        case .jsFailed(let m):              "BotGuard JS error: \(m)"
        case .integrityTokenFailed(let m):  "BotGuard integrity token failed: \(m)"
        case .mintFailed(let m):            "BotGuard mint failed: \(m)"
        }
    }
}

// MARK: - BotGuardClient

/// Generates YouTube Proof-of-Origin (PO) tokens on-device using JavaScriptCore.
///
/// The BotGuard attestation pipeline mirrors https://github.com/LuanRT/BgUtils (MIT):
/// 1. Fetch the BotGuard challenge (interpreter JS + program + globalName) from Google's WAA API.
/// 2. Execute the interpreter JS in a `JSContext`; call `vm.a(program, callback, …)` to load the program.
/// 3. Call `asyncSnapshotFn(callback, params)` → `botguardResponse` string.
/// 4. POST `botguardResponse` to WAA GenerateIT → `integrityTokenB64`.
/// 5. Call `webPoSignalOutput[0](integrityTokenBytes)` → minter → call minter with videoId bytes → base64 token.
///
/// All JSContext work and blocking network calls run on a dedicated serial `jsQueue` (a real OS thread).
/// Network calls use `URLSession.dataTask` + `DispatchSemaphore` — safe because `jsQueue` is not part of
/// Swift's cooperative concurrency thread pool.
public final class BotGuardClient: PoTokenProvider, @unchecked Sendable {

    // MARK: - WAA API constants
    // Public API key used by YouTube's web client; from BgUtils / YouTube JS source.
    private static let waaAPIKey  = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    // YouTube BotGuard request key (stable; from BgUtils examples).
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let waaCreateURL     = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/Create")!
    private static let waaGenerateITURL = URL(string: "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT")!

    // MARK: - Properties
    private let session: URLSession
    private let bgLog = Logger(subsystem: appSubsystem, category: "BotGuard")
    /// All JSContext access serialised on this queue. It is a real OS thread, so
    /// `DispatchSemaphore.wait()` inside blocks here does NOT block the Swift cooperative pool.
    private let jsQueue = DispatchQueue(label: "st.botguard.js", qos: .userInitiated)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PoTokenProvider

    public func token(for videoId: String) async throws -> String {
        bgLog.notice("[BotGuard] token requested for \(videoId, privacy: .public)")

        // Phase 1 – fetch challenge (async Swift network call, off jsQueue).
        let challenge = try await fetchChallenge()
        bgLog.notice("[BotGuard] challenge ok, globalName=\(challenge.globalName, privacy: .public) jsLen=\(challenge.interpreterJS.count)")

        // Phase 2–5 – run entirely on jsQueue to keep all JSValue references on one thread.
        let token = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            jsQueue.async {
                do {
                    let tok = try self.runPipelineSync(challenge: challenge, videoId: videoId)
                    cont.resume(returning: tok)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        bgLog.notice("[BotGuard] ✅ PO token minted (len=\(token.count)) for \(videoId, privacy: .public)")
        return token
    }

    // MARK: - Challenge model

    private struct BotGuardChallenge {
        let interpreterJS: String
        let program: String
        let globalName: String
    }

    // MARK: - Phase 1: fetch challenge from WAA Create endpoint

    private func fetchChallenge() async throws -> BotGuardChallenge {
        var req = URLRequest(url: Self.waaCreateURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [Self.requestKey])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BotGuardError.challengeFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // Log raw response for parse debugging (truncated to 300 chars)
        let rawPreview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "<binary>"
        bgLog.notice("[BotGuard] WAA Create raw response (first 300): \(rawPreview, privacy: .public)")

        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any],
              outer.count >= 2 else {
            throw BotGuardError.challengeParseError("outer array missing")
        }
        bgLog.notice("[BotGuard] outer array count=\(outer.count)")

        // Current WAA Create format (BgUtils v3.2+): outer[1] is a scrambled base64 string.
        // Scrambling: each byte of the UTF-8 inner JSON had 97 subtracted (mod 256).
        // Descrambling: base64-decode → add 97 to every byte (mod 256) → UTF-8 → JSON-parse.
        if let scrambled = outer[1] as? String, !scrambled.isEmpty {
            bgLog.notice("[BotGuard] outer[1] is String len=\(scrambled.count) — descrambling (BgUtils v3.2 format)")
            do {
                return try await descrambleAndParse(scrambled)
            } catch {
                bgLog.notice("[BotGuard] descramble failed: \(error) — falling back")
            }
        }

        // Legacy format: outer[0] is the inner challenge array directly.
        if let candidate = outer[0] as? [Any], candidate.count >= 5 {
            bgLog.notice("[BotGuard] outer[0] is array (legacy format) — trying inner parse")
            do {
                return try await parseInnerArray(candidate)
            } catch {
                bgLog.notice("[BotGuard] legacy inner parse failed: \(error) — falling back")
            }
        }

        // Last resort: fetch interpreter from YouTube homepage player JS.
        bgLog.notice("[BotGuard] all parse strategies failed — fetching interpreter from YouTube homepage")
        let js = try await fetchInterpreterFromYouTube()
        return BotGuardChallenge(interpreterJS: js, program: "", globalName: "")
    }

    /// Descrambles a WAA Create scrambled challenge string and parses the resulting inner JSON array.
    ///
    /// The WAA API (BgUtils v3.2+) encodes the challenge data as follows:
    /// 1. Inner challenge array → UTF-8 JSON
    /// 2. Each byte `b` → `(b - 97) mod 256`  (subtract 97, wrapping)
    /// 3. Result → base64-encoded string stored as `outer[1]`
    ///
    /// To descramble: base64-decode → `map { $0 &+ 97 }` → UTF-8-decode → JSON-parse.
    private func descrambleAndParse(_ scrambled: String) async throws -> BotGuardChallenge {
        // Restore standard base64 padding (WAA response omits trailing '=')
        let rem = scrambled.count % 4
        let padded = rem == 0 ? scrambled : scrambled + String(repeating: "=", count: 4 - rem)
        guard let encoded = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else {
            throw BotGuardError.challengeParseError("descramble: base64 decode failed (len=\(scrambled.count))")
        }
        // Add 97 to each byte with wrapping arithmetic — mirrors JS: Uint8Array b + 97
        let descrambled = Data(encoded.map { $0 &+ 97 })
        guard let json = String(data: descrambled, encoding: .utf8) else {
            throw BotGuardError.challengeParseError("descramble: UTF-8 decode failed after unshift")
        }
        bgLog.notice("[BotGuard] descrambled JSON (first 200): \(String(json.prefix(200)), privacy: .public)")
        guard let inner = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
            throw BotGuardError.challengeParseError("descramble: inner JSON parse failed")
        }
        return try await parseInnerArray(inner)
    }

    /// Parses the inner BotGuard challenge array (after descrambling).
    ///
    /// Expected layout from BgUtils `DescrambledChallenge`:
    /// ```
    /// [ messageId, wrappedScript, wrappedUrl, interpreterHash, program, globalName, ?, clientExperimentsStateBlob ]
    /// ```
    /// - `wrappedScript` (`inner[1]`): `[Any]` — first non-empty `String` is inline VM JS
    /// - `wrappedUrl`    (`inner[2]`): `[Any]` — first non-empty `String` is URL to fetch VM JS from
    /// - `program`       (`inner[4]`): `String`
    /// - `globalName`    (`inner[5]`): `String`
    private func parseInnerArray(_ inner: [Any]) async throws -> BotGuardChallenge {
        guard inner.count >= 6 else {
            throw BotGuardError.challengeParseError("inner array too short (\(inner.count), need ≥6)")
        }
        let wrappedScript = inner[1] as? [Any] ?? []
        let wrappedUrl    = inner[2] as? [Any] ?? []
        let program       = inner[4] as? String ?? ""
        let globalName    = inner[5] as? String ?? ""
        guard !program.isEmpty else {
            throw BotGuardError.challengeParseError("program empty at inner[4]")
        }
        bgLog.notice("[BotGuard] inner parse: globalName='\(globalName, privacy: .public)' programLen=\(program.count)")

        // Prefer inline JS from wrappedScript (avoids extra network round-trip)
        if let inlineJS = wrappedScript.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            bgLog.notice("[BotGuard] using inline interpreter JS from wrappedScript (len=\(inlineJS.count))")
            return BotGuardChallenge(interpreterJS: inlineJS, program: program, globalName: globalName)
        }

        // Fall back to fetching interpreter JS from URL in wrappedUrl
        if let urlRaw = wrappedUrl.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
            bgLog.notice("[BotGuard] fetching interpreter JS from wrappedUrl: \(String(urlRaw.prefix(80)), privacy: .public)")
            let js = try await fetchInterpreterJS(from: urlRaw)
            return BotGuardChallenge(interpreterJS: js, program: program, globalName: globalName)
        }

        throw BotGuardError.challengeParseError("no interpreter JS source in wrappedScript or wrappedUrl")
    }

    /// Fetches interpreter JS from a URL, or returns `raw` directly if it is inline JS.
    private func fetchInterpreterJS(from raw: String) async throws -> String {
        let urlStr = raw.hasPrefix("//") ? "https:\(raw)" : raw
        if let jsURL = URL(string: urlStr), jsURL.scheme != nil, jsURL.host != nil {
            let (jsData, _) = try await session.data(from: jsURL)
            let js = String(data: jsData, encoding: .utf8) ?? ""
            bgLog.notice("[BotGuard] interpreter JS fetched from URL (len=\(js.count))")
            return js
        }
        return raw  // raw is inline JS
    }

    /// Fetches YouTube's current player JS by extracting the player URL from the homepage.
    /// Used as a fallback when the WAA Create binary proto parse cannot provide an interpreter URL.
    private func fetchInterpreterFromYouTube() async throws -> String {
        bgLog.notice("[BotGuard] fetching interpreter URL from YouTube homepage")
        guard let homeURL = URL(string: "https://www.youtube.com/") else {
            throw BotGuardError.challengeParseError("YouTube homepage: invalid URL")
        }
        var homeReq = URLRequest(url: homeURL, timeoutInterval: 12)
        homeReq.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (htmlData, _) = try await session.data(for: homeReq)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw BotGuardError.challengeParseError("YouTube homepage: invalid UTF-8")
        }
        // Match the player JS path: /s/player/<hash>/player_ias.vflset/<locale>/base.js
        let patterns = [
            #"["'](/s/player/[a-f0-9]+/player_ias\.vflset/[^"'/]+/base\.js)["']"#,
            #"src\s*=\s*["']([^"']*player[^"']*\.js)["']"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let path = String(html[range])
                let fullURL: String
                if path.hasPrefix("//")   { fullURL = "https:\(path)" }
                else if path.hasPrefix("http") { fullURL = path }
                else                       { fullURL = "https://www.youtube.com\(path)" }
                bgLog.notice("[BotGuard] player JS URL: \(String(fullURL.prefix(80)), privacy: .public)")
                return try await fetchInterpreterJS(from: fullURL)
            }
        }
        throw BotGuardError.challengeParseError("YouTube homepage: player JS URL not found in HTML")
    }

    // MARK: - Binary Protobuf Helpers

    /// Reads a protobuf varint from `bytes` starting at `pos`.
    /// Returns (value, next_position) or nil on parse error / truncated input.
    private static func readVarint(from bytes: [UInt8], at pos: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var idx = pos
        while idx < bytes.count {
            let b = bytes[idx]; idx += 1
            result |= UInt64(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return (result, idx) }
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Parses a binary protobuf blob and returns a dict of `fieldNumber → raw Data`
    /// for every **length-delimited** (wire type 2) field encountered.
    /// Other wire types are skipped. Duplicate field numbers keep the last value.
    private static func readProtoFields(_ data: Data) -> [Int: Data] {
        let bytes = [UInt8](data)
        var pos = 0
        var fields: [Int: Data] = [:]

        while pos < bytes.count {
            guard let (tag, p1) = readVarint(from: bytes, at: pos) else { break }
            pos = p1
            let fieldNum = Int(tag >> 3)
            let wireType = Int(tag & 7)

            switch wireType {
            case 0:  // varint — skip
                guard let (_, p2) = readVarint(from: bytes, at: pos) else { return fields }
                pos = p2
            case 1:  // 64-bit — skip
                guard pos + 8 <= bytes.count else { return fields }
                pos += 8
            case 2:  // length-delimited — capture
                guard let (len, p2) = readVarint(from: bytes, at: pos) else { return fields }
                pos = p2
                let end = pos + Int(len)
                guard end <= bytes.count else { return fields }
                let startIdx = data.index(data.startIndex, offsetBy: pos)
                let endIdx   = data.index(data.startIndex, offsetBy: end)
                fields[fieldNum] = data[startIdx..<endIdx]
                pos = end
            case 3:  // start group (proto2, deprecated) — skip until matching end group
                let groupField = fieldNum
                var depth = 1
                groupLoop: while pos < bytes.count && depth > 0 {
                    guard let (innerTag, innerP) = readVarint(from: bytes, at: pos) else { break groupLoop }
                    pos = innerP
                    let iWire = Int(innerTag & 7)
                    let iField = Int(innerTag >> 3)
                    switch iWire {
                    case 0: guard let (_, p2) = readVarint(from: bytes, at: pos) else { break groupLoop }; pos = p2
                    case 1: guard pos + 8 <= bytes.count else { break groupLoop }; pos += 8
                    case 2:
                        guard let (len, p2) = readVarint(from: bytes, at: pos) else { break groupLoop }
                        pos = p2
                        guard pos + Int(len) <= bytes.count else { break groupLoop }
                        pos += Int(len)
                    case 3: depth += 1
                    case 4: if iField == groupField { depth -= 1 }
                    case 5: guard pos + 4 <= bytes.count else { break groupLoop }; pos += 4
                    default: break groupLoop
                    }
                }
            case 4:  // end group (unexpected at top level) — stop
                return fields
            case 5:  // 32-bit — skip
                guard pos + 4 <= bytes.count else { return fields }
                pos += 4
            default:
                return fields  // unknown wire type → stop parsing
            }
        }
        return fields
    }

    // MARK: - Phase 2–5: synchronous pipeline on jsQueue

    /// Runs the entire BotGuard pipeline synchronously:
    /// JS VM execution → integrity token fetch (blocking) → mint (JS).
    /// Must be called from `jsQueue` only.
    private func runPipelineSync(challenge: BotGuardChallenge, videoId: String) throws -> String {

        // --- Set up JSContext with minimal polyfills ---
        guard let ctx = JSContext() else {
            throw BotGuardError.jsFailed("JSContext() returned nil")
        }
        ctx.exceptionHandler = { [weak self] _, exc in
            self?.bgLog.warning("[BotGuard] JSContext exception: \(exc?.toString() ?? "nil", privacy: .public)")
        }
        installPolyfills(ctx)

        // --- Load BotGuard interpreter VM ---
        ctx.evaluateScript(challenge.interpreterJS)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("interpreter load: \(exc)")
        }

        // --- Locate the VM object in global scope ---
        // When globalName is non-empty, look it up directly.
        // When empty (fallback path), discover the VM by scanning globals for an object
        // with a method 'a' — this is the BotGuard VM's known entry-point signature.
        var vm: JSValue?
        if !challenge.globalName.isEmpty {
            vm = ctx.globalObject?.objectForKeyedSubscript(challenge.globalName)
        }
        if vm == nil || vm!.isNull || vm!.isUndefined {
            let discovered = ctx.evaluateScript("""
                (function() {
                    var ks = Object.keys(globalThis);
                    for (var i = 0; i < ks.length; i++) {
                        var v = globalThis[ks[i]];
                        if (v && typeof v === 'object' && typeof v.a === 'function') return ks[i];
                    }
                    return null;
                })()
            """)
            if let name = discovered?.toString(), name != "null", !name.isEmpty {
                bgLog.notice("[BotGuard] discovered globalName=\(name, privacy: .public) (requested='\(challenge.globalName, privacy: .public)')")
                vm = ctx.globalObject?.objectForKeyedSubscript(name)
            }
        }
        guard let vm, !vm.isNull, !vm.isUndefined else {
            throw BotGuardError.jsFailed("VM '\(challenge.globalName)' not in JSContext global (dynamic discovery also failed)")
        }

        // --- Phase 2: call vm.a(program, vmFunctionsCallback, true, undefined, noop, [[], []]) ---
        var asyncSnapshotFn: JSValue?
        let vmFnCallback: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { fn0, _, _, _ in
            // arg0 = integrityTokenBasedRequestKey — calls callback with snapshot response.
            // (webPoSignalOutput[0] is the getMinter factory; fallback to websafeFallbackToken when not set)
            asyncSnapshotFn = fn0
        }
        let undef    = JSValue(undefinedIn: ctx)!
        let noopFn   = JSValue(object: { } as @convention(block) () -> Void, in: ctx)!
        let initPair = ctx.evaluateScript("[[],[]]")!

        // invokeMethod sets this=vm, required by the real BotGuard VM's internal methods.
        let vmCallResult = vm.invokeMethod("a", withArguments: [
            challenge.program,
            JSValue(object: vmFnCallback, in: ctx)!,
            NSNumber(value: true),
            undef,
            noopFn,
            initPair
        ])

        if let exc = ctx.exception { throw BotGuardError.jsFailed("vm.a(): \(exc)") }

        // vm.a() may return [syncFn, ...] or [Promise, ...]; pump microtasks either way.
        if let initPromise = vmCallResult?.objectAtIndexedSubscript(0),
           initPromise.objectForKeyedSubscript("then")?.isObject == true {
            _ = try resolvePromise(initPromise, in: ctx, label: "vm.a() init")
        } else {
            pumpMicrotasks(ctx, count: 3)
        }

        guard let snapFn = asyncSnapshotFn, !snapFn.isNull, !snapFn.isUndefined else {
            throw BotGuardError.jsFailed("asyncSnapshotFn not set after vm.a() — VM may have changed API")
        }
        bgLog.notice("[BotGuard] Phase 2 ✅ VM loaded, asyncSnapshotFn set")

        // --- Phase 3: asyncSnapshotFn(callback, [undefined, undefined, webPoSignalOutput, undefined]) ---
        // webPoSignalOutput must be a named JS global so __bgSO in the snapArgs array
        // is a live reference to the same JS array object.  ctx.setObject(_:forKeyedSubscript:)
        // doesn't reliably set globals when passed a JSValue — create the array in JS instead.
        // --- Phase 3: call asyncSnapshotFn(callback, [undefined, undefined, webPoSignalOutput, undefined]) ---
        // webPoSignalOutput is a JS array; the VM may populate [0] with the getMinter factory.
        // ctx.setObject(_:forKeyedSubscript:) doesn't reliably set globals for JSValue — create in JS instead.
        var botguardResponse: String?
        ctx.evaluateScript("var __bgSO = []")
        let webPoSignalOutput = ctx.globalObject.objectForKeyedSubscript("__bgSO")!
        let snapArgs = ctx.evaluateScript("[undefined, undefined, __bgSO, undefined]")!

        let snapCallback: @convention(block) (JSValue) -> Void = { response in
            botguardResponse = response.isNull || response.isUndefined ? nil : response.toString()
        }

        let snapResult = snapFn.call(withArguments: [
            JSValue(object: snapCallback, in: ctx)!,
            snapArgs
        ])
        if let exc = ctx.exception { throw BotGuardError.jsFailed("asyncSnapshotFn: \(exc)") }
        pumpMicrotasks(ctx, count: 5)   // flush synchronous callback path

        // If asyncSnapshotFn returned a Promise, pump extra microtasks so the VM can settle
        if let snapPromise = snapResult, snapPromise.objectForKeyedSubscript("then")?.isObject == true {
            pumpMicrotasks(ctx, count: 100)
        } else {
            pumpMicrotasks(ctx, count: 30)
        }

        guard let bgResponse = botguardResponse, !bgResponse.isEmpty else {
            throw BotGuardError.jsFailed("botguard response empty after asyncSnapshotFn")
        }
        bgLog.notice("[BotGuard] Phase 3 ✅ botguardResponse len=\(bgResponse.count)")

        // --- Phase 4: fetch integrity token (blocking URLSession, safe on jsQueue) ---
        // Returns (integrityToken: json[0], websafeFallback: json[3]).
        // json[0] is the token passed to getMinter; json[3] is used directly when getMinter is unavailable.
        let (integrityToken, websafeFallback) = try fetchIntegrityTokenSync(bgResponse: bgResponse)
        bgLog.notice("[BotGuard] Phase 4 ✅ integrityToken=\(integrityToken?.count ?? 0) websafeFallback=\(websafeFallback?.count ?? 0)")

        // --- Phase 5: mint PO token ---
        return try mintSync(
            ctx: ctx,
            signalOutput: webPoSignalOutput,
            integrityToken: integrityToken,
            websafeFallback: websafeFallback,
            videoId: videoId
        )
    }

    // MARK: - Phase 4: integrity token (blocking, on jsQueue)

    // Holds the dataTask callback result across a DispatchSemaphore hand-off.
    // @unchecked Sendable is safe here: jsQueue blocks on the semaphore while the
    // URLSession delegate queue writes, so there is no concurrent access in practice.
    private final class _ResultBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func fetchIntegrityTokenSync(bgResponse: String) throws -> (integrityToken: String?, websafeFallback: String?) {
        let payload = [Self.requestKey, bgResponse]
        var req = URLRequest(url: Self.waaGenerateITURL, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.waaAPIKey,              forHTTPHeaderField: "x-goog-api-key")
        req.setValue("grpc-web-javascript/0.1",   forHTTPHeaderField: "x-user-agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let box = _ResultBox<Result<(integrityToken: String?, websafeFallback: String?), Error>?>(nil)
        let sema = DispatchSemaphore(value: 0)
        let log = bgLog   // capture logger value to avoid 'self' capture in closure

        session.dataTask(with: req) { data, response, error in
            defer { sema.signal() }
            if let error { box.value = .failure(error); return }
            // GenerateIT response: [integrityToken, ttlSecs, mintRefreshThreshold, websafeFallbackToken]
            // json[0]: integrityTokenBasedRequestKey — input to getMinter() for full minting flow (may be nil)
            // json[3]: websafeFallbackToken — ready-to-use PO token when getMinter is not available (may be absent)
            // Guard requires non-empty JSON array; json[3] is accessed only when present (API format may vary).
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  !json.isEmpty else {
                let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodySnippet = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "<nil>"
                log.notice("[BotGuard] GenerateIT failed: HTTP \(httpStatus) body=\(bodySnippet)")
                box.value = .failure(BotGuardError.integrityTokenFailed(
                    "HTTP \(httpStatus) body=\(bodySnippet.prefix(80))"
                ))
                return
            }
            let integrityToken    = json[0] as? String          // may be nil
            let websafeFallback   = json.count > 3 ? json[3] as? String : nil  // ready-to-use PO token fallback
            guard integrityToken != nil || websafeFallback != nil else {
                box.value = .failure(BotGuardError.integrityTokenFailed("both integrityToken and websafeFallback are nil"))
                return
            }
            box.value = .success((integrityToken, websafeFallback))
        }.resume()

        sema.wait()
        return try box.value!.get()
    }

    // MARK: - Phase 5: mint (JS, on jsQueue)

    private func mintSync(
        ctx: JSContext,
        signalOutput: JSValue,
        integrityToken: String?,
        websafeFallback: String?,
        videoId: String
    ) throws -> String {

        // getMinter = webPoSignalOutput[0] (set by the VM during asyncSnapshotFn, when available)
        let getMinterFn = signalOutput.objectAtIndexedSubscript(0)
        let hasMinter = getMinterFn != nil && !getMinterFn!.isNull && !getMinterFn!.isUndefined

        if !hasMinter {
            // webPoSignalOutput[0] not available — use websafeFallbackToken directly.
            // This token from GenerateIT (json[3]) is a ready-to-use URL-safe base64 PO token.
            guard let fallback = websafeFallback, !fallback.isEmpty else {
                throw BotGuardError.mintFailed("getMinter not set and no websafeFallbackToken available")
            }
            bgLog.notice("[BotGuard] ✅ using websafe fallback token (len=\(fallback.count)) for \(videoId)")
            return fallback
        }

        // Full minting flow: getMinter(integrityTokenBytes) → mintCallback(videoIdBytes) → PO token
        guard let integrityB64 = integrityToken, !integrityB64.isEmpty else {
            throw BotGuardError.mintFailed("getMinter available but integrityToken (json[0]) is nil")
        }

        // Decode integrity token bytes.
        // The token uses URL-safe base64 (- and _); convert to standard base64 before decoding.
        let standardB64 = integrityB64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = standardB64.count % 4
        let paddedB64 = rem == 0 ? standardB64 : standardB64 + String(repeating: "=", count: 4 - rem)
        guard let integrityData = Data(base64Encoded: paddedB64) else {
            throw BotGuardError.mintFailed("integrityToken base64 decode failed")
        }

        // Build JS Uint8Array for integrity token bytes
        let integrityU8 = try buildUint8Array(from: integrityData, in: ctx, label: "integrityToken")

        // mintCallback = await getMinter(integrityTokenBytes)  – may return Promise or function directly
        let getMinterResult = getMinterFn!.call(withArguments: [integrityU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("getMinter(): \(exc)") }
        let mintCallbackFn = try resolvePromise(getMinterResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "getMinter")

        guard !mintCallbackFn.isNull, !mintCallbackFn.isUndefined else {
            throw BotGuardError.mintFailed("mintCallback is null after getMinter")
        }

        // tokenBytes = await mintCallback(TextEncoder().encode(videoId))
        guard let videoIdData = videoId.data(using: .utf8) else {
            throw BotGuardError.mintFailed("videoId UTF-8 encoding failed")
        }
        let videoIdU8 = try buildUint8Array(from: videoIdData, in: ctx, label: "videoId")

        let mintResult = mintCallbackFn.call(withArguments: [videoIdU8])
        if let exc = ctx.exception { throw BotGuardError.mintFailed("mintCallback(): \(exc)") }
        let tokenValue = try resolvePromise(mintResult ?? JSValue(undefinedIn: ctx)!, in: ctx, label: "mintCallback")

        // Extract bytes from the result (Uint8Array or plain Array)
        var tokenBytes = Data()
        if let lengthVal = tokenValue.objectForKeyedSubscript("length"), lengthVal.isNumber {
            let length = Int(lengthVal.toInt32())
            for i in 0..<length {
                let byte = tokenValue.objectAtIndexedSubscript(i).toUInt32()
                tokenBytes.append(UInt8(byte & 0xFF))
            }
        }

        guard !tokenBytes.isEmpty else {
            throw BotGuardError.mintFailed("mint result was empty")
        }

        return tokenBytes.base64EncodedString()
    }

    // MARK: - JSContext helpers

    /// Installs minimal polyfills for APIs the BotGuard interpreter JS may reference.
    private func installPolyfills(_ ctx: JSContext) {
        // window / globalThis aliasing (BotGuard may write to window.X)
        ctx.evaluateScript("""
        if (typeof window === 'undefined') { var window = this; }
        if (typeof globalThis === 'undefined') { var globalThis = window; }
        if (typeof self === 'undefined') { var self = window; }
        """)

        // Minimal document stub (prevents crashes on e.g. document.createElement)
        ctx.evaluateScript("""
        if (typeof document === 'undefined') {
            var document = {
                createElement: function(tag) { return { tagName: tag, style: {}, setAttribute: function(){}, appendChild: function(){} }; },
                createTextNode: function(t) { return { textContent: t }; },
                getElementsByTagName: function() { return []; },
                querySelector: function() { return null; },
                querySelectorAll: function() { return []; },
                head: { appendChild: function(s){ if(s && s.src){ } } },
                body: { appendChild: function(){} },
                cookie: ''
            };
        }
        """)

        // navigator stub
        ctx.evaluateScript("""
        if (typeof navigator === 'undefined') {
            var navigator = { userAgent: 'Mozilla/5.0', language: 'en-US', languages: ['en-US'], cookieEnabled: true };
        }
        """)

        // setTimeout / setInterval stubs (synchronous — fires callback immediately for best-effort compat)
        // BotGuard typically does not rely on real timer semantics in its VM.
        let setTimeoutFn: @convention(block) (JSValue, JSValue) -> NSNumber = { cb, _ in
            if cb.isObject { cb.call(withArguments: []) }
            return 0
        }
        ctx.setObject(setTimeoutFn, forKeyedSubscript: "setTimeout" as NSString)
        ctx.setObject({ (_: JSValue, _: JSValue) -> NSNumber in 0 } as @convention(block) (JSValue, JSValue) -> NSNumber,
                      forKeyedSubscript: "setInterval" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject({ (_: NSNumber) in } as @convention(block) (NSNumber) -> Void,
                      forKeyedSubscript: "clearInterval" as NSString)
    }

    /// Builds a JS `Uint8Array` from `Data`. Used for passing byte arrays across the Swift/JS bridge.
    private func buildUint8Array(from data: Data, in ctx: JSContext, label: String) throws -> JSValue {
        guard let arr = ctx.evaluateScript("new Uint8Array(\(data.count))"),
              !arr.isNull, !arr.isUndefined else {
            throw BotGuardError.mintFailed("Uint8Array(\(label)) creation failed")
        }
        for (i, byte) in data.enumerated() {
            arr.setObject(NSNumber(value: byte), atIndexedSubscript: i)
        }
        return arr
    }

    /// Pumps pending JSC microtasks by re-entering the JS engine.
    /// Each call to `evaluateScript` creates a drain-point where JSC flushes its microtask queue.
    private func pumpMicrotasks(_ ctx: JSContext, count: Int) {
        for _ in 0..<count { ctx.evaluateScript("undefined") }
    }

    /// Resolves a JS Promise synchronously using a pure-JS then-handler that writes
    /// the settled value to a context global (`__bgR`), then reads it back in Swift.
    ///
    /// Avoids crossing the JS→Swift callback boundary during microtask draining
    /// (Swift `@convention(block)` callbacks from within JSC microtasks can be unreliable
    /// when microtask draining occurs re-entrantly inside `JSObjectCallAsFunction`).
    ///
    /// The `__bgR` global is single-use and deleted after reading; safe because jsQueue is serial.
    /// Returns `promise` directly if it is not thenable (mirrors `await nonPromise` in JS).
    private func resolvePromise(_ promise: JSValue, in ctx: JSContext, label: String, maxPumps: Int = 20) throws -> JSValue {
        guard promise.objectForKeyedSubscript("then")?.isObject == true else {
            return promise
        }

        // Store the promise in a JS global so the IIFE can access it by name.
        ctx.setObject(promise, forKeyedSubscript: "__bgP" as NSString)

        // The IIFE calls p.then(handler) as a method (this=p, correct binding).
        // JSEvaluateScript calls vm.drainMicrotasks() after the IIFE returns, which
        // executes the queued then-callback and sets __bgR before returning to Swift.
        ctx.evaluateScript("""
        (function() {
            var p = globalThis.__bgP;
            delete globalThis.__bgP;
            p.then(
                function(v) { globalThis.__bgR = { ok: 1, v: v }; },
                function(e) { globalThis.__bgR = { ok: 0, e: String(e) }; }
            );
        })();
        """)
        if let exc = ctx.exception {
            throw BotGuardError.jsFailed("resolvePromise '\(label)' setup: \(exc)")
        }

        // Read result — usually set during the evaluateScript above; pump more if needed
        // (e.g. multi-hop Promise chains that require additional microtask turns).
        for _ in 0..<maxPumps {
            if let r = ctx.evaluateScript("globalThis.__bgR"),
               !r.isNull, !r.isUndefined {
                ctx.evaluateScript("delete globalThis.__bgR")
                if r.objectForKeyedSubscript("ok")?.toInt32() == 1 {
                    return r.objectForKeyedSubscript("v") ?? JSValue(undefinedIn: ctx)!
                } else {
                    let err = r.objectForKeyedSubscript("e")?.toString() ?? "rejected"
                    throw BotGuardError.jsFailed("Promise '\(label)' rejected: \(err)")
                }
            }
            ctx.evaluateScript("undefined")   // additional microtask drain
        }

        throw BotGuardError.jsFailed("Promise '\(label)' did not settle after \(maxPumps) pumps")
    }
}
