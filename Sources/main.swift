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
if arguments.contains("--check-strings") {
    exit(L10n.check() ? 0 : 1)
}
if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

DeskVacApp.main()
