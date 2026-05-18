import AVFoundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Stats for Nerds

extension PlaybackViewModel {

    public func toggleStatsForNerds() {
        statsForNerdsVisible.toggle()
        if statsForNerdsVisible { updateStatsSnapshot() }
    }

    func updateStatsSnapshot() {
        guard let item = player.currentItem else {
            statsSnapshot = .empty
            return
        }
        let logEvent = item.accessLog()?.events.last
        let videoId = playerInfo?.video.id ?? currentVideo?.id ?? ""

        // Resolution – prefer actual presentation size, fall back to format metadata
        let presentationSize = item.presentationSize
        let res: String
        if presentationSize.width > 0 && presentationSize.height > 0 {
            res = "\(Int(presentationSize.width))×\(Int(presentationSize.height))"
        } else if let fmt = selectedFormat, fmt.height > 0 {
            res = fmt.width > 0 ? "\(fmt.width)×\(fmt.height)" : "\(fmt.height)p"
        } else {
            res = "—"
        }

        let fps = selectedFormat?.fps ?? 0

        // Codec: reflect the stream type in the stats overlay.
        // All quality is delivered via HLS; use the selected format's mimeType when available.
        let codec: String
        if let fmt = selectedFormat {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else if playerInfo?.hlsURL != nil {
            codec = "HLS"
        } else if playerInfo?.dashURL != nil {
            codec = "DASH"
        } else if let fmt = playerInfo?.formats.first {
            codec = Self.extractCodec(from: fmt.mimeType)
        } else {
            codec = "—"
        }

        let nominalBitrate: String
        if let br = selectedFormat?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else if playerInfo?.hlsURL != nil || playerInfo?.dashURL != nil {
            nominalBitrate = "Adaptive"
        } else if let br = playerInfo?.formats.first?.bitrate, br > 0 {
            nominalBitrate = Self.formatBitrate(br)
        } else {
            nominalBitrate = "—"
        }

        let observedBitrate: String
        if let br = logEvent?.observedBitrate, br > 0 {
            observedBitrate = Self.formatBitrate(Int(br))
        } else {
            observedBitrate = "—"
        }

        let droppedFrames = logEvent.map { $0.numberOfDroppedVideoFrames } ?? 0
        let stalls = logEvent.map { $0.numberOfStalls } ?? 0

        statsSnapshot = StatsForNerdsSnapshot(
            videoId: videoId,
            displayResolution: res,
            fps: fps,
            codec: codec,
            nominalBitrate: nominalBitrate,
            observedBitrate: observedBitrate,
            droppedFrames: droppedFrames,
            stalls: stalls,
            reportID: CrashlyticsLogger.sessionReportID
        )
    }

    static func extractCodec(from mimeType: String) -> String {
        if mimeType.contains("mpegURL") || mimeType.contains("m3u8") { return "HLS" }
        if let range = mimeType.range(of: #"codecs="([^"]+)""#, options: .regularExpression) {
            let matched = String(mimeType[range])
            if let valueRange = matched.range(of: #"(?<==)[^"]+"#, options: .regularExpression) {
                let codecs = String(matched[valueRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let first = codecs.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? codecs
                return first.components(separatedBy: ".").first ?? first
            }
        }
        if mimeType.contains("mp4")  { return "mp4" }
        if mimeType.contains("webm") { return "webm" }
        return mimeType.isEmpty ? "—" : mimeType
    }

    static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
        if bps >= 1_000     { return String(format: "%.0f kbps", Double(bps) / 1_000) }
        return "\(bps) bps"
    }
}

// MARK: - StatsForNerdsSnapshot

/// Snapshot of playback diagnostics for the "Stats for Nerds" overlay.
public struct StatsForNerdsSnapshot: Sendable {
    public var videoId: String
    public var displayResolution: String
    public var fps: Int
    public var codec: String
    public var nominalBitrate: String
    public var observedBitrate: String
    public var droppedFrames: Int
    public var stalls: Int
    /// Session report ID — matches the `report_id` custom key stamped on Crashlytics
    /// reports. Quote this when sending a diagnostic report so the developer can
    /// locate the exact session in Firebase.
    public var reportID: String

    public static let empty = StatsForNerdsSnapshot(
        videoId: "",
        displayResolution: "",
        fps: 0,
        codec: "",
        nominalBitrate: "",
        observedBitrate: "",
        droppedFrames: 0,
        stalls: 0,
        reportID: CrashlyticsLogger.sessionReportID
    )
}
