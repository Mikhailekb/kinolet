import AppKit
import QuartzCore
struct SPDamageSpanRecord { var cls: Int32; var fromUs: Int64; var untilUs: Int64 }
final class SPDamageSnapshot { let generation: UInt64 = 0; let main=Data(), pending=Data() }
struct SPThumbDustSnapshot {}
enum SPTimelineStyleSettings { enum Style { case starTrail,tide,classic }; static let style=Style.classic; static let changed=Notification.Name("test.style") }
@MainActor final class SPDustHost {
 static let enabled=false
 let layer=CALayer()
 func attach(to view:NSView){};func detach(){}
 func setGeometry(bounds:CGRect,scale:CGFloat){};func setSnapshot(_ snapshot:SPThumbDustSnapshot?,duration:Double){}
 func setDamage(bands:[SPDamageBand],duration:Double){};func setBufferedRanges(_ ranges:[ClosedRange<Double>],visible:Bool){}
 func setSplit(_ split:CGFloat){};func setVisible(_ visible:Bool){}
 func pointerEntered(x:CGFloat){};func pointerMoved(x:CGFloat){};func pointerExited(){};func pressed(x:CGFloat){};func released(hovering:Bool){}
}
enum SPPlayerCore { static func fullFeatureTier() -> Bool { ProcessInfo.processInfo.environment["PLAYLIST_NAV_ENHANCE"] != "0" } }

// INSERT_CONTROLLER_FIXTURE

