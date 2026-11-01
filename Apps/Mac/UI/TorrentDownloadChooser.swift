import AppKit
import Darwin
import UniformTypeIdentifiers

enum SPTorrentDownloadSourceKind {
    case metainfo
    case magnet(URL)
    case unavailable
}

enum SPTorrentDownloadError: LocalizedError {
    case sourceUnavailable
    var errorDescription: String? { L("torrent.downloadSourceUnavailable") }
}

/// Independent metadata copies outlive LaunchServices dispatch. They never
/// contain video data, and history pruning cannot remove an app's pending input.
final class SPTorrentExternalSourceStore: @unchecked Sendable {
    private let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let maximumCount: Int
    private let maximumBytes: Int64
    private let retention: TimeInterval
    private let minimumAge: TimeInterval

    init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Kinolet-Torrent-Handoff", isDirectory: true),
         maximumCount: Int = 32, maximumBytes: Int64 = 256 * 1_024 * 1_024,
         retention: TimeInterval = 7 * 24 * 60 * 60, minimumAge: TimeInterval = 60 * 60,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes; self.retention = retention
        self.minimumAge = minimumAge; self.now = now
    }

    static func kind(for descriptor: SPTorrentDescriptor) -> SPTorrentDownloadSourceKind {
        if descriptor.originalTorrentData != nil { return .metainfo }
        if let link = descriptor.originalLink, let url = validMagnet(link, hash: descriptor.hash) { return .magnet(url) }
        return .unavailable
    }

    private static func validMagnet(_ link: String, hash: String) -> URL? {
        guard link.utf8.count <= 65_536, SPTorrentInput.magnetHash(link) == hash,
              !link.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let components = URLComponents(string: link), components.scheme?.lowercased() == "magnet",
              components.host == nil, components.user == nil, components.password == nil,
              components.path.isEmpty else { return nil }
        return URL(string: link)
    }

    func prepare(descriptor: SPTorrentDescriptor, file: SPTorrentFile) throws -> URL {
        guard descriptor.files.contains(file), file.length > 0,
              SPTorrentInput.normalizedHash(descriptor.hash) == descriptor.hash else {
            throw SPTorrentDownloadError.sourceUnavailable
        }
        guard let data = descriptor.originalTorrentData else {
            guard let link = descriptor.originalLink, let url = Self.validMagnet(link, hash: descriptor.hash) else {
                throw SPTorrentDownloadError.sourceUnavailable
            }
            return url
        }
        guard (try? SPTorrentInput.infoHash(in: data)) == descriptor.hash else {
            throw SPTorrentDownloadError.sourceUnavailable
        }
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Self.storageError() }
        defer { Darwin.close(root) }
        var status = stat()
        guard fstat(root, &status) == 0, status.st_uid == geteuid(),
              fchmod(root, 0o700) == 0, flock(root, LOCK_EX) == 0 else { throw Self.storageError() }
        defer { _ = flock(root, LOCK_UN) }
        try makeRoom(for: Int64(data.count), manager: manager)
        let folder = directory.appendingPathComponent("handoff-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent("source.torrent")
        do {
            let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Self.storageError() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            try manager.setAttributes([.modificationDate: now()], ofItemAtPath: folder.path)
            return target
        } catch {
            try? removeCopy(at: folder)
            throw error
        }
    }

    private func makeRoom(for incoming: Int64, manager: FileManager) throws {
        struct Copy { let url: URL; let date: Date; let bytes: Int64 }
        var copies: [Copy] = []
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard url.lastPathComponent.hasPrefix("handoff-"),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) != nil,
                  let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let date = attributes[.modificationDate] as? Date else { continue }
            guard let fileAttributes = try? manager.attributesOfItem(atPath: url.appendingPathComponent("source.torrent").path),
                  fileAttributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = fileAttributes[.size] as? NSNumber else {
                // A client may move the metainfo after importing it. Reclaim
                // only old empty owned folders, never fresh or unknown contents.
                if now().timeIntervalSince(date) >= retention { try removeEmptyDirectory(at: url) }
                continue
            }
            let copy = Copy(url: url, date: date, bytes: bytes.int64Value)
            if now().timeIntervalSince(date) >= retention { try removeCopy(at: url) }
            else { copies.append(copy) }
        }
        copies.sort { $0.date < $1.date }
        var count = copies.count, bytes = copies.reduce(Int64(0)) { $0 + $1.bytes }
        for copy in copies where count >= maximumCount || bytes + incoming > maximumBytes {
            // Fresh dispatches may still be reading; never reclaim them to make
            // another handoff succeed. Surface a normal storage error instead.
            guard now().timeIntervalSince(copy.date) >= minimumAge else { continue }
            try removeCopy(at: copy.url)
            count -= 1; bytes -= copy.bytes
        }
        guard count < maximumCount, incoming <= maximumBytes, bytes <= maximumBytes - incoming else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func removeCopy(at folder: URL) throws {
        // The receiving app may save media beside its input. Only our known
        // metadata file belongs to this cache; never recursively remove a folder.
        let source = folder.appendingPathComponent("source.torrent")
        if Darwin.unlink(source.path) != 0, errno != ENOENT { throw Self.storageError() }
        try removeEmptyDirectory(at: folder)
    }

    private func removeEmptyDirectory(at folder: URL) throws {
        // rmdir is atomic: contents created between inspection and reclamation
        // keep the directory alive instead of being swept up by recursive I/O.
        if Darwin.rmdir(folder.path) != 0, errno != ENOENT, errno != ENOTEMPTY, errno != EEXIST {
            throw Self.storageError()
        }
    }

    private static func storageError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

