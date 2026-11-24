import AppKit
import Foundation

let arguments = CommandLine.arguments

if let i = arguments.firstIndex(of: "--render-icon"), i + 1 < arguments.count {
    MainActor.assumeIsolated { IconRenderer.render(to: URL(fileURLWithPath: arguments[i + 1])) }
    exit(0)
}
if let i = arguments.firstIndex(of: "--render-robots"), i + 1 < arguments.count {
    MainActor.assumeIsolated { IconRenderer.renderRobots(to: URL(fileURLWithPath: arguments[i + 1])) }
    exit(0)
}
if let i = arguments.firstIndex(of: "--reel-art"), i + 1 < arguments.count {
    let badge = i + 2 < arguments.count ? URL(fileURLWithPath: arguments[i + 2]) : nil
    MainActor.assumeIsolated { ReelArt.render(to: URL(fileURLWithPath: arguments[i + 1]), badge: badge) }
    exit(0)
}
if arguments.contains("--stage-test") {
    // Hides the real desktop items for 3 seconds, then brings them back and checks the count.
    MainActor.assumeIsolated {
        let before = (try? FileManager.default.contentsOfDirectory(at: AppSettings.desktopURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count) ?? -1
        StageDesk.hideReal()
        let during = (try? FileManager.default.contentsOfDirectory(at: AppSettings.desktopURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count) ?? -1
        Thread.sleep(forTimeInterval: 3)
        StageDesk.restore()
        let after = (try? FileManager.default.contentsOfDirectory(at: AppSettings.desktopURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count) ?? -1
        print("visible before \(before), during \(during), after \(after); list left: \(FileManager.default.fileExists(atPath: StageDesk.file.path))")
        exit(before == after && during == 0 ? 0 : 1)
    }
}
if arguments.contains("--check-strings") {
    exit(L10n.check() ? 0 : 1)
}
if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

DeskVacApp.main()
