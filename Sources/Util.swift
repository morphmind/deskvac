import AppKit
import SwiftUI

enum Links {
    static let repo = URL(string: "https://github.com/morphmind/deskvac")!
    static let onore = URL(string: "https://onore.io")!
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count != 6 { v = 0xFFFFFF }
        self.init(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    func mix(_ other: NSColor, _ f: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        return a.blended(withFraction: f, of: other.usingColorSpace(.sRGB) ?? other) ?? self
    }

    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

func hexString(from color: Color) -> String {
    NSColor(color).hexString
}

enum Ease {
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func inOutSine(_ t: Double) -> Double { -(cos(.pi * t) - 1) / 2 }
    static func inCubic(_ t: Double) -> Double { t * t * t }
    static func outCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func outBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    func distance(to p: CGPoint) -> Double { hypot(p.x - x, p.y - y) }
    var length: Double { hypot(x, y) }
    func normalized() -> CGPoint { let l = length; return l > 0.0001 ? CGPoint(x: x / l, y: y / l) : .zero }
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Wraps an angle difference into -pi...pi.
func shortestAngle(_ a: Double) -> Double {
    var v = a.truncatingRemainder(dividingBy: 2 * .pi)
    if v > .pi { v -= 2 * .pi }
    if v < -.pi { v += 2 * .pi }
    return v
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// Shortens long file names in the middle, the way Finder does.
func middleTruncate(_ s: String, max: Int) -> String {
    guard s.count > max, max > 3 else { return s }
    let keep = max - 1
    let head = s.prefix(keep / 2 + keep % 2)
    let tail = s.suffix(keep / 2)
    return head + "…" + tail
}

enum XAttr {
    static func has(_ url: URL, _ name: String) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    static func set(_ url: URL, _ name: String, _ value: String = "1") {
        let data = Array(value.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return setxattr(path, name, data, data.count, 0, XATTR_NOFOLLOW)
        }
    }
}
