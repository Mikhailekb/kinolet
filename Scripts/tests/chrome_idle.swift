import AppKit
import Foundation

@MainActor private final class IdleWindow: NSWindow {
    var pointer = NSPoint(x: 300, y: 30)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@MainActor private final class IdleChrome: NSView {
    let track = NSView(frame: NSRect(x: 20, y: 70, width: 600, height: 22))
    let button = NSButton(frame: NSRect(x: 20, y: 16, width: 44, height: 44))
    var ownsKeyboardFocus = false
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 150))
        addSubview(track)
        addSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }
    // INSERT_CHROME_METHODS
}

@MainActor private final class IdlePresenter {
    var shows = 0
    var hides = 0
    func show() { shows += 1 }
    func hide() { hides += 1 }
}

@MainActor private final class IdleCursor {
    var visibility: [Bool] = []
    func setChromeHidden(_ value: Bool) { visibility.append(value) }
}

@MainActor private final class IdleCore { var duration: Double = 60 }

// Only dependencies at the controller's boundary are controlled. Its actual
// mouseMoved, deadline, Foundation timer and hide decision are inserted below.
@MainActor private final class IdleOwner: NSViewController {
    static let useNewUI = true
    static let pinControls = false
    static let dbg = false
    var hasMediaSession = true
    var isControlBarVisible = false
    var isSettingsPanelShown = false
    var isPlaylistShown = false
    var isScrubbing = false
    var hideDeadline: TimeInterval = 0
    var hideControlsTimer: Timer?
    var chrome: IdleChrome? = IdleChrome()
    var chromePresenter: IdlePresenter? = IdlePresenter()
    var playbackCursor: IdleCursor? = IdleCursor()
    var core: IdleCore?
    let slider = NSSlider()
    let hoverTimeLabel = NSTextField(labelWithString: "")
    let controlBar = NSView()
    static func formatTime(_ position: Double, _ duration: Double) -> String { "unused legacy branch" }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400)) }
    func expireIdleTimer() {
        // Deliver the production Foundation callback at an elapsed deadline;
        // don't make every boundary case spend the full2.5s waiting in CI.
        hideDeadline = ProcessInfo.processInfo.systemUptime - 1
        hideControlsTimer?.fire()
    }
    func shutdown() { hideControlsTimer?.invalidate() }
    // INSERT_CONTROLLER_METHODS
}

@main @MainActor private enum ChromeIdleChecks {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
    static func fixture() -> (IdleOwner, IdleWindow) {
        let owner = IdleOwner()
        let window = IdleWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = owner.view
        owner.view.addSubview(owner.chrome!)
        return (owner, window)
    }
    static func move(_ owner: IdleOwner, _ window: IdleWindow, to point: NSPoint) {
        window.pointer = point
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 0, pressure: 0)!
        owner.mouseMoved(with: event)
    }
    static func main() {
        _ = NSApplication.shared
        for point in [NSPoint(x: 300, y: 30), NSPoint(x: 4, y: 30), NSPoint(x: 636, y: 30),
                      NSPoint(x: 300, y: 180)] {
            let (owner, window) = fixture()
            defer { owner.shutdown() }
            move(owner, window, to: point)
            check(owner.isControlBarVisible && owner.hideControlsTimer?.isValid == true,
                  "pointer activity shows controls and arms their existing timer")
            if point.y < 81 {
                check(owner.chrome?.hitTest(point) === owner.chrome,
                      "empty strip and side margins remain click-absorbing chrome")
            }
            owner.expireIdleTimer()
            check(!owner.isControlBarVisible && owner.chromePresenter?.hides == 1,
                  "stationary pointer on empty chrome or video lets idle timer hide controls")
            check(owner.playbackCursor?.visibility == [false, true],
                  "idle control hide also requests cursor hiding")
            move(owner, window, to: point)
            check(owner.isControlBarVisible && owner.chromePresenter?.shows == 2 &&
                  owner.hideControlsTimer?.isValid == true && owner.playbackCursor?.visibility == [false, true, false],
                  "next pointer activity reveals controls/cursor and rearms timeout")
        }
        for point in [NSPoint(x: 40, y: 30), NSPoint(x: 300, y: 80)] {
            let (owner, window) = fixture()
            defer { owner.shutdown() }
            move(owner, window, to: point)
            let hit = owner.chrome?.hitTest(point)
            check(hit != nil && hit !== owner.chrome, "button/timeline hit belongs to an actual control")
            owner.expireIdleTimer()
            check(owner.isControlBarVisible && owner.chromePresenter?.hides == 0 &&
                  owner.hideControlsTimer?.isValid == true && owner.playbackCursor?.visibility == [false],
                  "hover over an actual control retains controls and rearms idle check")
        }
        for gate in ["settings", "playlist", "scrubbing", "keyboard"] {
            let (owner, window) = fixture()
            defer { owner.shutdown() }
            move(owner, window, to: NSPoint(x: 300, y: 30))
            switch gate {
            case "settings": owner.isSettingsPanelShown = true
            case "playlist": owner.isPlaylistShown = true
            case "scrubbing": owner.isScrubbing = true
            default: owner.chrome?.ownsKeyboardFocus = true
            }
            owner.expireIdleTimer()
            check(owner.isControlBarVisible && owner.chromePresenter?.hides == 0 &&
                  owner.hideControlsTimer?.isValid == true,
                  "active \(gate) interaction retains controls")
            owner.isSettingsPanelShown = false
            owner.isPlaylistShown = false
            owner.isScrubbing = false
            owner.chrome?.ownsKeyboardFocus = false
            owner.expireIdleTimer()
            check(!owner.isControlBarVisible && owner.playbackCursor?.visibility.last == true,
                  "ending \(gate) interaction permits idle hiding over the same empty strip")
        }
        do {
            let (owner, window) = fixture()
            defer { owner.shutdown() }
            move(owner, window, to: NSPoint(x: 300, y: 30))
            let timer = owner.hideControlsTimer
            let oldDeadline = owner.hideDeadline
            move(owner, window, to: NSPoint(x: 301, y: 30))
            check(owner.hideControlsTimer === timer && owner.hideDeadline >= oldDeadline,
                  "movement while visible extends deadline without creating another timer")
            timer?.fire()
            check(owner.isControlBarVisible && owner.chromePresenter?.hides == 0,
                  "an early timer delivery respects the latest pointer deadline")
            owner.chrome?.isHidden = true
            check(owner.chrome?.videoGestureExclusionRect(in: owner.view).contains(NSPoint(x: 300, y: 30)) == true,
                  "hidden chrome preserves blank-strip click-exclusion geometry")
        }
        print("Chrome idle checks passed (\(assertions) assertions).")
    }
}
