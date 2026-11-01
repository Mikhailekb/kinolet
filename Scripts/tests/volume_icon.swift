import AppKit

@main @MainActor
struct VolumeIconChecks {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    static func bitmap(image: NSImage, button: Bool = false, imageView: Bool = false) -> NSBitmapImageRep {
        let canvas = NSRect(x: 0, y: 0, width: 40, height: 32)
        let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)!
        NSGraphicsContext.current!.cgContext.scaleBy(x: 4, y: 4)
        NSColor.clear.setFill(); canvas.fill()
        if button {
            let control = NSButton(frame: canvas)
            control.isBordered = false; control.bezelStyle = .regularSquare
            control.imagePosition = .imageOnly; control.contentTintColor = .white
            control.image = image
            control.draw(control.bounds)
        } else if imageView {
            let view = NSImageView(frame: canvas)
            view.contentTintColor = .white; view.image = image
            // NSImageView uses its native image cell/layer rather than the
            // base NSView draw method for image content.
            view.cell!.draw(withFrame: view.bounds, in: view)
        } else {
            image.draw(in: NSRect(x: (canvas.width - image.size.width) / 2,
                                 y: (canvas.height - image.size.height) / 2,
                                 width: image.size.width, height: image.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return result
    }
    static func color(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    static func orangePixels(_ image: NSBitmapImageRep) -> Int {
        var result = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                let p = color(image, x, y)
                if p.alphaComponent > 0.5 && p.redComponent > 0.9 &&
                    p.greenComponent > 0.4 && p.greenComponent < 0.9 && p.blueComponent < 0.6 {
                    result += 1
                }
            }
        }
        return result
    }
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let states: [(Double, SPVolumeIcon.Level)] = [(0,.muted),(1,.low),(50,.low),(51,.normal),
            (100,.normal),(101,.boosted),(500,.boosted)]
        let size = SPVolumeIcon.image(percent: 0, muted: false).size
        for (value, expected) in states {
            expect(SPVolumeIcon.level(percent: value, muted: false) == expected,
                   "Correct wave state at \(value)%")
            let image = SPVolumeIcon.image(percent: value, muted: false)
            expect(image.size == size && !image.isTemplate, "Fixed colored image canvas at \(value)%")
            expect((orangePixels(bitmap(image: image)) > 0) == (value > 100),
                   "Only boosted states contain an orange wave: \(value)%")
        }
        expect(SPVolumeIcon.level(percent: 500, muted: true) == .muted,
               "Mute overrides boosted volume")
        expect(SPVolumeIcon.level(percent: -20, muted: false) == .muted &&
               SPVolumeIcon.level(percent: .nan, muted: false) == .normal,
               "Zero/invalid fallback matches the controls")
        expect(SPVolumeIcon.image(percent: 1, muted: false) === SPVolumeIcon.image(percent: 50, muted: false),
               "Updates within one level reuse the same image")
        let normal = bitmap(image: SPVolumeIcon.image(percent: 100, muted: false))
        let boosted = bitmap(image: SPVolumeIcon.image(percent: 101, muted: false))
        var preserved = true
        var whites = 0
        for y in 0..<normal.pixelsHigh {
            for x in 0..<normal.pixelsWide {
                let a = color(normal, x, y), b = color(boosted, x, y)
                if a.alphaComponent > 0.02 {
                    whites += 1
                    if abs(a.redComponent - b.redComponent) > 0.01 ||
                        abs(a.greenComponent - b.greenComponent) > 0.01 ||
                        abs(a.blueComponent - b.blueComponent) > 0.01 ||
                        abs(a.alphaComponent - b.alphaComponent) > 0.01 { preserved = false }
                }
            }
        }
        expect(whites > 200 && preserved, "Boost preserves the white speaker and both original white waves pixel for pixel")
        expect(orangePixels(bitmap(image: SPVolumeIcon.image(percent: 150, muted: false), button: true)) > 80,
               "Actual white-tinted NSButton preserves the orange outer wave")
        expect(orangePixels(bitmap(image: SPVolumeIcon.image(percent: 150, muted: false), imageView: true)) > 80,
               "Actual white-tinted NSImageView preserves the HUD's orange outer wave")

        let hud = SPVolumeFeedbackView(frame: NSRect(x: 0,y: 0,width: 212,height: 44))
        let speaker = hud.subviews.compactMap { $0 as? NSImageView }.first!
        for (value, expected) in states {
            hud.show(percent: value, muted: false)
            expect(hud.displayedSpeakerSymbol == expected.symbolName &&
                   speaker.image === SPVolumeIcon.image(percent: value, muted: false, pointSize: 18),
                   "Actual hidden-controls HUD shares the state/image at \(value)%")
        }
        hud.show(percent: 500, muted: true)
        expect(speaker.image === SPVolumeIcon.image(percent: 500, muted: true, pointSize: 18),
               "Muted HUD has no boosted orange wave")
        hud.dismiss()

        let source = NSWindow(contentRect: NSRect(x: -2000,y: -2000,width: 640,height: 360),
                              styleMask: [.borderless],backing: .buffered,defer: false)
        source.isReleasedWhenClosed = false
        let video = NSView(frame: source.contentView!.bounds)
        source.contentView!.addSubview(video)
        let floating = SPFloatingVideoController()
        expect(floating.present(videoView: video, aspectRatio: 16 / 9, sourceWindow: source, showWindow: false),
               "Owned hidden PiP fixture is available")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let mute = descendants(floating.window!.contentView!).first {
            $0.accessibilityIdentifier() == "sp.floatingVideo.mute"
        } as! NSButton
        for (value, _) in states {
            floating.update(isPlaying: true,position: 10,duration: 100,volumePercent: value,muted: false)
            expect(mute.image === SPVolumeIcon.image(percent: value, muted: false, pointSize: 20),
                   "Actual PiP icon reflects raw owner percent, including over100: \(value)%")
        }
        floating.restore(); source.close()

        if CommandLine.arguments.count == 2 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory: true)
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            for (value, _) in states {
                let rendered = bitmap(image: SPVolumeIcon.image(percent: value,muted: false),button: true)
                try rendered.representation(using: .png,properties: [:])!.write(to:
                    directory.appendingPathComponent("volume-\(Int(value)).png"))
            }
        }
        print("Volume icon checks passed (\(checks) assertions; detached raster and owned hidden controls).")
    }
}
