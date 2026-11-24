import AppKit
import SwiftUI

struct RobotStyle {
    var body: NSColor
    var accent: NSColor
    var lidar: NSColor
    var brush: NSColor

    @MainActor
    static func current() -> RobotStyle {
        let s = AppSettings.shared
        return RobotStyle(
            body: NSColor(hex: s.bodyColor), accent: NSColor(hex: s.accentColor),
            lidar: NSColor(hex: s.lidarColor), brush: NSColor(hex: s.brushColor)
        )
    }
}

struct RobotPose {
    var center: CGPoint
    var heading: Double
    var radius: Double
    var brushAngle: Double = 0
    var lidarAngle: Double = 0
    var glow: Double = 0.6
    var squash: Double = 0
}

/// The DeskVac mark: app icon tile with a simple vacuum glyph. Used for the app icon and the robot's lid badge.
enum AppMark {
    static let gradient = Gradient(colors: [Color(hex: "#2FD49A"), Color(hex: "#138A72"), Color(hex: "#0B3B3C")])
    static let ink = Color(hex: "#0F5C55")

    static func draw(_ ctx: GraphicsContext, in rect: CGRect, shadow: Bool = false) {
        let tile = Path(roundedRect: rect, cornerRadius: rect.width * 0.225, style: .continuous)
        ctx.drawLayer { l in
            if shadow { l.addFilter(.shadow(color: .black.opacity(0.3), radius: rect.width * 0.04, y: rect.width * 0.02)) }
            l.fill(tile, with: .linearGradient(gradient, startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                               endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        var inner = ctx
        inner.clip(to: tile)
        drawGlyph(inner, center: CGPoint(x: rect.midX, y: rect.midY), size: rect.width * 0.62, color: .white)
    }

    /// A robot vacuum seen from above, as a solid glyph: shell, bumper seam, lidar turret, and the clean stripe behind it.
    static func drawGlyph(_ ctx: GraphicsContext, center c: CGPoint, size: Double, color: Color) {
        let r = size / 2
        let body = CGPoint(x: c.x + r * 0.08, y: c.y - r * 0.08)
        let br = r * 0.82
        var stripe = Path()
        stripe.move(to: CGPoint(x: c.x - r * 1.05, y: c.y + r * 1.05))
        stripe.addLine(to: body)
        ctx.stroke(stripe, with: .color(color.opacity(0.28)), style: StrokeStyle(lineWidth: br * 1.5, lineCap: .round))
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.015))
            l.fill(Path(ellipseIn: CGRect(x: body.x - br, y: body.y - br, width: br * 2, height: br * 2)), with: .color(color))
        }
        var seam = Path()
        seam.addArc(center: body, radius: br * 0.78, startAngle: .degrees(-135 - 60), endAngle: .degrees(-135 + 60), clockwise: false)
        ctx.stroke(seam, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
        let tr = br * 0.21
        let tc = CGPoint(x: body.x + br * 0.22, y: body.y - br * 0.22)
        ctx.fill(Path(ellipseIn: CGRect(x: tc.x - tr, y: tc.y - tr, width: tr * 2, height: tr * 2)), with: .color(ink))
    }
}

/// Draws a realistic top-down robot vacuum. +x of the local frame is the robot's front.
enum RobotPainter {
    static func draw(_ base: GraphicsContext, pose p: RobotPose, style s: RobotStyle) {
        var ctx = base
        let r = p.radius
        ctx.translateBy(x: p.center.x, y: p.center.y)

        // Floor shadow, fixed to screen space.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: r * 0.14))
            l.fill(Path(ellipseIn: CGRect(x: -r * 1.0, y: -r * 0.92 + r * 0.14, width: r * 2.0, height: r * 2.0)),
                   with: .color(.black.opacity(0.34)))
        }

        var rot = ctx
        rot.rotate(by: .radians(p.heading))
        let sq = 1 + p.squash * 0.04
        rot.scaleBy(x: sq, y: 1 / sq)

