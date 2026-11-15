import AppKit

/// Installed with the deferred controls. Hide the pointer only when the
/// controls are hidden and every safety gate passes. No independent timer,
/// event monitor, polling or work on media threads.
@MainActor
final class SPPlaybackCursorController {
    private weak var view: NSView?
    private var hasVideo = false
    private var chromeHidden = false
    private var transitioningFullscreen = false
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []
    private var ownsHiddenCursor = false
    private var pendingReleasePoint: NSPoint?
    private let setCursorHidden: (Bool) -> Void
    private static let dbg = ProcessInfo.processInfo.environment["SP_DEBUG"] != nil

    init(view: NSView,
         setCursorHidden: @escaping (Bool) -> Void = NSCursor.setHiddenUntilMouseMoves) {
        self.view = view
        self.setCursorHidden = setCursorHidden
        guard let window = view.window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didChangeScreenNotification] {
            observe(name, object: window) { $0.apply() }
        }
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification] {
            observe(name, object: nil) { $0.apply() }
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observe(name, object: window) {
                $0.transitioningFullscreen = true
                $0.apply()
            }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observe(name, object: window) {
                $0.transitioningFullscreen = false
                $0.apply()
            }
        }
        observe(NSWindow.willCloseNotification, object: window) {
            // The final player window is retained as the welcome window and can
            // reopen later. Closing suspends this session, not the controller.
            $0.hasVideo = false
            $0.transitioningFullscreen = false
            $0.apply()
        }
        // Menu tracking can keep the player key (including keyboard-opened menus).
        // Track menu identities so nested menus cannot re-hide early.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard let menu = note.object as? NSMenu else { return }
                let identity = ObjectIdentifier(menu)
                let began = note.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if began {
                        self.trackingMenus.insert(identity)
                    } else {
                        self.trackingMenus.remove(identity)
                    }
                    self.apply()
                }
            })
        }
    }

    deinit {
        // Owned exclusively by the main-thread view controller; observer
        // callbacks capture weakly, so none can extend that lifetime.
        MainActor.assumeIsolated {
            reveal()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Audio-only sessions never hide the pointer.
    func setHasVideo(_ video: Bool) {
        guard hasVideo != video else { return }
        hasVideo = video
        apply()
    }

    /// Driven by the chrome visibility state machine: hidden chrome hides the
    /// pointer (gates permitting); shown chrome restores it.
    func setChromeHidden(_ hidden: Bool) {
        chromeHidden = hidden
        apply()
    }

    /// Native motion can reveal the cursor without clearing our ownership.
    /// Reassert the existing request, then check once after AppKit finishes
    /// delivering mouse-up. Do not hide again if the pointer moved meanwhile.
    func refreshAfterMouseRelease() {
        apply(reassertHide: true)
        let alreadyPending = pendingReleasePoint != nil
        pendingReleasePoint = NSEvent.mouseLocation
        guard !alreadyPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let releasePoint = self.pendingReleasePoint else { return }
            self.pendingReleasePoint = nil
            guard NSEvent.mouseLocation == releasePoint else { return }
            self.apply(reassertHide: true)
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject?,
                         action: @escaping @MainActor (SPPlaybackCursorController) -> Void) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: object, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        })
    }

    /// Gates answer "would hiding the system pointer be wrong right now"; none
    /// of them carry product timing.
    private var eligible: Bool {
        guard hasVideo, !transitioningFullscreen, trackingMenus.isEmpty,
              NSApp.isActive, NSApp.modalWindow == nil, let window = view?.window else { return false }
        return window.isKeyWindow && window.isVisible && window.occlusionState.contains(.visible)
            && window.attachedSheet == nil
    }

    private var pointerInside: Bool {
        guard let view, let window = view.window else { return false }
        let point = NSEvent.mouseLocation
        // A focused window can retain focus while the pointer is on another
        // display, over the menu bar, Dock or a floating window.
        guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return false }
        return view.visibleRect.contains(view.convert(window.convertPoint(fromScreen: point), from: nil))
    }

    private func apply(reassertHide: Bool = false) {
        if chromeHidden, eligible, NSEvent.pressedMouseButtons == 0, pointerInside {
            hide(reassert: reassertHide)
        } else {
            reveal()
        }
    }

    private func hide(reassert: Bool) {
        guard reassert || !ownsHiddenCursor else { return }
        ownsHiddenCursor = true
        setCursorHidden(true)
        if Self.dbg { NSLog("[Cursor] 隐藏（随控制区）") }
    }

    private func reveal() {
        guard ownsHiddenCursor else { return }
        ownsHiddenCursor = false
        // This API must be undone with false, never NSCursor.unhide(). Only the
        // owning window restores it, so inactive windows cannot undo a new hide.
        setCursorHidden(false)
        if Self.dbg { NSLog("[Cursor] 恢复") }
    }
}
