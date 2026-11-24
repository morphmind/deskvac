import Foundation

/// End-to-end check of the parts that touch real files: scan rules, moves, name clashes,
/// the journal and undo. Runs in a temporary folder; `build.sh` runs it on every build.
enum SelfTest {
    static func run() -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deskvac-selftest-\(UUID().uuidString)")
        let desk = root.appendingPathComponent("Desk")
        let journalDir = root.appendingPathComponent("journals")
        Journal.directory = journalDir
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "  ok   " : "  FAIL ") + what)
            if !ok { failures.append(what) }
        }
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: desk, withIntermediateDirectories: true)
            let old = Date().addingTimeInterval(-86_400 * 3)
            func make(_ name: String, recent: Bool = false) -> URL {
                let u = desk.appendingPathComponent(name)
                fm.createFile(atPath: u.path, contents: Data(name.utf8))
                if !recent { try? fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path) }
                return u
            }
            _ = make("Screenshot 2026-11-01 at 10.00.00.png")
            _ = make("Ekran Resmi 2026-11-02 11.00.00.png")
            _ = make("photo.jpg")
            _ = make("report.pdf")
            _ = make("stuff.zip")
            _ = make("notes.txt")
            _ = make("DONT DELETE - taxes.pdf")
            _ = make("silme_bunu.txt")
            _ = make("fresh.png", recent: true)
            _ = make("half.crdownload")
            let folder = desk.appendingPathComponent("My Project")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            fm.createFile(atPath: folder.appendingPathComponent("inside.txt").path, contents: Data())
            try fm.createSymbolicLink(at: desk.appendingPathComponent("link.txt"), withDestinationURL: folder)

            let archiveName = "Desktop Archive"
            let config = ScanConfig(
                actions: [:], trashExtensions: [], trashOlderThanDays: 0, collectFolders: false,
                ownFolders: [archiveName], protectWords: ["DONT DELETE", "SİLME"], skipRecentMinutes: 5,
                demoOnly: false, useFinderPositions: false, screenSize: CGSize(width: 1440, height: 900)
            )
            let scan = try DesktopScanner.scan(folder: desk, config: config)
            let byName = Dictionary(uniqueKeysWithValues: scan.items.map { ($0.name, $0) })
            check(byName["Screenshot 2026-11-01 at 10.00.00.png"]?.category == .screenshots, "English screenshot detected")
            check(byName["Ekran Resmi 2026-11-02 11.00.00.png"]?.category == .screenshots, "Turkish screenshot detected")
            check(byName["photo.jpg"]?.category == .images, "photo is an image")
            check(byName["DONT DELETE - taxes.pdf"]?.isProtected == true, "DONT DELETE is protected")
            check(byName["silme_bunu.txt"]?.isProtected == true, "SİLME matches silme_ case and diacritic insensitive")
            check(byName["fresh.png"]?.status == .skipped(.recent), "recent file skipped")
            check(byName["half.crdownload"]?.status == .skipped(.inProgress), "download in progress skipped")
            check(byName["My Project"]?.status == .skipped(.folder(items: 1)), "folder never targeted")
            check(byName["link.txt"]?.status == .skipped(.shortcut), "symlink never targeted")
            check(scan.targets.count == 6, "six targets (got \(scan.targets.count))")
            check(scan.items.allSatisfy { $0.position != .zero }, "every item has a position")

            // A clash: the archive already has a photo.jpg.
            let mover = Mover(config: MoverConfig(base: desk, mode: .archiveFolder, archiveName: archiveName,
                                                  monthFolders: true, folderNames: [.images: "Images"]))
            let clashDir = mover.folder(for: .images, modified: old)
            try fm.createDirectory(at: clashDir, withIntermediateDirectories: true)
            fm.createFile(atPath: clashDir.appendingPathComponent("photo.jpg").path, contents: Data("existing".utf8))

            var journal = Journal.begin(base: desk)
            for t in scan.targets {
                let dest = try mover.move(t.url, kind: t.category ?? .other, modified: t.modified)
                journal.moves.append(MoveRecord(from: t.url.path, to: dest.path, x: 0, y: 0))
            }
            journal.createdFolders = mover.createdFolders.map(\.path)
            try Journal.save(journal)

            check(!fm.fileExists(atPath: desk.appendingPathComponent("photo.jpg").path), "photo left the desk")
            check(fm.fileExists(atPath: clashDir.appendingPathComponent("photo 2.jpg").path), "clash renamed to 'photo 2.jpg'")
            check((try? String(contentsOf: clashDir.appendingPathComponent("photo.jpg"), encoding: .utf8)) == "existing",
                  "existing file untouched")
            check(fm.fileExists(atPath: desk.appendingPathComponent("DONT DELETE - taxes.pdf").path), "protected file stayed")
            check(fm.fileExists(atPath: folder.appendingPathComponent("inside.txt").path), "folder contents untouched")
            check(Journal.latestUndoable()?.moves.count == 6, "journal recorded six moves")

            // A second scan must not pick up the archive folder or anything inside it.
            let again = try DesktopScanner.scan(folder: desk, config: config)
            check(again.targets.isEmpty, "second scan finds nothing to move")

            let undo = try Journal.undo(journal)
            check(undo.restored == 6 && undo.missing == 0, "undo restored six files")
            for name in ["Screenshot 2026-11-01 at 10.00.00.png", "photo.jpg", "report.pdf", "stuff.zip", "notes.txt"] {
                check(fm.fileExists(atPath: desk.appendingPathComponent(name).path), "\(name) is back")
            }
            check(fm.fileExists(atPath: clashDir.appendingPathComponent("photo.jpg").path), "pre-existing archive file kept after undo")
            let reportDir = mover.folder(for: .pdfs, modified: old)
            check(!fm.fileExists(atPath: reportDir.path), "empty folders we created are removed")
            check(Journal.latestUndoable() == nil, "journal marked as undone")

            // Tampered journal: paths outside the cleaned folder must be refused.
            let outside = root.appendingPathComponent("outside.txt")
            fm.createFile(atPath: outside.path, contents: Data("keep".utf8))
            var evil = Journal.begin(base: desk)
            evil.moves = [MoveRecord(from: desk.appendingPathComponent("stolen.txt").path, to: outside.path, x: 0, y: 0)]
            let evilResult = try Journal.undo(evil)
            check(evilResult.restored == 0 && fm.fileExists(atPath: outside.path), "journal pointing outside the folder is refused")

            // A different file now at the archived path is not moved back.
            let impostorDir = desk.appendingPathComponent(archiveName)
            try fm.createDirectory(at: impostorDir, withIntermediateDirectories: true)
            let impostor = impostorDir.appendingPathComponent("x.txt")
            fm.createFile(atPath: impostor.path, contents: Data("other".utf8))
            var stale = Journal.begin(base: desk)
            stale.moves = [MoveRecord(from: desk.appendingPathComponent("x.txt").path, to: impostor.path, x: 0, y: 0, inode: 1)]
            let staleResult = try Journal.undo(stale)
            check(staleResult.restored == 0 && fm.fileExists(atPath: impostor.path), "file with a different inode is left alone")

            // Trash: screenshots set to Trash, folders collected, git repos left alone.
            let desk2 = root.appendingPathComponent("Desk2")
            try fm.createDirectory(at: desk2, withIntermediateDirectories: true)
            for n in ["Screenshot 2026-11-01 at 09.00.00.png", "keep.pdf"] {
                let u = desk2.appendingPathComponent(n)
                fm.createFile(atPath: u.path, contents: Data(n.utf8))
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: u.path)
            }
            let plain = desk2.appendingPathComponent("old stuff")
            let repo = desk2.appendingPathComponent("my-app")
            try fm.createDirectory(at: plain, withIntermediateDirectories: false)
            try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: plain.path)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: repo.path)
            var cfg2 = config
            cfg2.actions = [.screenshots: .trash]
            cfg2.collectFolders = true
            let scan2 = try DesktopScanner.scan(folder: desk2, config: cfg2)
            let by2 = Dictionary(uniqueKeysWithValues: scan2.items.map { ($0.name, $0) })
            check(by2["Screenshot 2026-11-01 at 09.00.00.png"]?.trash == true, "screenshot marked for trash")
            check(by2["keep.pdf"]?.trash == false && by2["keep.pdf"]?.isTarget == true, "pdf still tidied, not trashed")
            check(by2["old stuff"]?.category == .folders && by2["old stuff"]?.isTarget == true, "plain folder collected when enabled")
            check(by2["my-app"]?.isTarget == false, "git repository never moved")

            let mover2 = Mover(config: MoverConfig(base: desk2, mode: .archiveFolder, archiveName: archiveName,
                                                   monthFolders: false, folderNames: [:]))
            var j2 = Journal.begin(base: desk2)
            for t in scan2.targets {
                let dest = t.trash ? try mover2.trash(t.url) : try mover2.move(t.url, kind: t.category ?? .other, modified: t.modified)
                j2.moves.append(MoveRecord(from: t.url.path, to: dest.path, x: 0, y: 0, inode: Mover.fileNumber(dest),
                                           trashed: t.trash ? true : nil))
            }
            try Journal.save(j2)
            let trashedRec = j2.moves.first { $0.isTrashed }!
            check(fm.fileExists(atPath: trashedRec.to) && trashedRec.to.contains("/.Trash/"), "screenshot is in the Trash")
            _ = try Journal.restoreTrashed(journalID: j2.id, paths: [trashedRec.to])
            check(fm.fileExists(atPath: trashedRec.from), "restore brings it back to the desk")

            // Trash it again and delete it for good.
            let again2 = try mover2.trash(URL(fileURLWithPath: trashedRec.from))
            var j3 = Journal.begin(base: desk2)
            j3.moves = [MoveRecord(from: trashedRec.from, to: again2.path, x: 0, y: 0, inode: Mover.fileNumber(again2), trashed: true)]
            try Journal.save(j3)
            let stranger = Journal.begin(base: desk2)
            var fake = stranger
            fake.moves = [MoveRecord(from: trashedRec.from, to: again2.path, x: 0, y: 0, inode: 42, trashed: true)]
            try Journal.save(fake)
            check(try Journal.deleteTrashed(journalID: fake.id, paths: [again2.path]) == 0, "won't delete a file whose inode doesn't match")
            check(try Journal.deleteTrashed(journalID: j3.id, paths: [again2.path]) == 1 && !fm.fileExists(atPath: again2.path),
                  "delete for good removes our trashed file")

            check(AppSettings.safeFolderName("../../etc") == nil && AppSettings.safeFolderName("a/b") == nil
                  && AppSettings.safeFolderName(".hidden") == nil && AppSettings.safeFolderName(" Archive ") == "Archive",
                  "archive names cannot escape the folder")
        } catch {
            check(false, "unexpected error: \(error)")
        }

        print(failures.isEmpty ? "selftest passed" : "selftest FAILED (\(failures.count))")
        return failures.isEmpty
    }
}