        drawSideBrush(rot, hub: CGPoint(x: r * 0.66, y: r * 0.6), r: r, angle: p.brushAngle, style: s)
        drawSideBrush(rot, hub: CGPoint(x: r * 0.66, y: -r * 0.6), r: r, angle: -p.brushAngle + 0.5, style: s)

        let lightBody = s.body.luminance > 0.5
        let shade = s.body.mix(.black, lightBody ? 0.16 : 0.38)
        let rim = s.body.mix(.black, lightBody ? 0.3 : 0.55)
        let highlight = s.body.mix(.white, lightBody ? 0.6 : 0.22)

        // Shell. Lighting stays fixed to the screen's top-left so it doesn't spin with the robot.
        let shell = Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r))
        ctx.fill(shell, with: .color(Color(nsColor: rim)))
        let top = Path(ellipseIn: CGRect(x: -r * 0.965, y: -r * 0.965, width: r * 1.93, height: r * 1.93))
        ctx.fill(top, with: .radialGradient(
            Gradient(colors: [Color(nsColor: highlight), Color(nsColor: s.body), Color(nsColor: shade)]),
            center: CGPoint(x: -r * 0.38, y: -r * 0.42), startRadius: 0, endRadius: r * 1.75))

        // Front bumper: a separate band with a shadow gap behind it.
        var gap = Path()
        gap.addArc(center: .zero, radius: r * 0.8, startAngle: .degrees(-78), endAngle: .degrees(78), clockwise: false)
        rot.stroke(gap, with: .color(.black.opacity(lightBody ? 0.22 : 0.45)), lineWidth: max(1, r * 0.018))
        var bumper = Path()
        bumper.addArc(center: .zero, radius: r * 0.885, startAngle: .degrees(-78), endAngle: .degrees(78), clockwise: false)
        rot.stroke(bumper, with: .color(Color(nsColor: s.body.mix(.black, lightBody ? 0.07 : 0.2)).opacity(0.9)),
                   style: StrokeStyle(lineWidth: r * 0.15, lineCap: .butt))
        // Cliff/IR window on the bumper nose.
        var window = Path()
        window.addArc(center: .zero, radius: r * 0.9, startAngle: .degrees(-11), endAngle: .degrees(11), clockwise: false)
        rot.stroke(window, with: .color(Color(white: 0.1).opacity(0.7)), style: StrokeStyle(lineWidth: r * 0.035, lineCap: .round))

        // Dust bin lid seam at the back.
        var lid = Path()
        lid.addArc(center: CGPoint(x: -r * 0.12, y: 0), radius: r * 0.62, startAngle: .degrees(118), endAngle: .degrees(242), clockwise: false)
        rot.stroke(lid, with: .color(.black.opacity(lightBody ? 0.12 : 0.3)), lineWidth: max(0.8, r * 0.014))

        // Lidar turret near the front, with its own shadow and a spinning glint.
        let tc = CGPoint(x: r * 0.34, y: 0)
        let tr = r * 0.25
        rot.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.35), radius: r * 0.05, y: r * 0.025))
            l.fill(Path(ellipseIn: CGRect(x: tc.x - tr, y: tc.y - tr, width: tr * 2, height: tr * 2)),
                   with: .color(Color(nsColor: s.body.mix(.black, lightBody ? 0.04 : 0.15))))
        }
        rot.fill(Path(ellipseIn: CGRect(x: tc.x - tr * 0.78, y: tc.y - tr * 0.78, width: tr * 1.56, height: tr * 1.56)),
                 with: .radialGradient(Gradient(colors: [Color(nsColor: highlight), Color(nsColor: s.body)]),
                                       center: CGPoint(x: tc.x - tr * 0.3, y: tc.y - tr * 0.3), startRadius: 0, endRadius: tr * 1.2))
        rot.stroke(Path(ellipseIn: CGRect(x: tc.x - tr * 0.78, y: tc.y - tr * 0.78, width: tr * 1.56, height: tr * 1.56)),
                   with: .color(.black.opacity(0.12)), lineWidth: max(0.6, r * 0.01))
        var glint = Path()
        glint.addArc(center: tc, radius: tr * 0.9, startAngle: .radians(p.lidarAngle - 0.35),
                     endAngle: .radians(p.lidarAngle + 0.35), clockwise: false)
        rot.stroke(glint, with: .color(Color(nsColor: s.lidar).opacity(0.85)),
                   style: StrokeStyle(lineWidth: max(1, r * 0.03), lineCap: .round))

        // Buttons between the turret and the lid: power with its status ring, home.
        for (i, y) in [-r * 0.13, r * 0.13].enumerated() {
            let bc = CGPoint(x: r * 0.02, y: y)
            let br = r * 0.055
            if i == 0 {
                rot.drawLayer { l in
                    l.addFilter(.shadow(color: Color(nsColor: s.accent).opacity(p.glow), radius: r * 0.06))
                    l.stroke(Path(ellipseIn: CGRect(x: bc.x - br * 1.35, y: bc.y - br * 1.35, width: br * 2.7, height: br * 2.7)),
                             with: .color(Color(nsColor: s.accent)), lineWidth: max(1, r * 0.02))
                }
            }
            rot.fill(Path(ellipseIn: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2)),
                     with: .color(Color(nsColor: shade)))
        }

    }

    private static func drawSideBrush(_ base: GraphicsContext, hub: CGPoint, r: Double, angle: Double, style s: RobotStyle) {
        var b = base
        b.translateBy(x: hub.x, y: hub.y)
        b.rotate(by: .radians(angle))
        let color = Color(nsColor: s.brush)
        for k in 0..<3 {
            let a = Double(k) * 2 * .pi / 3
            var arm = Path()
            let tip = CGPoint(x: cos(a) * r * 0.5, y: sin(a) * r * 0.5)
            let ctrl = CGPoint(x: cos(a + 0.35) * r * 0.28, y: sin(a + 0.35) * r * 0.28)
            arm.move(to: .zero)
            arm.addQuadCurve(to: tip, control: ctrl)
            b.stroke(arm, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: max(0.8, r * 0.022), lineCap: .round))
            for f in [-0.12, 0.0, 0.12] {
                var bristle = Path()
                bristle.move(to: CGPoint(x: tip.x * 0.82, y: tip.y * 0.82))
                bristle.addLine(to: CGPoint(x: cos(a + f) * r * 0.56, y: sin(a + f) * r * 0.56))
                b.stroke(bristle, with: .color(color.opacity(0.6)), lineWidth: max(0.6, r * 0.012))
            }
        }
        b.fill(Path(ellipseIn: CGRect(x: -r * 0.075, y: -r * 0.075, width: r * 0.15, height: r * 0.15)), with: .color(color))
    }

    /// Charging dock: a low base the robot backs into.
    static func drawDock(_ base: GraphicsContext, at c: CGPoint, radius r: Double, style s: RobotStyle, alpha: Double, time: Double) {
        guard alpha > 0.01 else { return }
        var ctx = base
        ctx.opacity = alpha
        let rect = CGRect(x: c.x - r * 1.2, y: c.y + r * 0.62, width: r * 2.4, height: r * 0.72)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.35), radius: r * 0.12, y: r * 0.06))
            l.fill(Path(roundedRect: rect, cornerRadius: r * 0.26, style: .continuous), with: .linearGradient(
                Gradient(colors: [Color(nsColor: s.body.mix(.white, 0.2)), Color(nsColor: s.body.mix(.black, 0.25))]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        let pulse = 0.5 + 0.5 * sin(time * 3)
        let led = CGRect(x: rect.midX - r * 0.18, y: rect.maxY - r * 0.22, width: r * 0.36, height: r * 0.07)
        ctx.fill(Path(roundedRect: led, cornerRadius: r * 0.035), with: .color(Color(nsColor: s.accent).opacity(0.4 + 0.6 * pulse)))
    }
}
