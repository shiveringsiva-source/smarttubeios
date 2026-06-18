#if !os(tvOS)
import Foundation

/// JS source strings and embed-URL/HTML-wrapper helpers shared by the Task 1
/// iframe-src-swap spike (`ShortsEmbedSrcSwapSpikeViewModel`) and, from Task 4
/// onward, `ShortsEmbedPlayerViewModel`.
///
/// `embedURL`/`htmlWrapper` intentionally duplicate what Task 2 extracts as a pure
/// function in `SmartTubeIOSCore` (`ShortsEmbedURL.swift`). Task 1 cannot depend on
/// Task 2 — the spike must be self-contained and runnable first. Once Task 2 lands,
/// `ShortsEmbedPlayerViewModel` (Task 4) uses the `SmartTubeIOSCore` version; these
/// copies remain spike-only.
enum ShortsEmbedJS {

    /// Injected at `.atDocumentStart` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.webkitHiderJS` (TOSPlayerViewModel.swift:460-475). Hides
    /// `window.webkit` before any page script runs so YouTube's player can't detect
    /// the WKWebView environment, and stashes the native `ytCallback` handler as
    /// `window.__nativeYTCallback` for `stateDetectionJS` to use.
    static let webkitHiderJS: String = """
    (function() {
        try {
            var wk = window.webkit;
            if (!wk) return;
            var mh = wk.messageHandlers;
            window.__nativeYTCallback = (mh && mh.ytCallback) ? mh.ytCallback : null;
            Object.defineProperty(window, 'webkit', {
                get: function() { return undefined; },
                set: function() {},
                configurable: true,
                enumerable: false
            });
        } catch(e) {}
    })();
    """

    /// Injected at `.atDocumentStart` into every frame. Hides all YouTube Shorts
    /// chrome without depending on class names or z-index tricks.
    ///
    /// Earlier version blanket-hid every `body *` via `visibility:hidden` and
    /// re-showed only `video` with `visibility:visible !important` — CSS-spec-legal
    /// (a descendant CAN override an ancestor's `visibility:hidden`), but setting
    /// `visibility:hidden` on an ancestor of a hardware-composited `<video>` layer
    /// is a known WebKit footgun (the ancestor's subtree can lose layer promotion
    /// regardless of a descendant's own `visibility`). #275's investigation found
    /// real on-screen black frames via `ShortsVisualPlaybackUITests`' pixel-brightness
    /// assertions, but ALSO found that a large fraction of embeds fail within a few
    /// seconds with a generic iframe error 153 ("An error occurred. Please try again
    /// later.") — separate from this CSS and likely the dominant cause of the
    /// reported black screens (see `advanceAfterError` / the per-VM `[ytCallback] ❌
    /// player error` log lines). Disabling this script entirely did not reliably fix
    /// brightness in every trial, so the CSS is not confirmed as the sole cause.
    ///
    /// This version is changed as a no-regret hardening regardless: it never sets
    /// `visibility:hidden` on any ancestor of `<video>`. It walks up from the video
    /// to `<body>`, tags every ancestor on that path with `__st_keep` (kept
    /// `visibility:visible`, but stripped of its own background/border/shadow so it
    /// doesn't paint a visible box), and only blanket-hides elements OFF that path —
    /// i.e. true UI chrome siblings (channel header, Shorts logo, share button,
    /// pause bezel), never anything in the video's own compositing chain.
    ///
    /// `window === window.top` guard: bails immediately in the wrapper page so
    /// we do not accidentally hide the `<iframe>` itself in the outer document.
    ///
    /// MutationObserver re-runs `apply()` whenever YouTube's JS mutates the DOM —
    /// re-tagging the path (cheap) and reusing the existing `<style>` tag (CSS
    /// rules are static; only which elements carry `__st_keep` can change).
    static let playerControlsHiderJS: String = """
    (function() {
        // Only run inside the YouTube embed iframe, not the wrapper page.
        if (window === window.top) return;

        function apply() {
            try {
                var video = document.querySelector('video');
                if (!video) return;

                // Tag the video's ancestor chain so the blanket-hide rule below
                // never touches anything in its compositing path.
                document.querySelectorAll('.__st_keep').forEach(function(el) {
                    el.classList.remove('__st_keep');
                });
                var node = video.parentElement;
                while (node && node !== document.documentElement) {
                    node.classList.add('__st_keep');
                    node = node.parentElement;
                }

                if (!document.getElementById('__st_css')) {
                    var s = document.createElement('style');
                    s.id = '__st_css';
                    // position:fixed is required on video: height:100% resolves to 0
                    // when the parent div has height:auto (no explicit height). With
                    // position:fixed the containing block is the iframe viewport, so
                    // height:100% = full iframe height (confirmed via [DIAG] eval:
                    // w=402 h=0 before fix — width was correct but height was zero).
                    s.textContent =
                        'html,body{background:#000!important;' +
                            'margin:0!important;padding:0!important}' +
                        'body *{visibility:hidden!important}' +
                        '.__st_keep{visibility:visible!important;' +
                            'background:transparent!important;border:none!important;' +
                            'box-shadow:none!important}' +
                        'video{visibility:visible!important;' +
                            'position:fixed!important;top:0!important;left:0!important;' +
                            'width:100%!important;height:100%!important;' +
                            'object-fit:cover!important;background:#000!important}';
                    (document.head || document.documentElement).appendChild(s);
                }
            } catch(e) {}
        }

        apply();
        new MutationObserver(apply).observe(document.documentElement, {childList: true, subtree: true});
    })();
    """

