import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// `--reel`: plays a scripted take (mess, clean, colors, settings) and records a vertical
/// 1080x1920 strip of the screen with the app's own sound. Developer tool for the launch video.
@MainActor
enum Reel {
    /// The vertical strip of the main screen that ends up in the video, in top-left screen points.
    static var band: CGRect?
    static var events: [String: Double] = [:]
    private static var clock = Date()

    static func mark(_ name: String) {
        guard band != nil, events[name] == nil else { return }
        events[name] = Date().timeIntervalSince(clock)
    }

    static func run() async {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        let w = (f.height * 9 / 16).rounded()
        let rect = CGRect(x: ((f.width - w) / 2).rounded(), y: 0, width: w, height: f.height)

        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DeskVac", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let video = out.appendingPathComponent("reel-raw.mov")
        try? FileManager.default.removeItem(at: video)

        let recorder = ReelRecorder()
        do {
            try await recorder.prepare(sourceRect: rect, url: video)
        } catch {
            FileHandle.standardError.write(Data("reel: recorder failed: \(error)\n".utf8))
            CleaningController.shared.alert(title: "Screen recording", text:
                "Allow DeskVac in System Settings > Privacy & Security > Screen & System Audio Recording, then run --reel again.\n\n\(error.localizedDescription)")
            NSApp.terminate(nil)
            return
        }

        let s = AppSettings.shared
        let saved = Snapshot(s)
        band = rect
        s.language = .en
        s.robotSize = 100
        s.speed = 430
        s.bubbles = true
        s.sound = true
        s.volume = 0.6
        s.scanAnimation = true
        s.getsStuck = false
        s.aboveWindows = true
        s.showHUD = false
        s.confirmBeforeCleaning = false
        s.demoOnly = true
        s.kindActions = [:]
        s.parkOnDesktop = true
        s.applyPreset(RobotPreset.all[0])

        let hidden = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0 != NSRunningApplication.current && !$0.isHidden
        }
        hidden.forEach { $0.hide() }
        DemoClutter.make(reel: true)
        try? await Task.sleep(for: .seconds(3.5))
        // Anything that popped back up while the mess was being laid out goes away again.
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0 != NSRunningApplication.current && !$0.isHidden }
            .forEach { $0.hide() }
        try? await Task.sleep(for: .seconds(0.8))

        clock = Date()
        events = [:]
        await recorder.start()
        try? await Task.sleep(for: .seconds(1.8))

        mark("clean")
        CleaningController.shared.start(.clean)
        while !CleaningController.shared.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        while CleaningController.shared.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        mark("summary")
        try? await Task.sleep(for: .seconds(3.2))
        CleaningController.shared.closeSummary()
        try? await Task.sleep(for: .seconds(0.8))

        mark("settings")
        let win = showSettings(in: rect, screen: screen)
        try? await Task.sleep(for: .seconds(1.0))
        for id in ["night", "bordo", "mint", "pink", "gold", "classic"] {
            if let p = RobotPreset.all.first(where: { $0.id == id }) { s.applyPreset(p) }
            try? await Task.sleep(for: .seconds(0.85))
        }
        mark("size")
        for v in stride(from: 100.0, through: 136, by: 4) { s.robotSize = v; try? await Task.sleep(for: .milliseconds(70)) }
        for v in stride(from: 136.0, through: 100, by: -4) { s.robotSize = v; try? await Task.sleep(for: .milliseconds(70)) }
        for v in stride(from: 430.0, through: 680, by: 25) { s.speed = v; try? await Task.sleep(for: .milliseconds(60)) }
        try? await Task.sleep(for: .seconds(1.2))
        win.close()
        try? await Task.sleep(for: .seconds(0.8))
        mark("end")

        await recorder.stop()
        saved.restore(s)
        band = nil
        DemoClutter.clear()
        hidden.forEach { $0.unhide() }

        let timeline = out.appendingPathComponent("reel-events.json")
        if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: timeline)
        }
        NSWorkspace.shared.activateFileViewerSelecting([video])
        NSApp.terminate(nil)
    }

    /// `--stage`: sets up the desktop for filming the screen with a phone. The person filming clicks
    /// the parked robot to start; closing the result card puts everything back.
    static func stage() async {
        let s = AppSettings.shared
        let saved = Snapshot(s)
        s.robotSize = 96
        s.speed = 360
        s.bubbles = true
        s.sound = true
        s.volume = 0.8
        s.scanAnimation = true
        s.getsStuck = true
        s.aboveWindows = true
        s.showHUD = false
        s.confirmBeforeCleaning = false
        s.demoOnly = true
        s.kindActions = [:]
        s.parkOnDesktop = true

        let hidden = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0 != NSRunningApplication.current && !$0.isHidden
        }
        hidden.forEach { $0.hide() }
        StageDesk.hideReal()
        try? await Task.sleep(for: .seconds(1.5))
        DemoClutter.make()

        let c = CleaningController.shared
        while !c.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        while c.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        while c.isShowingCard { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1))
        saved.restore(s)
        DemoClutter.clear()
        StageDesk.restore()
        hidden.forEach { $0.unhide() }
    }

    private static func showSettings(in rect: CGRect, screen: NSScreen) -> NSWindow {
        let view = SettingsView()
            .environmentObject(AppSettings.shared)
            .environmentObject(CleaningController.shared)
        let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "DeskVac"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.contentView = NSHostingView(rootView: view)
        let size = win.contentView?.fittingSize ?? NSSize(width: 620, height: 600)
        let x = screen.frame.minX + rect.midX - size.width / 2
        let y = screen.frame.maxY - 120 - size.height
        win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height + 28), display: true)
        win.orderFrontRegardless()
        return win
    }

    /// Settings the take changes, put back afterwards.
    private struct Snapshot {
        let values: [String: Any]
        @MainActor init(_ s: AppSettings) {
            values = [
                "language": s.language, "robotSize": s.robotSize, "speed": s.speed, "bubbles": s.bubbles,
                "sound": s.sound, "volume": s.volume, "scanAnimation": s.scanAnimation, "getsStuck": s.getsStuck,
                "aboveWindows": s.aboveWindows, "showHUD": s.showHUD, "confirm": s.confirmBeforeCleaning,
                "demoOnly": s.demoOnly, "kindActions": s.kindActions, "park": s.parkOnDesktop,
                "colors": [s.bodyColor, s.accentColor, s.lidarColor, s.brushColor],
            ]
        }

        @MainActor func restore(_ s: AppSettings) {
            s.language = values["language"] as! AppLanguage
            s.robotSize = values["robotSize"] as! Double
            s.speed = values["speed"] as! Double
            s.bubbles = values["bubbles"] as! Bool
            s.sound = values["sound"] as! Bool
            s.volume = values["volume"] as! Double
            s.scanAnimation = values["scanAnimation"] as! Bool
            s.getsStuck = values["getsStuck"] as! Bool
            s.aboveWindows = values["aboveWindows"] as! Bool
            s.showHUD = values["showHUD"] as! Bool
            s.confirmBeforeCleaning = values["confirm"] as! Bool
            s.demoOnly = values["demoOnly"] as! Bool
            s.kindActions = values["kindActions"] as! [FileKind: KindAction]
            let c = values["colors"] as! [String]
            s.bodyColor = c[0]; s.accentColor = c[1]; s.lidarColor = c[2]; s.brushColor = c[3]
            s.parkOnDesktop = values["park"] as! Bool
        }
    }
}

