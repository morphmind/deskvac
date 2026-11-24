import Foundation

struct MoverConfig {
    var base: URL
    var mode: DestinationMode
    var archiveName: String
    var monthFolders: Bool
    var folderNames: [FileKind: String]
}

/// Moves files into their category folders. Never deletes, never overwrites:
/// a name clash gets " 2", " 3"... like Finder does.
final class Mover {
    let config: MoverConfig
    private(set) var createdFolders: [URL] = []
    private let fm = FileManager.default
    private static let monthFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    init(config: MoverConfig) { self.config = config }

    var rootFolder: URL {
        switch config.mode {
        case .archiveFolder: config.base.appendingPathComponent(config.archiveName, isDirectory: true)
        case .categoryFolders: config.base
        }
    }

    func folder(for kind: FileKind, modified: Date) -> URL {
        var url = rootFolder.appendingPathComponent(config.folderNames[kind] ?? kind.rawValue, isDirectory: true)
        if config.monthFolders {
            url = url.appendingPathComponent(Mover.monthFormat.string(from: modified), isDirectory: true)
        }
        return url
    }

    func move(_ source: URL, kind: FileKind, modified: Date) throws -> URL {
        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let dir = folder(for: kind, modified: modified)
        try ensureDirectory(dir)
        for _ in 0..<5 {
            let dest = Mover.uniqueURL(dir.appendingPathComponent(source.lastPathComponent))
            if try Mover.renameExclusive(source, dest) { return dest }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: source.path])
    }

    /// Renames without ever replacing an existing file: the kernel refuses if `dest` exists.
    /// Returns false on a name clash so the caller can pick the next free name.
    static func renameExclusive(_ source: URL, _ dest: URL) throws -> Bool {
        let rc = source.withUnsafeFileSystemRepresentation { s in
            dest.withUnsafeFileSystemRepresentation { d in
                guard let s, let d else { return Int32(-1) }
                return renamex_np(s, d, UInt32(RENAME_EXCL))
            }
        }
        if rc == 0 { return true }
        let code = errno
        if code == EEXIST { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                      userInfo: [NSFilePathErrorKey: source.path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }

    static func fileNumber(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// Sends a file to the user's Trash, where Undo or the trash review can still bring it back.
    func trash(_ source: URL) throws -> URL {
        var out: NSURL?
        try fm.trashItem(at: source, resultingItemURL: &out)
        guard let url = out as URL? else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    private func ensureDirectory(_ dir: URL) throws {
        var missing: [URL] = []
        var cur = dir
        var isDir: ObjCBool = false
        while !fm.fileExists(atPath: cur.path, isDirectory: &isDir) {
            missing.append(cur)
            cur = cur.deletingLastPathComponent()
        }
        if !isDir.boolValue {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: cur.path])
        }
        for u in missing.reversed() {
            try fm.createDirectory(at: u, withIntermediateDirectories: false)
            createdFolders.append(u)
        }
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for n in 2...9999 {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8)).\(ext)")
    }
}

struct MoveRecord: Codable {
    let from: String
    let to: String
    let x: Double
    let y: Double
    var inode: UInt64? = nil
    var trashed: Bool? = nil
    var size: Int64? = nil

    var isTrashed: Bool { trashed == true }
}

struct SessionJournal: Codable {
    let id: String
    let date: Date
    let base: String
    var moves: [MoveRecord]
    var createdFolders: [String]
    var undone: Bool
}

struct UndoResult {
    var restored = 0
    var missing = 0
    var remaining = 0
    var positions: [(name: String, point: CGPoint)] = []
}

