import Foundation
import SwiftUI
import UserNotifications
import SimpleXChat

final class FPExperiment {
    static let shared = FPExperiment()
    private var timer: Timer?
    private var caseName: String?

    func start() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-fpxCase"), i + 1 < args.count {
            caseName = args[i + 1]
            runCase(args[i + 1])
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            fpxLog("notifications", "granted=\(granted ? 1 : 0)")
        }
        launchProbe {}
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.readCommand() }
    }

    private func launchProbe(_ end: @escaping () -> Void) {
        let probe = FPProbe.shared
        probe.run(caller: "app", tag: "launch", methods: [.root], budget: 5, hold: true) { summary in
            if summary.hasPrefix("root:ok") {
                probe.run(caller: "app", tag: "launch-methods", methods: [.item, .manager, .restricted], budget: 5) { _ in end() }
            } else {
                probe.listDomains(caller: "app", tag: "launch-domains") {
                    probe.run(caller: "app", tag: "launch-after-domains", methods: FPProbeMethod.allCases, budget: 5, hold: true) { _ in end() }
                }
            }
        }
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard caseName == nil else { return }
        FPProbe.shared.run(caller: "app", tag: "scene-\(phase)", methods: [.root], budget: 3) { _ in }
    }

    private func runCase(_ name: String) {
        let probe = FPProbe.shared
        let end = { fpxLog("done", "caller=app tag=case-end name=\(name)") }
        fpxLog("case", "name=\(name)")
        switch name {
        case "launch":
            launchProbe(end)
        case "url":
            probe.run(caller: "app", tag: "case", methods: [.root], budget: 60) { _ in end() }
        case "url-dir":
            probe.run(caller: "app", tag: "case", methods: [.root], budget: 60, storage: .directory) { _ in end() }
        case "url-none":
            probe.run(caller: "app", tag: "case", methods: [.root], budget: 30, storage: .none) { _ in
                probe.run(caller: "app", tag: "case-after", methods: [.root], budget: 30, storage: .directory) { _ in end() }
            }
        case "service":
            probe.run(caller: "app", tag: "case", methods: [.manager], budget: 30, storage: .none) { _ in
                probe.run(caller: "app", tag: "case-after", methods: [.root], budget: 30, storage: .none) { _ in end() }
            }
        case "domains":
            probe.listDomains(caller: "app", tag: "case-domains") {
                probe.run(caller: "app", tag: "case", methods: [.root], budget: 60) { _ in end() }
            }
        default:
            fpxLog("case", "unknown=\(name)")
            end()
        }
    }

    private func readCommand() {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_NAME)?.appendingPathComponent("fpx-cmd"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return }
        let tag = words[0]
        let arg = words.count > 2 ? words[2] : "all"
        let budget = words.count > 3 ? Double(words[3]) ?? 5 : 5
        fpxLog("command", "tag=\(tag) command=\(words[1]) arg=\(arg)")
        switch words[1] {
        case "probe":
            let methods = arg == "all" ? FPProbeMethod.allCases : arg.split(separator: ",").compactMap { FPProbeMethod(rawValue: String($0)) }
            FPProbe.shared.run(caller: "app", tag: tag, methods: methods, budget: budget) { _ in }
        case "hold":
            FPProbe.shared.run(caller: "app", tag: tag, methods: [.root], budget: budget, hold: true) { _ in }
        case "burst":
            FPProbe.shared.run(caller: "app", tag: tag, methods: Array(repeating: .root, count: Int(arg) ?? 10), budget: budget) { _ in }
        case "held":
            FPProbe.shared.pingHeld(caller: "app", tag: tag, timeout: budget) {}
        case "release":
            FPProbe.shared.release(caller: "app", tag: tag) {}
        case "crash":
            FPProbe.shared.crash(caller: "app", tag: tag) {}
        default:
            fpxLog("done", "caller=app tag=\(tag) unknown=1")
        }
    }
}