@MainActor
final class SPTorrentDownloadChooser {
    struct Application {
        let url: URL
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
    }
    typealias Discover = @MainActor (SPTorrentDownloadSourceKind) -> [URL]
    typealias AppInfo = @MainActor (URL) -> Application?
    typealias MenuPresenter = @MainActor (NSMenu, NSPoint, NSView) -> Void
    typealias PanelPresenter = @MainActor (NSOpenPanel, NSWindow?, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void
    typealias Launcher = @MainActor (URL, URL) async throws -> Void

    @MainActor private final class Action: NSObject {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
        @objc func invoke(_ sender: Any?) { perform() }
    }

    private let store: SPTorrentExternalSourceStore
    private let discover: Discover
    private let appInfo: AppInfo
    private let showMenu: MenuPresenter
    private let showPanel: PanelPresenter
    private let launch: Launcher
    private let ownURL: URL
    private let ownIdentifier: String?
    private var generation: UInt64 = 0
    private var applicationPanel: NSOpenPanel?
    private var launchTask: Task<Void, Never>?

    init(store: SPTorrentExternalSourceStore = .init(),
         discover: @escaping Discover = SPTorrentDownloadChooser.discoverApplications,
         appInfo: @escaping AppInfo = SPTorrentDownloadChooser.applicationInfo,
         showMenu: @escaping MenuPresenter = { menu, point, view in menu.popUp(positioning: nil, at: point, in: view) },
         showPanel: @escaping PanelPresenter = { panel, window, finished in
             if let window { panel.beginSheetModal(for: window, completionHandler: finished) }
             else { panel.begin(completionHandler: finished) }
         },
         launch: @escaping Launcher = { url, app in
             _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
         },
         ownURL: URL = Bundle.main.bundleURL, ownIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.store = store; self.discover = discover; self.appInfo = appInfo
        self.showMenu = showMenu; self.showPanel = showPanel; self.launch = launch
        self.ownURL = Self.canonical(ownURL); self.ownIdentifier = ownIdentifier
    }

    func present(descriptor: SPTorrentDescriptor, file: SPTorrentFile, in view: NSView,
                 isCurrent: @escaping @MainActor () -> Bool,
                 builtIn: @escaping @MainActor () -> Void,
                 failed: @escaping @MainActor (Error) -> Void) {
        guard isCurrent() else { return }
        generation &+= 1
        let token = generation
        applicationPanel?.cancel(nil)
        applicationPanel = nil
        launchTask?.cancel()
        let valid: @MainActor () -> Bool = { [weak self] in self?.generation == token && isCurrent() }
        let menu = NSMenu(title: L("torrent.downloadWith"))
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: L("torrent.downloadWith"), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Кинолёт"
        addAction(L("torrent.downloadBuiltIn", ownName), image: NSWorkspace.shared.icon(forFile: ownURL.path), to: menu) {
            if valid() { builtIn() }
        }
        menu.addItem(.separator())
        var seen = Set<URL>()
        var seenIdentifiers = Set<String>()
        for url in discover(SPTorrentExternalSourceStore.kind(for: descriptor)) {
            guard let app = externalApplication(url), seen.insert(Self.canonical(app.url)).inserted else { continue }
            if let identifier = app.bundleIdentifier, !identifier.isEmpty,
               !seenIdentifiers.insert(identifier).inserted { continue }
            addAction(app.name, image: app.icon, to: menu) { [weak self] in
                guard valid() else { return }
                self?.open(app.url, descriptor: descriptor, file: file, valid: valid, failed: failed)
            }
        }
        addAction(L("torrent.downloadOtherApp"), to: menu) { [weak self, weak view] in
            guard let self, let view, valid() else { return }
            self.chooseApplication(in: view) { [weak self] url in
                guard let self, let url, valid() else { return }
                self.open(url, descriptor: descriptor, file: file, valid: valid, failed: failed)
            }
        }
        menu.addItem(.separator())
        let hint = NSMenuItem()
        let label = NSTextField(wrappingLabelWithString: L("torrent.downloadExternalHint"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 12, y: 6, width: 290, height: 1)
        label.frame.size.height = label.sizeThatFits(NSSize(width: 290, height: CGFloat.greatestFiniteMagnitude)).height
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 314, height: label.frame.height + 12))
        footer.addSubview(label)
        hint.view = footer
        hint.isEnabled = false
        menu.addItem(hint)
        var point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let window = view.window {
            let cursor = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if view.bounds.contains(cursor) { point = cursor }
        }
        if valid() { showMenu(menu, point, view) }
    }