/// Records a region of the main display plus system audio straight into a vertical H.264 movie.
final class ReelRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "deskvac.reel")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var started = false
    private var recording = false

    func prepare(sourceRect: CGRect, url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = sourceRect
        cfg.width = 1080
        cfg.height = 1920
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 8
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        let w = try AVAssetWriter(url: url, fileType: .mov)
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoExpectedSourceFrameRateKey: 60],
        ])
        v.expectsMediaDataInRealTime = true
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
        a.expectsMediaDataInRealTime = true
        w.add(v)
        w.add(a)
        writer = w
        videoIn = v
        audioIn = a

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = s
    }

    func start() async {
        queue.sync { recording = true }
        try? await stream?.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                recording = false
                guard let writer, started else { c.resume(); return }
                videoIn?.markAsFinished()
                audioIn?.markAsFinished()
                writer.finishWriting { c.resume() }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard recording, sb.isValid, let writer else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                writer.startWriting()
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                started = true
            }
            if videoIn?.isReadyForMoreMediaData == true { videoIn?.append(sb) }
        } else if type == .audio, started, audioIn?.isReadyForMoreMediaData == true {
            audioIn?.append(sb)
        }
    }
}

/// Renders the overlays the ffmpeg pass lays over the take: captions per language and the end card.
@MainActor
enum ReelArt {
    static let captions: [String: [(String, String)]] = [
        "en": [("hook", "I made a robot vacuum\nfor my desktop"),
               ("scan", "It scans the mess first"),
               ("clean", "then sorts every file by type"),
               ("summary", "Nothing gets deleted.\nOne click undoes it all."),
               ("settings", "Pick your colors"),
               ("size", "size, speed, name…")],
        "tr": [("hook", "Masaüstüm için\nrobot süpürge yaptım"),
               ("scan", "Önce dağınıklığı tarıyor"),
               ("clean", "sonra her dosyayı türüne göre ayırıyor"),
               ("summary", "Hiçbir şey silinmiyor.\nTek tıkla hepsi geri geliyor."),
               ("settings", "Rengini sen seç"),
               ("size", "boyutu, hızı, adı…")],
    ]

