import AppKit
import QuartzCore

// INSERT_PRODUCTION_TOKENS
// INSERT_PRODUCTION_NORMALIZATION

struct SPDamageBand: Equatable {
    static let partial: Int32 = 1, none: Int32 = 2, pending: Int32 = 3
    let cls: Int32
    let from: Double
    let until: Double
}
enum SPDamage {
    static let partialColor = NSColor.orange
    static let noneColor = NSColor.red
    static let pendingColor = NSColor.black
}
struct SPThumbDustSnapshot {}
enum SPTimelineStyleSettings {
    enum Style { case classic, tide, dust }
    static let style = Style.classic
}
// Peripheral Dust dependency is deterministic. The real progress view still
// exercises its dynamic layer insertion, style changes and interaction paths.
@MainActor final class SPDustHost {
    static let enabled = false
    static var latest: SPDustHost?
    var buffered: [ClosedRange<Double>] = []
    var showsBuffered = false
    init() { Self.latest = self }
    let layer = CALayer()
    func attach(to view: NSView) { layer.name = "test.dust" }
    func detach() {}
    func setGeometry(bounds: CGRect, scale: CGFloat) { layer.frame = bounds }
    func setSnapshot(_ snapshot: SPThumbDustSnapshot?, duration: Double) {}
    func setDamage(bands: [SPDamageBand], duration: Double) {}
    func setBufferedRanges(_ ranges: [ClosedRange<Double>], visible: Bool) { buffered = ranges; showsBuffered = visible }
    func setSplit(_ split: CGFloat) {}
    func setVisible(_ visible: Bool) {}
    func pointerEntered(x: CGFloat) {}
    func pointerMoved(x: CGFloat) {}
    func pointerExited() {}
    func pressed(x: CGFloat) {}
    func released(hovering: Bool) {}
}

// INSERT_PRODUCTION_PROGRESS