    private func addAction(_ title: String, image: NSImage? = nil, to menu: NSMenu,
                           action: @escaping @MainActor () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: "")
        let target = Action(action)
        item.target = target
        item.representedObject = target
        if let image { let icon = image.copy() as! NSImage; icon.size = NSSize(width: 16, height: 16); item.image = icon }
        menu.addItem(item)
    }

    private func chooseApplication(in view: NSView, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L("torrent.downloadOtherApp")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        applicationPanel = panel
        let finished: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self, self.applicationPanel === panel else { return }
            self.applicationPanel = nil
            completion(response == .OK ? panel?.url : nil)
        }
        showPanel(panel, view.window, finished)
    }

    private func open(_ appURL: URL, descriptor: SPTorrentDescriptor, file: SPTorrentFile,
                      valid: @escaping @MainActor () -> Bool,
                      failed: @escaping @MainActor (Error) -> Void) {
        guard valid() else { return }
        guard let app = externalApplication(appURL) else {
            failed(CocoaError(.executableNotLoadable)); return
        }
        let store = store
        launchTask = Task { [weak self] in
            do {
                guard valid(), !Task.isCancelled else { return }
                let source = try await Task.detached(priority: .utility) {
                    try store.prepare(descriptor: descriptor, file: file)
                }.value
                guard let self, valid(), !Task.isCancelled else { return }
                try await self.launch(source, app.url)
            } catch {
                if valid(), !Task.isCancelled { failed(error) }
            }
        }
    }

    private func externalApplication(_ url: URL) -> Application? {
        guard url.isFileURL, let app = appInfo(url), Self.canonical(app.url) != ownURL,
              app.bundleIdentifier != "app.kinolet.player",
              ownIdentifier == nil || app.bundleIdentifier != ownIdentifier else { return nil }
        return app
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func discoverApplications(_ source: SPTorrentDownloadSourceKind) -> [URL] {
        switch source {
        case .metainfo:
            guard let type = UTType(filenameExtension: "torrent") else { return [] }
            return NSWorkspace.shared.urlsForApplications(toOpen: type)
        case .magnet(let url): return NSWorkspace.shared.urlsForApplications(toOpen: url)
        case .unavailable: return []
        }
    }
    private static func applicationInfo(_ url: URL) -> Application? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Application(url: url, name: name, bundleIdentifier: bundle.bundleIdentifier,
                           icon: NSWorkspace.shared.icon(forFile: url.path))
    }
}
