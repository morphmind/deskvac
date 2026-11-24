import AppKit

/// Makes a believable messy desktop for videos and first tries. Every file it writes carries
/// the `io.onore.deskvac.demo` extended attribute, and `clear()` only ever touches files with it.
@MainActor
enum DemoClutter {
    static func make() {
        let settings = AppSettings.shared
        guard settings.targetIsDesktop else {
            CleaningController.shared.alert(title: L("menu.demo.make"), text: L("err.demoDesktop"))
            return
        }
        let dir = AppSettings.desktopURL
        var made: [URL] = []
        let fm = FileManager.default

        func write(_ name: String, _ data: Data, daysAgo: Int) {
            let url = Mover.uniqueURL(dir.appendingPathComponent(name))
            guard fm.createFile(atPath: url.path, contents: data) else { return }
            XAttr.set(url, DesktopScanner.demoAttr)
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400 - Double.random(in: 0...80_000))
            try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
            made.append(url)
        }

        for i in 0..<9 {
            let name = L("demo.screenshot", 3 + i * 2, 9 + i, (i * 7) % 60, (i * 13) % 60)
            write(name, png(screenshot(seed: i)), daysAgo: 2 + i * 3)
        }
        write("IMG_4821.jpg", jpeg(photo(seed: 1)), daysAgo: 12)
        write("IMG_4822.jpg", jpeg(photo(seed: 2)), daysAgo: 12)
        write("logo-final-v3.png", png(logo()), daysAgo: 30)
        write("boarding pass.pdf", pdf(title: "BOARDING PASS", lines: ["IST → AMS", "Seat 14C", "Gate B7"]), daysAgo: 20)
        write("invoice_2026_11.pdf", pdf(title: "INVOICE", lines: ["#2026-11-04", "Total 1.240,00"]), daysAgo: 6)
        write(L("demo.protected"), pdf(title: "2025", lines: ["Keep me"]), daysAgo: 60)
        write("meeting notes 11-14.txt", Data("- ship the robot\n- record the reel\n".utf8), daysAgo: 9)
        write("essay_final_FINAL_v2.docx", Data(count: 18_000), daysAgo: 40)
        write("budget.csv", Data("month,spend\n10,1200\n11,980\n".utf8), daysAgo: 15)
        write("node_modules (1).zip", zip(), daysAgo: 50)
        write("design-assets.zip", zip(), daysAgo: 25)
        write("Installer.dmg", Data(count: 1_400_000), daysAgo: 70)
        write(L("demo.recording", 18), Data(count: 2_600_000), daysAgo: 5)
        write("landing.html", Data("<!doctype html><h1>hello</h1>".utf8), daysAgo: 8)
        write("script.py", Data("print('tidy')\n".utf8), daysAgo: 11)
        write("voice memo.m4a", Data(count: 320_000), daysAgo: 4)

        let folder = Mover.uniqueURL(dir.appendingPathComponent(L("demo.folder")))
        if (try? fm.createDirectory(at: folder, withIntermediateDirectories: false)) != nil {
            XAttr.set(folder, DesktopScanner.demoAttr)
            made.append(folder)
        }

        let names = made.map(\.lastPathComponent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { scatter(names) }
    }

    /// Spreads the new icons around like a real messy desktop: a pile in the middle, strays elsewhere.
    private static func scatter(_ names: [String]) {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame, vf = screen.visibleFrame
        let top = f.maxY - vf.maxY + 70
        let bottom = f.maxY - vf.minY - 90
        let left = 150.0, right = f.width - 240
        let pile = CGPoint(x: f.width * 0.42, y: (top + bottom) * 0.62)
        var placed: [(String, CGPoint)] = []
        for (i, n) in names.enumerated() {
            let p: CGPoint
            if i % 3 == 0 {
                p = pile + CGPoint(x: Double.random(in: -110...110), y: Double.random(in: -70...70))
            } else {
                p = CGPoint(x: Double.random(in: left...right), y: Double.random(in: top...bottom))
            }
            placed.append((n, p))
        }
        FinderBridge.setPositions(placed.map { (name: $0.0, point: $0.1) })
    }

