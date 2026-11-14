import AppKit
import QuartzCore

@main @MainActor
struct MotionButtonChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func descendants(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(descendants)
    }
    static func named<T: CALayer>(_ button: SPMotionButton, _ name: String, as type: T.Type) -> T {
        descendants(button.layer!).first { $0.name == name }! as! T
    }
    static func model(requested: Bool = true, available: Bool = true, bypassed: Bool = false,
                      output: Double = 60, source: Double = 24) -> MotionPresentation {
        .init(hasMedia: true, requested: requested, available: available, active: requested,
              contentBypassed: bypassed, outputFPS: output, sourceFPS: source, coverage: 1, status: "")
    }
    static func configure(_ button: SPMotionButton, _ value: MotionPresentation) {
        button.configure(value, interactionEnabled: true)
        button.needsLayout = true
        button.layoutSubtreeIfNeeded()
    }
    static func image(_ button: SPMotionButton, scale: CGFloat = 4) -> CGImage {
        let width = Int(button.bounds.width * scale), height = Int(button.bounds.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(srgbRed: 0.035, green: 0.04, blue: 0.045, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        button.layer!.render(in: context)
        return context.makeImage()!
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let button = SPMotionButton()
        configure(button, model())
        let badge = named(button, "sp.motion.fpsBadge", as: CALayer.self)
        let text = named(button, "sp.motion.fpsText", as: CATextLayer.self)
        let originals = named(button, "sp.motion.frames", as: CAShapeLayer.self)
        let inserted = named(button, "sp.motion.insertedPlus", as: CAShapeLayer.self)
        expect(button.preferredWidth == 36 && button.frame.size == NSSize(width: 36, height: 32), "The control remains compact")
        expect(text.string as? String == "60", "The counter shows measured output cadence")
        expect(button.toolTip?.contains("24 → 60 fps") == true, "Tooltip distinguishes source from measured output")
        let frameBounds = originals.path!.boundingBoxOfPath
        let plusBounds = inserted.path!.boundingBoxOfPath
        expect(frameBounds.width > frameBounds.height && frameBounds.height >= 8,
               "One large landscape frame replaces the tiny filmstrip cells")
        expect(plusBounds.width >= 5.5 && plusBounds.height >= 5.5 && inserted.lineWidth >= 1.5,
               "The plus remains bold and recognizable at actual size")
        expect(frameBounds.maxX + originals.lineWidth / 2 < plusBounds.minX - inserted.lineWidth / 2,
               "Frame and plus have a clear gap instead of overlapping windows")
        expect(!originals.frame.intersects(badge.frame), "Pictogram and FPS badge remain separate")
        let amber = NSColor(cgColor: text.foregroundColor!)!.usingColorSpace(.sRGB)!
        expect(amber.redComponent > 0.95 && amber.greenComponent > 0.65 && amber.blueComponent < 0.45, "Enabled FPS badge uses the established warm orange")
        expect(button.isEnabled && button.state == .on, "Measured readouts preserve the requested On state")
        expect(descendants(button.layer!).allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "Detached controls do not animate behind hidden chrome")
        let surface = named(button, "sp.motion.surface", as: CALayer.self)
        let activeOpacity = surface.opacity
        button.configure(model(), interactionEnabled: false, preserveEnabledAppearance: true)
        expect(!button.isEnabled && surface.opacity == activeOpacity && button.state == .on,
               "A temporary Turbo lock blocks input without dimming the active control")
        button.configure(model(available: false), interactionEnabled: false, preserveEnabledAppearance: true)
        expect(!button.isEnabled && surface.opacity < activeOpacity,
               "A real media capability restriction still looks unavailable")
        configure(button, model())
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil)!
        let restingBorder = badge.borderColor
        button.mouseEntered(with: event)
        expect(badge.borderColor != restingBorder, "Hover gives the FPS element an interactive highlight")
        button.mouseExited(with: event)
        expect(badge.borderColor == restingBorder, "Leaving restores the badge's resting appearance")
        configure(button, model(output: 120))
        expect(text.string as? String == "120" && button.preferredWidth == 36, "Three-digit cadence does not widen the button")
        configure(button, model(requested: false, output: 0))
        expect(text.string as? String == "24" && button.state == .off, "Off retains the identified source cadence until output is known")
        configure(button, model(output: .infinity, source: .nan))
        expect(text.string as? String == "—", "Malformed unknown cadence never renders inf or nan")
        expect(button.toolTip?.contains("inf") == false && button.toolTip?.contains("nan") == false, "Malformed cadence stays out of hover help")
        configure(button, model(output: 1_000, source: 1_200))
        expect(text.string as? String == "—", "Out-of-range cadence does not overflow the compact badge")
        configure(button, model(output: 0.5, source: 0.5))
        expect(text.string as? String == "<1", "Sub-one cadence is not rounded to an invented zero")
        configure(button, model(available: false))
        expect(!button.isEnabled, "Unavailable media cannot toggle interpolation")
        configure(button, model(bypassed: true))
        expect(!button.isEnabled && button.state == .off, "Content bypass remains disabled and visually Off")
        for width: CGFloat in [28, 36] {
            button.frame.size = NSSize(width: width, height: 32)
            configure(button, model(output: 240))
            expect(button.bounds.contains(badge.frame) && badge.bounds.contains(text.frame.insetBy(dx: 0, dy: 0.2)),
                   "Badge and three-digit label fit compact and regular widths")
            expect(originals.path!.boundingBoxOfPath.maxX + originals.lineWidth / 2 <
                   inserted.path!.boundingBoxOfPath.minX - inserted.lineWidth / 2,
                   "The compact glyph retains clear separation between frame and plus")
        }
        if CommandLine.arguments.count == 2 {
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let cases: [(String, CGFloat, MotionPresentation)] = [
                ("off-24", 36, model(requested: false, output: 0)),
                ("enabled-60", 36, model()), ("enabled-120", 36, model(output: 120)),
                ("enabled-240-compact", 28, model(output: 240)),
                ("unavailable", 36, model(available: false)),
                ("unknown", 36, model(output: 0, source: 0))]
            for (name, width, value) in cases {
                button.frame.size = NSSize(width: width, height: 32)
                configure(button, value)
                try NSBitmapImageRep(cgImage: image(button)).representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent(name + ".png"))
                for scale: CGFloat in [1, 2] {
                    try NSBitmapImageRep(cgImage: image(button, scale: scale)).representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent(name + "-\(Int(scale))x.png"))
                }
                let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: width, height: 32),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = button
                button.layoutSubtreeIfNeeded()
                button.displayIfNeeded()
                if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                    button.cacheDisplay(in: button.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent(name + "-appkit.png"))
                }
                expect(!window.isVisible, "Native capture stays in an owned hidden window")
                window.contentView = nil
                window.close()
            }
        }
        print("Motion button checks passed (\(checks) assertions; detached native layers only).")
    }
}
