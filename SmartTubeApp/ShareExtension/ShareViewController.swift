import UIKit
import UniformTypeIdentifiers
import SmartTubeIOSCore
import os

private let shareLog = Logger(subsystem: "com.void.smarttube.app.shareextension", category: "Share")

// MARK: - ShareViewController
//
// Presents a compact sheet with an "Open in SmartTube" button. The button tap
// is user-initiated, which is required for `extensionContext?.open(_:)` to
// reliably launch the containing app from a Share Extension in modern iOS —
// programmatic (non-user-initiated) calls are not honoured when the host is a
// third-party app such as the YouTube app.
//
// The video ID is also written to the shared App Group UserDefaults as a
// fallback so `AppEntry.consumePendingVideoID()` can pick it up.

final class ShareViewController: UIViewController {

    private static let appGroup   = "group.com.void.smarttube"
    private static let pendingKey = "pendingVideoID"

    // Set after successful URL extraction; nil means extraction failed or pending.
    private var deeplink: URL?

    // MARK: - UI

    private let spinner: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .medium)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let openButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Open in SmartTube"
        config.cornerStyle = .large
        config.baseBackgroundColor = UIColor(red: 0.40, green: 0.20, blue: 0.80, alpha: 1)
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isHidden = true
        return b
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "Looking for video\u{2026}"
        l.textColor = .secondaryLabel
        l.font = .systemFont(ofSize: 15)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: view.bounds.width, height: 130)

        view.addSubview(spinner)
        view.addSubview(openButton)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            openButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            openButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        spinner.startAnimating()
        openButton.addTarget(self, action: #selector(openButtonTapped), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shareLog.notice("viewDidAppear — starting extraction")
        Task { @MainActor in await extractAndPrepare() }
    }

    // MARK: - User action

    @objc private func openButtonTapped() {
        guard let deeplink else {
            shareLog.error("openButtonTapped — deeplink is nil")
            return
        }
        shareLog.notice("openButtonTapped — \(deeplink.absoluteString, privacy: .public)")

        // Strategy 1: extensionContext?.open() — officially only for Today/iMessage but
        // works for share extensions on iOS 14+ in practice when called user-initiated.
        if let ctx = extensionContext {
            ctx.open(deeplink, completionHandler: nil)
            shareLog.notice("dispatched via extensionContext.open")
            return
        }

        // Strategy 2: Walk the responder chain to find the extension's UIApplication
        // and call the modern open(_:options:completionHandler:) on it. The extension
        // process owns its own UIApplication which CAN dispatch URLs via the system.
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                shareLog.notice("dispatching via UIApplication responder chain")
                app.open(deeplink, options: [:], completionHandler: nil)
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            responder = r.next
        }

        shareLog.error("neither extensionContext nor UIApplication found — relying on App Group fallback")
        // App Group write already happened in extractAndPrepare(). User will see the video
        // next time they open SmartTube manually.
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Extraction

    @MainActor
    private func extractAndPrepare() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            shareLog.error("No inputItems — cancelling")
            cancel(); return
        }

        shareLog.notice("inputItems count: \(items.count, privacy: .public)")

        guard let (videoID, _) = await resolveVideoID(from: items) else {
            shareLog.error("No YouTube URL found")
            spinner.stopAnimating()
            spinner.isHidden = true
            statusLabel.text = "Cannot find a YouTube video URL."
            statusLabel.textColor = .secondaryLabel
            try? await Task.sleep(for: .seconds(2))
            cancel()
            return
        }

        shareLog.notice("videoID: \(videoID, privacy: .public)")

        // Write to App Group (reliable data-transfer fallback)
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(videoID, forKey: Self.pendingKey)
            defaults.synchronize()
            shareLog.notice("wrote to App Group")
        } else {
            shareLog.error("FAILED to open App Group \(Self.appGroup, privacy: .public)")
        }

        guard let link = URL(string: "smarttube://video/\(videoID)") else {
            shareLog.error("failed to build deeplink — cancelling")
            cancel(); return
        }

        deeplink = link

        // Show the button — user tap is required for extensionContext.open
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.isHidden = true
        openButton.isHidden = false
    }

    // MARK: - URL resolution

    /// Extracts all candidate URLs from the NSExtensionItem list, then runs each
    /// through `URLVideoResolver` (direct parse → redirect chain → scrape).
    /// Returns the first `(videoID, deeplink)` pair found, or `nil`.
    private func resolveVideoID(from items: [NSExtensionItem]) async -> (String, URL)? {
        let resolver = URLVideoResolver()
        for (i, item) in items.enumerated() {
            let attachments = item.attachments ?? []
            shareLog.notice("item[\(i, privacy: .public)] attachments: \(attachments.count, privacy: .public)")
            for (j, provider) in attachments.enumerated() {
                shareLog.notice("  provider[\(j, privacy: .public)] types: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
                guard let url = await loadURL(from: provider, index: j) else { continue }
                if let id = await resolver.resolve(url: url) {
                    guard let link = URL(string: "smarttube://video/\(id)") else { continue }
                    return (id, link)
                }
            }
        }
        return nil
    }

    /// Tries `public.url` first, then `public.plain-text` as a fallback.
    private func loadURL(from provider: NSItemProvider, index j: Int) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            shareLog.notice("  provider[\(j, privacy: .public)] url loaded: \(String(describing: loaded), privacy: .public)")
            if let u = loaded as? URL { return u }
            if let s = loaded as? String { return URL(string: s) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let s = loaded as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                shareLog.notice("  provider[\(j, privacy: .public)] text fallback: \(trimmed, privacy: .public)")
                return URL(string: trimmed)
            }
        }
        return nil
    }

    // MARK: - Cancel

    private func cancel() {
        shareLog.notice("cancel() called")
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.void.smarttube.share", code: 0, userInfo: nil)
        )
    }
}

