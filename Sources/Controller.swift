import AppKit
import Combine
import SwiftUI

@MainActor
final class CleaningController: ObservableObject {
    static let shared = CleaningController()
    enum Mode { case clean, scanOnly }

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = ""
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var lastJournal: SessionJournal? = Journal.latestUndoable()

    private var stopRequested = false
    private var scene: SceneModel?
    private var overlay: OverlayWindow?
    private var hud: FloatingPanel?
    private var dockButton: DockButtonWindow?
    private var card: FloatingPanel?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?

    private var settingsWatch: AnyCancellable?

    var canUndo: Bool { lastJournal != nil }

    /// Rebuilds the parked robot shortly after its look changes in Settings.
    func watchSettings() {
        settingsWatch = AppSettings.shared.objectWillChange
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshParking() }
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    func start(_ mode: Mode) {
        guard !isRunning else { return }
        closeCard()
        if !(scene?.idle ?? false) { dropSceneNow() }
        isRunning = true
        stopRequested = false
        done = 0
        total = 0
        Task { await run(mode) }
    }

    func stop() {
        guard isRunning else { return }
        stopRequested = true
        if let c = confirmContinuation {
            confirmContinuation = nil
            c.resume(returning: false)
        }
        scene?.say("stop")
    }

    // MARK: Session

    private func run(_ mode: Mode) async {
        let settings = AppSettings.shared
        let folder = settings.targetFolderURL
        let scr = screen
        let result: ScanResult
        do {
            result = try DesktopScanner.scan(folder: folder, config: settings.scanConfig(screenSize: scr.frame.size))
        } catch {
            isRunning = false
            showAccessError(folder: folder, error: error)
            return
        }

        let model: SceneModel
        if let parked = scene, let win = overlay, parked.idle {
            // Reuse the robot that is already parked on the desktop.
            model = parked
            model.idle = false
            dockButton?.orderOut(nil)
            dockButton = nil
            win.setAbove(settings.aboveWindows)
        } else {
            dropSceneNow()
            model = SceneModel(screen: scr, settings: settings)
            scene = model
            let win = OverlayWindow(screen: scr, model: model, aboveWindows: settings.aboveWindows)
            overlay = win
            win.orderFrontRegardless()
        }
        let visible = result.items.filter { $0.isTarget || $0.isProtected }
        async let thumbs = Thumbnails.load(visible, size: model.geometry.iconSize)
        model.startClock()
        SoundEngine.shared.start(volume: settings.volume, enabled: settings.sound)
        showHUD()
        setStatus(L("hud.scanning", settings.displayName))

        let started = Date()
        await model.appear()
        model.say("start")
        let images = await thumbs

        if settings.scanAnimation && !stopRequested {
            model.buildBoxes(result.items)
            Reel.mark("scan")
            model.say("scan")
            await model.scan()
            if !result.targets.isEmpty { model.say("found", result.targets.count) }
            await model.wait(0.9)
        }

        var summary = CleanSummary(kind: mode == .scanOnly ? .scanned : .cleaned)
        summary.protectedCount = result.protected.count

        if mode == .scanOnly || stopRequested {
            for t in result.targets {
                summary.moved += 1
                summary.bytes += t.size
                if let k = t.category { summary.byKind[k, default: 0] += 1 }
            }
            if stopRequested { summary.kind = .stopped; summary.moved = 0; summary.bytes = 0 }
            await model.fadeBoxes()
            await model.dockHome()
            finish(summary, started: started)
            return
        }

        if result.targets.isEmpty {
            model.say("empty", hold: 2.4)
            await model.fadeBoxes()
            await model.wait(1.2)
            await model.dockHome()
            finish(summary, started: started)
            return
        }

        if settings.confirmBeforeCleaning {
            setStatus(L("hud.waiting", settings.displayName))
            model.say("wait", hold: 600)
            let ok = await askConfirm(result: result, settings: settings)
            model.bubble = nil
            if !ok {
                await model.fadeBoxes()
                await model.dockHome()
                summary.kind = .stopped
                finish(summary, started: started)
                return
            }
        }
        await model.fadeBoxes()

        await clean(result: result, images: images, model: model, settings: settings, summary: &summary)

        if !stopRequested {
            model.say("done", hold: 1.6)
        }
        setStatus(L("hud.returning", settings.displayName))
        await model.dockHome()
        finish(summary, started: started)
    }

