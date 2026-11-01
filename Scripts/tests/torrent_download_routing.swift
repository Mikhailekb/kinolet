import AppKit

private enum RoutingFailure: LocalizedError {
    case owned
    var errorDescription: String? { "Owned routing failure" }
}

/// These are the only asynchronous/UI boundaries replaced by the extraction.
/// They record requests without opening menus, panels, other apps or a worker.
@MainActor private final class RoutingChooser {
    final class Request {
        let descriptor: SPTorrentDescriptor
        let file: SPTorrentFile
        weak var view: NSView?
        let isCurrent: @MainActor () -> Bool
        let builtIn: @MainActor () -> Void
        let failed: @MainActor (any Error) -> Void
        init(descriptor: SPTorrentDescriptor, file: SPTorrentFile, view: NSView,
             isCurrent: @escaping @MainActor () -> Bool,
             builtIn: @escaping @MainActor () -> Void,
             failed: @escaping @MainActor (any Error) -> Void) {
            self.descriptor = descriptor; self.file = file; self.view = view
            self.isCurrent = isCurrent; self.builtIn = builtIn; self.failed = failed
        }
    }
    var requests: [Request] = []
    var externalHandoffs: [SPTorrentDescriptor] = []
    func present(descriptor: SPTorrentDescriptor, file: SPTorrentFile, in view: NSView,
                 isCurrent: @escaping @MainActor () -> Bool,
                 builtIn: @escaping @MainActor () -> Void,
                 failed: @escaping @MainActor (any Error) -> Void) {
        requests.append(Request(descriptor: descriptor, file: file, view: view,
                                isCurrent: isCurrent, builtIn: builtIn, failed: failed))
    }
    func external(_ index: Int) {
        let request = requests[index]
        guard request.isCurrent() else { return }
        externalHandoffs.append(request.descriptor)
    }
}

@MainActor private final class RoutingWindow: NSWindow {
    var ownedSheet: NSWindow?
    override var attachedSheet: NSWindow? { ownedSheet }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
}

@MainActor private final class RoutingSavePanel {
    static var instances: [RoutingSavePanel] = []
    var title = ""
    var nameFieldStringValue = ""
    var url: URL?
    weak var parentWindow: NSWindow?
    var callback: (@MainActor (NSApplication.ModalResponse) -> Void)?
    init() { Self.instances.append(self) }
    func beginSheetModal(for window: NSWindow,
                         completionHandler: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        parentWindow = window; callback = completionHandler
    }
    func respond(_ response: NSApplication.ModalResponse, destination: URL? = nil) {
        url = destination
        let completion = callback
        callback = nil
        completion?(response)
    }
}

@MainActor private enum RoutingGrants {
    static var allows = true
    static var acquired: [URL] = []
    static var released: [URL] = []
    static func start(_ url: URL) -> Bool { acquired.append(url); return allows }
    static func stop(_ url: URL) { released.append(url) }
    static func reset() { allows = true; acquired = []; released = [] }
}

@MainActor private final class RoutingSaveTransport {
    final class Request {
        let descriptor: SPTorrentDescriptor
        let file: SPTorrentFile
        let destination: URL
        let replace: Bool
        let progress: SPTorrentFileSaves.Progress
        var completion: CheckedContinuation<URL, any Error>?
        init(_ descriptor: SPTorrentDescriptor, _ file: SPTorrentFile, _ destination: URL,
             _ replace: Bool, _ progress: @escaping SPTorrentFileSaves.Progress,
             _ completion: CheckedContinuation<URL, any Error>) {
            self.descriptor = descriptor; self.file = file; self.destination = destination
            self.replace = replace; self.progress = progress; self.completion = completion
        }
    }
    var requests: [Request] = []
    func save(_ descriptor: SPTorrentDescriptor, _ file: SPTorrentFile, _ destination: URL,
              _ replace: Bool, _ progress: @escaping SPTorrentFileSaves.Progress) async throws -> URL {
        try await withCheckedThrowingContinuation { completion in
            requests.append(Request(descriptor, file, destination, replace, progress, completion))
        }
    }
    func finish(_ index: Int, error: (any Error)? = nil) {
        let request = requests[index], completion = requests[index].completion
        request.completion = nil
        if let error { completion?.resume(throwing: error) }
        else { completion?.resume(returning: request.destination) }
    }
}

