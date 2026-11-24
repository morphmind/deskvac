import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            if !settings.hasOnboarded {
                WelcomeBanner()
            }
            TabView(selection: $tab) {
                RobotTab().tabItem { Label(L("tab.robot"), systemImage: "circle.circle") }.tag(0)
                CleaningTab().tabItem { Label(L("tab.cleaning"), systemImage: "tray.full") }.tag(1)
                ScheduleTab().tabItem { Label(L("tab.schedule"), systemImage: "clock") }.tag(2)
                GeneralTab().tabItem { Label(L("tab.general"), systemImage: "gearshape") }.tag(3)
            }
            .padding(.top, 8)
        }
        .frame(width: 620, height: settings.hasOnboarded ? 600 : 760)
        .environment(\.locale, Locale(identifier: L10n.lang.rawValue))
    }
}

struct WelcomeBanner: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RobotPreview(height: 120, roam: false).frame(width: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("welcome.title", settings.displayName)).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(L("welcome.body")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("welcome.note")).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                HStack {
                    Button(L("welcome.demo")) {
                        settings.hasOnboarded = true
                        settings.demoOnly = true
                        DemoClutter.make()
                    }
                    Button(L("welcome.clean")) {
                        settings.hasOnboarded = true
                        CleaningController.shared.start(.clean)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L("welcome.later")) { settings.hasOnboarded = true }.buttonStyle(.link)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }
}

/// A live robot that wanders in a little box so color and shape changes show instantly.
struct RobotPreview: View {
    var height: Double = 150
    var roam = true
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let r = min(settings.robotSize / 2, size.height * 0.36)
                let c: CGPoint
                let heading: Double
                if roam {
                    let w = max(10, size.width / 2 - r - 20)
                    let speedK = settings.speed / 280
                    let a = t * 0.55 * speedK
                    c = CGPoint(x: size.width / 2 + cos(a) * w, y: size.height / 2 + sin(a * 2) * (size.height / 2 - r - 10) * 0.6)
                    let dx = -sin(a) * w, dy = cos(a * 2) * 2 * (size.height / 2 - r - 10) * 0.6
                    heading = atan2(dy, dx)
                } else {
                    c = CGPoint(x: size.width / 2, y: size.height / 2)
                    heading = -.pi / 2 + sin(t * 0.8) * 0.5
                }
                RobotPainter.draw(ctx, pose: RobotPose(center: c, heading: heading, radius: r, brushAngle: t * 14,
                                                       lidarAngle: t * 5, glow: 0.6 + 0.4 * sin(t * 3)),
                                  style: RobotStyle.current())
            }
        }
        .frame(height: height)
    }
}

struct RobotTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                RobotPreview(height: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: "#3A2E5C"), Color(hex: "#C86B6B")],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets())
                HStack(spacing: 10) {
                    ForEach(RobotPreset.all) { p in
                        Button { settings.applyPreset(p) } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle().fill(Color(hex: p.body))
                                    Circle().strokeBorder(.black.opacity(0.15))
                                    Circle().fill(Color(hex: p.accent)).frame(width: 8, height: 8).offset(y: 9)
                                }
                                .frame(width: 30, height: 30)
                                Text(L("preset.\(p.id)")).font(.system(size: 10.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            } header: { Text(L("set.presets")) }

            Section(L("set.colors")) {
                colorRow(L("set.body"), \.bodyColor)
                colorRow(L("set.accent"), \.accentColor)
                colorRow(L("set.lidar"), \.lidarColor)
                colorRow(L("set.brush"), \.brushColor)
            }

            Section(L("set.shape")) {
                LabeledContent(L("set.size")) {
                    Slider(value: $settings.robotSize, in: 44...140, step: 2)
                }
                LabeledContent(L("set.speed")) {
                    Slider(value: $settings.speed, in: 120...700, step: 10)
                }
                TextField(L("set.name"), text: $settings.robotName)
            }

            Section(L("set.behavior")) {
                Toggle(isOn: $settings.parkOnDesktop) {
                    Text(L("set.park"))
                    Text(L("set.park.help"))
                }
                Toggle(L("set.bubbles"), isOn: $settings.bubbles)
                Toggle(L("set.scanAnim"), isOn: $settings.scanAnimation)
                Toggle(L("set.stuck"), isOn: $settings.getsStuck)
                Toggle(L("set.hud"), isOn: $settings.showHUD)
                Toggle(isOn: $settings.aboveWindows) {
                    Text(L("set.above"))
                    Text(L("set.above.help"))
                }
                Toggle(L("set.sound"), isOn: $settings.sound)
                if settings.sound {
                    LabeledContent(L("set.volume")) { Slider(value: $settings.volume, in: 0...1) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, _ key: ReferenceWritableKeyPath<AppSettings, String>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(hex: settings[keyPath: key]) },
            set: { settings[keyPath: key] = hexString(from: $0) }
        ), supportsOpacity: false)
    }
}

