import Foundation

/// An observation of complete resident bytes immediately ahead of playback.
/// Neither peer traffic nor the prefetch reader's cumulative HTTP progress is a
/// substitute: distant pieces and holes cannot extend this contiguous prefix.
struct SPTorrentBufferMetrics: Equatable {
    let aheadBytes: Int64
    let targetBytes: Int64

    var fraction: Double? {
        guard targetBytes > 0 else { return nil }
        return min(1, max(0, Double(aheadBytes) / Double(targetBytes)))
    }

    init?(cache: SPTorrentCacheSnapshot?, file: SPTorrentFile,
          playbackOffset: Int64, forwardUpperBound: Int64) {
        guard let cache, cache.fileID == file.id, cache.fileLength == file.length,
              playbackOffset >= 0, playbackOffset <= file.length,
              forwardUpperBound >= playbackOffset, forwardUpperBound <= file.length else { return nil }
        targetBytes = forwardUpperBound - playbackOffset
        let extent = cache.ranges.first {
            $0.lowerBound <= playbackOffset && playbackOffset < $0.upperBound
        }
        aheadBytes = extent.map { min($0.upperBound, forwardUpperBound) - playbackOffset } ?? 0
    }
}

/// A successful HTTP read is not proof that its pieces are still resident.
/// Plan only the earliest missing span, stopping at the next actual resident
/// range so repair does not reread the useful remainder of the cache.
struct SPTorrentCacheRefillPlan: Equatable {
    let missingRange: SPTorrentCachedByteRange?

    init?(cache: SPTorrentCacheSnapshot?, file: SPTorrentFile,
          playbackOffset: Int64, forwardUpperBound: Int64) {
        guard let cache, cache.fileID == file.id, cache.fileLength == file.length,
              playbackOffset >= 0, playbackOffset <= file.length,
              forwardUpperBound >= playbackOffset, forwardUpperBound <= file.length else { return nil }
        var cursor = playbackOffset
        for range in cache.ranges {
            if cursor >= forwardUpperBound { break }
            if range.upperBound <= cursor { continue }
            if range.lowerBound > cursor {
                missingRange = .init(lowerBound: cursor, upperBound: min(range.lowerBound, forwardUpperBound))
                return
            }
            cursor = min(range.upperBound, forwardUpperBound)
        }
        missingRange = cursor < forwardUpperBound
            ? .init(lowerBound: cursor, upperBound: forwardUpperBound) : nil
    }
}
