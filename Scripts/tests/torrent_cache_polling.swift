import Foundation
import CoreFoundation

// INSERT_MODEL

private struct SPTorrentPlaybackContext {
    struct Descriptor { let hash = "owned-cache-fixture"; let leaseID: UUID }
    struct File { let id: Int; let length: Int64 = 1_000_000 }
    let descriptor: Descriptor
    let file: File
}
private struct SPTorrentCacheSnapshot {
    struct Span { let lowerBound: Int64; let upperBound: Int64 }
    let fileID: Int
    let fileLength: Int64 = 1_000_000
    var ranges: [Span] { [.init(lowerBound: fileID == 7 ? 1000 : 4000, upperBound: fileID == 7 ? 2000 : 5000)] }
}
private struct Status { let sequence: Int }
private enum FixtureError: Error { case unavailable }
@MainActor private final class SPTorrentServer {
    static let shared = SPTorrentServer()
    struct PendingStatus { let id: Int; let reply: CheckedContinuation<Status, any Error> }
    struct PendingCache { let id: Int; let file: Int; let reply: CheckedContinuation<SPTorrentCacheSnapshot, any Error> }
    var statuses: [Int: PendingStatus] = [:]
    var caches: [Int: PendingCache] = [:]
    var statusCount = 0
    var cacheCount = 0
    func status(hash: String) async throws -> Status {
        statusCount += 1
        let id = statusCount
        return try await withCheckedThrowingContinuation { statuses[id] = .init(id: id, reply: $0) }
    }
    func cacheSnapshot(_ descriptor: SPTorrentPlaybackContext.Descriptor,
                       file: SPTorrentPlaybackContext.File) async throws -> SPTorrentCacheSnapshot {
        cacheCount += 1
        let id = cacheCount
        return try await withCheckedThrowingContinuation { caches[id] = .init(id: id, file: file.id, reply: $0) }
    }
    func statusReply(_ id: Int, failing: Bool = false) {
        let pending = statuses.removeValue(forKey: id)!
        if failing { pending.reply.resume(throwing: FixtureError.unavailable) }
        else { pending.reply.resume(returning: Status(sequence: id)) }
    }
    func cacheReply(_ id: Int, failing: Bool = false) {
        let pending = caches.removeValue(forKey: id)!
        if failing { pending.reply.resume(throwing: FixtureError.unavailable) }
        else { pending.reply.resume(returning: SPTorrentCacheSnapshot(fileID: pending.file)) }
    }
    func finish() {
        for pending in statuses.values { pending.reply.resume(throwing: CancellationError()) }
        for pending in caches.values { pending.reply.resume(throwing: CancellationError()) }
        statuses.removeAll(); caches.removeAll()
    }
}
@MainActor private final class Core {
    enum State { case idle, playing }
    var state = State.playing
    var position = 12.0
    var duration = 100.0
    var volume: Float = 0.5
    var isMuted = false
    struct Window { var openGeneration: Int64 = 1; var seekGeneration: Int64 = 1 }
    var sourcePlaybackWindow = Window()
    var seekSettled = true
    func cachedTimeline(forByteRanges bytes: [[NSNumber]]) -> [String: Any] {
        // Explicit fixture anchors; deliberately unrelated to byte/file ratios.
        let ranges = bytes.first?.first?.intValue == 1000 ? [[10.0,20.0]] : [[40.0,50.0]]
        return ["openGeneration": 1, "seekGeneration": 1, "duration": duration,
                "sourceSize": Int64(1_000_000), "completeIndex": false,
                "videoMappingAvailable": true, "videoRanges": ranges]
    }
}
@MainActor private final class Rail {
    var ranges: [ClosedRange<Double>] = []
    var visible = false
    var updates = 0
    var isActive = false
    var playbackUpdates = 0
    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) {
        self.ranges = ranges; self.visible = visible; updates += 1
    }
    func update(isPlaying: Bool, position: Double, duration: Double, volumePercent: Double, muted: Bool) {
        playbackUpdates += 1
    }
}
@MainActor private final class Controller {
    var torrentContext: SPTorrentPlaybackContext?
    var torrentStatusTask: Task<Void, Never>?
    var torrentLastStatus: Status?
    var torrentLastCacheSnapshot: SPTorrentCacheSnapshot?
    // INSERT_REFILL_OBSERVATION
    var torrentPlaybackWindowEpoch = UUID()
    var refillID: UUID? { torrentCacheRefillObservation?.id }
    var refillLease: UUID? { torrentCacheRefillObservation?.leaseID }
    var refillFile: Int? { torrentCacheRefillObservation?.cache.fileID }
    var refillOpen: Int64? { torrentCacheRefillObservation?.openGeneration }
    var refillSeek: Int64? { torrentCacheRefillObservation?.seekGeneration }
    var refillPolicy: UUID? { torrentCacheRefillObservation?.policyEpoch }
    var refillRequestedAt: TimeInterval? { torrentCacheRefillObservation?.requestedAt }
    var torrentTimelinePresentation: SPTorrentTimelinePresentation?
    var core: Core? = Core()
    var hasMediaSession = true
    var chrome: Rail? = Rail()
    let floatingVideo = Rail()
    var pauseUpdates = 0
    var policyStarts = 0
    var refreshes = 0
    func updateTorrentPauseBuffer() { pauseUpdates += 1 }
    func startTorrentPlaybackWindowPolicyIfNeeded() { policyStarts += 1 }
    func refreshPlaylistView() { refreshes += 1 }
    func updateTorrentLoadingForCoreState(_ state: Core.State) {}
    func recordPlaybackDiagnosticSnapshotIfNeeded() {}
    func start(_ context: SPTorrentPlaybackContext) { torrentContext = context; startTorrentStatusUpdates() }
    func changeContextOnly(_ context: SPTorrentPlaybackContext) { torrentContext = context }
    func prime(_ context: SPTorrentPlaybackContext) {
        applyTorrentCacheSnapshot(SPTorrentCacheSnapshot(fileID: context.file.id), context: context)
    }
    func enterPiP() { floatingVideo.isActive = true; updateFloatingVideoPresentation() }
    func close() {
        torrentStatusTask?.cancel(); torrentStatusTask = nil
        torrentContext = nil; clearTorrentCacheTimeline(visible: false)
    }
    // INSERT_POLLING_METHODS
    // INSERT_PIP_UPDATE
}

