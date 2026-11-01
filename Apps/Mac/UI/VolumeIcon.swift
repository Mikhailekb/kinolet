import AppKit

/// One volume vocabulary across the player, floating controls and feedback HUD.
/// The outer wave alone carries the existing Turbo/boost accent above 100%.
@MainActor
enum SPVolumeIcon {
    enum Level: String, Hashable {
        case muted, low, normal, boosted

        var symbolName: String {
            switch self {
            case .muted: return "speaker.slash.fill"
            case .low: return "speaker.wave.1.fill"
            case .normal: return "speaker.wave.2.fill"
            case .boosted: return "speaker.wave.3.fill"
            }
        }
    }

    static let accentColor = NSColor(srgbRed: 1, green: 0xB6 / 255, blue: 0x5C / 255, alpha: 1)

    static func level(percent: Double, muted: Bool) -> Level {
        let value = percent.isFinite ? max(0, percent) : 100
        if muted || value == 0 { return .muted }
        if value <= 50 { return .low }
        if value <= 100 { return .normal }
        return .boosted
    }

    private struct Key: Hashable {
        let level: Level
        let pointSize: CGFloat
    }
    private static var images: [Key: NSImage] = [:]

    static func image(percent: Double, muted: Bool, pointSize: CGFloat = 17) -> NSImage {
        let key = Key(level: level(percent: percent, muted: muted),
                      pointSize: pointSize.isFinite ? max(1, pointSize) : 17)
        if let cached = images[key] { return cached }
        let scale = key.pointSize / 20
        let accent = accentColor
        let image = NSImage(size: NSSize(width: 30 * scale, height: 24 * scale), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.white.cgColor)
            let body = CGMutablePath()
            body.move(to: CGPoint(x: 3, y: 8))
            body.addLine(to: CGPoint(x: 6.5, y: 8))
            body.addLine(to: CGPoint(x: 12, y: 3.5))
            body.addQuadCurve(to: CGPoint(x: 13, y: 4), control: CGPoint(x: 13, y: 2.7))
            body.addLine(to: CGPoint(x: 13, y: 20))
            body.addQuadCurve(to: CGPoint(x: 12, y: 20.5), control: CGPoint(x: 13, y: 21.3))
            body.addLine(to: CGPoint(x: 6.5, y: 16))
            body.addLine(to: CGPoint(x: 3, y: 16))
            body.addQuadCurve(to: CGPoint(x: 2, y: 15), control: CGPoint(x: 2, y: 16))
            body.addLine(to: CGPoint(x: 2, y: 9))
            body.addQuadCurve(to: CGPoint(x: 3, y: 8), control: CGPoint(x: 2, y: 8))
            body.closeSubpath()
            context.addPath(body)
            context.fillPath()

            context.setLineWidth(1.9)
            context.setLineCap(.round)
            if key.level == .muted {
                let slash = CGMutablePath()
                slash.move(to: CGPoint(x: 3, y: 21))
                slash.addLine(to: CGPoint(x: 24, y: 3))
                context.saveGState()
                context.setBlendMode(.clear)
                context.setLineWidth(4.4)
                context.addPath(slash)
                context.strokePath()
                context.restoreGState()
                context.setStrokeColor(NSColor.white.cgColor)
                context.addPath(slash)
                context.strokePath()
            } else {
                func wave(x: CGFloat, halfHeight: CGFloat, reach: CGFloat, color: NSColor) {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: x, y: 12 - halfHeight))
                    path.addCurve(to: CGPoint(x: x, y: 12 + halfHeight),
                                  control1: CGPoint(x: x + reach, y: 12 - halfHeight * 0.42),
                                  control2: CGPoint(x: x + reach, y: 12 + halfHeight * 0.42))
                    context.setStrokeColor(color.cgColor)
                    context.addPath(path)
                    context.strokePath()
                }
                wave(x: 16.5, halfHeight: 3.5, reach: 2.7, color: .white)
                if key.level == .normal || key.level == .boosted {
                    wave(x: 20.5, halfHeight: 6.2, reach: 3.5, color: .white)
                }
                if key.level == .boosted {
                    wave(x: 24.5, halfHeight: 8.8, reach: 4.1, color: accent)
                }
            }
            return true
        }
        // NSButton/NSImageView must preserve the colored outer wave rather
        // than tinting the complete image with their white foreground tint.
        image.isTemplate = false
        images[key] = image
        return image
    }
}