/// Every move is written to disk right after it happens, so a crash or quit mid-clean can still be undone.
enum Journal {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DeskVac/journals", isDirectory: true)
    }()

    static func begin(base: URL) -> SessionJournal {
        SessionJournal(id: UUID().uuidString, date: Date(), base: base.path, moves: [], createdFolders: [], undone: false)
    }

    static func save(_ j: SessionJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(j).write(to: directory.appendingPathComponent("\(j.id).json"), options: .atomic)
    }

    static func all() -> [SessionJournal] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(SessionJournal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    static func latestUndoable() -> SessionJournal? {
        all().first { !$0.undone && !$0.moves.isEmpty }
    }

    /// A journal may only move files between the cleaned folder and folders inside it.
    static func isSafe(_ m: MoveRecord, base: URL) -> Bool {
        let b = base.standardizedFileURL.resolvingSymlinksInPath().path
        let from = URL(fileURLWithPath: m.from).standardizedFileURL
        let to = URL(fileURLWithPath: m.to).standardizedFileURL
        let fromParent = from.deletingLastPathComponent().resolvingSymlinksInPath().path
        let toParent = to.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard fromParent == b, !m.from.contains("/../"), !m.to.contains("/../") else { return false }
        if m.isTrashed {
            guard let trash = trashDirectory?.standardizedFileURL.resolvingSymlinksInPath().path else { return false }
            return toParent == trash
        }
        return toParent.hasPrefix(b + "/")
    }

    static var trashDirectory: URL? {
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    /// The record still points at the very file DeskVac moved (same path and same inode).
    static func stillOurs(_ m: MoveRecord) -> Bool {
        let to = URL(fileURLWithPath: m.to)
        guard FileManager.default.fileExists(atPath: to.path) else { return false }
        if let ino = m.inode { return Mover.fileNumber(to) == ino }
        return true
    }

    static func load(id: String) -> SessionJournal? { all().first { $0.id == id } }

    /// Puts chosen trashed files back on the desktop. Returns where they landed, for Finder positions.
    static func restoreTrashed(journalID: String, paths: Set<String>) throws -> [(name: String, point: CGPoint)] {
        guard var j = load(id: journalID) else { return [] }
        let base = URL(fileURLWithPath: j.base)
        var positions: [(name: String, point: CGPoint)] = []
        var keep: [MoveRecord] = []
        for m in j.moves {
            guard m.isTrashed, paths.contains(m.to), isSafe(m, base: base), stillOurs(m) else { keep.append(m); continue }
            var done = false
            for _ in 0..<5 {
                let dest = Mover.uniqueURL(URL(fileURLWithPath: m.from))
                if (try? Mover.renameExclusive(URL(fileURLWithPath: m.to), dest)) == true {
                    positions.append((dest.lastPathComponent, CGPoint(x: m.x, y: m.y)))
                    done = true
                    break
                }
            }
            if !done { keep.append(m) }
        }
        j.moves = keep
        try save(j)
        return positions
    }

    /// Permanently deletes chosen files, but only ones DeskVac itself put in the Trash and that are unchanged.
    static func deleteTrashed(journalID: String, paths: Set<String>) throws -> Int {
        guard var j = load(id: journalID) else { return 0 }
        let base = URL(fileURLWithPath: j.base)
        var deleted = 0
        var keep: [MoveRecord] = []
        for m in j.moves {
            guard m.isTrashed, paths.contains(m.to) else { keep.append(m); continue }
            guard isSafe(m, base: base), stillOurs(m) else { keep.append(m); continue }
            do {
                try FileManager.default.removeItem(at: URL(fileURLWithPath: m.to))
                deleted += 1
            } catch {
                keep.append(m)
            }
        }
        j.moves = keep
        try save(j)
        return deleted
    }

    static func undo(_ journal: SessionJournal) throws -> UndoResult {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: journal.base)
        var result = UndoResult()
        var left: [MoveRecord] = []
        for m in journal.moves.reversed() {
            let to = URL(fileURLWithPath: m.to)
            guard isSafe(m, base: base) else { result.missing += 1; continue }
            guard fm.fileExists(atPath: to.path) else { result.missing += 1; continue }
            // A different file now sitting at the same path is not ours to move.
            if let ino = m.inode, Mover.fileNumber(to) != ino { result.missing += 1; continue }
            var restored = false
            for _ in 0..<5 {
                let from = Mover.uniqueURL(URL(fileURLWithPath: m.from))
                if (try? Mover.renameExclusive(to, from)) == true {
                    restored = true
                    result.restored += 1
                    if m.x != 0 || m.y != 0 {
                        result.positions.append((from.lastPathComponent, CGPoint(x: m.x, y: m.y)))
                    }
                    break
                }
            }
            if !restored { left.append(m) }
        }
        let basePath = base.standardizedFileURL.path
        for path in journal.createdFolders.sorted(by: { $0.count > $1.count })
        where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(basePath + "/") {
            removeIfEmpty(URL(fileURLWithPath: path))
        }
        var done = journal
        done.moves = left.reversed()
        done.undone = left.isEmpty
        result.remaining = left.count
        try save(done)
        return result
    }

    /// Removes a folder only when nothing but Finder's .DS_Store is left inside.
    static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        for c in contents { try? fm.removeItem(at: dir.appendingPathComponent(c)) }
        // rmdir refuses a folder that is no longer empty, so nothing that arrived meanwhile can be lost.
        _ = dir.withUnsafeFileSystemRepresentation { p in p.map { rmdir($0) } }
    }
}