@main @MainActor struct PlaylistNavigationChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }
    static func capture(_ view: NSView, to path: URL) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: path)
    }
    static func centerRuns(_ image: NSImage) -> Int {
        let pixels = NSBitmapImageRep(data: image.tiffRepresentation!)!
        var count = 0, inside = false
        for x in 0..<pixels.pixelsWide {
            let opaque = pixels.colorAt(x: x, y: pixels.pixelsHigh / 2)!.alphaComponent > 0.5
            if opaque && !inside { count += 1 }
            inside = opaque
        }
        return count
    }
    static func buttonPixels(_ button: NSButton) -> Data {
        button.layoutSubtreeIfNeeded()
        button.displayIfNeeded()
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { fatalError("No button bitmap") }
        button.cacheDisplay(in: button.bounds, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let artifactDirectory = CommandLine.arguments.count == 2 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) : nil
        if let artifactDirectory { try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true) }
        let chrome = SPChromeView()
        chrome.appearance = NSAppearance(named: .darkAqua)
        chrome.setTime(position: 614, duration: 3231, rate: 1)
        var previousCalls = 0, nextCalls = 0
        chrome.onPreviousMedia = { previousCalls += 1 }
        chrome.onNextMedia = { nextCalls += 1 }
        chrome.layoutChrome(in: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let standaloneX = chrome.volumeGroup.frame.minX
        check(chrome.previousBtn.isHidden && chrome.nextBtn.isHidden, "standalone does not show navigation")
        chrome.previousTapped(); chrome.nextTapped()
        check(previousCalls == 0 && nextCalls == 0, "hidden navigation actions are inert")
        for count in [0,1] {
            let state = SPPlaylistNavigationPresentation(hasMedia: true, count: count, currentIndex: 0)
            check(!state.isVisible, "zero and single-item catalogues have no navigation")
        }
        check(!SPPlaylistNavigationPresentation(hasMedia: false, count: 3, currentIndex: 1).isVisible,
              "catalogue without active media does not show controls")
        check(!SPPlaylistNavigationPresentation(hasMedia: true, count: 3, currentIndex: -1).isVisible &&
              !SPPlaylistNavigationPresentation(hasMedia: true, count: 3, currentIndex: 3).isVisible,
              "invalid catalogue positions hide both controls")
        chrome.setPlaylistNavigation(.init(hasMedia: true, count: 3, currentIndex: 0))
        check(!chrome.previousBtn.isHidden && !chrome.nextBtn.isHidden, "both controls show for a playlist")
        check(!chrome.previousBtn.isEnabled && chrome.nextBtn.isEnabled, "first item disables only Previous")
        chrome.previousBtn.performClick(nil); chrome.nextBtn.performClick(nil)
        check(previousCalls == 0 && nextCalls == 1, "first item dispatches only available Next")
        chrome.setPlaylistNavigation(.init(hasMedia: true, count: 3, currentIndex: 1))
        chrome.previousBtn.performClick(nil); chrome.nextBtn.performClick(nil)
        check(previousCalls == 1 && nextCalls == 2, "middle item dispatches both directions exactly once")
        check(chrome.previousBtn.image != nil && chrome.nextBtn.image != nil, "single-triangle-and-bar template icons exist")
        check(centerRuns(chrome.previousBtn.image!) == 2 && centerRuns(chrome.nextBtn.image!) == 2,
              "each skip icon has exactly one triangle and one separate end bar")
        check(chrome.previousBtn.toolTip == L("control.previousVideo") && chrome.nextBtn.toolTip == L("control.nextVideo"),
              "navigation has localized descriptive tooltips")
        check(!chrome.previousBtn.refusesFirstResponder && !chrome.nextBtn.refusesFirstResponder &&
              chrome.previousBtn.preservesKeyboardFocusOnClick && chrome.nextBtn.preservesKeyboardFocusOnClick,
              "navigation remains keyboard accessible without stealing mouse-click focus")
        chrome.setTime(position: 614, duration: 3231, rate: 2)
        chrome.layoutRightControls()
        check(!chrome.rateChip.isHidden, "An ordinary fixed 2x rate still has its bottom control")
        let previousPixels = buttonPixels(chrome.previousBtn)
        let nextPixels = buttonPixels(chrome.nextBtn)
        let ratePixels = buttonPixels(chrome.rateChip)
        check(ratePixels.contains { $0 != 0 }, "Visible rate comparison uses actual rendered title pixels")
        if let artifactDirectory {
            try capture(chrome.nextBtn, to: artifactDirectory.appendingPathComponent("next-enabled-\(SPFeatures.enhancements ? "full" : "basic").png"))
            try capture(chrome.rateChip, to: artifactDirectory.appendingPathComponent("rate-enabled-\(SPFeatures.enhancements ? "full" : "basic").png"))
        }
        chrome.setTurboPhase(.charging)
        check(!chrome.previousBtn.isEnabled && !chrome.nextBtn.isEnabled, "Turbo charge disables navigation")
        check(chrome.previousBtn.alphaValue == 1 && chrome.nextBtn.alphaValue == 1 && chrome.rateChip.alphaValue == 1,
              "Turbo lock preserves the alpha of controls that were available")
        check(buttonPixels(chrome.previousBtn) == previousPixels && buttonPixels(chrome.nextBtn) == nextPixels,
              "Native disabled icon cells keep their exact enabled pixels during Turbo")
        check(buttonPixels(chrome.rateChip) == ratePixels && !chrome.rateChip.isEnabled,
              "The disabled rate chip retains its original native title rendering")
        if let artifactDirectory {
            try capture(chrome.nextBtn, to: artifactDirectory.appendingPathComponent("next-turbo-locked-\(SPFeatures.enhancements ? "full" : "basic").png"))
            try capture(chrome.rateChip, to: artifactDirectory.appendingPathComponent("rate-turbo-locked-\(SPFeatures.enhancements ? "full" : "basic").png"))
        }
        chrome.previousBtn.performClick(nil); chrome.nextBtn.performClick(nil)
        check(previousCalls == 1 && nextCalls == 2, "Native clicks stay blocked despite the normal icon appearance")
        check(!chrome.nextBtn.accessibilityPerformPress() && nextCalls == 2,
              "Accessibility press cannot activate Turbo-locked navigation")
        chrome.nextBtn.keyEquivalent = "n"
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        check(!chrome.nextBtn.performKeyEquivalent(with: key) && nextCalls == 2,
              "Keyboard activation respects the actual disabled state")
        chrome.nextBtn.keyEquivalent = ""
        chrome.setTurboPhase(.active)
        check(chrome.rateChip.isHidden, "Active temporary Turbo removes the duplicate bottom rate indicator")
        check(buttonPixels(chrome.previousBtn) == previousPixels && buttonPixels(chrome.nextBtn) == nextPixels,
              "Active Turbo also retains normal navigation pixels")
        chrome.setTurboPhase(.idle)
        check(!chrome.rateChip.isHidden, "Releasing Turbo restores the ordinary fixed-rate control")
        check(chrome.previousBtn.isEnabled && chrome.nextBtn.isEnabled, "releasing Turbo restores current navigation state")
        check(!chrome.previousBtn.preservesEnabledAppearance && !chrome.nextBtn.preservesEnabledAppearance,
              "Releasing Turbo removes the render-only enabled override")
        chrome.setPlaylistNavigation(.init(hasMedia: true, count: 3, currentIndex: 2))
        let unavailablePixels = buttonPixels(chrome.nextBtn)
        chrome.setTurboPhase(.charging)
        check(chrome.nextBtn.alphaValue == 0.35 && !chrome.nextBtn.preservesEnabledAppearance &&
              buttonPixels(chrome.nextBtn) == unavailablePixels,
              "A real playlist boundary stays dim and unavailable during Turbo")
        chrome.setTurboPhase(.idle)
        chrome.isHidden = true
        chrome.setTurboPhase(.active)
        chrome.show()
        check(chrome.rateChip.isHidden, "Showing hidden chrome replays active Turbo without a bottom rate indicator")
        chrome.isHidden = true
        chrome.setTurboPhase(.idle)
        chrome.show()
        check(!chrome.rateChip.isHidden, "Showing chrome after hidden Turbo release restores the fixed-rate control")
        chrome.setTime(position: 614, duration: 3231, rate: 1)
        chrome.nextBtn.performClick(nil)
        check(chrome.previousBtn.isEnabled && !chrome.nextBtn.isEnabled && nextCalls == 2,
              "last item disables Next without wrapping")
        chrome.setPlaylistNavigation(.init(hasMedia: true, count: 3, currentIndex: 1, enabled: false))
        check(!chrome.previousBtn.isEnabled && !chrome.nextBtn.isEnabled && !chrome.previousBtn.isHidden,
              "opening keeps playlist positions but disables switching")
        chrome.setPlaylistNavigation(.none)
        check(chrome.volumeGroup.frame.minX == standaloneX, "leaving playlist removes all navigation spacing")
        for width: CGFloat in [480,500,540,640,1280] {
            chrome.setPlaylistNavigation(.init(hasMedia: true, count: 3, currentIndex: 1))
            chrome.layoutChrome(in: NSRect(x: 0, y: 0, width: width, height: 720))
            let actions = [chrome.playlistBtn, chrome.motionBtn, chrome.subtitlesBtn, chrome.settingsBtn, chrome.pipBtn, chrome.fsBtn].filter {
                $0.superview != nil && !$0.isHidden
            }
            for button in [chrome.playBtn, chrome.previousBtn, chrome.nextBtn] + actions {
                check(button.frame.minX >= 0 && button.frame.maxX <= width && button.frame.width >= 28,
                      "every quick button fits minimum and normal windows")
                check(chrome.hitTest(button.frame.center) === button, "actual Chrome hitTest reaches each quick button")
            }
            check(chrome.previousBtn.frame.minX > chrome.playBtn.frame.maxX && chrome.nextBtn.frame.minX > chrome.previousBtn.frame.maxX,
                  "navigation follows Play without overlap")
            chrome.volumeGroup.hovering = true
            chrome.volumeGroup.setExpanded(true, animated: false)
            chrome.layoutRightControls()
            for percent: Double in [100,500] {
                chrome.setVolumeBoost(percent > 100 ? .unlocked : .normal)
                chrome.setVolume(pct: percent, muted: false)
                chrome.layoutRightControls()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.24))
                chrome.layoutRightControls()
                chrome.volSlider.layoutSubtreeIfNeeded()
                let slider = chrome.volSlider
                let endpoint = slider.convert(slider.knobLayer.frame, to: chrome.volumeGroup)
                check(endpoint.minX >= 0 && endpoint.maxX <= chrome.volumeGroup.bounds.maxX + 0.01,
                      "volume100 and500 endpoint knobs are fully visible at every width")
                let point = slider.knobLayer.frame.midX
                check(abs(slider.value(at: point) - percent) < 0.001, "visible volume endpoint maps to intended percentage")
                check(actions.allSatisfy { !chrome.volumeGroup.frame.intersects($0.frame) },
                      "expanded volume never overlaps quick-action targets")
            }
            chrome.setVolumeBoost(.normal);chrome.setVolume(pct:100,muted:false)
            chrome.volumeGroup.hovering = false
            chrome.volumeGroup.setExpanded(false, animated:false);chrome.layoutRightControls()
            if let artifactDirectory, [480,1280].contains(Int(width)) {
                try capture(chrome, to: artifactDirectory.appendingPathComponent("playlist-controls-\(Int(width))-\(SPFeatures.enhancements ? "full" : "basic").png"))
            }
        }
        controllerChecks(chrome)
        print("Playlist navigation checks passed (\(checks) assertions; enhancements=\(SPFeatures.enhancements)).")
    }
    static func controllerChecks(_ chrome: SPChromeView) {
        let owner = NavigationFixtureOwner(chrome: chrome)
        owner.refreshPlaylistNavigationControls()
        check(!chrome.previousBtn.isHidden && chrome.nextBtn.isEnabled, "controller publishes catalogue while sidebar is closed")
        for shown in [false,true] {
            for direction in [false,true] {
                owner.currentMediaIndex = 1; owner.playbackIdentityURL = owner.mediaList[1]
                owner.core!.state = .playing;owner.isPlaylistShown = shown;owner.opened = []
                owner.refreshPlaylistNavigationControls()
                if direction { chrome.nextBtn.performClick(nil) } else { chrome.previousBtn.performClick(nil) }
                check(owner.opened == [owner.mediaList[direction ? 2 : 0]], "button routes to correct neighbouring episode")
                check(owner.isPlaylistShown == shown, "torrent episode change preserves exact sidebar state")
                chrome.nextBtn.performClick(nil)
                check(owner.opened.count == 1, "Opening blocks rapid navigation presses")
            }
        }
        owner.currentMediaIndex = 0;owner.playbackIdentityURL=owner.mediaList[0];owner.core!.state = .playing
        owner.mediaList = [owner.mediaList[0]]; owner.refreshPlaylistNavigationControls()
        check(chrome.previousBtn.isHidden && chrome.nextBtn.isHidden, "catalogue shrinking to one removes controls")
        owner.mediaList.append(URL(fileURLWithPath:"/fixture/E2.mp4"));owner.refreshPlaylistNavigationControls()
        check(chrome.nextBtn.isEnabled, "newly arrived disk episode makes Next available without opening sidebar")
        owner.playbackIdentityURL=URL(fileURLWithPath:"/fixture/Unrelated.mp4");owner.refreshPlaylistNavigationControls()
        check(chrome.nextBtn.isHidden, "unrelated current session cannot navigate an old catalogue")
        owner.playbackIdentityURL=owner.mediaList[0];owner.hasMediaSession=false;owner.refreshPlaylistNavigationControls()
        check(chrome.nextBtn.isHidden, "failed or closed session removes navigation")
    }
}
extension NSRect { var center:NSPoint { CGPoint(x:midX,y:midY) } }
