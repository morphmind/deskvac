import AppKit
import ServiceManagement
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, tr, en
    var id: String { rawValue }
}

enum KindAction: String, CaseIterable, Identifiable {
    case collect, trash, ignore
    var id: String { rawValue }
}

enum DestinationMode: String, CaseIterable, Identifiable {
    case archiveFolder, categoryFolders
    var id: String { rawValue }
}

enum ScheduleMode: String, CaseIterable, Identifiable {
    case off, daily
    var id: String { rawValue }
}

struct RobotPreset: Identifiable {
    let id: String
    let body: String
    let accent: String
    let lidar: String
    let brush: String

    static let all: [RobotPreset] = [
        RobotPreset(id: "classic", body: "#F4F3F0", accent: "#34C759", lidar: "#5AC8FA", brush: "#3A3A3C"),
        RobotPreset(id: "night", body: "#1F1F23", accent: "#0A84FF", lidar: "#64D2FF", brush: "#8E8E93"),
        RobotPreset(id: "bordo", body: "#7A1F2B", accent: "#F7F5F3", lidar: "#FFB4A2", brush: "#2A0E12"),
        RobotPreset(id: "mint", body: "#BFE8D6", accent: "#123C2E", lidar: "#2BD9A0", brush: "#123C2E"),
        RobotPreset(id: "pink", body: "#FFC8DD", accent: "#FF4D8D", lidar: "#FF8FB1", brush: "#7A2948"),
        RobotPreset(id: "gold", body: "#E5C158", accent: "#1A1A1A", lidar: "#FFE08A", brush: "#5A4512"),
    ]
}

