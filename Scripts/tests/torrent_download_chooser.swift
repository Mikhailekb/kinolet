import AppKit
import UniformTypeIdentifiers

// Deterministic localization boundary; the repository's catalog gate checks
// actual translations independently. All menu/store implementation is real.
func L(_ key: String) -> String {
    ["torrent.downloadWith": "Download with",
     "torrent.downloadBuiltIn": "%@ (built-in)",
     "torrent.downloadOtherApp": "Other Application…",
     "torrent.downloadExternalHint": "The external app opens the torrent. Choose the episodes you want in its add-torrent window.",
     "torrent.downloadSourceUnavailable": "Original torrent source unavailable."][key] ?? key
}
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000_000)
    private var nextRead: (@Sendable () -> Void)?
    func read() -> Date {
        lock.lock()
        let result = value, action = nextRead
        nextRead = nil
        lock.unlock()
        action?()
        return result
    }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    func onNextRead(_ action: @escaping @Sendable () -> Void) { lock.lock(); nextRead = action; lock.unlock() }
}

@MainActor private final class Boundary {
    var menu: NSMenu?
    var menuPoint = NSPoint.zero
    var panel: NSOpenPanel?
    var finishPanel: (@MainActor (NSApplication.ModalResponse) -> Void)?
    var launches: [(URL, URL)] = []
    var failures: [Error] = []
    var builtIn = 0
    var current = true
    var rejectLaunch = false
}