    private func clean(result: ScanResult, images: [UUID: NSImage], model: SceneModel,
                       settings: AppSettings, summary: inout CleanSummary) async {
        let mover = Mover(config: settings.moverConfig())
        var journal = Journal.begin(base: settings.targetFolderURL)
        let visitsProtected = result.items.filter {
            if case .protected = $0.status { return true } else { return false }
        }.prefix(3)
        let route = Self.route(from: model.pos, through: result.targets + visitsProtected)
        total = result.targets.count
        setStatus(L("hud.cleaning", settings.displayName, 0, total))
        summary.destination = mover.rootFolder

        var screenshots = 0, saidScreens = false, stuckCount = 0
        Reel.mark("pick")
        for item in route {
            if stopRequested { break }
            if item.isProtected {
                await model.drive(to: model.approachPoint(for: item), speedScale: 1.1)
                model.say("protected")
                await model.wait(0.9)
                continue
            }

            // The scan may be minutes old (the confirm card waits): skip anything that changed since.
            let now = try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = now?.contentModificationDate, abs(modified.timeIntervalSince(item.modified)) < 1 else {
                continue
            }
            let image = images[item.id] ?? NSWorkspace.shared.icon(forFile: item.url.path)
            model.placeGhost(for: item, image: image)
            let dest: URL
            do {
                dest = item.trash
                    ? try mover.trash(item.url)
                    : try mover.move(item.url, kind: item.category ?? .other, modified: item.modified)
            } catch {
                model.dropGhost(item.id)
                summary.failed += 1
                model.say("fail")
                continue
            }
            journal.moves.append(MoveRecord(from: item.url.path, to: dest.path, x: item.position.x, y: item.position.y,
                                            inode: Mover.fileNumber(dest), trashed: item.trash ? true : nil, size: item.size))
            journal.createdFolders = mover.createdFolders.map(\.path)
            do {
                try Journal.save(journal)
            } catch {
                // No undo record means no move: put the file back and stop.
                _ = try? Mover.renameExclusive(dest, item.url)
                journal.moves.removeLast()
                model.dropGhost(item.id)
                summary.failed += 1
                stopRequested = true
                alert(title: L("err.title"), text: L("err.undo", error.localizedDescription))
                break
            }

            let target = model.approachPoint(for: item)
            if settings.getsStuck, stuckCount < 2, model.pos.distance(to: target) > 260, Double.random(in: 0...1) < 0.12 {
                stuckCount += 1
                await model.drive(to: lerp(model.pos, target, 0.55))
                model.say("stuck")
                await model.bumpWiggle()
                await model.wait(0.35)
                model.say("unstuck", hold: 1.0)
            }
            await model.drive(to: target)
            await model.suck(item.id)

            done += 1
            summary.moved += 1
            summary.bytes += item.size
            if item.trash {
                summary.trashed += 1
            } else if let k = item.category {
                summary.byKind[k, default: 0] += 1
            }
            setStatus(L("hud.cleaning", settings.displayName, done, total))

            if item.category == .screenshots { screenshots += 1 }
            if item.trash, !model.isTalking, Double.random(in: 0...1) < 0.35 {
                model.say("trash", hold: 0.9)
            } else if !model.isTalking {
                if screenshots >= 5, !saidScreens {
                    saidScreens = true
                    model.say("screens")
                } else if item.size > 200_000_000 {
                    model.say("big")
                } else if done % 9 == 0 {
                    model.say("spot")
                } else if Double.random(in: 0...1) < 0.16 {
                    model.say("nom", hold: 0.8)
                }
            }
        }

        summary.foldersCreated = mover.createdFolders.count
        if stopRequested { summary.kind = .stopped }
        if !journal.moves.isEmpty {
            summary.journalID = journal.id
            lastJournal = journal
        }
    }

