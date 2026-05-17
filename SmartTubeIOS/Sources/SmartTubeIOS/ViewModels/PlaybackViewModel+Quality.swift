import AVFoundation
import SmartTubeIOSCore

// MARK: - Stream Format / HLS Quality Selection (thin wrapper — logic lives in PlaybackQualityManager)

extension PlaybackViewModel {

    public func selectFormat(_ format: VideoFormat?) {
        qualityManager.selectFormat(format)
    }

    func reloadHLSItem(seekTo time: TimeInterval, qualityCap: Int?) async {
        await qualityManager.reloadHLSItem(seekTo: time, qualityCap: qualityCap)
    }

    func fetchHLSVariantURLs(url: URL) async -> [Int: URL] {
        await qualityManager.fetchHLSVariantURLs(url: url)
    }

    static func deduplicatedVideoFormats(_ formats: [VideoFormat]) -> [VideoFormat] {
        PlaybackQualityManager.deduplicatedVideoFormats(formats)
    }

    func peakBitRate(for height: Int) -> Double {
        qualityManager.peakBitRate(for: height)
    }

    func applyQualityPreference(to masterURL: URL) -> URL {
        qualityManager.applyQualityPreference(to: masterURL)
    }

    func reloadHLSItemH264Capped(seekTo time: TimeInterval) async {
        await qualityManager.reloadHLSItemH264Capped(seekTo: time)
    }
}