struct CleaningTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent(L("set.folder")) {
                    HStack {
                        Text(settings.targetIsDesktop ? L("set.desktop") : settings.targetFolderURL.lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button(L("set.choose")) { chooseFolder() }
                        if !settings.targetIsDesktop {
                            Button(L("set.desktop")) { settings.targetFolderPath = AppSettings.desktopURL.path }
                        }
                    }
                }
                if !settings.targetIsDesktop {
                    Text(L("set.folder.help")).font(.caption).foregroundStyle(.secondary)
                }
                Picker(L("set.dest"), selection: $settings.destination) {
                    ForEach(DestinationMode.allCases) { Text(L("dest.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if settings.destination == .archiveFolder {
                    TextField(L("set.archiveName"), text: $settings.archiveName, prompt: Text(L("archive.default")))
                }
                Toggle(L("set.month"), isOn: $settings.monthFolders)
            }

            Section(L("set.kinds")) {
                ForEach(FileKind.fileKinds) { kind in
                    Picker(selection: Binding(
                        get: { settings.action(for: kind) },
                        set: { settings.setAction($0, for: kind) }
                    )) {
                        ForEach(KindAction.allCases) { Text(L("action.\($0.rawValue)")).tag($0) }
                    } label: {
                        Label(kind.folderName, systemImage: kind.symbol)
                    }
                }
            }

            Section {
                DisclosureGroup(L("set.advanced")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L("set.trashExt"), text: $settings.trashExtensions, prompt: Text("dmg, pkg"))
                        Text(L("set.trashExt.help")).font(.caption).foregroundStyle(.secondary)
                        Stepper(value: $settings.trashOlderThanDays, in: 0...365, step: 7) {
                            Text(settings.trashOlderThanDays == 0 ? L("set.trashAge.any") : L("set.trashAge", settings.trashOlderThanDays))
                        }
                        Label(L("set.trash.help"), systemImage: "arrow.uturn.backward.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Toggle(isOn: $settings.collectFolders) {
                            Text(L("set.folders"))
                            Text(L("set.folders.help"))
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section(L("set.protect")) {
                TextField(L("set.protectWords"), text: $settings.protectWords, axis: .vertical)
                    .lineLimit(2...4)
                Text(L("set.protect.help")).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $settings.skipRecentMinutes, in: 0...240, step: 5) {
                    Text(L("set.recent", settings.skipRecentMinutes))
                }
                Toggle(L("set.confirm"), isOn: $settings.confirmBeforeCleaning)
                Label(L("set.never"), systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.targetFolderURL
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { settings.targetFolderPath = url.path }
    }
}

struct ScheduleTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section(L("set.auto")) {
                Picker(L("set.auto"), selection: $settings.schedule) {
                    ForEach(ScheduleMode.allCases) { Text(L("schedule.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.schedule == .daily {
                    Picker(L("set.hour"), selection: $settings.scheduleHour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                }
            }
            Section {
                Stepper(value: $settings.fileThreshold, in: 0...500, step: 5) {
                    LabeledContent(L("set.threshold")) {
                        Text(settings.fileThreshold == 0 ? L("set.threshold.off") : "\(settings.fileThreshold)")
                            .monospacedDigit()
                    }
                }
                Text(L("set.threshold.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("set.login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: CleaningController
    @State private var folderOK: Bool?
    @State private var finderOK: Bool?

    var body: some View {
        Form {
            Section(L("set.language")) {
                Picker(L("set.language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text(L("lang.\($0.rawValue)")).tag($0) }
                }
            }

            Section(L("set.demo")) {
                Toggle(isOn: $settings.demoOnly) {
                    Text(L("set.demoOnly"))
                    Text(L("set.demoOnly.help"))
                }
                HStack {
                    Button(L("menu.demo.make")) { DemoClutter.make() }
                    Button(L("menu.demo.clear")) { DemoClutter.clear() }
                }
            }

            Section(L("set.permissions")) {
                permRow(L("perm.desktop"), folderOK)
                permRow(L("perm.finder"), finderOK)
                HStack {
                    Text(L("perm.help")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("perm.check")) { checkPermissions() }
                }
            }

            Section(L("set.history")) {
                if let j = controller.lastJournal {
                    LabeledContent(L("set.lastClean", j.date.formatted(date: .abbreviated, time: .shortened), j.moves.count)) {
                        Button(L("menu.undo")) { controller.undoLast() }.disabled(controller.isRunning)
                    }
                } else {
                    Text(L("set.noHistory")).foregroundStyle(.secondary)
                }
            }

            Section(L("set.about")) {
                HStack(spacing: 12) {
                    RobotBadge(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DeskVac").font(.headline)
                        Text(L("app.tagline")).font(.caption).foregroundStyle(.secondary)
                        Text(L("about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Link("GitHub", destination: Links.repo)
                    Link("onore.io", destination: Links.onore)
                }
                Text(L("about.body")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { checkPermissions() }
    }

    private func permRow(_ title: String, _ ok: Bool?) -> some View {
        LabeledContent(title) {
            if let ok {
                Label(ok ? L("perm.ok") : L("perm.missing"), systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            } else {
                Text("…").foregroundStyle(.secondary)
            }
        }
    }

    private func checkPermissions() {
        folderOK = (try? FileManager.default.contentsOfDirectory(atPath: settings.targetFolderPath)) != nil
        finderOK = FinderBridge.desktopPositions() != nil
    }
}
