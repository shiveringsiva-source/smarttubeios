import Darwin
import Foundation
import os.log

#if targetEnvironment(simulator)
/// Descrambles YouTube's n-parameter (throttle token) in HLS variant playlist URLs.
///
/// YouTube CDN embeds a scrambled `n` value in manifest URLs. When AVPlayer fetches
/// segment URLs that contain the scrambled `n`, the CDN returns HTTP 403.
/// Replacing `n` with its descrambled form makes all segment requests succeed (HTTP 200).
///
/// This implementation uses Deno + yt-dlp's EJS AST solver via `posix_spawn`, which is
/// available in the iOS Simulator (the app runs as a native macOS process against the iOS SDK).
/// A production implementation would port the n-cipher to JavaScriptCore by extracting
/// the cipher function from player.js at runtime.
actor YouTubeNDescrambler {
    static let shared = YouTubeNDescrambler()

    private let log = Logger(subsystem: "com.void.smarttube.app", category: "NDescramble")

    /// player.js temp file path once downloaded.
    private var cachedPlayerJSPath: String?

    /// Memoisation cache: scrambled n → descrambled n.
    private var nCache: [String: String] = [:]

    // MARK: - Public

    /// Returns `url` with its `/n/SCRAMBLED/` path component replaced by the descrambled value.
    /// Falls back to the original URL if descrambling is not possible.
    func descrambleURL(_ url: URL) async -> URL {
        guard let scrambled = extractNParam(from: url) else { return url }
        if let cached = nCache[scrambled] {
            return replacing(n: scrambled, with: cached, in: url)
        }
        guard let descrambled = await computeDescrambledN(scrambled) else {
            log.error("n-descramble failed — returning original URL (n=\(scrambled))")
            return url
        }
        nCache[scrambled] = descrambled
        log.notice("n-descramble OK: \(scrambled) → \(descrambled)")
        return replacing(n: scrambled, with: descrambled, in: url)
    }

    // MARK: - URL helpers

    private func extractNParam(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "n"), idx + 1 < parts.count else { return nil }
        let n = parts[idx + 1]
        return n.isEmpty ? nil : n
    }

    private func replacing(n old: String, with new: String, in url: URL) -> URL {
        let s = url.absoluteString.replacingOccurrences(of: "/n/\(old)/", with: "/n/\(new)/")
        return URL(string: s) ?? url
    }

    // MARK: - Core descrambling

    private func computeDescrambledN(_ scrambled: String) async -> String? {
        let playerPath: String
        if let cached = cachedPlayerJSPath {
            playerPath = cached
        } else {
            guard let path = await ensurePlayerJS() else { return nil }
            cachedPlayerJSPath = path
            playerPath = path
        }

        guard let libPath  = await findSolverFile("yt.solver.deno.lib.js"),
              let corePath = await findSolverFile("yt.solver.core.js") else {
            log.error("yt-dlp EJS solver scripts not found under /opt/homebrew")
            return nil
        }

        guard let libCode  = try? String(contentsOfFile: libPath, encoding: .utf8),
              let coreCode = try? String(contentsOfFile: corePath, encoding: .utf8) else {
            log.error("Failed to read yt-dlp solver scripts")
            return nil
        }

        let encodedN    = jsonString(scrambled)
        let encodedPath = jsonString(playerPath)

        let script = """
        \(libCode)
        Object.assign(globalThis, lib);
        \(coreCode)
        const playerJs = await Deno.readTextFile(\(encodedPath));
        const result = jsc({type:'player',player:playerJs,requests:[{type:'n',challenges:[\(encodedN)]}]});
        console.log(JSON.stringify(result));
        """

        return await runDeno(script: script, scrambledKey: scrambled)
    }

    // MARK: - player.js management

    private func ensurePlayerJS() async -> String? {
        guard let version = await fetchPlayerVersion() else {
            log.error("Could not determine YouTube player version")
            return nil
        }
        let tempPath = "/tmp/yt_player_\(version).js"
        if FileManager.default.fileExists(atPath: tempPath) {
            log.notice("Reusing cached player.js v\(version)")
            return tempPath
        }
        guard let playerURL = URL(string: "https://www.youtube.com/s/player/\(version)/player_es6.vflset/en_US/base.js") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: playerURL)
            try data.write(to: URL(fileURLWithPath: tempPath))
            log.notice("Downloaded player.js v\(version) (\(data.count) bytes)")
            return tempPath
        } catch {
            log.error("Failed to download player.js v\(version): \(error)")
            return nil
        }
    }

    private func fetchPlayerVersion() async -> String? {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/")!)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // Match /s/player/XXXXXXXX/ (8 lowercase hex chars).
        guard let range = html.range(of: #"/s/player/([a-f0-9]{8})/"#, options: .regularExpression) else { return nil }
        // e.g. "/s/player/c2f7551f/" → ["", "s", "player", "c2f7551f", ""]
        let parts = String(html[range]).components(separatedBy: "/")
        guard parts.count >= 2 else { return nil }
        let version = parts[parts.count - 2]
        return version.isEmpty ? nil : version
    }

    // MARK: - Solver file discovery

    /// Finds the yt-dlp EJS vendor file under Homebrew using `posix_spawn`/`find`.
    private func findSolverFile(_ filename: String) async -> String? {
        return await Task.detached(priority: .background) { [filename] in
            let args = ["/usr/bin/find", "/opt/homebrew", "-name", filename,
                        "-path", "*/yt_dlp/*", "-maxdepth", "15"]
            let output = YouTubeNDescrambler.spawnAndRead(path: "/usr/bin/find", args: args)
            return output.components(separatedBy: "\n").first { !$0.isEmpty }
        }.value
    }

    // MARK: - Deno runner

    /// Writes the solver script to a temp file and invokes Deno via `posix_spawn`.
    private func runDeno(script: String, scrambledKey: String) async -> String? {
        let log = self.log
        return await Task.detached(priority: .userInitiated) { [script, scrambledKey] in
            // Write script to a temp file; avoids the stdin-deadlock risk with large payloads.
            let scriptPath = "/tmp/yt_n_solver_\(Int(Date().timeIntervalSince1970)).ts"
            guard let scriptData = script.data(using: .utf8),
                  (try? scriptData.write(to: URL(fileURLWithPath: scriptPath))) != nil else { return nil }
            defer { try? FileManager.default.removeItem(atPath: scriptPath) }

            let args = ["/opt/homebrew/bin/deno", "run",
                        "--allow-read", "--allow-net", "--allow-env", scriptPath]
            let raw = YouTubeNDescrambler.spawnAndRead(
                path: "/opt/homebrew/bin/deno", args: args
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            // Expected: {"type":"result","responses":[{"type":"result","data":{"SCRAMBLED":"DESCRAMBLED"}}]}
            guard let jsonData = raw.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let responses = root["responses"] as? [[String: Any]],
                  let first = responses.first,
                  let resultData = first["data"] as? [String: String],
                  let descrambled = resultData[scrambledKey] else {
                log.error("Deno solver: unexpected output — raw='\(raw.prefix(300))'")
                return nil
            }
            return descrambled
        }.value
    }

    // MARK: - posix_spawn helper

    /// Launches `path` with `args`, captures stdout, and returns it as a String.
    /// Stderr is suppressed. Blocks until the child exits.
    private static func spawnAndRead(path: String, args: [String]) -> String {
        var stdoutFDs = [Int32](repeating: 0, count: 2) // [0]=read [1]=write
        guard Darwin.pipe(&stdoutFDs) == 0 else { return "" }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Child stdout → write end of pipe.
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFDs[1], STDOUT_FILENO)
        // Close read end in child (it's the parent's read handle).
        posix_spawn_file_actions_addclose(&fileActions, stdoutFDs[0])

        // Suppress stderr by redirecting to /dev/null.
        let devNull = Darwin.open("/dev/null", O_WRONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDERR_FILENO)
        }

        // Build C argument array: [execPath, arg1, arg2, ..., nil]
        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)
        defer { cArgs.compactMap { $0 }.forEach { free($0) } }

        // Inherit parent environment so Deno can find its npm cache (DENO_DIR, HOME, etc.).
        var pid: pid_t = 0
        let spawnRet = withUnsafeMutablePointer(to: &fileActions) { fa in
            cArgs.withUnsafeMutableBufferPointer { argv in
                posix_spawn(&pid, path, fa, nil, argv.baseAddress!, environ)
            }
        }

        // Close write end in parent (child now owns it; closing here lets read() return EOF).
        Darwin.close(stdoutFDs[1])
        if devNull >= 0 { Darwin.close(devNull) }

        guard spawnRet == 0 else {
            Darwin.close(stdoutFDs[0])
            return ""
        }

        // Read all stdout.
        var output = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(stdoutFDs[0], &buf, buf.count)
            if n <= 0 { break }
            output.append(contentsOf: buf.prefix(Int(n)))
        }
        Darwin.close(stdoutFDs[0])
        Darwin.waitpid(pid, nil, 0)

        return String(data: output, encoding: .utf8) ?? ""
    }

    // MARK: - Utilities

    private func jsonString(_ value: String) -> String {
        // JSONEncoder.encode(_:) correctly serialises a Swift String as a JSON string literal.
        // NSJSONSerialization.dataWithJSONObject: throws an NSException (not a Swift Error)
        // when passed a bare String, so it must not be used here.
        if let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Fallback: manual escaping.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
#endif