@main @MainActor private struct CachePollingChecks {
    static var count = 0
    static func check(_ condition: Bool, _ text: String) {
        precondition(condition, text)
        count += 1; print("PASS \(count): \(text)")
    }
    static func wait(_ predicate: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < until else { throw FixtureError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }
    static func main() async throws {
        setbuf(stdout, nil)
        let server = SPTorrentServer.shared
        let lease = UUID()
        let a = SPTorrentPlaybackContext(descriptor: .init(leaseID: lease), file: .init(id: 7))
        let b = SPTorrentPlaybackContext(descriptor: .init(leaseID: lease), file: .init(id: 8))
        let vc = Controller()
        vc.start(a)
        try await wait { server.statuses[1] != nil }
        check(vc.chrome!.visible && vc.chrome!.ranges.isEmpty, "Starting the real poll clears previous coverage before requesting bytes")
        server.statusReply(1)
        try await wait { server.caches[1] != nil }
        check(server.caches[1]!.file == 7, "The cache request uses the captured selected episode")
        vc.start(b)
        try await wait { server.statuses[2] != nil }
        server.statusReply(2)
        try await wait { server.caches[2] != nil }
        server.cacheReply(2)
        try await wait { vc.torrentLastCacheSnapshot?.fileID == 8 }
        check(vc.chrome!.ranges == [0.4...0.5] && vc.floatingVideo.ranges == [0.4...0.5],
              "The current episode publishes its exact mapped coverage to both timelines")
        check(vc.refillID != nil && vc.refillLease == lease && vc.refillFile == 8 &&
              vc.refillOpen == 1 && vc.refillSeek == 1 && vc.refillPolicy == vc.torrentPlaybackWindowEpoch,
              "A fresh cache reply records its exact lease, file, source generations and policy epoch")
        let firstObservation = vc.refillID
        let currentUpdates = vc.chrome!.updates
        server.cacheReply(1)
        await settle()
        check(vc.chrome!.updates == currentUpdates && vc.chrome!.ranges == [0.4...0.5],
              "A cancelled old cache reply cannot repaint a different episode sharing the same lease")
        check(vc.refillID == firstObservation,
              "A cancelled old cache reply cannot replace the current repair observation")
        vc.floatingVideo.ranges = []
        vc.enterPiP()
        check(vc.floatingVideo.playbackUpdates == 1 && vc.floatingVideo.ranges == [0.4...0.5],
              "Entering PiP forwards the latest current-source cache presentation immediately")

        try await wait { server.statuses[3] != nil }
        server.statusReply(3)
        try await wait { server.caches[3] != nil }
        let pauses = vc.pauseUpdates
        server.cacheReply(3, failing: true)
        try await wait { vc.torrentLastCacheSnapshot == nil }
        check(vc.chrome!.ranges.isEmpty && vc.floatingVideo.ranges.isEmpty && vc.chrome!.visible,
              "A current cache-poll failure removes stale resident markings instead of retaining old bars")
        check(vc.refillID == nil, "A current cache-poll failure revokes the resident repair observation")
        check(vc.pauseUpdates == pauses && vc.torrentContext?.file.id == 8,
              "Diagnostic cache-poll failure does not restart or stop the playback/prefetch owner")
        try await wait { server.statuses[4] != nil }
        vc.prime(b)
        server.statusReply(4, failing: true)
        try await wait { vc.torrentLastCacheSnapshot == nil }
        check(vc.chrome!.ranges.isEmpty && vc.floatingVideo.ranges.isEmpty,
              "A current status failure also clears stale cache ranges")

        vc.start(a)
        try await wait { server.statuses[5] != nil }
        server.statusReply(5)
        try await wait { server.caches[4] != nil }
        vc.start(b)
        try await wait { server.statuses[6] != nil }
        server.statusReply(6)
        try await wait { server.caches[5] != nil }
        server.cacheReply(5)
        try await wait { vc.torrentLastCacheSnapshot?.fileID == 8 }
        let beforeLateFailure = vc.chrome!.updates
        server.cacheReply(4, failing: true)
        await settle()
        check(vc.chrome!.updates == beforeLateFailure && vc.chrome!.ranges == [0.4...0.5],
              "A late old cache failure cannot erase the new episode's cache bars")

        vc.start(a)
        try await wait { server.statuses[7] != nil }
        server.statusReply(7)
        try await wait { server.caches[6] != nil }
        vc.changeContextOnly(b)
        vc.prime(b)
        let beforeWrongFile = vc.chrome!.updates
        server.cacheReply(6)
        await settle()
        check(vc.chrome!.updates == beforeWrongFile && vc.torrentLastCacheSnapshot?.fileID == 8,
              "File identity guards reject an old-episode reply even before its task is explicitly cancelled")

        vc.start(a)
        try await wait { server.statuses[8] != nil }
        vc.changeContextOnly(b)
        vc.prime(b)
        let beforeWrongFailure = vc.chrome!.updates
        server.statusReply(8, failing: true)
        await settle()
        check(vc.chrome!.updates == beforeWrongFailure && vc.chrome!.ranges == [0.4...0.5],
              "File identity guards also reject a same-lease old status failure before cancellation")

        vc.start(b)
        try await wait { server.statuses[9] != nil }
        vc.close()
        server.statusReply(9)
        await settle()
        check(!vc.chrome!.visible && !vc.floatingVideo.visible && vc.torrentLastCacheSnapshot == nil,
              "Close/local-source reset stays clear after an outstanding status request completes")
        check(server.cacheCount == 6, "A closed source cannot start another cache request from its late status reply")
        check(vc.refillID == nil, "Close revokes any resident repair authorization")
        server.finish()
        await settle()

        // Exercise the actual suspension between cache request and response.
        // A physical cache map can remain useful to the timeline, but it cannot
        // authorize repair in an epoch that did not issue that observation.
        func beginCache(_ owner: Controller, _ context: SPTorrentPlaybackContext) async throws -> Int {
            let statusID = server.statusCount + 1
            let cacheID = server.cacheCount + 1
            owner.start(context)
            try await wait { server.statuses[statusID] != nil }
            server.statusReply(statusID)
            try await wait { server.caches[cacheID] != nil }
            return cacheID
        }
        for change in ["seek", "open", "policy", "unsettled", "invalidSource"] {
            let owner = Controller()
            let cacheID = try await beginCache(owner, a)
            switch change {
            case "seek": owner.core!.sourcePlaybackWindow.seekGeneration += 1
            case "open": owner.core!.sourcePlaybackWindow.openGeneration += 1
            case "policy": owner.torrentPlaybackWindowEpoch = UUID()
            case "unsettled": owner.core!.seekSettled = false
            default: owner.core!.sourcePlaybackWindow.openGeneration = -1
            }
            server.cacheReply(cacheID)
            try await wait { owner.torrentLastCacheSnapshot != nil }
            check(owner.refillID == nil,
                  "A cache response crossing \(change) cannot authorize resident-gap repair")
            owner.close()
        }
        let owner = Controller()
        let firstCache = try await beginCache(owner, a)
        server.cacheReply(firstCache)
        try await wait { owner.refillID != nil }
        let firstID = owner.refillID
        check(owner.refillRequestedAt.map { $0 <= ProcessInfo.processInfo.systemUptime &&
              ProcessInfo.processInfo.systemUptime - $0 < 3 } == true,
              "Fresh observations retain the actual pre-request monotonic time")
        let secondStatus = server.statusCount + 1
        let secondCache = server.cacheCount + 1
        try await wait { server.statuses[secondStatus] != nil }
        server.statusReply(secondStatus)
        try await wait { server.caches[secondCache] != nil }
        server.cacheReply(secondCache)
        try await wait { owner.refillID != nil && owner.refillID != firstID }
        check(owner.refillID != firstID && owner.refillFile == 7,
              "A new accepted observation gets a distinct token even when resident ranges are unchanged")
        let failingStatus = server.statusCount + 1
        try await wait { server.statuses[failingStatus] != nil }
        server.statusReply(failingStatus, failing: true)
        try await wait { owner.torrentLastCacheSnapshot == nil }
        check(owner.refillID == nil,
              "A current status failure revokes the previously accepted repair observation")
        owner.close()
        server.finish()
        await settle()
        print("Torrent cache polling checks passed (\(count) assertions; controlled async replies, actual owner methods).")
    }
}
