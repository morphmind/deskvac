import AppKit
import QuartzCore
import SwiftUI

struct IconGeometry {
    var iconSize: Double
    var textSize: Double
    var labelOnBottom: Bool

    /// Reads the user's real desktop icon settings so our fake icons line up with Finder's.
    static func current() -> IconGeometry {
        let finder = UserDefaults(suiteName: "com.apple.finder")
        let view = finder?.dictionary(forKey: "DesktopViewSettings")?["IconViewSettings"] as? [String: Any]
        let size = (view?["iconSize"] as? NSNumber)?.doubleValue ?? 64
        let text = (view?["textSize"] as? NSNumber)?.doubleValue ?? 12
        let bottom = (view?["labelOnBottom"] as? NSNumber)?.boolValue ?? true
        return IconGeometry(iconSize: size, textSize: text, labelOnBottom: bottom)
    }

    func iconRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x - iconSize / 2, y: p.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    func labelRect(at p: CGPoint) -> CGRect {
        let w = max(iconSize + 36, 96)
        if labelOnBottom {
            return CGRect(x: p.x - w / 2, y: p.y + iconSize / 2 + 3, width: w, height: textSize * 2.6)
        }
        return CGRect(x: p.x + iconSize / 2 + 4, y: p.y - textSize, width: w, height: textSize * 2.6)
    }

    func box(at p: CGPoint) -> CGRect { iconRect(at: p).union(labelRect(at: p)).insetBy(dx: -4, dy: -4) }
}

struct Ghost {
    var image: NSImage
    var label: String
    var origin: CGPoint
    var pos: CGPoint
    var scale = 1.0
    var alpha = 1.0
    var labelAlpha = 1.0
    var rotation = 0.0
}

enum BoxKind { case target, trash, protected, folder, skip }

struct ScanBox {
    var id: UUID
    var rect: CGRect
    var text: String
    var kind: BoxKind
    var angle: Double
    var revealedAt: Double?
}

struct TrailPoint { var p: CGPoint; var t: Double }

struct Particle {
    var p: CGPoint
    var v: CGPoint
    var life: Double
    var maxLife: Double
    var size: Double
}

struct Bubble { var text: String; var until: Double; var born: Double }

private final class Tween {
    var elapsed = 0.0
    let duration: Double
    let update: (Double) -> Void
    var continuation: CheckedContinuation<Void, Never>?
    init(duration: Double, update: @escaping (Double) -> Void, continuation: CheckedContinuation<Void, Never>) {
        self.duration = max(0.0001, duration)
        self.update = update
        self.continuation = continuation
    }
}

/// The world the robot lives in. A timer advances it, the overlay view only paints it.
@MainActor
final class SceneModel: ObservableObject {
    /// Parked and waiting: the view stops repainting and the clock stops ticking.
    @Published var idle = false
    let size: CGSize
    let geometry = IconGeometry.current()
    let style: RobotStyle
    let radius: Double
    let speed: Double
    let bubblesOn: Bool

    var pos: CGPoint
    var heading = -Double.pi / 2
    var brushAngle = 0.0
    var lidarAngle = 0.0
    var squash = 0.0
    var moving = false
    var sucking = 0.0
    var robotAlpha = 0.0
    var dockAlpha = 0.0
    var dock: CGPoint

    var boxes: [ScanBox] = []
    var boxesAlpha = 1.0
    var scanSweep: Double?
    var ghosts: [UUID: Ghost] = [:]
    var trail: [TrailPoint] = []
    var particles: [Particle] = []
    var bubble: Bubble?
    var time = 0.0

    private var tweens: [Tween] = []
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    init(screen: NSScreen, settings: AppSettings) {
        size = screen.frame.size
        style = RobotStyle.current()
        radius = settings.robotSize / 2
        speed = settings.speed
        bubblesOn = settings.bubbles
        let vf = screen.visibleFrame, f = screen.frame
        let bottom = f.maxY - vf.minY
        dock = CGPoint(x: vf.minX - f.minX + 110, y: bottom - radius * 1.6 - 18)
        pos = dock
    }

    func startClock() {
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopClock() {
        timer?.invalidate()
        timer = nil
        cancelAll()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - last)
        last = now
        step(dt)
    }