    static let endCard: [String: (String, String)] = [
        "en": ("Open source. Free.", "github.com/morphmind/deskvac"),
        "tr": ("Açık kaynak. Ücretsiz.", "github.com/morphmind/deskvac"),
    ]

    static func render(to dir: URL, badge: URL?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (lang, list) in captions {
            for (key, text) in list {
                write(CaptionArt(text: text, big: key == "hook"), dir.appendingPathComponent("cap-\(lang)-\(key).png"))
            }
            if let card = endCard[lang] {
                let image = badge.flatMap { NSImage(contentsOf: $0) }
                write(EndCardArt(title: card.0, url: card.1, badge: image), dir.appendingPathComponent("end-\(lang).png"))
            }
        }
        print("reel art written to \(dir.path)")
    }

    private static func write<V: View>(_ view: V, _ url: URL) {
        let r = ImageRenderer(content: view.frame(width: 1080, height: 1920))
        r.scale = 1
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

private struct CaptionArt: View {
    let text: String
    let big: Bool
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.custom("AvenirNext-DemiBold", size: 60))
                .lineSpacing(-4)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 0, x: 0, y: 1.5)
                .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 1)
                .padding(.horizontal, 80)
            Spacer().frame(height: 440)
        }
    }
}

private struct EndCardArt: View {
    let title: String
    let url: String
    let badge: NSImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#0B3B3C"), Color(hex: "#07201F")], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 34) {
                Canvas { ctx, size in
                    AppMark.draw(ctx, in: CGRect(origin: .zero, size: size), shadow: true)
                }
                .frame(width: 280, height: 280)
                Text("DeskVac").font(.system(size: 96, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                Text(title).font(.system(size: 52, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                Text(url).font(.system(size: 40, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: "#2FD49A"))
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            VStack {
                Spacer()
                if let badge {
                    Image(nsImage: badge).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 54)
                }
                Spacer().frame(height: 130)
            }
        }
    }
}

/// A staged desktop for filming: the user's own items get Finder's hidden flag (nothing moves,
/// every path stays the same) and come back afterwards. The list is written to disk first, so an
/// interrupted take is undone on the next launch.
@MainActor
enum StageDesk {
    static var file: URL { Journal.directory.deletingLastPathComponent().appendingPathComponent("stage-hidden.json") }

    static func hideReal() {
        let desk = AppSettings.desktopURL
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: desk, includingPropertiesForKeys: [.isHiddenKey], options: [.skipsHiddenFiles])) ?? []
        let mine = urls.filter { !XAttr.has($0, DesktopScanner.demoAttr) }
        var list = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: file))) ?? []
        list += mine.map(\.path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? JSONEncoder().encode(Array(Set(list))).write(to: file, options: .atomic)) != nil else { return }
        for u in mine { setHidden(u, true) }
    }

    static func restore() {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        var failed: [String] = []
        for p in list {
            let u = URL(fileURLWithPath: p)
            guard FileManager.default.fileExists(atPath: p) else { continue }
            if !setHidden(u, false) { failed.append(p) }
        }
        if failed.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? JSONEncoder().encode(failed).write(to: file, options: .atomic)
        }
    }

    @discardableResult
    private static func setHidden(_ url: URL, _ hidden: Bool) -> Bool {
        var u = url
        var v = URLResourceValues()
        v.isHidden = hidden
        return (try? u.setResourceValues(v)) != nil
    }
}
