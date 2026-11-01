import Foundation

@main struct Checks {
    static func main() {
        var count = 0
        func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
            precondition(ok(), name); count += 1
        }
        let hash = String(repeating: "a", count: 40)
        let file = SPTorrentFile(id: 1, path: "Season/episode.mp4", length: 1_000)
        func cache(_ ranges: [[Int64]]) -> SPTorrentCacheSnapshot {
            let resident = ranges.reduce(Int64(0)) { $0 + $1[1] - $1[0] }
            return SPTorrentCacheSnapshot(json: ["hash": hash, "file_index": 1,
                "file_offset": 0, "file_length": 1_000, "piece_length": 10,
                "resident_bytes": resident, "ranges": ranges], expectedHash: hash, file: file)!
        }
        func measure(_ ranges: [[Int64]], _ offset: Int64 = 100, _ upper: Int64 = 600) -> SPTorrentBufferMetrics? {
            .init(cache: cache(ranges), file: file, playbackOffset: offset, forwardUpperBound: upper)
        }
        let fragmented = measure([[0, 50], [100, 200], [210, 1_000]])!
        expect(fragmented.aheadBytes == 100, "a large distant cache cannot cross a ten-byte hole")
        expect(fragmented.targetBytes == 500, "target is the approved forward window, not global RAM size")
        expect(fragmented.fraction == 0.2, "only the contiguous resident prefix fills the bar")
        expect(measure([[110, 1_000]])?.aheadBytes == 0, "a missing current piece is zero even with890bytes elsewhere")
        expect(measure([[0, 100], [110, 1_000]])?.aheadBytes == 0, "half-open end does not bridge current gap")
        expect(measure([[100, 1_000]])?.aheadBytes == 500, "cap resident extent at worker-approved bound")
        expect(measure([[100, 1_000]])?.fraction == 1, "a complete forward window is full")
        expect(measure([[100, 200]], 150, 600)?.aheadBytes == 50, "playback consumes the prefix")
        expect(measure([[0, 100], [200, 1_000]], 500, 800)?.aheadBytes == 300, "seek measures the new position")
        expect(measure([[0, 200]], 500, 800)?.aheadBytes == 0, "old cached scene is not the new buffer")
        expect(measure([])?.aheadBytes == 0, "known empty cache is zero")
        expect(measure([[100, 200]], 200, 600)?.aheadBytes == 0, "last cached byte is not an extra piece")
        expect(measure([[0, 1_000]], 1_000, 1_000)?.targetBytes == 0, "end of file is an empty target")
        expect(measure([[0, 1_000]], 1_000, 1_000)?.fraction == nil, "no divide by zero or invented100percent atEOF")
        expect(measure([], -1, 600) == nil, "unknown playback anchor stays unknown")
        expect(measure([], 601, 600) == nil, "stale forward bound stays unknown")
        expect(measure([], 100, 1_001) == nil, "out-of-file bound rejected")
        expect(SPTorrentBufferMetrics(cache: nil, file: file, playbackOffset: 100, forwardUpperBound: 600) == nil,
               "absent observation is not zero or filled")
        expect(SPTorrentBufferMetrics(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 2, path: file.path, length: file.length),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "another file cannot paint this row")
        expect(SPTorrentBufferMetrics(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 1, path: file.path, length: 2_000),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "changed manifest length rejected")
        func plan(_ ranges: [[Int64]], _ offset: Int64 = 100, _ upper: Int64 = 600) -> SPTorrentCacheRefillPlan? {
            .init(cache: cache(ranges), file: file, playbackOffset: offset, forwardUpperBound: upper)
        }
        let firstGap = plan([[100, 200], [210, 1_000]])!
        expect(firstGap.missingRange == .init(lowerBound: 200, upperBound: 210),
               "repair the earliest hole without rereading distant resident data")
        expect(plan([[110, 1_000]])?.missingRange == .init(lowerBound: 100, upperBound: 110),
               "a missing playback piece wins over a distant decoder cursor")
        expect(plan([[100, 200], [210, 400], [410, 1_000]])?.missingRange == .init(lowerBound: 200, upperBound: 210),
               "later holes cannot skip the first missing piece")
        expect(plan([[0, 90], [100, 200]])?.missingRange == .init(lowerBound: 200, upperBound: 600),
               "ignore history and repair only the missing forward tail")
        expect(plan([[100, 200], [800, 1_000]])?.missingRange == .init(lowerBound: 200, upperBound: 600),
               "worker-approved upper clips repair before an out-of-window resident range")
        expect(plan([])?.missingRange == .init(lowerBound: 100, upperBound: 600),
               "known empty residency repairs exactly the approved forward window")
        expect(plan([[100, 1_000]]) != nil && plan([[100, 1_000]])?.missingRange == nil,
               "known complete residency is distinguishable from an unknown observation")
        expect(plan([[0, 1_000]], 1_000, 1_000)?.missingRange == nil, "EOF needs no repair")
        expect(plan([[100, 200]], 200, 600)?.missingRange == .init(lowerBound: 200, upperBound: 600),
               "half-open resident end is the first missing byte")
        expect(plan([[100, 200]], 100, 150)?.missingRange == nil, "a fully resident smaller quota needs no repair")
        expect(plan([], -1, 600) == nil && plan([], 601, 600) == nil && plan([], 100, 1_001) == nil,
               "invalid or stale approved bounds cannot authorize a repair")
        expect(SPTorrentCacheRefillPlan(cache: nil, file: file, playbackOffset: 100, forwardUpperBound: 600) == nil,
               "a failed cache observation does not invent a missing range")
        expect(SPTorrentCacheRefillPlan(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 2, path: file.path, length: file.length),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "another file cannot authorize repair")
        expect(SPTorrentCacheRefillPlan(cache: cache([[100, 200]]),
            file: SPTorrentFile(id: 1, path: file.path, length: 2_000),
            playbackOffset: 100, forwardUpperBound: 600) == nil, "changed file length cannot authorize repair")
        let episode = SPTorrentFile(id: 1, path: "owned-episode.mp4", length: 8_589_934_592)
        let resident: [[Int64]] = [[5_595_201_536,5_637_144_576],[5_670_699_008,5_687_476_224],
            [5_695_864_832,5_771_362_304],[5_796_528_128,6_056_574_976],
            [6_073_352_192,6_090_129_408],[7_633_633_280,7_642_021_888],[7_843_348_480,7_851_737_088]]
        let observed = SPTorrentCacheSnapshot(json: ["hash":hash,"file_index":1,"file_offset":0,
            "file_length":episode.length,"piece_length":8_388_608,
            "resident_bytes":resident.reduce(Int64(0)) { $0 + $1[1] - $1[0] },"ranges":resident],
            expectedHash:hash,file:episode)!
        expect(observed.residentBytes == 427_819_008, "reported episode case contains408MiB of actual cache")
        expect(SPTorrentCacheRefillPlan(cache:observed,file:episode,playbackOffset:5_622_664_580,
            forwardUpperBound:6_098_518_016)?.missingRange ==
            .init(lowerBound:5_637_144_576,upperBound:5_670_699_008),
            "reported408MiB case repairs the first32MiB hole rather than trusting440MiB HTTP delivery")
        print("PASS \(count) contiguous resident buffer metrics checks")
    }
}