    func step(_ dt: Double) {
        time += dt
        let spin = moving ? 18.0 : (sucking > 0.01 ? 26.0 : 3.0)
        brushAngle += dt * spin
        lidarAngle += dt * (scanSweep != nil ? 14 : 5)
        sucking = max(0, sucking - dt * 1.4)
        squash = sucking > 0 ? sin(time * 40) * sucking * 0.6 : 0

        if moving, trail.last.map({ $0.p.distance(to: pos) > 6 }) ?? true {
            trail.append(TrailPoint(p: pos, t: time))
        }
        trail.removeAll { time - $0.t > 3.2 }

        for i in particles.indices {
            particles[i].life -= dt
            let toRobot = (pos - particles[i].p)
            particles[i].v = particles[i].v * 0.9 + toRobot * (dt * 14)
            particles[i].p = particles[i].p + particles[i].v * dt
        }
        particles.removeAll { $0.life <= 0 || $0.p.distance(to: pos) < radius * 0.3 }

        if let b = bubble, time > b.until { bubble = nil }

        var finished: [Tween] = []
        for tw in tweens {
            tw.elapsed += dt
            let t = min(1, tw.elapsed / tw.duration)
            tw.update(t)
            if t >= 1 { finished.append(tw) }
        }
        if !finished.isEmpty {
            tweens.removeAll { tw in finished.contains { $0 === tw } }
            for tw in finished {
                tw.continuation?.resume()
                tw.continuation = nil
            }
        }
    }

