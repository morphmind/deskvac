import AppKit
import SwiftUI

struct DeskVacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var controller = CleaningController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(settings)
                .environmentObject(controller)
        } label: {
            Image(nsImage: MenuIcon.make(running: controller.isRunning))
        }
        Window("DeskVac", id: "settings") {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(settings.hasOnboarded ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyLanguage()
            if !CommandLine.arguments.contains("--stage") { StageDesk.restore() }
            Scheduler.shared.start()
            CleaningController.shared.refreshParking()
            CleaningController.shared.watchSettings()
            if !AppSettings.shared.hasOnboarded { NSApp.activate(ignoringOtherApps: true) }
            // `open -a DeskVac --args --demo --clean` sets up a take for a screen recording.
            let args = CommandLine.arguments
            if args.contains("--stage") {
                Task { await Reel.stage() }
                return
            }
            if args.contains("--reel") {
                Task { await Reel.run() }
                return
            }
            if args.contains("--demo") { DemoClutter.make() }
            if args.contains("--clean") || args.contains("--scan") {
                let mode: CleaningController.Mode = args.contains("--scan") ? .scanOnly : .clean
                DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("--demo") ? 3.5 : 0.8)) {
                    CleaningController.shared.start(mode)
                }
            }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: CleaningController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if controller.isRunning {
            Text(L("menu.running", settings.displayName))
            Button(L("menu.stop")) { controller.stop() }
        } else {
            Button(L("menu.clean")) { controller.start(.clean) }
                .keyboardShortcut("k", modifiers: [.command])
            Button(L("menu.scan")) { controller.start(.scanOnly) }
        }
        Button(L("menu.undo")) { controller.undoLast() }
            .disabled(!controller.canUndo || controller.isRunning)
        Button(L("menu.trash")) { controller.openTrashReview() }
            .disabled(controller.lastTrashedCount == 0)
        Divider()
        Toggle(L("menu.park"), isOn: $settings.parkOnDesktop)
        Divider()
        Button(L("menu.demo.make")) { DemoClutter.make() }
        Button(L("menu.demo.clear")) { DemoClutter.clear() }
        Divider()
        Button(L("menu.settings")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: [.command])
        Button(L("menu.github")) { NSWorkspace.shared.open(Links.repo) }
        Divider()
        Button(L("menu.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }
}

/// Renders the app icon from the same painter the app uses, so the icon always matches the robot.
@MainActor
enum IconRenderer {
    static func render(to url: URL) {
        let view = IconArt().frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { print("icon render failed"); exit(1) }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: url) } catch { print(error); exit(1) }
        print("icon written to \(url.path)")
    }
}

extension IconRenderer {
    /// Developer aid: every preset side by side, for checking the robot drawing.
    static func renderRobots(to url: URL) {
        let view = Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                AppMark.gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            for (i, p) in RobotPreset.all.enumerated() {
                let style = RobotStyle(body: NSColor(hex: p.body), accent: NSColor(hex: p.accent),
                                       lidar: NSColor(hex: p.lidar), brush: NSColor(hex: p.brush))
                let c = CGPoint(x: 170 + Double(i % 3) * 320, y: 180 + Double(i / 3) * 330)
                RobotPainter.draw(ctx, pose: RobotPose(center: c, heading: -.pi / 2 + Double(i) * 0.5, radius: 120,
                                                       brushAngle: 0.4, lidarAngle: 1, glow: 1), style: style)
            }
        }
        .frame(width: 960, height: 680)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: url)
    }
}

struct IconArt: View {
    var body: some View {
        Canvas { ctx, size in
            let inset = size.width * 0.098
            AppMark.draw(ctx, in: CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2),
                         shadow: true)
        }
    }
}