    /// Injected at `.atDocumentEnd` into every frame — verbatim copy of
    /// `TOSPlayerViewModel.stateDetectionJS` (TOSPlayerViewModel.swift:480-587). Polls
    /// the `<video>` element every 250ms and relays `ping`/`ready`/`tick`/`stateChange`/
    /// `autoUnmuted`/`error` via `window.__nativeYTCallback.postMessage`.
    static let stateDetectionJS: String = """
    (function() {
        try {
            var _cb = window.__nativeYTCallback;
            if (_cb) _cb.postMessage('{"type":"ping"}');
        } catch(e) {}

        var _prevState = -2;
        var _playAttempts = 0;
        var _autoUnmuted = false;

        function postMsg(obj) {
            try {
                var cb = window.__nativeYTCallback;
                if (cb) cb.postMessage(JSON.stringify(obj));
            } catch(e) {}
        }

        var _errorReported = false;
        function checkErrorOverlay(node) {
            if (_errorReported) return;
            var errEl = node.nodeType === 1 && (
                (node.classList && node.classList.contains('ytp-error')) ||
                node.querySelector && node.querySelector('.ytp-error')
            );
            if (!errEl) return;
            _errorReported = true;
            var txt = (typeof errEl === 'object' ? (errEl.textContent || '') : (node.textContent || ''));
            var m = txt.match(/Error\\s+(\\d+)/i);
            postMsg({type: 'error', code: m ? parseInt(m[1], 10) : 153, text: txt.trim().substring(0, 200)});
        }
        var _observer = new MutationObserver(function(mutations) {
            for (var i = 0; i < mutations.length; i++) {
                var added = mutations[i].addedNodes;
                for (var j = 0; j < added.length; j++) { checkErrorOverlay(added[j]); }
            }
        });
        _observer.observe(document.documentElement, {childList: true, subtree: true});

        function pollVideo() {
            var video = document.querySelector('video');
            if (!video) return;

            var s;
            if (video.ended) {
                s = 0;
            } else if (video.paused) {
                s = 2;
            } else if (video.readyState >= 3) {
                s = 1;
            } else {
                s = 3;
            }

            var t = video.currentTime || 0;

            if (_prevState === -2) {
                var dur = video.duration || 0;
                if (dur <= 0) {
                    // Metadata not loaded yet on this poll — stay in the "not yet
                    // ready" sentinel state and try again on the next 250ms tick
                    // rather than firing "ready" with a bogus duration of 0.
                    return;
                }
                _prevState = s;
                postMsg({type: 'ready', duration: dur,
                         readyState: video.readyState, buffered: video.buffered.length});
            }

            if (video.paused && t === 0 && _playAttempts < 20) {
                _playAttempts++;
                video.muted = true;
                var p = video.play();
                if (p && p['catch']) { p['catch'](function() {}); }
            }

            if (!_autoUnmuted && !video.paused && t > 0.1) {
                _autoUnmuted = true;
                video.muted = false;
                var ytPlayer = document.getElementById('movie_player');
                if (ytPlayer && typeof ytPlayer.unMute === 'function') { ytPlayer.unMute(); }
                postMsg({type: 'autoUnmuted', t: t, muted: video.muted});
            }

            postMsg({type: 'tick', t: t, state: s});

            if (s !== _prevState) {
                _prevState = s;
                postMsg({type: 'stateChange', state: s});
            }
        }

        setInterval(pollVideo, 250);
    })();
    """

    /// Builds `https://www.youtube.com/embed/{videoId}?...` — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s query items (TOSPlayerViewModel.swift:405-416).
    static func embedURL(videoId: String, startTime: Double = 0) -> URL {
        var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoId)")!
        comps.queryItems = [
            URLQueryItem(name: "autoplay",       value: "1"),
            URLQueryItem(name: "mute",           value: "1"),
            URLQueryItem(name: "controls",       value: "0"),
            URLQueryItem(name: "playsinline",    value: "1"),
            URLQueryItem(name: "rel",            value: "0"),
            URLQueryItem(name: "iv_load_policy", value: "3"),
            URLQueryItem(name: "start",          value: "\(Int(startTime))"),
            URLQueryItem(name: "origin",         value: "https://www.example.com"),
        ]
        return comps.url!
    }

    /// Wraps an embed URL in the `<iframe id="yt">` HTML page — mirrors
    /// `TOSPlayerViewModel.loadEmbed`'s HTML template (TOSPlayerViewModel.swift:427-446).
    static func htmlWrapper(embedURL: URL) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
                html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#000}
                iframe{position:absolute;top:0;left:0}
            </style>
        </head>
        <body>
            <iframe id="yt"
                src="\(embedURL.absoluteString)"
                frameborder="0"
                allow="autoplay; encrypted-media; fullscreen"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
    }
}
#endif