    func tween(_ duration: Double, _ update: @escaping (Double) -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            tweens.append(Tween(duration: duration, update: update, continuation: c))
        }
    }

    func wait(_ seconds: Double) async { await tween(seconds) { _ in } }

    /// Resumes every pending animation so a stopped session never hangs.
    func cancelAll() {
        let pending = tweens
        tweens.removeAll()
        for tw in pending {
            tw.update(1)
            tw.continuation?.resume()
            tw.continuation = nil
        }
    }

    // MARK: Speech

    func say(_ key: String, _ args: CVarArg..., hold: Double = 1.7) {
        guard bubblesOn else { return }
        let options = L10n.phrases(key)
        guard var text = options.randomElement() else { return }
        if !args.isEmpty { text = String(format: text, arguments: args) }
        bubble = Bubble(text: text, until: time + hold + Double(text.count) * 0.02, born: time)
    }

    var isTalking: Bool { bubble != nil }

    // MARK: Moves

    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, radius + 6), size.width - radius - 6),
                y: min(max(p.y, radius + 30), size.height - radius - 6))
    }

    /// Puts the robot on its dock, fully visible, with nothing else on screen.
    func park() {
        pos = dock
        heading = -.pi / 2
        robotAlpha = 1
        dockAlpha = 1
        boxes = []
        ghosts = [:]
        trail = []
        particles = []
        bubble = nil
        scanSweep = nil
        moving = false
        sucking = 0
    }

    func appear() async {
        pos = dock
        heading = -.pi / 2
        if robotAlpha < 1 {
            await tween(0.45) { [unowned self] t in dockAlpha = t; robotAlpha = t }
        }
        SoundEngine.shared.setMotor(0.5)
        let start = pos
        let out = clamp(CGPoint(x: dock.x, y: dock.y - radius * 2.6))
        moving = true
        await tween(0.8) { [unowned self] t in pos = lerp(start, out, Ease.inOut(t)) }
        moving = false
    }

    func turn(to angle: Double) async {
        let start = heading
        let diff = shortestAngle(angle - start)
        guard abs(diff) > 0.02 else { return }
        await tween(max(0.08, abs(diff) / 7.5)) { [unowned self] t in heading = start + diff * Ease.inOutSine(t) }
    }

    func drive(to target: CGPoint, speedScale: Double = 1) async {
        let dest = clamp(target)
        let d = pos.distance(to: dest)
        guard d > 2 else { return }
        await turn(to: atan2(dest.y - pos.y, dest.x - pos.x))
        let start = pos
        SoundEngine.shared.setMotor(1)
        moving = true
        await tween(d / (speed * speedScale) + 0.12) { [unowned self] t in pos = lerp(start, dest, Ease.inOutSine(t)) }
        moving = false
        SoundEngine.shared.setMotor(0.55)
    }

    func bumpWiggle() async {
        SoundEngine.shared.bump()
        let base = heading, start = pos
        let back = start - CGPoint(x: cos(base), y: sin(base)) * 14
        await tween(0.12) { [unowned self] t in pos = lerp(start, back, t) }
        await tween(0.7) { [unowned self] t in heading = base + sin(t * .pi * 5) * 0.45 * (1 - t) }
    }

    func dockHome() async {
        let approach = clamp(CGPoint(x: dock.x, y: dock.y - radius * 2.4))
        await drive(to: approach)
        await turn(to: -.pi / 2)
        let start = pos
        moving = true
        await tween(0.7) { [unowned self] t in pos = lerp(start, dock, Ease.inOut(t)) }
        moving = false
        SoundEngine.shared.setMotor(0.2)
    }

    func vanish() async {
        await tween(0.5) { [unowned self] t in robotAlpha = 1 - t; dockAlpha = 1 - t; boxesAlpha = min(boxesAlpha, 1 - t) }
    }

    // MARK: Scan

    func buildBoxes(_ items: [DeskItem]) {
        boxes = items.map { item in
            let rect = geometry.box(at: item.position)
            let a = atan2(item.position.y - pos.y, item.position.x - pos.x)
            return ScanBox(id: item.id, rect: rect, text: boxLabel(item), kind: boxKind(item), angle: a, revealedAt: nil)
        }
    }

    private func boxKind(_ item: DeskItem) -> BoxKind {
        switch item.status {
        case .target: item.trash ? .trash : .target
        case .protected: .protected
        case .skipped(.folder), .skipped(.app): .folder
        case .skipped: .skip
        }
    }

    private func boxLabel(_ item: DeskItem) -> String {
        switch item.status {
        case .protected: return L("tag.protected")
        case .skipped(.folder(let n)): return L("tag.folder", n)
        case .skipped(.app): return L("tag.app")
        case .skipped(.shortcut): return L("tag.shortcut")
        case .skipped(.recent): return L("tag.recent")
        default:
            let tag = item.category?.tag ?? L("tag.other")
            let text = item.size > 0 ? "\(tag) · \(formatBytes(item.size))" : tag
            return item.trash ? "\(text) \(L("tag.trash"))" : text
        }
    }

    func scan() async {
        boxesAlpha = 1
        scanSweep = 0
        let start = heading
        SoundEngine.shared.setMotor(0.7)
        await tween(2.6) { [unowned self] t in
            let sweep = t * 2 * .pi
            scanSweep = sweep
            heading = start + Ease.inOutSine(t) * 2 * .pi
            for i in boxes.indices where boxes[i].revealedAt == nil {
                var rel = (boxes[i].angle - start).truncatingRemainder(dividingBy: 2 * .pi)
                if rel < 0 { rel += 2 * .pi }
                if rel <= sweep { boxes[i].revealedAt = time }
            }
        }
        heading = start
        scanSweep = nil
        for i in boxes.indices where boxes[i].revealedAt == nil { boxes[i].revealedAt = time }
    }

    func fadeBoxes() async {
        await tween(0.6) { [unowned self] t in boxesAlpha = 1 - t }
        boxes.removeAll { $0.kind != .protected }
        boxesAlpha = 1
    }

    // MARK: Pick up

    func placeGhost(for item: DeskItem, image: NSImage) {
        let label = middleTruncate(item.name, max: 34)
        ghosts[item.id] = Ghost(image: image, label: label, origin: item.position, pos: item.position)
    }

    func dropGhost(_ id: UUID) { ghosts[id] = nil }

    func approachPoint(for item: DeskItem) -> CGPoint {
        let dir = (item.position - pos).normalized()
        let fallback = dir == .zero ? CGPoint(x: 0, y: 1) : dir
        return item.position - fallback * (radius + geometry.iconSize * 0.42)
    }

    func suck(_ id: UUID) async {
        guard let g = ghosts[id] else { return }
        sucking = 1
        SoundEngine.shared.whoosh()
        for _ in 0..<10 {
            let a = Double.random(in: 0..<(2 * .pi))
            let p = g.origin + CGPoint(x: cos(a), y: sin(a)) * Double.random(in: 8...geometry.iconSize * 0.7)
            particles.append(Particle(p: p, v: CGPoint(x: -sin(a), y: cos(a)) * 60, life: 0.7, maxLife: 0.7,
                                      size: Double.random(in: 1.5...3.2)))
        }
        await tween(0.46) { [unowned self] t in
            guard var gh = ghosts[id] else { return }
            let front = pos + CGPoint(x: cos(heading), y: sin(heading)) * (radius * 0.35)
            let e = Ease.inCubic(t)
            let swirl = CGPoint(x: -sin(t * .pi * 2), y: cos(t * .pi * 2)) * (14 * (1 - t))
            gh.pos = lerp(gh.origin, front, e) + swirl
            gh.scale = 1 - 0.92 * Ease.inOut(t)
            gh.rotation = t * .pi * 1.4
            gh.alpha = 1 - pow(t, 4)
            gh.labelAlpha = max(0, 1 - t * 4)
            ghosts[id] = gh
        }
        ghosts[id] = nil
    }

    // MARK: Paint

    func render(_ ctx: inout GraphicsContext) {
        drawTrail(ctx)
        drawScan(ctx)
        drawBoxes(ctx)
        drawGhosts(ctx)
        RobotPainter.drawDock(ctx, at: dock, radius: radius, style: style, alpha: dockAlpha, time: time)
        drawParticles(ctx)
        if robotAlpha > 0.01 {
            var r = ctx
            r.opacity = robotAlpha
            let pose = RobotPose(center: pos, heading: heading, radius: radius, brushAngle: brushAngle,
                                 lidarAngle: lidarAngle,
                                 glow: 0.55 + 0.45 * sin(time * (moving ? 6 : 2.5)), squash: squash)
            RobotPainter.draw(r, pose: pose, style: style)
        }
        drawBubble(ctx)
    }

    private func drawTrail(_ ctx: GraphicsContext) {
        guard trail.count > 1 else { return }
        for i in 1..<trail.count {
            let a = trail[i - 1], b = trail[i]
            let age = time - b.t
            let alpha = max(0, 0.1 * (1 - age / 3.2))
            var path = Path()
            path.move(to: a.p)
            path.addLine(to: b.p)
            ctx.stroke(path, with: .color(.white.opacity(alpha)),
                       style: StrokeStyle(lineWidth: radius * 1.7, lineCap: .round))
            for off in [-0.45, 0.0, 0.45] {
                let n = CGPoint(x: -(b.p.y - a.p.y), y: b.p.x - a.p.x).normalized() * (radius * off)
                var stripe = Path()
                stripe.move(to: a.p + n)
                stripe.addLine(to: b.p + n)
                ctx.stroke(stripe, with: .color(.white.opacity(alpha * 0.9)), lineWidth: 1)
            }
        }
    }

    private func drawScan(_ ctx: GraphicsContext) {
        guard let sweep = scanSweep else { return }
        let reach = hypot(size.width, size.height)
        let lidar = Color(nsColor: style.lidar)
        let start = boxes.isEmpty ? 0 : 0
        _ = start
        let head = heading
        let slices = 18
        let width = 0.55
        for i in 0..<slices {
            let a1 = head - width * Double(i) / Double(slices)
            let a0 = head - width * Double(i + 1) / Double(slices)
            var p = Path()
            p.move(to: pos)
            p.addArc(center: pos, radius: reach, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            p.closeSubpath()
            ctx.fill(p, with: .color(lidar.opacity(0.16 * (1 - Double(i) / Double(slices)))))
        }
        var edge = Path()
        edge.move(to: pos)
        edge.addLine(to: pos + CGPoint(x: cos(head), y: sin(head)) * reach)
        ctx.stroke(edge, with: .color(lidar.opacity(0.7)), lineWidth: 1.5)
        // Range rings.
        for k in 1...4 {
            let rr = radius * 2.2 * Double(k) + (sweep * 30).truncatingRemainder(dividingBy: radius * 2.2)
            ctx.stroke(Path(ellipseIn: CGRect(x: pos.x - rr, y: pos.y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(lidar.opacity(0.08)), lineWidth: 1)
        }
    }

    private func drawBoxes(_ ctx: GraphicsContext) {
        guard !boxes.isEmpty, boxesAlpha > 0.01 else { return }
        let lidar = Color(nsColor: style.lidar)
        for b in boxes {
            guard let at = b.revealedAt else { continue }
            let appear = min(1, (time - at) * 5)
            let color: Color = switch b.kind {
            case .target: lidar
            case .protected: Color(red: 1, green: 0.62, blue: 0.04)
            case .trash: Color(red: 1, green: 0.36, blue: 0.36)
            case .folder: .white.opacity(0.75)
            case .skip: .white.opacity(0.45)
            }
            var c = ctx
            c.opacity = appear * boxesAlpha
            let grow = 1 + (1 - Ease.outBack(appear)) * 0.25
            let rect = b.rect.insetBy(dx: -b.rect.width * (grow - 1) / 2, dy: -b.rect.height * (grow - 1) / 2)
            c.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(color.opacity(0.07)))
            c.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(color.opacity(0.9)),
                     style: StrokeStyle(lineWidth: 1, dash: b.kind == .skip ? [3, 3] : []))
            let text = c.resolve(Text(b.text).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(color))
            let ts = text.measure(in: CGSize(width: 400, height: 40))
            let tag = CGRect(x: rect.minX, y: rect.minY - ts.height - 6, width: ts.width + 8, height: ts.height + 4)
            c.fill(Path(roundedRect: tag, cornerRadius: 3), with: .color(.black.opacity(0.55)))
            c.draw(text, at: CGPoint(x: tag.minX + 4, y: tag.midY), anchor: .leading)
        }
    }

    private func drawGhosts(_ ctx: GraphicsContext) {
        for g in ghosts.values {
            var c = ctx
            c.opacity = g.alpha
            let s = geometry.iconSize * g.scale
            var ic = c
            ic.translateBy(x: g.pos.x, y: g.pos.y)
            ic.rotate(by: .radians(g.rotation))
            ic.draw(Image(nsImage: g.image), in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
            if g.labelAlpha > 0.01 {
                var lc = ctx
                lc.opacity = g.labelAlpha
                lc.addFilter(.shadow(color: .black.opacity(0.85), radius: 1.5, y: 1))
                let text = lc.resolve(Text(g.label).font(.system(size: geometry.textSize, weight: .medium))
                    .foregroundColor(.white))
                let lr = geometry.labelRect(at: g.origin)
                lc.draw(text, in: CGRect(x: lr.minX, y: lr.minY, width: lr.width, height: lr.height))
            }
        }
    }

    private func drawParticles(_ ctx: GraphicsContext) {
        for p in particles {
            let a = max(0, p.life / p.maxLife)
            ctx.fill(Path(ellipseIn: CGRect(x: p.p.x - p.size / 2, y: p.p.y - p.size / 2, width: p.size, height: p.size)),
                     with: .color(Color(white: 0.9).opacity(a * 0.9)))
        }
    }

    private func drawBubble(_ ctx: GraphicsContext) {
        guard let b = bubble, robotAlpha > 0.5 else { return }
        let appear = min(1, (time - b.born) * 6)
        let fade = min(1, (b.until - time) * 4)
        var c = ctx
        c.opacity = min(appear, fade)
        let text = c.resolve(Text(b.text).font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(Color(white: 0.12)))
        let ts = text.measure(in: CGSize(width: 320, height: 200))
        let w = ts.width + 22, h = ts.height + 12
        var center = CGPoint(x: pos.x, y: pos.y - radius - h / 2 - 14)
        if center.y - h / 2 < 34 { center.y = pos.y + radius + h / 2 + 14 }
        center.x = min(max(center.x, w / 2 + 8), size.width - w / 2 - 8)
        let pop = Ease.outBack(appear)
        let rect = CGRect(x: center.x - w / 2 * pop, y: center.y - h / 2 * pop, width: w * pop, height: h * pop)
        c.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.3), radius: 8, y: 3))
            l.fill(Path(roundedRect: rect, cornerRadius: h / 2), with: .color(.white.opacity(0.96)))
            var tail = Path()
            let below = center.y < pos.y
            let ty = below ? rect.maxY : rect.minY
            let tipX = min(max(pos.x, rect.minX + 14), rect.maxX - 14)
            tail.move(to: CGPoint(x: tipX - 6, y: ty))
            tail.addLine(to: CGPoint(x: tipX, y: ty + (below ? 7 : -7)))
            tail.addLine(to: CGPoint(x: tipX + 6, y: ty))
            tail.closeSubpath()
            l.fill(tail, with: .color(.white.opacity(0.96)))
        }
        if appear > 0.6 { c.draw(text, at: center, anchor: .center) }
    }
}

