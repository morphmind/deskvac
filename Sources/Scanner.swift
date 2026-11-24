import AppKit
import CoreServices

enum FileKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case screenshots, images, videos, audio, documents, pdfs, archives, installers, code, other, folders
    var id: String { rawValue }

    /// File types shown in Settings; folders have their own switch.
    static var fileKinds: [FileKind] { allCases.filter { $0 != .folders } }

    var folderName: String { L("cat.\(rawValue)") }
    var tag: String { L("tag.\(rawValue)") }

    var symbol: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .documents: "doc.text"
        case .pdfs: "doc.richtext"
        case .archives: "archivebox"
        case .installers: "shippingbox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "questionmark.square.dashed"
        case .folders: "folder"
        }
    }
}

enum Classifier {
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "dng", "psd", "ai", "sketch", "fig", "avif", "ico", "icns"]
    static let videoExt: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "3gp", "mpg", "mpeg"]
    static let audioExt: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "flac", "aac", "ogg", "opus", "caf", "mid", "midi"]
    static let docExt: Set<String> = ["doc", "docx", "pages", "txt", "rtf", "rtfd", "md", "markdown", "odt", "key", "ppt", "pptx", "numbers", "xls", "xlsx", "csv", "tsv", "ods", "odp", "epub", "vcf", "ics", "webloc", "url"]
    static let archiveExt: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz", "cab", "jar"]
    static let installerExt: Set<String> = ["dmg", "pkg", "mpkg", "iso", "img", "xip", "exe", "msi", "apk", "aab", "ipa", "deb", "rpm"]
    static let codeExt: Set<String> = ["swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "html", "htm", "css", "scss", "json", "yaml", "yml", "toml", "xml", "sh", "zsh", "bash", "sql", "ipynb", "vue", "svelte", "env", "lua", "dart"]
    /// Document bundles that look like folders on disk but are single documents to the user.
    static let documentPackages: Set<String> = ["pages", "key", "numbers", "rtfd", "sketch", "fcpbundle", "logicx", "band", "playground", "graffle"]
    /// Files that are still being written by a download or copy.
    static let inProgressExt: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "icloud"]

    static let screenshotPrefixes = [
        "screenshot", "screen shot", "ekran resmi", "ekran görüntüsü", "ekran goruntusu",
        "bildschirmfoto", "capture d’écran", "capture d'écran", "cleanshot", "schermafbeelding",
    ]
    static let recordingPrefixes = ["screen recording", "ekran kaydı", "ekran kaydi", "bildschirmaufnahme"]

    static func category(for url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        if videoExt.contains(ext) || recordingPrefixes.contains(where: name.hasPrefix) {
            return recordingPrefixes.contains(where: name.hasPrefix) ? .screenshots : .videos
        }
        if imageExt.contains(ext) {
            if screenshotPrefixes.contains(where: name.hasPrefix) || isScreenCapture(url) { return .screenshots }
            return .images
        }
        if ext == "pdf" { return .pdfs }
        if audioExt.contains(ext) { return .audio }
        if docExt.contains(ext) || documentPackages.contains(ext) { return .documents }
        if archiveExt.contains(ext) { return .archives }
        if installerExt.contains(ext) { return .installers }
        if codeExt.contains(ext) { return .code }
        return .other
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return false }
        let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString)
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
    }
}

enum SkipReason: Equatable {
    case folder(items: Int)
    case app
    case shortcut
    case recent
    case inProgress
    case categoryOff
    case notDemo
}

enum ItemStatus: Equatable {
    case target
    case protected(word: String)
    case skipped(SkipReason)
}

struct DeskItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
    let category: FileKind?
    var status: ItemStatus
    var position: CGPoint
    var isDemo: Bool
    var trash = false

    var isTarget: Bool { status == .target }
    var isProtected: Bool { if case .protected = status { true } else { false } }
}

struct ScanConfig {
    var actions: [FileKind: KindAction]
    var trashExtensions: Set<String>
    var trashOlderThanDays: Int
    var collectFolders: Bool
    var ownFolders: Set<String>
    var protectWords: [String]
    var skipRecentMinutes: Int
    var demoOnly: Bool
    var useFinderPositions: Bool
    var screenSize: CGSize
}

struct ScanResult {
    var items: [DeskItem]
    var positionsFromFinder: Bool
    var targets: [DeskItem] { items.filter(\.isTarget) }
    var protected: [DeskItem] { items.filter(\.isProtected) }
}

enum DesktopScanner {
    static let demoAttr = "io.onore.deskvac.demo"

