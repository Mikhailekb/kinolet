import Foundation

private struct SPTorrentPrefetchCapacityStop: Equatable {
    let requestID: UUID
    let fileID: Int
    let rangeStart: Int64
    let rangeEnd: Int64
    let nextOffset: Int64
    let revision: Int64
}

private struct Context {
    struct Descriptor { let hash = "owned-fixture"; let leaseID = UUID() }
    let descriptor = Descriptor()
    let file = SPTorrentFile(id: 7, path: "owned-fixture.mp4", length: 1_048_576)
    let streamURL = URL(string: "http://127.0.0.1/owned-fixture")!
}
@MainActor private final class Core {
    enum State { case opening, ready, playing, paused, idle, ended, failed }
    struct Window { var openGeneration: Int64 = 1; var seekGeneration: Int64 = 1; var playbackOffset: Int64 = 256 }
    var state = State.playing
    var seekSettled = true
    var sourceReadOffset: Int64 = 256
    var sourcePlaybackWindow = Window()
}
@MainActor private final class SPTorrentPauseBuffer {
    struct Identity { let hash: String; let fileID: Int; let sessionGeneration: UUID }
    struct ResidentGap: Equatable { let observationID: UUID; let start: Int64; let end: Int64 }
    enum State { case idle, filling, filled, waitingForCapacity, stopped, failed }
    struct Snapshot { var state = State.idle }
    var snapshot = Snapshot()
    var starts = 0
    var cancellations = 0
    var lastCapacityStop: SPTorrentPrefetchCapacityStop?
    var lastOffset: Int64?
    var lastForwardUpper: Int64?
    var repairCalls = 0
    var handlesRepair = false
    var lastGap: ResidentGap?
    var lastApprovedLower: Int64?
    var lastApprovedUpper: Int64?
    var lastConfirmedResidentCoverage = false
    func repairResidentGap(identity: Identity, streamURL: URL, fileLength: Int64,
                           approvedLowerBound: Int64, approvedUpperBound: Int64,
                           gap: ResidentGap?, capacityStop: SPTorrentPrefetchCapacityStop? = nil,
                           confirmedResidentCoverage: Bool = false) -> Bool {
        repairCalls += 1
        lastConfirmedResidentCoverage = confirmedResidentCoverage
        lastGap = gap; lastCapacityStop = capacityStop
        lastApprovedLower = approvedLowerBound; lastApprovedUpper = approvedUpperBound
        return handlesRepair
    }
    func start(identity: Identity, streamURL: URL, offset: Int64, fileLength: Int64, forwardEndOffset: Int64,
               capacityStop: SPTorrentPrefetchCapacityStop? = nil) {
        lastCapacityStop = capacityStop
        lastOffset = offset; lastForwardUpper = forwardEndOffset
        starts += 1; snapshot.state = .filling
    }
    func cancel() { cancellations += 1; snapshot.state = .idle }
    func stop() { snapshot.state = .stopped }
}
@MainActor private final class Controller {
    struct AppliedWindow {
        let leaseID: UUID
        let fileID: Int
        var openGeneration: Int64 = 1
        var seekGeneration: Int64 = 1
        var historyLowerBound: Int64 = 0
        var forwardUpperBound: Int64 = 65536
        var prefetchCapacityStop: SPTorrentPrefetchCapacityStop?
    }
    // INSERT_PRODUCTION_OBSERVATION
    private var torrentCacheRefillObservation: TorrentCacheRefillObservation?
    var torrentPlaybackWindowEpoch = UUID()
    var torrentContext: Context? = Context()
    var core: Core? = Core()
    var hasMediaSession = true
    var torrentCacheRestartToken: UUID?
    var torrentResolving = false
    var torrentAppliedPlaybackWindow: AppliedWindow?
    var torrentPauseBuffer = SPTorrentPauseBuffer()
    var torrentPauseBufferManuallyStopped = false
    var torrentPauseBufferMonitor: Task<Void, Never>?
    var torrentPauseBufferMonitorGeneration = UUID()
    init() {
        torrentAppliedPlaybackWindow = AppliedWindow(leaseID: torrentContext!.descriptor.leaseID,
                                                     fileID: torrentContext!.file.id)
    }
    func observe(_ ranges: [[Int64]], lease: UUID? = nil, open: Int64? = nil, seek: Int64? = nil,
                 policy: UUID? = nil, requestedAt: TimeInterval? = nil, fileID: Int? = nil,
                 fileLength: Int64? = nil) -> UUID {
        let context = torrentContext!
        let observedFile = SPTorrentFile(id: fileID ?? context.file.id, path: context.file.path,
                                        length: fileLength ?? context.file.length)
        let cache = SPTorrentCacheSnapshot(json: ["hash": context.descriptor.hash,
            "file_index": observedFile.id, "file_offset": 0, "file_length": observedFile.length,
            "piece_length": 1, "resident_bytes": ranges.reduce(Int64(0)) { $0 + $1[1] - $1[0] },
            "ranges": ranges], expectedHash: context.descriptor.hash, file: observedFile)!
        let id = UUID()
        torrentCacheRefillObservation = .init(id: id, cache: cache,
            leaseID: lease ?? context.descriptor.leaseID,
            openGeneration: open ?? core!.sourcePlaybackWindow.openGeneration,
            seekGeneration: seek ?? core!.sourcePlaybackWindow.seekGeneration,
            policyEpoch: policy ?? torrentPlaybackWindowEpoch,
            requestedAt: requestedAt ?? ProcessInfo.processInfo.systemUptime)
        return id
    }
    func forgetObservation() { torrentCacheRefillObservation = nil }
    func refreshPlaylistView() {}
    func updateTorrentBackgroundJobs() {}
    func startTorrentPlaybackWindowPolicyIfNeeded() {}
    func cancelTorrentPlaybackWindowPolicy(releaseRetainedWindow: Bool = false) {}
    func stateChanged(_ state: Core.State) {
        core!.state = state
        // INSERT_PRODUCTION_STATE_BOUNDARY
    }
    func update() { updateTorrentPauseBuffer() }
    func close() { cancelTorrentPauseBuffer(resetManualStop: true) }
    // INSERT_PRODUCTION_PREFETCH_METHODS
}