struct SceneView: View {
    @ObservedObject var model: SceneModel
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.idle)) { timeline in
            // Reading the timeline date inside the renderer is what makes SwiftUI repaint every frame.
            let frameDate = timeline.date
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
                _ = frameDate
                model.render(&ctx)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Click target that sits exactly over the parked robot. The rest of the screen stays click-through.
final class DockButtonWindow: NSPanel {
    init(frame: NSRect, above: Bool, action: @escaping () -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        level = above ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        contentView = NSHostingView(rootView:
            Circle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Circle())
                .onTapGesture(perform: action)
                .help(L("dock.help"))
        )
    }

    override var canBecomeKey: Bool { false }
}

/// Transparent full-screen window that sits just above the desktop icons
/// (or above every window, if the user asks for it).
final class OverlayWindow: NSWindow {
    init(screen: NSScreen, model: SceneModel, aboveWindows: Bool) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        setAbove(aboveWindows)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let host = NSHostingView(rootView: SceneView(model: model))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = host
        setFrame(screen.frame, display: true)
        if CommandLine.arguments.contains("--debug-snapshots") { startSnapshots(host) }
    }

    /// Developer aid: writes what the overlay draws to /tmp/deskvac-snaps every second.
    private func startSnapshots(_ view: NSView) {
        let dir = URL(fileURLWithPath: "/tmp/deskvac-snaps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak view] timer in
            MainActor.assumeIsolated {
                guard let view, n < 60 else { timer.invalidate(); return }
                n += 1
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(String(format: "%02d.png", n)))
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func setAbove(_ above: Bool) {
        level = above ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