    static func clear() {
        let fm = FileManager.default
        let settings = AppSettings.shared
        let desk = AppSettings.desktopURL
        var roots = [desk]
        roots.append(desk.appendingPathComponent(settings.effectiveArchiveName))
        roots += FileKind.allCases.map { desk.appendingPathComponent($0.folderName) }
        var emptied: [URL] = []

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            let deep = root != desk
            let urls: [URL]
            if deep, let en = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                urls = en.compactMap { $0 as? URL }
            } else {
                urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            }
            for u in urls where XAttr.has(u, DesktopScanner.demoAttr) && !hasUntaggedChildren(u) {
                try? fm.trashItem(at: u, resultingItemURL: nil)
                emptied.append(u.deletingLastPathComponent())
            }
        }
        // Only folders DeskVac itself created may be removed, and only when they are empty.
        let ours = Set(Journal.all().flatMap(\.createdFolders))
        let archive = desk.appendingPathComponent(settings.effectiveArchiveName).path
        let parents = Set(emptied.map(\.path)).filter { ours.contains($0) || $0.hasPrefix(archive + "/") }
        for p in parents.sorted(by: { $0.count > $1.count }) { Journal.removeIfEmpty(URL(fileURLWithPath: p)) }
        if ours.contains(archive) { Journal.removeIfEmpty(URL(fileURLWithPath: archive)) }
    }

    /// A demo folder the user has put real files into is left alone.
    private static func hasUntaggedChildren(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return kids.contains { !XAttr.has($0, DesktopScanner.demoAttr) }
    }

    // MARK: Fake content

    private static func screenshot(seed: Int) -> NSImage {
        let size = NSSize(width: 1440, height: 900)
        var rng = SeededRandom(seed: UInt64(seed + 7))
        return NSImage(size: size, flipped: false) { rect in
            let hue = CGFloat(rng.next() * 0.9)
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1),
                                NSColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.7, alpha: 1)])?.draw(in: rect, angle: -60)
            let win = NSRect(x: 160, y: 90, width: 1120, height: 700)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: win.offsetBy(dx: 0, dy: -12), xRadius: 18, yRadius: 18).fill()
            NSColor(white: 0.98, alpha: 1).setFill()
            NSBezierPath(roundedRect: win, xRadius: 16, yRadius: 16).fill()
            NSColor(white: 0.92, alpha: 1).setFill()
            NSRect(x: win.minX, y: win.maxY - 52, width: win.width, height: 52).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: win.minX + 22 + Double(i) * 26, y: win.maxY - 34, width: 14, height: 14)).fill()
            }
            NSColor(white: 0.94, alpha: 1).setFill()
            NSRect(x: win.minX, y: win.minY, width: 240, height: win.height - 52).fill()
            for row in 0..<7 {
                NSColor(white: 0.8, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: win.minX + 24, y: win.maxY - 100 - Double(row) * 44,
                                                 width: 140 + rng.next() * 50, height: 14), xRadius: 7, yRadius: 7).fill()
            }
            let accent = NSColor(hue: hue + 0.5, saturation: 0.7, brightness: 0.85, alpha: 1)
            for bar in 0..<8 {
                accent.withAlphaComponent(0.4 + rng.next() * 0.6).setFill()
                let h = 80 + rng.next() * 300
                NSBezierPath(roundedRect: NSRect(x: win.minX + 300 + Double(bar) * 92, y: win.minY + 60,
                                                 width: 56, height: h), xRadius: 8, yRadius: 8).fill()
            }
            NSColor(white: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: win.minX + 300, y: win.maxY - 120, width: 420, height: 26),
                         xRadius: 8, yRadius: 8).fill()
            return true
        }
    }

    private static func photo(seed: Int) -> NSImage {
        NSImage(size: NSSize(width: 1200, height: 900), flipped: false) { rect in
            NSGradient(colors: [NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.4, alpha: 1),
                                NSColor(calibratedRed: 0.45, green: 0.3, blue: 0.62, alpha: 1)])?.draw(in: rect, angle: -90)
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 450 + Double(seed) * 120, y: 360, width: 220, height: 220)).fill()
            NSColor(calibratedRed: 0.2, green: 0.15, blue: 0.3, alpha: 1).setFill()
            let hills = NSBezierPath()
            hills.move(to: .zero)
            for x in stride(from: 0.0, through: 1200, by: 60) {
                hills.line(to: NSPoint(x: x, y: 260 + sin(x / 140 + Double(seed)) * 70))
            }
            hills.line(to: NSPoint(x: 1200, y: 0))
            hills.close()
            hills.fill()
            return true
        }
    }

    private static func logo() -> NSImage {
        NSImage(size: NSSize(width: 800, height: 800), flipped: false) { rect in
            NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.24, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 220, dy: 220)).fill()
            return true
        }
    }

    private static func png(_ img: NSImage) -> Data {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func jpeg(_ img: NSImage) -> Data {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) ?? Data()
    }

    private static func pdf(title: String, lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 0, y: 742, width: 595, height: 100).fill()
        (title as NSString).draw(at: NSPoint(x: 40, y: 778), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white,
        ])
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: NSPoint(x: 40, y: 680 - Double(i) * 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.darkGray,
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// The smallest valid zip: an empty end-of-central-directory record.
    private static func zip() -> Data {
        Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

/// Runs the robot on its own: once a day, or when too many files pile up.
@MainActor
final class Scheduler {
    static let shared = Scheduler()
    private var timer: Timer?
    private let key = "lastAutoRun"

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Scheduler.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let s = AppSettings.shared
        let c = CleaningController.shared
        guard !c.isRunning else { return }
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        let now = Date()
        let cal = Calendar.current

        if s.schedule == .daily, !cal.isDate(last, inSameDayAs: now) || last < cal.startOfDay(for: now),
           cal.component(.hour, from: now) >= s.scheduleHour {
            let todayAtHour = cal.date(bySettingHour: s.scheduleHour, minute: 0, second: 0, of: now) ?? now
            if last < todayAtHour {
                fire(at: now)
                return
            }
        }
        if s.fileThreshold > 0, now.timeIntervalSince(last) > 30 * 60,
           DesktopScanner.looseFileCount(folder: s.targetFolderURL) >= s.fileThreshold {
            fire(at: now)
        }
    }

    private func fire(at date: Date) {
        UserDefaults.standard.set(date, forKey: key)
        CleaningController.shared.start(.clean)
    }
}
