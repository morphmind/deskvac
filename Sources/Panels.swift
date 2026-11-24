import AppKit
import SwiftUI

struct CleanSummary {
    enum Kind { case cleaned, stopped, scanned, undone }
    var kind: Kind
    var moved = 0
    var bytes: Int64 = 0
    var byKind: [FileKind: Int] = [:]
    var protectedCount = 0
    var foldersCreated = 0
    var failed = 0
    var trashed = 0
    var seconds = 0
    var destination: URL?
    var journalID: String?
    var restored = 0
    var missing = 0
}

/// Borderless floating card that never steals focus from the app the user is in.
final class FloatingPanel: NSPanel {
    init<V: View>(_ view: V) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: view)
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { true }

    func show(on screen: NSScreen, place: (NSRect, NSSize) -> NSPoint) {
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        setFrameOrigin(place(screen.visibleFrame, size))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; animator().alphaValue = 1 }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; animator().alphaValue = 0 }) { [weak self] in
            self?.orderOut(nil)
        }
    }
}

struct RobotBadge: View {
    var size: Double = 34
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        Canvas { ctx, s in
            RobotPainter.draw(ctx, pose: RobotPose(center: CGPoint(x: s.width / 2, y: s.height / 2),
                                                   heading: -.pi / 2, radius: s.width * 0.4, brushAngle: 0.6),
                              style: RobotStyle.current())
        }
        .frame(width: size, height: size)
    }
}

struct HUDView: View {
    @ObservedObject var controller = CleaningController.shared
    var body: some View {
        HStack(spacing: 10) {
            RobotBadge(size: 26)
            Text(controller.statusText)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            if controller.total > 0 {
                ProgressView(value: Double(controller.done), total: Double(max(1, controller.total)))
                    .progressViewStyle(.linear)
                    .frame(width: 70)
            }
            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(L("menu.stop"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .fixedSize()
    }
}

struct ConfirmView: View {
    let targets: Int
    let protectedCount: Int
    let skipped: Int
    let trashCount: Int
    let destination: String
    let kinds: [(FileKind, Int)]
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RobotBadge(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("confirm.title", targets)).font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(L("confirm.dest", destination)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(kinds.prefix(6), id: \.0) { kind, count in
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                        Text(kind.folderName).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.05)))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if trashCount > 0 {
                    Label(L("confirm.trash", trashCount), systemImage: "trash").foregroundStyle(.red)
                }
                if protectedCount > 0 {
                    Label(L("confirm.protected", protectedCount), systemImage: "lock.fill")
                }
                if skipped > 0 {
                    Label(L("confirm.skipped", skipped), systemImage: "clock")
                }
                Label(L("confirm.safe"), systemImage: "arrow.uturn.backward")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("confirm.cancel")) { decide(false) }.keyboardShortcut(.cancelAction)
                Button(L("confirm.start")) { decide(true) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

struct SummaryView: View {
    let summary: CleanSummary
    let name: String
    let onUndo: () -> Void
    let onReviewTrash: () -> Void
    let onReveal: () -> Void
    let onAgain: () -> Void
    let onClose: () -> Void

    private var title: String {
        switch summary.kind {
        case .cleaned: L("summary.title")
        case .stopped: L("summary.stopped")
        case .scanned: L("summary.scan")
        case .undone: L("summary.undone")
        }
    }

    private var topKind: (FileKind, Int)? {
        summary.byKind.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RobotBadge(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
                    if summary.kind != .undone {
                        Text(L("summary.sub", name, summary.seconds, formatBytes(summary.bytes)))
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
            }
            if summary.kind == .undone {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("summary.restored", summary.restored)).font(.system(size: 13, weight: .medium))
                    if summary.missing > 0 {
                        Text(L("summary.missing", summary.missing)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    tile(summary.moved, summary.kind == .scanned ? L("summary.found") : L("summary.files"))
                    if let top = topKind {
                        tile(top.1, top.0.folderName.lowercased(with: Locale(identifier: L10n.lang.rawValue)))
                    } else {
                        tile(summary.byKind.count, L("summary.kinds"))
                    }
                    tile(summary.protectedCount, L("summary.protected"))
                    tile(summary.kind == .scanned ? summary.byKind.count : summary.foldersCreated,
                         summary.kind == .scanned ? L("summary.kinds") : L("summary.folders"))
                }
                if summary.trashed > 0, summary.kind != .scanned {
                    Button(action: onReviewTrash) {
                        Label(L("summary.trashed", summary.trashed), systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                if summary.failed > 0 {
                    Label(L("summary.failed", summary.failed), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                if let dest = summary.destination, summary.moved > 0, summary.kind != .scanned {
                    Text(L("summary.where", dest.lastPathComponent))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                if summary.kind == .cleaned || summary.kind == .stopped, summary.moved > 0 {
                    Button(L("summary.undo"), action: onUndo)
                    Button(L("summary.reveal"), action: onReveal)
                }
                Spacer()
                if summary.kind == .scanned {
                    Button(L("summary.clean"), action: onAgain)
                } else if summary.kind == .cleaned {
                    Button(L("summary.again"), action: onAgain)
                }
                Button(L("summary.close"), action: onClose).keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private func tile(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

// MARK: Trash review

@MainActor
final class TrashReviewModel: ObservableObject {
    let journalID: String
    @Published private(set) var records: [MoveRecord] = []
    @Published var message: String?
    private let onChange: () -> Void

    init(journalID: String, onChange: @escaping () -> Void) {
        self.journalID = journalID
        self.onChange = onChange
        reload()
    }

    func reload() {
        records = (Journal.load(id: journalID)?.moves ?? []).filter { $0.isTrashed && Journal.stillOurs($0) }
    }

    func restore(_ paths: Set<String>) {
        do {
            let positions = try Journal.restoreTrashed(journalID: journalID, paths: paths)
            message = L("trash.restored", positions.count)
            if !positions.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FinderBridge.setPositions(positions) }
            }
        } catch {
            message = error.localizedDescription
        }
        reload()
        onChange()
    }

    func deleteForever(_ paths: Set<String>) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("trash.confirm.title", paths.count)
        a.informativeText = L("trash.confirm.body")
        a.addButton(withTitle: L("trash.delete"))
        a.addButton(withTitle: L("confirm.cancel"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let n = try Journal.deleteTrashed(journalID: journalID, paths: paths)
            message = L("trash.deleted", n)
        } catch {
            message = error.localizedDescription
        }
        reload()
        onChange()
    }
}

struct TrashReviewView: View {
    @ObservedObject var model: TrashReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("trash.heading", model.records.count)).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(L("trash.sub")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 12)
            Divider()
            if model.records.isEmpty {
                Spacer()
                Text(L("trash.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.records, id: \.to) { r in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: r.to)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: r.from).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(formatBytes(r.size ?? 0)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("trash.restore")) { model.restore([r.to]) }
                        Button(role: .destructive) { model.deleteForever([r.to]) } label: {
                            Image(systemName: "trash")
                        }
                        .help(L("trash.delete"))
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("trash.restoreAll")) { model.restore(Set(model.records.map(\.to))) }
                    .disabled(model.records.isEmpty)
                Button(L("trash.deleteAll"), role: .destructive) { model.deleteForever(Set(model.records.map(\.to))) }
                    .disabled(model.records.isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 460, minHeight: 360)
    }
}
