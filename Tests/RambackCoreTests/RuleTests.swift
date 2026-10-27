import Foundation
import Testing
@testable import RambackCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func row(_ kind: Item.Kind, _ title: String, gb: Double = 1, idleHours: Double? = nil, startedHoursAgo: Double = 1,
                 by: String? = nil, cwd: String? = nil, key: String? = nil, stop: Stop = .signal) -> Item {
    var item = Item(id: "\(kind):\(title)", key: key ?? title, kind: kind, title: title, cwd: cwd, startedBy: by,
                    pids: [1], memory: UInt64(gb * 1e9), started: now.addingTimeInterval(-startedHoursAgo * 3600), stop: stop)
    item.idleSince = idleHours.map { now.addingTimeInterval(-$0 * 3600) }
    return item
}

private func titles(_ rule: Rule, _ trigger: Rule.Trigger, _ items: [Item], value: Int? = nil, all: [Item]? = nil,
                    agentEnded: Set<String> = [], gone: Set<String> = []) -> [String] {
    rule.stops(on: trigger, value: value ?? rule.value?.default ?? 0, stoppable: items, all: all ?? items,
               agentEnded: agentEnded, now: now, folderGone: gone.contains).map(\.title)
}

@Test func quitRulesOnlyFireForTheirApp() {
    let items = [row(.simulator, "iPhone"), row(.emulator, "Pixel"), row(.gradle, "Gradle"), row(.server, "Vite")]
    #expect(titles(.xcodeQuit, .quit(bundleID: "com.apple.dt.Xcode"), items) == ["iPhone"])
    #expect(titles(.xcodeQuit, .quit(bundleID: "com.google.android.studio"), items).isEmpty)
    #expect(titles(.studioQuit, .quit(bundleID: "com.google.android.studio"), items) == ["Pixel", "Gradle"])
    #expect(titles(.studioQuit, .scan, items).isEmpty)
}

@Test func batteryWaitsForItsPercent() {
    let items = [row(.simulator, "iPhone"), row(.server, "Vite")]
    #expect(titles(.battery, .battery(80), items, value: 100) == ["iPhone"])
    #expect(titles(.battery, .battery(40), items, value: 30).isEmpty)
    #expect(titles(.battery, .battery(30), items, value: 30) == ["iPhone"])
}

@Test func idleRulesUseTheirThreshold() {
    let items = [row(.gradle, "fresh", idleHours: 0.3), row(.gradle, "stale", idleHours: 2), row(.gradle, "busy"),
                 row(.server, "Vite", idleHours: 4), row(.server, "Next", idleHours: 1)]
    #expect(titles(.idleDaemons, .scan, items, value: 60) == ["stale"])
    #expect(titles(.idleServers, .scan, items, value: 3) == ["Vite"])
}

@Test func maxDevicesStopsTheOldestIdleOne() {
    let old = row(.emulator, "old", idleHours: 1, startedHoursAgo: 5)
    let older = row(.emulator, "older", idleHours: 1, startedHoursAgo: 9)
    let busy = row(.emulator, "busy", startedHoursAgo: 20)
    #expect(titles(.maxDevices, .scan, [old, older, busy], value: 2) == ["older"])
    #expect(titles(.maxDevices, .scan, [old, older, busy], value: 3).isEmpty)
    // A pinned device counts toward the limit without being stopped itself.
    #expect(titles(.maxDevices, .scan, [old], value: 1, all: [old, busy]) == ["old"])
    // Xcode Previews devices neither count nor get stopped: Xcode would boot them right back.
    let phone = row(.simulator, "iPhone", startedHoursAgo: 3)
    let preview = row(.simulator, "Previews", idleHours: 1, startedHoursAgo: 4, stop: .simulator(udid: "P", previews: true))
    #expect(titles(.maxDevices, .scan, [phone, preview], value: 1).isEmpty)
}

@Test func agentLeftoversAndDeletedFolders() {
    let orphan = row(.server, "orphan", by: nil, cwd: "/p/a")
    let live = row(.server, "live", by: "Claude Code", cwd: "/p/b")
    let mine = row(.server, "mine", by: "Terminal", cwd: "/p/gone")
    #expect(titles(.agentEnded, .scan, [orphan, live, mine], agentEnded: [orphan.id]) == ["orphan"])
    #expect(titles(.folderDeleted, .scan, [orphan, live, mine], gone: ["/p/gone"]) == ["mine"])
    #expect(!Rule.folderGone(NSHomeDirectory()))
    #expect(Rule.folderGone("/definitely/not/here"))
}

@Test func pressureOffersIdleRowsFirstAndNeverBusyServers() throws {
    let items = [row(.emulator, "Pixel", gb: 3.1), row(.gradle, "Gradle", gb: 1.3, idleHours: 2),
                 row(.server, "Next", gb: 0.7), row(.server, "Vite", gb: 0.3, idleHours: 7), row(.simulator, "iPhone", gb: 1.8)]
    let picked = try #require(Pressure.suggestion(items, target: 4_000_000_000)).map(\.title)
    #expect(picked == ["Gradle", "Vite", "Pixel"])
    #expect(Pressure.suggestion([row(.server, "Next", gb: 2)], target: 4_000_000_000) == nil)
}

@Test func undoBringsBackDevicesAndContainersOnly() {
    #expect(row(.simulator, "iPhone", stop: .simulator(udid: "U", previews: false)).undo == .boot(udid: "U"))
    #expect(row(.simulator, "Previews", stop: .simulator(udid: "U", previews: true)).undo == nil)
    #expect(row(.emulator, "Pixel", key: "avd:Pixel_8", stop: .emulator(serial: nil)).undo == .avd("Pixel_8"))
    #expect(row(.container, "db", stop: .containers(["c1"])).undo == .start(["c1"]))
    #expect(row(.server, "Vite").undo == nil)
}

@Test func activityRoundTripsAndSumsTheWeek() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-test-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let log = ActivityLog(url: url)
    var undone = Activity(row(.simulator, "iPhone", gb: 2), reason: "You", date: now)
    undone.undone = true
    let entries = [Activity(row(.gradle, "Gradle", gb: 1.5), reason: "idleDaemons", date: now),
                   Activity(row(.server, "Vite", gb: 9), reason: "You", date: now.addingTimeInterval(-30 * 86400)), undone]
    log.save(entries)
    #expect(log.load() == entries)
    #expect(ActivityLog.freedThisWeek(entries, now: now) == 1_500_000_000)
}

@Test func activityWritersDontDropEachOthersEntries() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-test-\(UUID().uuidString).jsonl")
    defer { for path in [url.path, url.path + ".lock"] { try? FileManager.default.removeItem(atPath: path) } }
    // The app, the CLI and the MCP server each load, add and save at once.
    DispatchQueue.concurrentPerform(iterations: 20) { i in
        ActivityLog(url: url).update { $0 + [Activity(row(.server, "s\(i)"), reason: "You", date: now)] }
    }
    #expect(ActivityLog(url: url).load().count == 20)
}
