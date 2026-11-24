import AppKit

/// `--reel-full`: records the whole main display (staged: real desktop files and apps hidden) and
/// logs where the robot is on every frame, so the edit can run a camera that follows it.
extension Reel {
    static func fullTake() async {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        let width = Int((f.width * 1.5 / 2).rounded()) * 2
        let height = Int((f.height * 1.5 / 2).rounded()) * 2

        let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DeskVac", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let video = out.appendingPathComponent("full-raw.mov")
        try? FileManager.default.removeItem(at: video)

        let recorder = ReelRecorder()
        do {
            try await recorder.prepare(sourceRect: nil, width: width, height: height, hevc: true, url: video)
        } catch {
            FileHandle.standardError.write(Data("reel: recorder failed: \(error)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        let s = AppSettings.shared
        let c = CleaningController.shared
        let saved = Snapshot(s)
        s.language = .en
        s.robotSize = 100
        s.speed = 400
        s.bubbles = true
        s.sound = true
        s.volume = 0.7
        s.scanAnimation = true
        s.getsStuck = false
        s.aboveWindows = true
        s.showHUD = false
        s.confirmBeforeCleaning = false
        s.demoOnly = true
        s.kindActions = [:]
        s.applyPreset(RobotPreset.all[0])
        s.parkOnDesktop = true
        c.resetDockPosition()

        let hidden = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0 != NSRunningApplication.current && !$0.isHidden
        }
        hidden.forEach { $0.hide() }
        StageDesk.hideReal()
        try? await Task.sleep(for: .seconds(1.5))
        DemoClutter.make()
        try? await Task.sleep(for: .seconds(4))
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0 != NSRunningApplication.current && !$0.isHidden }
            .forEach { $0.hide() }
        try? await Task.sleep(for: .seconds(1))

        var track: [[Double]] = []
        let start = Date()
        let sampler = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start)
                if let (p, a) = c.robotTrack {
                    track.append([t, p.x, p.y, a])
                } else {
                    track.append([t, -1, -1, 0])
                }
            }
        }
        RunLoop.main.add(sampler, forMode: .common)
        await recorder.start()
        var marks: [String: Double] = [:]
        func mark(_ name: String) { marks[name] = Date().timeIntervalSince(start) }

        try? await Task.sleep(for: .seconds(2.2))
        mark("clean")
        c.start(.clean)
        while !c.isRunning { try? await Task.sleep(for: .milliseconds(30)) }
        while c.isRunning { try? await Task.sleep(for: .milliseconds(30)) }
        mark("done")
        while !c.isShowingCard { try? await Task.sleep(for: .milliseconds(30)) }
        mark("summary")
        try? await Task.sleep(for: .seconds(3.4))
        c.closeSummary()
        try? await Task.sleep(for: .seconds(1.0))

        mark("colors")
        for id in ["night", "bordo", "mint", "pink", "gold", "classic"] {
            if let p = RobotPreset.all.first(where: { $0.id == id }) { s.applyPreset(p) }
            try? await Task.sleep(for: .seconds(0.75))
        }
        try? await Task.sleep(for: .seconds(0.6))
        mark("end")

        await recorder.stop()
        sampler.invalidate()
        saved.restore(s)
        DemoClutter.clear()
        StageDesk.restore()
        hidden.forEach { $0.unhide() }
        c.refreshParking()

        let info: [String: Any] = [
            "screen": [f.width, f.height], "pixels": [width, height],
            "events": marks, "track": track,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: out.appendingPathComponent("full-track.json"))
        }
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }
}
