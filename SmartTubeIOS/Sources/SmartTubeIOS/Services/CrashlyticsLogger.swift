import Foundation
import os
import FirebaseCrashlytics
import SmartTubeIOSCore

/// Logs to `os.Logger` and forwards `.notice` and `.error` entries to Firebase
/// Crashlytics as breadcrumbs so they appear in crash reports.
/// `.debug` entries are only written to `os.log` — too verbose for crash reports.
struct CrashlyticsLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(subsystem: String = appSubsystem, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func notice(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.notice("\(msg, privacy: .public)")
        Crashlytics.crashlytics().log("[\(category)] \(msg)")
    }

    func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        Crashlytics.crashlytics().log("[ERR][\(category)] \(msg)")
    }

    func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        // Not forwarded — too verbose for crash reports
    }

    /// Records a non-fatal error in Crashlytics with additional key-value context.
    /// Use this for surfaced errors the user sees (e.g. player errors) so they
    /// appear as non-fatal issues in the Firebase console.
    func recordNonFatal(_ error: Error, userInfo: [String: String] = [:]) {
        let nsError = error as NSError
        let msg = "[\(category)] \(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
        logger.error("\(msg, privacy: .public)")
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log(msg)
        for (key, value) in userInfo {
            crashlytics.setCustomValue(value, forKey: key)
        }
        crashlytics.record(error: error)
    }

    /// Stamps the video currently being loaded onto Crashlytics' persistent custom keys.
    /// Called once per `load(video:)` so that both crashes and non-fatals show which
    /// video was active at the time of the failure.
    static func setVideoContext(id: String, title: String) {
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCustomValue(id, forKey: "active_video_id")
        crashlytics.setCustomValue(title.prefix(120).description, forKey: "active_video_title")
    }

    /// Records a user-triggered diagnostic non-fatal event in Crashlytics.
    /// All breadcrumbs accumulated during the session are attached to this event,
    /// giving a detailed picture of the app flow leading up to the user's report.
    static func sendDiagnosticReport() {
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log("[Diagnostic] User-requested diagnostic report — see breadcrumbs for session flow.")
        let error = NSError(
            domain: "SmartTube.UserDiagnostic",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "User-requested diagnostic report"]
        )
        crashlytics.record(error: error)
    }

    /// Automatically records a diagnostic report when playback fails and the error is
    /// shown to the user. Uses domain `SmartTube.AutoDiagnostic` (code 1) so it appears
    /// as a distinct Firebase issue from user-triggered reports, making it easy to query
    /// "all sessions where a user couldn't play a video" without manual intervention.
    /// Custom keys set by `recordNonFatal` (stream_url, has_retried, etc.) are already
    /// stamped on the Crashlytics instance and are automatically attached to this event.
    static func sendAutoPlaybackDiagnostic() {
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.log("[AutoDiagnostic] Playback failure — see custom keys and session breadcrumbs.")
        crashlytics.setCustomValue("auto", forKey: "trigger")
        crashlytics.record(error: NSError(
            domain: "SmartTube.AutoDiagnostic",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Playback failure — see session breadcrumbs"]
        ))
    }
}