@main @MainActor
struct TorrentDownloadChooserChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1; print("PASS \(checks): \(message)")
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure(message) } catch { checks += 1; print("PASS \(checks): \(message)") }
    }
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        preconditionFailure("Owned asynchronous boundary did not finish")
    }
    static func choose(_ title: String, _ menu: NSMenu) {
        let index = menu.items.firstIndex { $0.title == title }!
        menu.performActionForItem(at: index)
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory.appendingPathComponent("kinolet-chooser-fixture-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }
        func bstring(_ text: String) -> String { "\(text.utf8.count):\(text)" }
        let info = "d6:lengthi99e4:name7:one.mkve"
        let metainfo = Data(("d8:announce" + bstring("https://tracker.invalid/announce?passkey=owned-fixture") + "7:comment" + bstring("retain original bytes") + "4:info" + info + "e").utf8)
        let hash = try SPTorrentInput.infoHash(in: metainfo)
        let file = SPTorrentFile(id: 7, path: "Show/one.mkv", length: 99)
        let other = SPTorrentFile(id: 19, path: "Show/two.mkv", length: 99)
        let descriptor = SPTorrentDescriptor(leaseID: UUID(), hash: hash, name: "Show", files: [file, other], originalLink: nil, originalTorrentData: metainfo)
        let clock = Clock()
        let directory = scratch.appendingPathComponent("copies", isDirectory: true)
        let store = SPTorrentExternalSourceStore(directory: directory, maximumCount: 2, maximumBytes: Int64(metainfo.count * 2), now: { clock.read() })
        let first = try store.prepare(descriptor: descriptor, file: other)
        let exported = try Data(contentsOf: first)
        let filePermissions = try manager.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try manager.attributesOfItem(atPath: first.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        expect(exported == metainfo, "Original metainfo, trackers and private parameters survive byte-for-byte")
        expect(filePermissions?.intValue == 0o600,
               "The exported metainfo file is private0600")
        expect(directoryPermissions?.intValue == 0o700,
               "Each randomized handoff directory is private0700")
        let second = try store.prepare(descriptor: descriptor, file: file)
        rejects("A full fresh handoff cache never removes another app's pending input") { _ = try store.prepare(descriptor: descriptor, file: file) }
        expect(manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path), "Fresh metadata copies outlive immediate subsequent handoffs")
        clock.advance(3_601)
        let third = try store.prepare(descriptor: descriptor, file: file)
        expect(manager.fileExists(atPath: third.path) && (!manager.fileExists(atPath: first.path) || !manager.fileExists(atPath: second.path)),
               "Later count/byte pressure reclaims only sufficiently old copies")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        clock.advance(8 * 24 * 60 * 60)
        let fourth = try store.prepare(descriptor: descriptor, file: file)
        expect(!manager.fileExists(atPath: third.path) && manager.fileExists(atPath: fourth.path), "Later handoffs prune expired metadata")
        expect(manager.fileExists(atPath: unrelated.path), "Cleanup leaves files outside its owned naming scheme alone")
        let consumed = try store.prepare(descriptor: descriptor, file: file)
        try manager.removeItem(at: consumed)
        let orphan = consumed.deletingLastPathComponent()
        try manager.setAttributes([.modificationDate: clock.read()], ofItemAtPath: orphan.path)
        _ = try store.prepare(descriptor: descriptor, file: file)
        expect(manager.fileExists(atPath: orphan.path), "A freshly consumed handoff folder is not reclaimed while another app may still use it")
        clock.advance(8 * 24 * 60 * 60)
        _ = try store.prepare(descriptor: descriptor, file: file)
        expect(!manager.fileExists(atPath: orphan.path), "Expired empty owned folders are reclaimed after an external client consumes the source")
        for (name, age) in [("retention", 8.0 * 24 * 60 * 60), ("pressure", 3_601.0)] {
            let cleanupClock = Clock()
            let cleanupStore = SPTorrentExternalSourceStore(directory: scratch.appendingPathComponent(name),
                maximumCount: 1, now: { cleanupClock.read() })
            let input = try cleanupStore.prepare(descriptor: descriptor, file: file)
            let externalMedia = input.deletingLastPathComponent().appendingPathComponent("external-client-video.mkv")
            let concurrentMedia = input.deletingLastPathComponent().appendingPathComponent("new-during-cleanup.mp4")
            let sentinel = Data("external download must survive".utf8)
            try sentinel.write(to: externalMedia)
            try manager.setAttributes([.modificationDate: cleanupClock.read()],
                                      ofItemAtPath: input.deletingLastPathComponent().path)
            cleanupClock.advance(age)
            cleanupClock.onNextRead { try? sentinel.write(to: concurrentMedia) }
            _ = try cleanupStore.prepare(descriptor: descriptor, file: file)
            let retainedMedia = try? Data(contentsOf: externalMedia)
            let retainedConcurrentMedia = try? Data(contentsOf: concurrentMedia)
            expect(retainedMedia == sentinel, "\(name) cleanup preserves media saved beside the original metainfo")
            expect(retainedConcurrentMedia == sentinel, "\(name) cleanup preserves new contents appearing during reclamation")
            expect(!manager.fileExists(atPath: input.path), "\(name) cleanup reclaims only its known source.torrent")
        }
        let link = "magnet:?xt=urn:btih:\(hash)&dn=Show&tr=https%3A%2F%2Ftracker.invalid%2Fannounce%3Fpasskey%3Dfixture"
        let magnet = SPTorrentDescriptor(leaseID: UUID(), hash: hash, name: "Show", files: [file], originalLink: link)
        let magnetURL = try store.prepare(descriptor: magnet, file: file)
        expect(magnetURL.absoluteString == link, "Original magnet URI is handed off without tracker loss or index invention")
        let missing = SPTorrentDescriptor(leaseID: UUID(), hash: hash, name: "Show", files: [file], originalLink: nil)
        rejects("A missing source cannot become a hash-only fabricated magnet") { _ = try store.prepare(descriptor: missing, file: file) }
        let wrongHash = SPTorrentDescriptor(leaseID: UUID(), hash: String(repeating: "a", count: 40), name: "Show", files: [file], originalLink: nil, originalTorrentData: metainfo)
        rejects("Metainfo must match the descriptor's original identity") { _ = try store.prepare(descriptor: wrongHash, file: file) }
        rejects("A file from another descriptor cannot be handed off") { _ = try store.prepare(descriptor: descriptor, file: SPTorrentFile(id: 8, path: "foreign.mkv", length: 99)) }

        let boundary = Boundary()
        let own = scratch.appendingPathComponent("Kinolet.app")
        let ownCopy = scratch.appendingPathComponent("Other Kinolet.app")
        let qbit = scratch.appendingPathComponent("qBittorrent.app")
        let qbitCopy = scratch.appendingPathComponent("qBittorrent Duplicate.app")
        let transmission = scratch.appendingPathComponent("Transmission.app")
        let dispatchDirectory = scratch.appendingPathComponent("dispatch", isDirectory: true)
        let dispatchStore = SPTorrentExternalSourceStore(directory: dispatchDirectory)
        let chooser = SPTorrentDownloadChooser(store: dispatchStore,
            discover: { _ in [own, ownCopy, qbit, qbit.appendingPathComponent("../qBittorrent.app").standardizedFileURL, qbitCopy, transmission] },
            appInfo: { url in
                let normalized = url.standardizedFileURL
                return .init(url: normalized, name: normalized.deletingPathExtension().lastPathComponent,
                             bundleIdentifier: normalized == own || normalized == ownCopy ? "app.kinolet.player"
                                 : (normalized == transmission ? "fixture.transmission" : "fixture.qbittorrent"),
                             icon: NSImage(size: NSSize(width: 32, height: 32)))
            },
            showMenu: { menu, point, _ in boundary.menu = menu; boundary.menuPoint = point },
            showPanel: { panel, _, finished in boundary.panel = panel; boundary.finishPanel = finished },
            launch: { source, application in
                if boundary.rejectLaunch { throw CocoaError(.executableNotLoadable) }
                boundary.launches.append((source, application))
            }, ownURL: own, ownIdentifier: "app.kinolet.player")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        func present(_ source: SPTorrentDescriptor = descriptor) {
            chooser.present(descriptor: source, file: file, in: view,
                isCurrent: { boundary.current }, builtIn: { boundary.builtIn += 1 }, failed: { boundary.failures.append($0) })
        }
        present()
        let menu = boundary.menu!
        expect(menu.items.filter { $0.title == "qBittorrent" }.count == 1 && !menu.items.contains { $0.title.contains("Kinolet") || $0.title.contains("Duplicate") },
               "Discovered applications exclude this app, duplicate canonical paths and duplicate bundle identities")
        expect(menu.items.filter { $0.image != nil }.count == 3, "Built-in and external choices use native application icons")
        expect(boundary.menuPoint == NSPoint(x: 200, y: 150), "Keyboard/detached invocation has a sensible anchor fallback")
        let footer = menu.items.last!.view!
        let label = footer.subviews.first as! NSTextField
        expect(!menu.items.last!.isEnabled && label.stringValue == L("torrent.downloadExternalHint") && label.frame.height > 20,
               "The file-selection caveat is a visible wrapping, noninteractive menu footer")
        if CommandLine.arguments.count > 1 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            let bitmap = footer.bitmapImageRepForCachingDisplay(in: footer.bounds)!
            footer.cacheDisplay(in: footer.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("external-download-footer.png"))
        }
        let builtinTitle = menu.items[1].title
        choose(builtinTitle, menu)
        expect(boundary.builtIn == 1 && boundary.launches.isEmpty && !manager.fileExists(atPath: dispatchDirectory.path),
               "Built-in selection needs no external source file or application launch")
        choose("qBittorrent", menu)
        try await wait { boundary.launches.count == 1 }
        let dispatchedData = try Data(contentsOf: boundary.launches[0].0)
        expect(boundary.launches[0].1 == qbit && dispatchedData == metainfo,
               "A native menu action dispatches exact metadata to the explicitly selected app")
        expect(manager.fileExists(atPath: boundary.launches[0].0.path), "Successful LaunchServices dispatch does not delete asynchronously consumed metainfo")
        choose(L("torrent.downloadOtherApp"), menu)
        expect(boundary.panel?.allowedContentTypes == [.applicationBundle] && boundary.panel?.allowsMultipleSelection == false
               && boundary.panel?.allowsOtherFileTypes == false,
               "Other Application uses the actual application-bundle-only native picker")
        let cancel = boundary.finishPanel!
        cancel(.cancel)
        expect(boundary.launches.count == 1 && boundary.failures.isEmpty, "Canceling the native application picker has no download or error side effect")
        choose(L("torrent.downloadOtherApp"), menu)
        let stalePicker = boundary.finishPanel!
        present()
        stalePicker(.OK)
        expect(boundary.launches.count == 1 && boundary.failures.isEmpty, "A replaced native picker callback cannot launch a stale request")
        let currentMenu = boundary.menu!
        choose("qBittorrent", currentMenu)
        boundary.current = false
        try await Task.sleep(for: .milliseconds(20))
        expect(boundary.launches.count == 1, "Playback scope is rechecked inside the asynchronous handoff before preparing or dispatching metadata")
        choose("qBittorrent", currentMenu)
        choose(builtinTitle, currentMenu)
        try await Task.sleep(for: .milliseconds(20))
        expect(boundary.launches.count == 1 && boundary.builtIn == 1, "Invalid playback scope blocks both internal and external stale actions")
        boundary.current = true
        present(missing)
        choose(boundary.menu!.items[1].title, boundary.menu!)
        expect(boundary.builtIn == 2, "Missing external source never disables the existing built-in downloader")
        choose("qBittorrent", boundary.menu!)
        try await wait { boundary.failures.count == 1 }
        expect(boundary.failures[0] is SPTorrentDownloadError && boundary.launches.count == 1,
               "Missing original metadata reports a scoped source error without a fake fallback")
        boundary.rejectLaunch = true
        present(magnet)
        choose("qBittorrent", boundary.menu!)
        try await wait { boundary.failures.count == 2 }
        expect(boundary.launches.count == 1, "External application failures return through the owner error callback")
        if CommandLine.arguments.contains("--discovery-smoke") {
            var actualNames: [String] = []
            let liveDiscovery = SPTorrentDownloadChooser(showMenu: { menu, _, _ in
                actualNames = menu.items.filter { $0.action != nil && !$0.title.contains("(built-in)") && $0.title != L("torrent.downloadOtherApp") }.map(\.title)
            })
            for (name, source) in [("metainfo", descriptor), ("magnet", magnet)] {
                liveDiscovery.present(descriptor: source, file: file, in: view,
                    isCurrent: { true }, builtIn: {}, failed: { _ in })
                print("READ-ONLY DEFAULT DISCOVERY \(name): " + actualNames.joined(separator: ", "))
            }
            let urls = (UTType(filenameExtension: "torrent").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? [])
                + NSWorkspace.shared.urlsForApplications(toOpen: magnetURL)
            let identifiers = Set(urls.compactMap { Bundle(url: $0)?.bundleIdentifier }).sorted()
            print("READ-ONLY HANDLER IDS: " + identifiers.joined(separator: ", "))
        }
        print("Torrent download chooser checks passed (\(checks) assertions; actual native menu/picker configuration, no live app launch).")
    }
}