    /// Greedy nearest-neighbour tour: short, natural-looking paths without a solver.
    static func route(from start: CGPoint, through items: [DeskItem]) -> [DeskItem] {
        var left = items
        var out: [DeskItem] = []
        var cur = start
        while !left.isEmpty {
            var best = 0
            var bestD = Double.infinity
            for (i, it) in left.enumerated() {
                let d = it.position.distance(to: cur)
                if d < bestD { bestD = d; best = i }
            }
            let next = left.remove(at: best)
            out.append(next)
            cur = next.position
        }
        return out
    }

    private func finish(_ summary: CleanSummary, started: Date) {
        var s = summary
        s.seconds = Int(Date().timeIntervalSince(started).rounded())
        hud?.dismiss()
        hud = nil
        isRunning = false
        if s.kind == .cleaned { SoundEngine.shared.chime() }
        SoundEngine.shared.stop()
        if AppSettings.shared.parkOnDesktop, let model = scene {
            parkIdle(model)
        }
        showSummary(s)
    }

    private func teardownScene() {
        guard let model = scene else { return }
        if AppSettings.shared.parkOnDesktop {
            if !model.idle { parkIdle(model) }
            return
        }
        scene = nil
        Task {
            await model.vanish()
            model.stopClock()
            overlay?.orderOut(nil)
            overlay = nil
            SoundEngine.shared.stop()
        }
    }

    /// Leaves the robot on its dock behind the windows, animation stopped.
    private func parkIdle(_ model: SceneModel) {
        model.stopClock()
        model.park()
        model.idle = true
        overlay?.setAbove(AppSettings.shared.aboveWindows)
        SoundEngine.shared.stop()
        showDockButton(for: model)
    }

    /// An invisible button over the parked robot: click it and the robot sets off again.
    private func showDockButton(for model: SceneModel) {
        dockButton?.orderOut(nil)
        let f = screen.frame
        let r = model.radius
        let rect = NSRect(x: f.minX + model.dock.x - r * 1.2, y: f.maxY - model.dock.y - r * 1.2,
                          width: r * 2.4, height: r * 2.4)
        let button = DockButtonWindow(frame: rect, above: AppSettings.shared.aboveWindows) { [weak self] in
            self?.start(.clean)
        }
        dockButton = button
        button.orderFrontRegardless()
    }

    /// Shows or hides the parked robot after a settings change or at launch.
    func refreshParking() {
        guard !isRunning, card == nil else { return }
        let want = AppSettings.shared.parkOnDesktop
        if want, scene == nil {
            let model = SceneModel(screen: screen, settings: AppSettings.shared)
            model.park()
            model.idle = true
            let win = OverlayWindow(screen: screen, model: model, aboveWindows: AppSettings.shared.aboveWindows)
            scene = model
            overlay = win
            win.orderFrontRegardless()
            showDockButton(for: model)
        } else if !want, let model = scene, model.idle {
            dropSceneNow()
        } else if want, let model = scene, model.idle {
            if model.radius == AppSettings.shared.robotSize / 2 {
                // Only colors changed: repaint in place, no flicker.
                model.style = RobotStyle.current()
                model.objectWillChange.send()
            } else {
                dropSceneNow()
                refreshParking()
            }
        }
    }

    private func dropSceneNow() {
        dockButton?.orderOut(nil)
        dockButton = nil
        scene?.stopClock()
        scene = nil
        overlay?.orderOut(nil)
        overlay = nil
        SoundEngine.shared.stop()
    }

    // MARK: Confirm