@main @MainActor private struct TorrentPrefetchLifecycleChecks {
    static var assertions = 0
    static func check(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        assertions += 1; print("PASS \(assertions): \(message)")
    }
    static func main() async {
        let vc = Controller()
        vc.update()
        check(vc.torrentPauseBuffer.snapshot.state == .filling,
              "A playing source with a current worker ACK starts bounded forward prefetch")
        let cancels = vc.torrentPauseBuffer.cancellations
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.cancellations == cancels,
              "Pausing preserves the existing valid prefetch reader")
        vc.stateChanged(.playing); vc.update()
        check(vc.torrentPauseBuffer.cancellations == cancels,
              "Resuming playback preserves the same valid prefetch reader")
        check(vc.torrentPauseBufferMonitor != nil,
              "Both playing and paused sessions retain a frontier monitor")

        vc.torrentAppliedPlaybackWindow!.historyLowerBound = 4096
        vc.core!.sourceReadOffset = 256
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 4096,
              "A stale metadata read cursor cannot start prefetch below the worker's accepted lower bound")
        vc.stateChanged(.paused)
        vc.core!.sourceReadOffset = 0
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 4096,
              "A paused source also skips the rejected old byte region after a metadata rewind")
        vc.core!.sourceReadOffset = 8192
        vc.update()
        check(vc.torrentPauseBuffer.lastOffset == 8192,
              "An actual read frontier inside the accepted window remains unchanged")
        vc.torrentAppliedPlaybackWindow!.historyLowerBound = 0
        vc.core!.sourceReadOffset = 256

        let proof = SPTorrentPrefetchCapacityStop(requestID: UUID(), fileID: 7,
            rangeStart: 256, rangeEnd: 65536, nextOffset: 32768, revision: 1)
        vc.torrentAppliedPlaybackWindow!.prefetchCapacityStop = proof
        vc.update()
        check(vc.torrentPauseBuffer.lastCapacityStop == proof,
              "The current worker ACK passes its capacity-stop proof to the bounded reader")
        vc.torrentPauseBuffer.snapshot.state = .waitingForCapacity
        vc.toggleTorrentPauseBuffer()
        let stoppedWhileWaiting = vc.torrentPauseBuffer.starts
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .stopped,
              "Stop while waiting for cache space disables future automatic refill")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == stoppedWhileWaiting,
              "Play, pause and polling cannot restart a manually stopped capacity wait")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > stoppedWhileWaiting,
              "Explicit Resume re-enables filling after a stopped capacity wait")

        vc.stateChanged(.playing)
        vc.torrentPauseBuffer.snapshot.state = .failed
        let startsBeforeRetry = vc.torrentPauseBuffer.starts
        vc.toggleTorrentPauseBuffer()
        check(vc.torrentPauseBuffer.starts > startsBeforeRetry && vc.torrentPauseBuffer.snapshot.state == .filling,
              "The existing control can explicitly retry a failed fill while playback continues")
        vc.toggleTorrentPauseBuffer()
        let starts = vc.torrentPauseBuffer.starts
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .stopped,
              "The existing control explicitly stops forward filling while playing")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == starts && vc.torrentPauseBufferManuallyStopped,
              "Manual Stop remains effective across play and pause transitions")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > starts,
              "Explicit Resume re-enables bounded forward filling")

        vc.torrentPauseBuffer.snapshot.state = .filled
        let fullStarts = vc.torrentPauseBuffer.starts
        vc.toggleTorrentPauseBuffer()
        check(vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.snapshot.state == .idle,
              "Stop remains available when the current rolling window is already full")
        vc.stateChanged(.playing); vc.update()
        vc.stateChanged(.paused); vc.update()
        check(vc.torrentPauseBuffer.starts == fullStarts && vc.torrentPauseBufferManuallyStopped,
              "Stopping a full window also prevents future automatic fills across playback transitions")
        vc.toggleTorrentPauseBuffer()
        check(!vc.torrentPauseBufferManuallyStopped && vc.torrentPauseBuffer.starts > fullStarts,
              "Resume after stopping a full window restores forward filling")

        vc.core!.sourcePlaybackWindow.seekGeneration = 2
        vc.core!.seekSettled = false; vc.update()
        check(vc.torrentPauseBuffer.snapshot.state == .idle,
              "An unsettled seek cancels prefetch from the previous playback epoch")
        let beforeAck = vc.torrentPauseBuffer.starts
        vc.core!.seekSettled = true; vc.update()
        check(vc.torrentPauseBuffer.starts == beforeAck,
              "A stale ACK cannot authorize prefetch in the new seek generation")
        vc.torrentAppliedPlaybackWindow!.seekGeneration = 2
        vc.update()
        check(vc.torrentPauseBuffer.starts > beforeAck,
              "Only the matching new worker ACK authorizes the post-seek fill")

        vc.stateChanged(.opening)
        check(vc.torrentPauseBuffer.snapshot.state == .idle && vc.torrentPauseBufferMonitor == nil,
              "Opening a replacement source stops the old reader and monitor")
        vc.close()
        check(!vc.torrentPauseBufferManuallyStopped, "Source close resets the per-source manual Stop preference")
        // Exercise the exact production owner against actual resident-range
        // parsing/planning. Only the manager's admission boundary is recorded;
        // its real HTTP behavior is covered separately by pause-buffer checks.
        let gapOwner = Controller()
        defer { gapOwner.close() }
        gapOwner.core!.sourcePlaybackWindow.playbackOffset = 1_000
        gapOwner.core!.sourceReadOffset = 12_000
        gapOwner.torrentPauseBuffer.snapshot.state = .waitingForCapacity
        gapOwner.torrentPauseBuffer.handlesRepair = true
        let observation = gapOwner.observe([[0, 2_000], [4_000, 60_000]])
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.lastGap == .init(observationID: observation, start: 2_000, end: 4_000),
              "The owner repairs the earliest actual resident hole before a distant decoder cursor")
        check(gapOwner.torrentPauseBuffer.starts == 0 && gapOwner.torrentPauseBuffer.lastApprovedLower == 1_000 &&
              gapOwner.torrentPauseBuffer.lastApprovedUpper == 65_536 && !gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
              "A bounded repair owns the monitor and remains inside the accepted playback window")
        gapOwner.core!.state = .paused
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.lastGap?.observationID == observation && gapOwner.torrentPauseBuffer.starts == 0,
              "Pausing retains the same observation identity instead of inventing another refill")
        gapOwner.forgetObservation()
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.lastGap == nil && gapOwner.torrentPauseBuffer.starts == 0 &&
              !gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
              "An unknown cache map preserves an admitted repair without confirming residency")
        gapOwner.torrentPauseBuffer.handlesRepair = false
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.starts == 1,
              "Unknown residency without an active repair retains the normal forward reader")
        _ = gapOwner.observe([[1_000, 65_536]])
        for terminal in [SPTorrentPauseBuffer.State.filled, .waitingForCapacity] {
            gapOwner.torrentPauseBuffer.snapshot.state = terminal
            let beforeFull = gapOwner.torrentPauseBuffer.starts
            gapOwner.update()
            check(gapOwner.torrentPauseBuffer.lastGap == nil && gapOwner.torrentPauseBuffer.starts == beforeFull &&
                  gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
                  "A fresh fully resident terminal window confirms coverage and suppresses whole-window fill: \(terminal)")
        }
        gapOwner.torrentPauseBuffer.snapshot.state = .filling
        gapOwner.torrentAppliedPlaybackWindow!.forwardUpperBound = 5_000
        gapOwner.torrentAppliedPlaybackWindow!.prefetchCapacityStop = proof
        let beforeActiveQuota = gapOwner.torrentPauseBuffer.starts
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.starts == beforeActiveQuota + 1 &&
              gapOwner.torrentPauseBuffer.lastForwardUpper == 5_000 && gapOwner.torrentPauseBuffer.lastCapacityStop == proof &&
              gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
              "A fully resident map still forwards shrunk quota and exact capacity proof to an ordinary active read")
        for initial in [SPTorrentPauseBuffer.State.idle, .stopped] {
            gapOwner.torrentPauseBuffer.snapshot.state = initial
            let beforeInitial = gapOwner.torrentPauseBuffer.starts
            gapOwner.update()
            check(gapOwner.torrentPauseBuffer.starts == beforeInitial + 1,
                  "Fully resident observations cannot suppress ordinary idle/start or explicit Resume: \(initial)")
        }
        gapOwner.torrentAppliedPlaybackWindow!.forwardUpperBound = 65_536
        gapOwner.torrentPauseBuffer.handlesRepair = true
        gapOwner.forgetObservation()
        gapOwner.update()
        check(!gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
              "A missing observation revokes the previous confirmation instead of resetting backoff")
        gapOwner.torrentPauseBuffer.handlesRepair = false
        for invalid in ["lease", "open", "seek", "policy", "age", "file", "length"] {
            gapOwner.forgetObservation()
            _ = gapOwner.observe([[1_000, 2_000], [4_000, 60_000]],
                lease: invalid == "lease" ? UUID() : nil,
                open: invalid == "open" ? 2 : nil, seek: invalid == "seek" ? 2 : nil,
                policy: invalid == "policy" ? UUID() : nil,
                requestedAt: invalid == "age" ? ProcessInfo.processInfo.systemUptime - 6 : nil,
                fileID: invalid == "file" ? 8 : nil, fileLength: invalid == "length" ? 2_000_000 : nil)
            gapOwner.update()
            check(gapOwner.torrentPauseBuffer.lastGap == nil && !gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
                  "A stale or mismatched resident map cannot authorize repair: \(invalid)")
            _ = gapOwner.observe([[1_000, 65_536]],
                lease: invalid == "lease" ? UUID() : nil,
                open: invalid == "open" ? 2 : nil, seek: invalid == "seek" ? 2 : nil,
                policy: invalid == "policy" ? UUID() : nil,
                requestedAt: invalid == "age" ? ProcessInfo.processInfo.systemUptime - 6 : nil,
                fileID: invalid == "file" ? 8 : nil, fileLength: invalid == "length" ? 2_000_000 : nil)
            gapOwner.update()
            check(!gapOwner.torrentPauseBuffer.lastConfirmedResidentCoverage,
                  "A stale or mismatched full map cannot reset the manager's gap backoff: \(invalid)")
        }
        _ = gapOwner.observe([[1_000, 2_000], [4_000, 60_000]])
        gapOwner.torrentPauseBufferManuallyStopped = true
        let stoppedRepairCalls = gapOwner.torrentPauseBuffer.repairCalls
        let stoppedStarts = gapOwner.torrentPauseBuffer.starts
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.repairCalls == stoppedRepairCalls && gapOwner.torrentPauseBuffer.starts == stoppedStarts,
              "Explicit Stop dominates even a fresh resident hole")
        gapOwner.torrentPauseBufferManuallyStopped = false
        gapOwner.torrentPauseBuffer.handlesRepair = true
        gapOwner.torrentAppliedPlaybackWindow!.prefetchCapacityStop = proof
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.lastCapacityStop == proof,
              "The bounded repair receives the current exact capacity-stop receipt")
        gapOwner.core!.sourcePlaybackWindow.seekGeneration = 2
        let beforeSeekRepair = gapOwner.torrentPauseBuffer.repairCalls
        gapOwner.update()
        check(gapOwner.torrentPauseBuffer.repairCalls == beforeSeekRepair && gapOwner.torrentPauseBuffer.snapshot.state == .idle,
              "A new seek cannot use the old worker ACK or resident observation")
        print("Torrent prefetch lifecycle checks passed (\(assertions) assertions).")
    }
}