@main @MainActor
struct BufferedTimelineChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS \(checks): \(message)")
    }
    static func shape(_ view: NSView, _ suffix: String) -> CAShapeLayer {
        view.layer!.sublayers!.first { $0.name == "sp.timeline.buffered." + suffix }! as! CAShapeLayer
    }
    static func pixels(_ view: NSView, scale: Int = 2) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = CGContext(data: image.bitmapData, width: image.pixelsWide, height: image.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: image.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // CALayer.render(in:) walks array order, unlike the on-screen
        // compositor's zPosition ordering. Render these same production layers
        // in their stable painter order so damage overlays are actually tested.
        let layers = view.layer!.sublayers ?? []
        view.layer!.sublayers = layers.enumerated().sorted {
            $0.element.zPosition == $1.element.zPosition ? $0.offset < $1.offset : $0.element.zPosition < $1.element.zPosition
        }.map(\.element)
        defer { view.layer!.sublayers = layers }
        view.layer!.render(in: context)
        return image
    }
    static func white(_ image: NSBitmapImageRep, x: Double) -> Double {
        image.colorAt(x: Int(x * Double(image.pixelsWide)), y: image.pixelsHigh / 2)!
            .usingColorSpace(.deviceRGB)!.redComponent
    }
    static func orange(_ image: NSBitmapImageRep, x: Double) -> Bool {
        let color = image.colorAt(x: Int(x * Double(image.pixelsWide)), y: image.pixelsHigh / 2)!
            .usingColorSpace(.sRGB)!
        return color.redComponent > 0.95 && abs(color.greenComponent - 182 / 255) < 0.04 &&
            abs(color.blueComponent - 92 / 255) < 0.04
    }
    static func damage(_ view: NSView, color: NSColor) -> CAShapeLayer {
        view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
            .first { $0.zPosition == 15 && $0.fillColor == color.cgColor }!
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        expect(SPBufferedTimeline.normalized([-0.5...0.2, 0.1...0.3, 0.3...0.4, 0.6...0.7, 0.9...1.4]) ==
            [0...0.4, 0.6...0.7, 0.9...1], "Normalized ranges clip, sort and merge only overlapping or touching intervals")
        expect(SPBufferedTimeline.normalized([(-Double.infinity)...0.5, 0.5...Double.infinity,
                                               0.3...0.3, 1.1...1.2]).isEmpty,
               "Nonfinite, empty and entirely out-of-duration coverage is discarded")
        expect(SPBufferedTimeline.normalized([0.1...0.2, 0.20001...0.3]).count == 2,
               "A real gap is never bridged by a rounding tolerance")
        let view = SPProgressView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        view.setBufferedRanges([0.1...0.3, 0.5...0.6, 0.8...0.9], visible: true)
        view.setValue(0.2)
        let initial = pixels(view)
        expect(white(initial, x: 0.1) > 0.95, "Played media remains white above cached coverage")
        expect(orange(initial, x: 0.25), "Resident forward media uses the existing Turbo orange")
        expect(white(initial, x: 0.4) < 0.25 && white(initial, x: 0.7) < 0.25,
               "Uncached gaps stay visibly dark")
        expect(orange(initial, x: 0.55) && orange(initial, x: 0.85),
               "Discontinuous cached segments are drawn at their supplied media times")

        let paused = SPProgressView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))
        paused.setValue(0.2)
        let pending = SPDamageBand(cls: SPDamageBand.pending, from: 0, until: 10)
        paused.setDamage(bands: [pending], duration: 10)
        paused.setBufferedRanges([], visible: true)
        let pendingLayer = damage(paused, color: SPDamage.pendingColor)
        let pausedBeforeArrival = pixels(paused)
        expect(pendingLayer.path!.contains(CGPoint(x: 100, y: 22)) && white(pausedBeforeArrival, x: 0.25) < 0.05,
               "An actually missing paused span keeps its pending overlay")
        paused.setBufferedRanges([0.1...0.3, 0.5...0.6, 0.8...0.9], visible: true)
        let pausedAfterArrival = pixels(paused)
        expect(orange(pausedAfterArrival, x: 0.25) && orange(pausedAfterArrival, x: 0.55) &&
               !pendingLayer.path!.contains(CGPoint(x: 100, y: 22)),
               "Cache arrival removes stale pending from resident spans without moving the playhead")
        expect(white(pausedAfterArrival, x: 0.15) > 0.95 &&
               abs(shape(paused, "played").path!.boundingBox.width - 80) < 0.001,
               "Known resident played media stays white at the frozen playback position")
        expect(pendingLayer.path!.contains(CGPoint(x: 160, y: 22)) && white(pausedAfterArrival, x: 0.4) < 0.05,
               "Pending remains visible inside real gaps between resident spans")
        paused.setDamage(bands: [], duration: 10)
        paused.setDamage(bands: [pending], duration: 10)
        expect(orange(pixels(paused), x: 0.55) && !pendingLayer.path!.contains(CGPoint(x: 220, y: 22)),
               "Pending arriving after cache cannot repaint a resident solid segment")
        paused.setBufferedRanges([0.1...0.3, 0.5...0.55, 0.5502...0.6], visible: true)
        expect(pendingLayer.path!.contains(CGPoint(x: 0.5501 * 400, y: 22)) &&
               !pendingLayer.path!.contains(CGPoint(x: 0.5504 * 400, y: 22)),
               "A sub-point missing gap stays exact without extending pending into adjacent cache")
        paused.setBufferedRanges([0.1...0.3], visible: true)
        let pausedAfterEviction = pixels(paused)
        expect(pendingLayer.path!.contains(CGPoint(x: 220, y: 22)) && white(pausedAfterEviction, x: 0.55) < 0.05,
               "Eviction restores pending over precisely the removed resident span")
        paused.setBufferedRanges([0.1...0.3, 0.5...0.6], visible: true)
        paused.setDamage(bands: [pending, .init(cls: SPDamageBand.partial, from: 2.4, until: 2.6),
                                .init(cls: SPDamageBand.none, from: 5.4, until: 5.6)], duration: 10)
        expect(damage(paused, color: SPDamage.partialColor).path!.contains(CGPoint(x: 100, y: 22)) &&
               damage(paused, color: SPDamage.noneColor).path!.contains(CGPoint(x: 220, y: 22)),
               "Confirmed partial and unavailable damage still cover resident bytes beneath stale pending")
        paused.setDamage(bands: [pending], duration: 10)
        paused.applyStyle(.tide)
        paused.pointerEntered(atX: 220)
        expect(orange(pixels(paused), x: 0.55) && pendingLayer.path!.contains(CGPoint(x: 160, y: 22)),
               "Liquid style keeps the same resident-over-pending precedence and real gaps")
        paused.pointerExited()
        paused.applyStyle(.classic)
        paused.setBufferedRanges([0...1], visible: true)
        expect(pendingLayer.path == nil && orange(pixels(paused), x: 0.85),
               "Full residency removes the entire stale pending overlay in classic style")
        paused.setBufferedRanges([], visible: false)
        expect(pendingLayer.path!.contains(CGPoint(x: 100, y: 22)),
               "Local-media mode retains the original full pending presentation")

        view.setBufferedRanges([0.1...0.3, 0.8...0.9], visible: true)
        expect(white(pixels(view), x: 0.55) < 0.25, "Evicted cache immediately removes its previous orange segment")
        view.setBufferedRanges([], visible: true)
        expect(white(pixels(view), x: 0.8) < 0.25 && !shape(view, "base").isHidden,
               "A visible empty torrent cache keeps an honest unloaded rail")
        view.setBufferedRanges([0.5...0.6], visible: false)
        expect(shape(view, "base").isHidden && shape(view, "ranges").isHidden,
               "Leaving cache mode hides all cache layers and clears stale coverage")
        view.setBufferedRanges([0.5...0.6], visible: true)
        view.setFrameSize(NSSize(width: 600, height: 44))
        view.layoutSubtreeIfNeeded()
        expect(shape(view, "ranges").mask!.frame.width == 600,
               "Resize remaps normalized coverage to the new timeline width")
        let mask = shape(view, "ranges").mask as! CAShapeLayer
        expect(mask.path!.contains(CGPoint(x: 330, y: 22)) &&
               !mask.path!.contains(CGPoint(x: 410, y: 22)),
               "Resized masks retain segment bounds and gaps")
        view.pointerEntered(atX: 330)
        expect(abs(shape(view, "base").path!.boundingBox.height - 7) < 0.01,
               "Hover expands the same cache rail from four to seven points")
        var began: [Double] = [], scrubbed: [Double] = [], ended: [(Double, Bool)] = []
        view.onBegan = { began.append($0) }
        view.onScrub = { scrubbed.append($0) }
        view.onEnded = { ended.append(($0, $1)) }
        view.pointerPressed(atX: 300)
        view.pointerDragged(toX: 480)
        view.pointerReleased(atX: 480)
        expect(began == [0.5] && scrubbed == [0.8] && ended.count == 1 && ended[0].0 == 0.8 && ended[0].1,
               "Cached segments never change seek, drag or commit behavior")
        view.pointerExited()
        expect(abs(shape(view, "base").path!.boundingBox.height - 4) < 0.01,
               "Leaving the timeline restores the resting rail height")
        view.setDustEnabled(true)
        let dust = view.layer!.sublayers!.first { $0.name == "test.dust" }!
        expect(shape(view, "base").isHidden && shape(view, "ranges").isHidden && shape(view, "played").isHidden,
               "Particle style hides every solid cache rail instead of covering its grains")
        expect(SPDustHost.latest?.buffered == [0.5...0.6] && SPDustHost.latest?.showsBuffered == true,
               "Enabling particle style transfers current resident ranges to the renderer")
        view.setBufferedRanges([0.2...0.25, 0.6...0.9], visible: true)
        expect(SPDustHost.latest?.buffered == [0.2...0.25, 0.6...0.9],
               "Cache changes reach the particle renderer while the solid rail remains hidden")
        expect(dust.superlayer === view.layer, "Particle layer stays attached to the progress view")
        view.setDamage(bands: [.init(cls: SPDamageBand.partial, from: 2, until: 3)], duration: 10)
        let overlays = view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
        expect(overlays.filter { $0.zPosition == 15 }.allSatisfy { $0.isHidden },
               "Damage is presented by particles without rectangular overlays")
        view.setBufferedRanges([], visible: false)
        expect(shape(view, "base").isHidden && SPDustHost.latest?.showsBuffered == false && SPDustHost.latest?.buffered.isEmpty == true,
               "Disabling cache mode clears particle coverage and keeps solid layers hidden")
        view.setBufferedRanges([0.4...0.5], visible: true)
        view.setDustEnabled(false)
        expect(!shape(view, "base").isHidden && !shape(view, "ranges").isHidden,
               "Returning to a solid style restores its current cache rail")
        view.setDustEnabled(true)
        expect(SPDustHost.latest?.buffered == [0.4...0.5] && shape(view, "base").isHidden,
               "Returning to particles transfers the latest coverage without a stale rail")
        view.setDustEnabled(false)
        view.setDamage(bands: [], duration: 0)
        view.setValue(0.2)
        view.setBufferedRanges([0.1...0.3, 0.5...0.6, 0.8...0.9], visible: true)
        view.setFrameSize(NSSize(width: 900, height: 64))
        view.layoutSubtreeIfNeeded()
        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pixels(view).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("cached-timeline.png"))
            try pausedBeforeArrival.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("paused-before-arrival.png"))
            try pausedAfterArrival.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("paused-after-arrival.png"))
            try pausedAfterEviction.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("paused-after-eviction.png"))
        }
        expect(view.window == nil, "Tests render detached layers without opening or inspecting a user window")
        print("Buffered timeline checks passed (\(checks) assertions; deterministic peripheral Dust stub, actual AppKit progress paths).")
    }
}