/// Every user preference lives here and is persisted to UserDefaults on change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Robot look
    @Published var bodyColor: String { didSet { d.set(bodyColor, forKey: "bodyColor") } }
    @Published var accentColor: String { didSet { d.set(accentColor, forKey: "accentColor") } }
    @Published var lidarColor: String { didSet { d.set(lidarColor, forKey: "lidarColor") } }
    @Published var brushColor: String { didSet { d.set(brushColor, forKey: "brushColor") } }
    @Published var robotSize: Double { didSet { d.set(robotSize, forKey: "robotSize") } }
    @Published var speed: Double { didSet { d.set(speed, forKey: "speed") } }
    @Published var robotName: String { didSet { d.set(robotName, forKey: "robotName") } }

    // Robot behaviour
    @Published var bubbles: Bool { didSet { d.set(bubbles, forKey: "bubbles") } }
    @Published var sound: Bool { didSet { d.set(sound, forKey: "sound") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var scanAnimation: Bool { didSet { d.set(scanAnimation, forKey: "scanAnimation") } }
    @Published var getsStuck: Bool { didSet { d.set(getsStuck, forKey: "getsStuck") } }
    @Published var aboveWindows: Bool { didSet { d.set(aboveWindows, forKey: "aboveWindows") } }
    @Published var showHUD: Bool { didSet { d.set(showHUD, forKey: "showHUD") } }
    @Published var parkOnDesktop: Bool {
        didSet { d.set(parkOnDesktop, forKey: "parkOnDesktop"); CleaningController.shared.refreshParking() }
    }

    // Cleaning
    @Published var targetFolderPath: String { didSet { d.set(targetFolderPath, forKey: "targetFolderPath") } }
    @Published var destination: DestinationMode { didSet { d.set(destination.rawValue, forKey: "destination") } }
    @Published var archiveName: String { didSet { d.set(archiveName, forKey: "archiveName") } }
    @Published var monthFolders: Bool { didSet { d.set(monthFolders, forKey: "monthFolders") } }
    @Published var kindActions: [FileKind: KindAction] {
        didSet {
            d.set(Dictionary(uniqueKeysWithValues: kindActions.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "kindActions")
        }
    }
    @Published var trashExtensions: String { didSet { d.set(trashExtensions, forKey: "trashExtensions") } }
    @Published var trashOlderThanDays: Int { didSet { d.set(trashOlderThanDays, forKey: "trashOlderThanDays") } }
    @Published var collectFolders: Bool { didSet { d.set(collectFolders, forKey: "collectFolders") } }
    @Published var protectWords: String { didSet { d.set(protectWords, forKey: "protectWords") } }
    @Published var skipRecentMinutes: Int { didSet { d.set(skipRecentMinutes, forKey: "skipRecentMinutes") } }
    @Published var confirmBeforeCleaning: Bool { didSet { d.set(confirmBeforeCleaning, forKey: "confirm") } }
    @Published var demoOnly: Bool { didSet { d.set(demoOnly, forKey: "demoOnly") } }

    // Schedule
    @Published var schedule: ScheduleMode { didSet { d.set(schedule.rawValue, forKey: "schedule") } }
    @Published var scheduleHour: Int { didSet { d.set(scheduleHour, forKey: "scheduleHour") } }
    @Published var fileThreshold: Int { didSet { d.set(fileThreshold, forKey: "fileThreshold") } }

    // General
    @Published var language: AppLanguage {
        didSet { d.set(language.rawValue, forKey: "language"); applyLanguage() }
    }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private init() {
        let p = RobotPreset.all[0]
        bodyColor = d.string(forKey: "bodyColor") ?? p.body
        accentColor = d.string(forKey: "accentColor") ?? p.accent
        lidarColor = d.string(forKey: "lidarColor") ?? p.lidar
        brushColor = d.string(forKey: "brushColor") ?? p.brush
        robotSize = d.object(forKey: "robotSize") as? Double ?? 72
        speed = d.object(forKey: "speed") as? Double ?? 280
        robotName = d.string(forKey: "robotName") ?? "Robi"

        bubbles = d.object(forKey: "bubbles") as? Bool ?? true
        sound = d.object(forKey: "sound") as? Bool ?? true
        volume = d.object(forKey: "volume") as? Double ?? 0.5
        scanAnimation = d.object(forKey: "scanAnimation") as? Bool ?? true
        getsStuck = d.object(forKey: "getsStuck") as? Bool ?? true
        aboveWindows = d.object(forKey: "aboveWindows") as? Bool ?? false
        showHUD = d.object(forKey: "showHUD") as? Bool ?? true
        parkOnDesktop = d.object(forKey: "parkOnDesktop") as? Bool ?? false

        targetFolderPath = d.string(forKey: "targetFolderPath") ?? AppSettings.desktopURL.path
        destination = DestinationMode(rawValue: d.string(forKey: "destination") ?? "") ?? .archiveFolder
        archiveName = d.string(forKey: "archiveName") ?? ""
        monthFolders = d.object(forKey: "monthFolders") as? Bool ?? false
        var actions: [FileKind: KindAction] = [:]
        if let raw = d.dictionary(forKey: "kindActions") as? [String: String] {
            for (k, v) in raw { if let kind = FileKind(rawValue: k), let a = KindAction(rawValue: v) { actions[kind] = a } }
        }
        kindActions = actions
        trashExtensions = d.string(forKey: "trashExtensions") ?? ""
        trashOlderThanDays = d.object(forKey: "trashOlderThanDays") as? Int ?? 0
        collectFolders = d.object(forKey: "collectFolders") as? Bool ?? false
        protectWords = d.string(forKey: "protectWords") ?? "DONT DELETE, DON'T DELETE, DO NOT DELETE, KEEP, SİLME, SILME, SAKLA"
        skipRecentMinutes = d.object(forKey: "skipRecentMinutes") as? Int ?? 5
        confirmBeforeCleaning = d.object(forKey: "confirm") as? Bool ?? true
        demoOnly = d.object(forKey: "demoOnly") as? Bool ?? false

        schedule = ScheduleMode(rawValue: d.string(forKey: "schedule") ?? "") ?? .off
        scheduleHour = d.object(forKey: "scheduleHour") as? Int ?? 18
        fileThreshold = d.object(forKey: "fileThreshold") as? Int ?? 0

        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        applyLanguage()
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    var targetFolderURL: URL { URL(fileURLWithPath: targetFolderPath, isDirectory: true) }

    var targetIsDesktop: Bool {
        targetFolderURL.standardizedFileURL.path == AppSettings.desktopURL.standardizedFileURL.path
    }

    var effectiveArchiveName: String {
        return AppSettings.safeFolderName(archiveName) ?? L("archive.default")
    }

    /// A single folder name: no path separators, no "..", not hidden.
    nonisolated static func safeFolderName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("/"), !t.contains(":"), !t.hasPrefix("."), t.count <= 120 else { return nil }
        return t
    }

    var displayName: String {
        let n = robotName.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Robi" : n
    }

    var protectWordList: [String] {
        protectWords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func action(for kind: FileKind) -> KindAction { kindActions[kind] ?? .collect }

    func setAction(_ a: KindAction, for kind: FileKind) {
        var copy = kindActions
        copy[kind] = a
        kindActions = copy
    }

    func applyPreset(_ p: RobotPreset) {
        bodyColor = p.body
        accentColor = p.accent
        lidarColor = p.lidar
        brushColor = p.brush
    }

    func applyLanguage() {
        switch language {
        case .tr: L10n.lang = .tr
        case .en: L10n.lang = .en
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            L10n.lang = first.hasPrefix("tr") ? .tr : .en
        }
        objectWillChange.send()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func scanConfig(screenSize: CGSize) -> ScanConfig {
        ScanConfig(
            actions: kindActions,
            trashExtensions: Set(trashExtensions.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            }.filter { !$0.isEmpty }),
            trashOlderThanDays: trashOlderThanDays,
            collectFolders: collectFolders,
            ownFolders: Set([effectiveArchiveName] + FileKind.allCases.map(\.folderName)),
            protectWords: protectWordList,
            skipRecentMinutes: skipRecentMinutes,
            demoOnly: demoOnly,
            useFinderPositions: targetIsDesktop,
            screenSize: screenSize
        )
    }

    func moverConfig() -> MoverConfig {
        MoverConfig(
            base: targetFolderURL,
            mode: destination,
            archiveName: effectiveArchiveName,
            monthFolders: monthFolders,
            folderNames: Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, $0.folderName) })
        )
    }
}
