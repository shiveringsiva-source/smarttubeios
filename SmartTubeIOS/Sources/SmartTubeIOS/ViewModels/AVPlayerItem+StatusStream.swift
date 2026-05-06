import AVFoundation

extension AVPlayerItem {
    /// An `AsyncStream` that emits the item's `status` on each KVO change.
    var statusStream: AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let observer = observe(\.status, options: [.initial, .new]) { item, _ in
                continuation.yield(item.status)
                if item.status == .readyToPlay || item.status == .failed {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in observer.invalidate() }
        }
    }
}