    private func askConfirm(result: ScanResult, settings: AppSettings) async -> Bool {
        var kinds: [FileKind: Int] = [:]
        for t in result.targets where !t.trash { kinds[t.category ?? .other, default: 0] += 1 }
        let trashCount = result.targets.filter(\.trash).count
        let sorted = kinds.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let skipped = result.items.filter {
            if case .skipped(.recent) = $0.status { return true }
            if case .skipped(.categoryOff) = $0.status { return true }
            return false
        }.count
        let destName = settings.destination == .archiveFolder ? settings.effectiveArchiveName : L("dest.categoryFolders")
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            confirmContinuation = c
            let view = ConfirmView(targets: result.targets.count, protectedCount: result.protected.count,
                                   skipped: skipped, trashCount: trashCount, destination: destName, kinds: sorted) { [weak self] ok in
                guard let self else { return }
                self.card?.dismiss()
                self.card = nil
                if let cc = self.confirmContinuation {
                    self.confirmContinuation = nil
                    cc.resume(returning: ok)
                }
            }
            let panel = FloatingPanel(view)
            card = panel
            panel.show(on: screen) { vf, size in NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 40) }
            panel.makeKey()
        }
    }

    // MARK: Panels

    private func setStatus(_ s: String) { statusText = s }

    private func showHUD() {
        guard AppSettings.shared.showHUD else { return }
        let panel = FloatingPanel(HUDView())
        hud = panel
        panel.show(on: screen) { vf, size in NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 10) }
    }

    private func showSummary(_ s: CleanSummary) {
        closeCard()
        let view = SummaryView(
            summary: s, name: AppSettings.shared.displayName,
            onUndo: { [weak self] in self?.undo(journalID: s.journalID) },
            onReviewTrash: { [weak self] in
                if let id = s.journalID { self?.openTrashReview(journalID: id) }
            },
            onReveal: { [weak self] in
                if let d = s.destination { NSWorkspace.shared.activateFileViewerSelecting([d]) }
                self?.closeCard()
                self?.teardownScene()
            },
            onAgain: { [weak self] in
                self?.closeCard()
                self?.teardownAndRestart()
            },
            onClose: { [weak self] in
                self?.closeCard()
                self?.teardownScene()
            }
        )
        let panel = FloatingPanel(view)
        card = panel
        let band = Reel.band
        let f = screen.frame
        panel.show(on: screen) { vf, size in
            if let band { return NSPoint(x: f.minX + band.midX - size.width / 2, y: vf.midY - size.height / 2 + 120) }
            return NSPoint(x: vf.midX + 40, y: vf.midY - size.height / 2)
        }
    }

    private func teardownAndRestart() {
        start(.clean)
    }

    func closeSummary() {
        closeCard()
        teardownScene()
    }

    private func closeCard() {
        card?.dismiss()
        card = nil
    }

    // MARK: Trash review

    private var trashWindow: NSWindow?

    var lastTrashedCount: Int { lastJournal?.moves.filter(\.isTrashed).count ?? 0 }

    func openTrashReview(journalID: String? = nil) {
        guard let id = journalID ?? Journal.all().first(where: { $0.moves.contains(where: \.isTrashed) })?.id else { return }
        trashWindow?.close()
        let model = TrashReviewModel(journalID: id) { [weak self] in
            self?.lastJournal = Journal.latestUndoable()
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = L("trash.title")
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: TrashReviewView(model: model))
        win.center()
        trashWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: Undo

    func undoLast() { undo(journalID: nil) }

    private func undo(journalID: String?) {
        let journal = journalID.flatMap { id in Journal.all().first { $0.id == id && !$0.undone } } ?? Journal.latestUndoable()
        guard let journal else { return }
        do {
            let r = try Journal.undo(journal)
            lastJournal = Journal.latestUndoable()
            if !r.positions.isEmpty, journal.base == AppSettings.desktopURL.path {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FinderBridge.setPositions(r.positions) }
            }
            var s = CleanSummary(kind: .undone)
            s.restored = r.restored
            s.missing = r.missing + r.remaining
            if scene != nil { teardownScene() }
            showSummary(s)
        } catch {
            alert(title: L("err.title"), text: L("err.undo", error.localizedDescription))
        }
    }

    // MARK: Errors

    private func showAccessError(folder: URL, error: Error) {
        let a = NSAlert()
        a.messageText = L("err.title")
        a.informativeText = L("err.body", folder.lastPathComponent, error.localizedDescription)
        a.addButton(withTitle: L("err.open"))
        a.addButton(withTitle: L("err.ok"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: L("err.ok"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