@MainActor private final class RoutingOwner {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    let torrentDownloadChooser = RoutingChooser()
    let torrentFileSaves: SPTorrentFileSaves
    let transport = RoutingSaveTransport()
    var window: RoutingWindow?
    var torrentContext: SPTorrentPlaybackContext?
    var torrentCacheRestartToken: UUID?
    var hasMediaSession = true
    var torrentSavePanelToken = UUID()
    var torrentResolving = false
    var torrentOpenGeneration: UInt64 = 0
    var alerts: [(message: String, informative: String)] = []
    var changeNotifications = 0
    init(_ context: SPTorrentPlaybackContext) {
        torrentContext = context
        let transport = transport
        torrentFileSaves = SPTorrentFileSaves(saver: transport.save)
        torrentFileSaves.onChange = { [weak self] in self?.changeNotifications += 1 }
        window = RoutingWindow()
        window?.contentView = view
    }
    func presentNonBlockingAlert(message: String, informative: String) {
        alerts.append((message, informative))
    }
    func torrentErrorMessage(_ error: any Error) -> String { error.localizedDescription }
    func detachWindow() {
        window?.contentView = nil
        window = nil
    }
    // INSERT_PRODUCTION_ROUTING_METHODS
}

@main @MainActor private struct TorrentDownloadRoutingChecks {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: \(message)"); exit(1) }
        assertions += 1
        print("PASS \(assertions): \(message)")
    }
    static func settle(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(false, "Owned async routing fixture reached its expected state")
    }
    static let first = SPTorrentFile(id: 1, path: "Show/Season 1/Episode 1.mkv", length: 1000)
    static let second = SPTorrentFile(id: 2, path: "Show/Season 2/Episode 2.mp4", length: 2000)
    static let third = SPTorrentFile(id: 3, path: "Show/Season 2/Episode 3.mp4", length: 3000)
    static func descriptor(hash: String = String(repeating: "a", count: 40),
                           files: [SPTorrentFile] = [first, second, third]) -> SPTorrentDescriptor {
        SPTorrentDescriptor(leaseID: UUID(), hash: hash, name: "Show", files: files,
                           originalLink: "magnet:?xt=urn:btih:" + hash,
                           originalTorrentData: Data("owned-metainfo".utf8))
    }
    static func context(_ descriptor: SPTorrentDescriptor, file: SPTorrentFile = first) -> SPTorrentPlaybackContext {
        SPTorrentPlaybackContext(descriptor: descriptor, file: file,
                                streamURL: URL(string: "http://127.0.0.1:1/never-used")!)
    }
    static func owner() -> RoutingOwner { RoutingOwner(context(descriptor())) }
    static func assertNoBuiltInWork(_ owner: RoutingOwner, _ panelCount: Int, _ message: String) {
        check(RoutingSavePanel.instances.count == panelCount && owner.transport.requests.isEmpty
              && owner.torrentFileSaves.activeCount == 0 && owner.torrentFileSaves.snapshots.isEmpty
              && RoutingGrants.acquired.isEmpty && RoutingGrants.released.isEmpty
              && owner.changeNotifications == 0, message)
    }
    static func main() async throws {
        _ = NSApplication.shared
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = descriptor(), initial = context(source)
        let current = RoutingOwner(initial)
        current.saveTorrentFileAction(nil)
        check(current.torrentDownloadChooser.requests.count == 1,
              "The current-file action opens the chooser instead of immediately saving")
        let currentRequest = current.torrentDownloadChooser.requests[0]
        check(currentRequest.descriptor == source && currentRequest.file == first
              && currentRequest.view === current.view && currentRequest.isCurrent(),
              "The current-file chooser receives the exact descriptor, metainfo, file and owning view")
        assertNoBuiltInWork(current, 0, "Opening the chooser starts no built-in transport, destination grant or progress row")
        current.torrentDownloadChooser.external(0)
        check(current.torrentDownloadChooser.externalHandoffs == [source],
              "The external branch receives the captured torrent source")
        check(current.torrentContext?.descriptor == source && current.torrentContext?.file == first
              && current.hasMediaSession && current.torrentCacheRestartToken == nil,
              "External selection leaves the playback context and session unchanged")
        assertNoBuiltInWork(current, 0, "External selection starts no save, cache/restart operation or security-scoped destination")

        let playlist = RoutingOwner(initial)
        let targetIdentity = initial.identityURL(for: second)
        playlist.saveTorrentPlaylistEntry(targetIdentity)
        check(playlist.torrentDownloadChooser.requests.count == 1,
              "A noncurrent playlist identity also opens the chooser")
        let playlistRequest = playlist.torrentDownloadChooser.requests[0]
        check(playlistRequest.descriptor == source && playlistRequest.file == second
              && playlist.torrentContext?.file == first && playlistRequest.isCurrent(),
              "A playlist row routes its exact unselected file without changing the playing episode")
        playlist.saveTorrentPlaylistEntry(URL(fileURLWithPath: "/owned-fixture/not-in-playlist.mp4"))
        check(playlist.torrentDownloadChooser.requests.count == 1,
              "An unknown playlist identity cannot reach the chooser")
        let noSource = owner()
        noSource.torrentContext = nil
        noSource.saveTorrentFileAction(nil); noSource.saveTorrentPlaylistEntry(targetIdentity)
        check(noSource.torrentDownloadChooser.requests.isEmpty,
              "Both entry points reject a departed torrent context")

        // A captured choice remains tied to its own row even if playback advances.
        playlist.torrentContext = context(source, file: third)
        playlistRequest.builtIn()
        check(RoutingSavePanel.instances.count == 1
              && RoutingSavePanel.instances[0].nameFieldStringValue == second.displayName
              && RoutingSavePanel.instances[0].parentWindow === playlist.window,
              "Built-in selection opens exactly one old-style save panel for the captured row")
        check(!playlistRequest.isCurrent() && playlist.transport.requests.isEmpty,
              "Opening the save panel invalidates the chooser token and waits for a destination")
        playlistRequest.builtIn()
        check(RoutingSavePanel.instances.count == 1,
              "A repeated chooser callback cannot open a second built-in panel")
        let destination = scratch.appendingPathComponent("episode-2.mp4")
        try Data("old-owned-fixture".utf8).write(to: destination)
        playlist.torrentContext = context(source, file: first)
        RoutingSavePanel.instances[0].respond(.OK, destination: destination)
        check(playlist.torrentFileSaves.activeCount == 1 && RoutingGrants.acquired == [destination]
              && RoutingGrants.released.isEmpty,
              "The original panel callback retains its security grant while a save runs")
        await settle { playlist.transport.requests.count == 1 }
        let transfer = playlist.transport.requests[0]
        check(transfer.descriptor == source && transfer.file == second && transfer.destination == destination
              && transfer.replace,
              "Episode changes before and after panel opening preserve the requested file, descriptor and replacement permission")
        transfer.progress(.init(receivedBytes: 750, expectedBytes: 12345))
        check(playlist.torrentFileSaves.snapshot(descriptor: source, file: second)?.fraction == 0.375
              && playlist.changeNotifications == 2,
              "The real coordinator publishes progress for the requested file with manifest length")
        playlist.transport.finish(0)
        await settle { playlist.torrentFileSaves.activeCount == 0 && RoutingGrants.released.count == 1 }
        check(playlist.torrentFileSaves.snapshot(descriptor: source, file: second)?.phase == .saved
              && RoutingGrants.released == [destination] && playlist.alerts.isEmpty,
              "Successful built-in completion keeps its progress row and releases the grant exactly once")
        RoutingGrants.reset()

        let blockedChanges: [(String, @MainActor (RoutingOwner) -> Void)] = [
            ("missing media session", { $0.hasMediaSession = false }),
            ("new torrent resolving with old context retained", { $0.torrentResolving = true }),
            ("cache restart", { $0.torrentCacheRestartToken = UUID() }),
            ("detached window", { $0.detachWindow() }),
            ("existing sheet", { $0.window?.ownedSheet = RoutingWindow() }),
        ]
        for (name, change) in blockedChanges {
            let blocked = owner(), before = RoutingSavePanel.instances.count
            change(blocked)
            blocked.saveTorrentFileAction(nil)
            blocked.presentBuiltInTorrentFileSave(first, descriptor: blocked.torrentContext!.descriptor)
            check(blocked.torrentDownloadChooser.requests.isEmpty,
                  "Initial routing rejects \(name)")
            assertNoBuiltInWork(blocked, before, "Rejected \(name) has no built-in side effects")
        }
        let sheetRace = owner()
        sheetRace.saveTorrentFileAction(nil)
        let sheetRaceRequest = sheetRace.torrentDownloadChooser.requests[0]
        let panelCountBeforeSheet = RoutingSavePanel.instances.count
        sheetRace.window?.ownedSheet = RoutingWindow()
        sheetRaceRequest.builtIn()
        check(RoutingSavePanel.instances.count == panelCountBeforeSheet && sheetRace.transport.requests.isEmpty,
              "The retained built-in panel method rejects a sheet opened after the chooser")
        let active = owner(), activeSource = active.torrentContext!.descriptor
        check(active.torrentFileSaves.start(descriptor: activeSource, file: first,
              to: scratch.appendingPathComponent("already-saving.mkv")), "The active-save guard fixture starts")
        active.saveTorrentFileAction(nil)
        check(active.torrentDownloadChooser.requests.isEmpty,
              "A file already saving cannot open another chooser")
        await settle { active.transport.requests.count == 1 }
        active.torrentFileSaves.cancel(descriptor: activeSource, file: first)
        active.saveTorrentFileAction(nil)
        check(active.torrentDownloadChooser.requests.isEmpty,
              "A still-draining cancelled save also blocks a second chooser")
        active.transport.finish(0)
        await settle { active.torrentFileSaves.activeCount == 0 }

        let staleChanges: [(String, @MainActor (RoutingOwner) -> Void)] = [
            ("new picker token", { $0.torrentSavePanelToken = UUID() }),
            ("departed source", { $0.torrentContext = nil }),
            ("different torrent", { $0.torrentContext = context(descriptor(hash: String(repeating: "b", count: 40))) }),
            ("removed requested file", { owner in
                let old = owner.torrentContext!.descriptor
                owner.torrentContext = context(descriptor(hash: old.hash, files: [second, third]), file: second)
            }),
            ("changed immutable file", { owner in
                let old = owner.torrentContext!.descriptor
                let changed = SPTorrentFile(id: first.id, path: first.path, length: first.length + 1)
                owner.torrentContext = context(descriptor(hash: old.hash, files: [changed, second]), file: changed)
            }),
            ("ended media session", { $0.hasMediaSession = false }),
            ("new cache restart", { $0.torrentCacheRestartToken = UUID() }),
            ("replaced owning window", { owner in
                owner.window?.contentView = nil
                owner.window = RoutingWindow(); owner.window?.contentView = owner.view
            }),
            ("closed owning window", { $0.detachWindow() }),
        ]
        let pendingOpenChanges: [(String, @MainActor (RoutingOwner) -> Void)] = [
            ("new torrent open begun with old context retained", { owner in
                owner.torrentOpenGeneration &+= 1
                owner.torrentResolving = true
            }),
            ("new torrent open cancelled with old context retained", { owner in
                owner.torrentOpenGeneration &+= 2
                owner.torrentResolving = false
            }),
        ]
        for (name, change) in staleChanges + pendingOpenChanges {
            let stale = owner(), before = RoutingSavePanel.instances.count
            stale.saveTorrentFileAction(nil)
            let request = stale.torrentDownloadChooser.requests[0]
            change(stale)
            check(!request.isCurrent(), "The chooser validity closure rejects \(name)")
            request.builtIn(); request.failed(RoutingFailure.owned)
            stale.torrentDownloadChooser.external(0)
            check(RoutingSavePanel.instances.count == before && stale.alerts.isEmpty
                  && stale.torrentDownloadChooser.externalHandoffs.isEmpty,
                  "Delayed chooser callbacks after \(name) cannot save, hand off or show a stale error")
        }
        let becameActive = owner(), becameActiveSource = becameActive.torrentContext!.descriptor
        becameActive.saveTorrentFileAction(nil)
        let becameActiveRequest = becameActive.torrentDownloadChooser.requests[0]
        check(becameActive.torrentFileSaves.start(descriptor: becameActiveSource, file: first,
            to: scratch.appendingPathComponent("became-active.mkv")), "The concurrent active-save fixture starts")
        let beforeActive = RoutingSavePanel.instances.count
        check(!becameActiveRequest.isCurrent(), "A newly active save invalidates an already-open chooser")
        becameActiveRequest.builtIn(); becameActiveRequest.failed(RoutingFailure.owned)
        check(RoutingSavePanel.instances.count == beforeActive && becameActive.alerts.isEmpty,
              "A concurrent save cannot be duplicated by delayed choice callbacks")
        await settle { becameActive.transport.requests.count == 1 }
        becameActive.transport.finish(0)
        await settle { becameActive.torrentFileSaves.activeCount == 0 }

        let failure = owner()
        failure.saveTorrentFileAction(nil)
        failure.torrentDownloadChooser.requests[0].failed(RoutingFailure.owned)
        check(failure.alerts.count == 1 && failure.alerts[0].informative == "Owned routing failure",
              "A current external-opening failure is reported through the nonblocking alert boundary")

        // Validate the retained panel callback, not just the chooser callback.
        for (name, change) in staleChanges + pendingOpenChanges {
            let stale = owner()
            stale.saveTorrentFileAction(nil)
            stale.torrentDownloadChooser.requests[0].builtIn()
            let panel = RoutingSavePanel.instances.last!
            change(stale)
            panel.respond(.OK, destination: scratch.appendingPathComponent("stale-\(name).mkv"))
            check(stale.torrentFileSaves.activeCount == 0 && stale.transport.requests.isEmpty
                  && RoutingGrants.acquired.isEmpty,
                  "The retained built-in panel rejects \(name) before acquiring a grant or starting a transfer")
        }
        let cancel = owner()
        cancel.saveTorrentFileAction(nil); cancel.torrentDownloadChooser.requests[0].builtIn()
        RoutingSavePanel.instances.last!.respond(.cancel)
        check(cancel.torrentFileSaves.activeCount == 0 && RoutingGrants.acquired.isEmpty,
              "Cancelling the original save panel leaves the transfer and grant untouched")

        // A destination race can reject start after the user grants a URL.
        let rejected = owner(), rejectedSource = rejected.torrentContext!.descriptor
        let reserved = scratch.appendingPathComponent("reserved.mkv")
        check(rejected.torrentFileSaves.start(descriptor: rejectedSource, file: second, to: reserved),
              "A sibling reserves the destination while the current-file chooser is pending")
        await settle { rejected.transport.requests.count == 1 }
        rejected.saveTorrentFileAction(nil); rejected.torrentDownloadChooser.requests[0].builtIn()
        RoutingSavePanel.instances.last!.respond(.OK, destination: reserved)
        check(rejected.torrentFileSaves.activeCount == 1 && rejected.transport.requests.count == 1
              && RoutingGrants.acquired == [reserved] && RoutingGrants.released == [reserved],
              "A coordinator-rejected destination releases the newly acquired grant immediately")
        rejected.transport.finish(0)
        await settle { rejected.torrentFileSaves.activeCount == 0 }
        RoutingGrants.reset()

        let failedSave = owner(), failedSource = failedSave.torrentContext!.descriptor
        failedSave.saveTorrentFileAction(nil); failedSave.torrentDownloadChooser.requests[0].builtIn()
        let failedDestination = scratch.appendingPathComponent("failed.mkv")
        RoutingSavePanel.instances.last!.respond(.OK, destination: failedDestination)
        await settle { failedSave.transport.requests.count == 1 }
        failedSave.transport.finish(0, error: RoutingFailure.owned)
        await settle { failedSave.torrentFileSaves.activeCount == 0 && RoutingGrants.released.count == 1 }
        check(failedSave.torrentFileSaves.snapshot(descriptor: failedSource, file: first)?.phase == .failed
              && failedSave.alerts.count == 1 && RoutingGrants.released == [failedDestination],
              "The retained built-in failure path releases the grant and keeps the failed row visible")
        RoutingGrants.reset()

        let departed = owner()
        departed.saveTorrentFileAction(nil); departed.torrentDownloadChooser.requests[0].builtIn()
        let departedDestination = scratch.appendingPathComponent("departed.mkv")
        RoutingSavePanel.instances.last!.respond(.OK, destination: departedDestination)
        await settle { departed.transport.requests.count == 1 }
        departed.torrentContext = context(descriptor(hash: String(repeating: "c", count: 40)))
        departed.transport.finish(0, error: RoutingFailure.owned)
        await settle { departed.torrentFileSaves.activeCount == 0 && RoutingGrants.released.count == 1 }
        check(departed.alerts.isEmpty && RoutingGrants.released == [departedDestination],
              "A completed old-source save releases its grant without interrupting a newer torrent")
        RoutingGrants.reset()

        var releasedOwner: RoutingOwner? = owner()
        releasedOwner!.saveTorrentFileAction(nil)
        let orphan = releasedOwner!.torrentDownloadChooser.requests[0]
        weak let weakOwner = releasedOwner
        releasedOwner = nil
        check(weakOwner == nil && !orphan.isCurrent(),
              "Pending chooser closures do not keep their player owner alive")
        orphan.builtIn(); orphan.failed(RoutingFailure.owned)
        print("PASS \(assertions) actual controller torrent download-routing checks")
        let evidence = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        if !evidence.isEmpty {
            let output = URL(fileURLWithPath: evidence, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let payload: [String: Any] = ["assertions": assertions, "result": "PASS",
                "actualMethods": ["saveTorrentFileAction", "saveTorrentPlaylistEntry", "presentTorrentFileSave", "presentBuiltInTorrentFileSave"],
                "boundaries": ["chooser", "save panel", "security-scoped URL access", "injected save transport"],
                "noWorkerOrNetwork": true, "noLivePlayerOrUserPreferences": true]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("runtime-evidence.json"))
        }
    }
}