    static func scan(folder: URL, config: ScanConfig, now: Date = Date()) throws -> ScanResult {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey,
            .totalFileAllocatedSizeKey, .contentModificationDateKey, .tagNamesKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
        let finder: [String: CGPoint]? = config.useFinderPositions ? FinderBridge.desktopPositions() : nil
        let fm = FileManager.default
        var items: [DeskItem] = []

        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = url.lastPathComponent
            if name == ".localized" { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            let isPackage = v?.isPackage ?? false
            let ext = url.pathExtension.lowercased()
            let modified = v?.contentModificationDate ?? .distantPast
            let isDemo = XAttr.has(url, demoAttr)
            var size = Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            var category: FileKind?
            var status: ItemStatus = .target
            var trash = false
            let recent = !isDemo && config.skipRecentMinutes > 0
                && now.timeIntervalSince(modified) < Double(config.skipRecentMinutes) * 60

            if isDir && !(isPackage && Classifier.documentPackages.contains(ext)) {
                if ext == "app" || isPackage {
                    status = .skipped(.app)
                } else {
                    let count = (try? fm.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
                    let isRepo = fm.fileExists(atPath: url.appendingPathComponent(".git").path)
                    let word = protectedWord(name: name, tags: v?.tagNames ?? [], words: config.protectWords)
                    if config.collectFolders, !isRepo, word == nil, !config.ownFolders.contains(name),
                       !(config.demoOnly && !isDemo), !recent {
                        category = .folders
                    } else if config.collectFolders, let word {
                        status = .protected(word: word)
                    } else {
                        status = .skipped(.folder(items: count))
                    }
                }
                size = 0
            } else if v?.isSymbolicLink == true || v?.isAliasFile == true {
                status = .skipped(.shortcut)
            } else {
                category = Classifier.category(for: url)
                if Classifier.inProgressExt.contains(ext) {
                    status = .skipped(.inProgress)
                } else if let word = protectedWord(name: name, tags: v?.tagNames ?? [], words: config.protectWords) {
                    status = .protected(word: word)
                } else if config.demoOnly && !isDemo {
                    status = .skipped(.notDemo)
                } else if recent {
                    status = .skipped(.recent)
                } else if let c = category {
                    let forced = config.trashExtensions.contains(ext)
                    let action: KindAction = forced ? .trash : (config.actions[c] ?? .collect)
                    if action == .ignore {
                        status = .skipped(.categoryOff)
                    } else if action == .trash {
                        // Too young to throw away: it gets tidied instead.
                        let days = Double(config.trashOlderThanDays) * 86_400
                        trash = config.trashOlderThanDays == 0 || now.timeIntervalSince(modified) >= days
                    }
                }
            }

            items.append(DeskItem(
                url: url, name: name, size: size, modified: modified, category: category,
                status: status, position: finder?[name] ?? .zero, isDemo: isDemo, trash: trash
            ))
        }

        let fromFinder = finder != nil && !(finder?.isEmpty ?? true)
        if !fromFinder || items.contains(where: { $0.position == .zero }) {
            layoutFallback(&items, screen: config.screenSize, onlyMissing: fromFinder)
        }
        return ScanResult(items: items, positionsFromFinder: fromFinder)
    }

    static func protectedWord(name: String, tags: [String], words: [String]) -> String? {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let normalized = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        for w in words {
            let wn = w.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            if normalized.range(of: wn, options: opts) != nil { return w }
            if tags.contains(where: { $0.compare(w, options: opts) == .orderedSame }) { return w }
        }
        return nil
    }

    /// When Finder can't tell us where icons are, mimic its default column layout from the top right.
    static func layoutFallback(_ items: inout [DeskItem], screen: CGSize, onlyMissing: Bool) {
        let step = 112.0
        let top = 86.0
        let rows = max(1, Int((screen.height - top - 120) / step))
        var slot = 0
        for i in items.indices where !onlyMissing || items[i].position == .zero {
            let col = slot / rows, row = slot % rows
            items[i].position = CGPoint(x: screen.width - 70 - Double(col) * step, y: top + Double(row) * step)
            slot += 1
        }
    }

    /// Cheap count used by the scheduler, no Finder round trip.
    static func looseFileCount(folder: URL) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }.count
    }
}

/// Talks to Finder over Apple Events to read and set desktop icon positions.
enum FinderBridge {
    private(set) static var lastError: String?

    static func desktopPositions() -> [String: CGPoint]? {
        let src = """
        tell application "Finder"
            set ns to name of every item of desktop
            set ps to desktop position of every item of desktop
            return {ns, ps}
        end tell
        """
        guard let script = NSAppleScript(source: src) else { return nil }
        var err: NSDictionary?
        let res = script.executeAndReturnError(&err)
        if let err {
            lastError = (err[NSAppleScript.errorMessage] as? String) ?? "Finder"
            return nil
        }
        lastError = nil
        guard res.numberOfItems == 2, let names = res.atIndex(1), let points = res.atIndex(2) else { return [:] }
        var out: [String: CGPoint] = [:]
        let n = min(names.numberOfItems, points.numberOfItems)
        guard n > 0 else { return [:] }
        for i in 1...n {
            guard let name = names.atIndex(i)?.stringValue, let p = points.atIndex(i), p.numberOfItems == 2 else { continue }
            let x = Double(p.atIndex(1)?.int32Value ?? 0)
            let y = Double(p.atIndex(2)?.int32Value ?? 0)
            out[name] = CGPoint(x: x, y: y)
        }
        return out
    }

    static func setPositions(_ list: [(name: String, point: CGPoint)]) {
        guard !list.isEmpty else { return }
        var lines = ["tell application \"Finder\""]
        for item in list {
            let esc = item.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("try")
            lines.append("set desktop position of item \"\(esc)\" of desktop to {\(Int(item.point.x)), \(Int(item.point.y))}")
            lines.append("end try")
        }
        lines.append("end tell")
        var err: NSDictionary?
        NSAppleScript(source: lines.joined(separator: "\n"))?.executeAndReturnError(&err)
    }
}
