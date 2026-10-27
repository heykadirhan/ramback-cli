import Foundation
import Testing
@testable import RambackCore

private let mb: UInt64 = 1_000_000

private func p(_ pid: Int32, _ ppid: Int32, _ path: String, _ args: [String] = [], cwd: String = "/",
               mb memory: UInt64 = 10, ports: [UInt16] = [], responsible: Int32? = nil) -> Proc {
    Proc(pid: pid, ppid: ppid, path: path, args: args.isEmpty ? [path] : args, cwd: cwd, footprint: memory * mb,
         listening: ports, responsible: responsible)
}

private let udid = "F9E4B8E5-497E-44BE-BE92-B3B08CE788BD"
private let previewsUDID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

/// A day in a React Native developer's life, plus things that must not show up. AnonymizerTests uses it too.
let fixture = World(
    snapshot: Snapshot(procs: [
        // Terminal → interactive zsh → npm run dev → sh -c → next dev → next-server → worker
        p(100, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        p(101, 100, "/bin/zsh", ["-zsh"], cwd: "/p/web"),
        p(102, 101, "/opt/homebrew/bin/node", ["npm", "run", "dev"], cwd: "/p/web"),
        p(103, 102, "/bin/sh", ["sh", "-c", "next dev"], cwd: "/p/web"),
        p(104, 103, "/opt/homebrew/bin/node", ["node", "/p/web/node_modules/.bin/next", "dev"], cwd: "/p/web", mb: 300),
        p(105, 104, "/opt/homebrew/bin/node", ["next-server (v16.1.6) "], cwd: "/p/web", mb: 900, ports: [3000]),
        p(106, 105, "/opt/homebrew/bin/node", ["node", "/p/web/.next/postcss.js"], cwd: "/p/web", mb: 80),
        // Claude Code → zsh -c → bun dev server; and an MCP server that doesn't listen.
        p(200, 101, "/Users/me/.local/bin/claude", cwd: "/p/api", mb: 200),
        p(201, 200, "/bin/zsh", ["/bin/zsh", "-c", "bun run dev"], cwd: "/p/api"),
        p(202, 201, "/opt/homebrew/bin/bun", ["bun", "run", "dev"], cwd: "/p/api", mb: 120, ports: [4000]),
        p(203, 200, "/opt/homebrew/bin/node", ["node", "/p/api/mcp/main.js"], cwd: "/p/api", mb: 60),
        // Metro, started by hand.
        p(210, 101, "/opt/homebrew/bin/node", ["node", "/p/app/node_modules/.bin/react-native", "start"], cwd: "/p/app", mb: 400, ports: [8081]),
        // A booted simulator with two processes inside, an Xcode Previews device, and Simulator.app.
        p(300, 1, "/Library/Developer/CoreSimulator/launchd_sim",
          ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"], mb: 20),
        p(301, 300, "/Library/Developer/CoreSimulator/SpringBoard", mb: 600),
        p(302, 300, "/Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/MyApp.app/MyApp", mb: 400),
        p(310, 1, "/Library/Developer/CoreSimulator/launchd_sim",
          ["launchd_sim", "/Users/me/Library/Developer/Xcode/UserData/Previews/Simulator Devices/\(previewsUDID)/data/var/run/launchd_bootstrap.plist"]),
        p(320, 1, "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", mb: 150),
        // Android: emulator, a Gradle daemon and the Kotlin daemon it started.
        p(400, 1, "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64",
          ["qemu-system-aarch64", "-avd", "Pixel_8_API_35", "-netdelay", "none"], mb: 3100, ports: [5554, 5555]),
        p(410, 1, "/usr/bin/java", ["java", "-cp", "/x/gradle-daemon-main-8.7.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.7"],
          cwd: "/Users/me/.gradle/daemon/8.7", mb: 1300),
        p(411, 410, "/usr/bin/java", ["java", "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"], mb: 700),
        // Postgres and its workers, Xcode and its helper.
        p(500, 1, "/opt/homebrew/opt/postgresql@16/bin/postgres", ["postgres", "-D", "/opt/homebrew/var/postgresql@16"],
          cwd: "/opt/homebrew/var/postgresql@16", mb: 30, ports: [5432]),
        p(501, 500, "/opt/homebrew/opt/postgresql@16/bin/postgres", mb: 5),
        p(502, 500, "/opt/homebrew/opt/postgresql@16/bin/postgres", mb: 5),
        p(600, 1, "/Applications/Xcode.app/Contents/MacOS/Xcode", mb: 900),
        p(601, 1, "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService", mb: 1100),
        // OrbStack: the app, and the VM in Virtualization.framework's XPC service.
        p(700, 1, "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper", mb: 100),
        p(701, 1, "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
          mb: 2000, responsible: 700),
        // Not dev servers: an app listening on a port, a daemon run from /, an ngrok tunnel is fine though.
        p(800, 1, "/Applications/Spotify.app/Contents/MacOS/Spotify", ports: [57621]),
        p(801, 1, "/opt/homebrew/bin/syncthing", cwd: "/", ports: [8384]),
        p(802, 101, "/opt/homebrew/bin/ngrok", ["ngrok", "http", "3000"], cwd: "/p/web"),
    ]),
    simulators: [udid: "iPhone 17 Pro", previewsUDID: "iPhone 17"],
    containers: [
        Container(id: "c1", name: "api-db-1", image: "postgres:16", project: "api", memory: 80 * mb),
        Container(id: "c2", name: "api-worker-1", image: "node:22", project: "api", memory: 150 * mb),
    ]
)

private let items = detect(fixture)
private func row(_ title: String) throws -> Item { try #require(items.first { $0.title == title }, "no row titled \(title)") }

@Test func everyProcessHasAtMostOneOwner() {
    let pids = items.flatMap(\.pids)
    #expect(pids.count == Set(pids).count)
}

@Test func devServerStopsTheWholeCommandButNotTheShell() throws {
    let next = try row("Next.js :3000")
    #expect(next.pids.first == 102)  // npm run dev
    #expect(Set(next.pids) == [102, 103, 104, 105, 106])
    #expect(next.memory == 1300 * mb)
    #expect(next.startedBy == "Terminal")
    #expect(next.cwd == "/p/web")
    #expect(next.stop == .signal)
}

@Test func agentKeepsItsLeftoversAndStopsOnlyByHand() throws {
    let bun = try row("Bun :4000")
    #expect(bun.pids == [201, 202])  // zsh -c belongs to the command, claude doesn't
    #expect(bun.startedBy == "Claude Code")
    let agent = try row("Claude Code")
    #expect(Set(agent.pids) == [200, 203])
    #expect(agent.stop == .signal)
    #expect(agent.guarded)
}

@Test func mobileStack() throws {
    #expect(try row("Metro :8081").kind == .bundler)

    let sim = try row("iPhone 17 Pro")
    #expect(sim.memory == 1020 * mb)
    #expect(sim.stop == .simulator(udid: udid, previews: false))
    #expect(try row("Xcode Previews · iPhone 17").stop == .simulator(udid: previewsUDID, previews: true))
    #expect(try row("Simulator app").kind == .simulatorApp)

    let emulator = try row("Pixel 8 API 35")
    #expect(emulator.stop == .emulator(serial: "emulator-5554"))

    let gradle = try row("Gradle daemon 8.7")
    #expect(gradle.pids == [410])
    #expect(gradle.key == "gradle 8.7")
    #expect(try row("Kotlin daemon").pids == [411])
}

@Test func databasesAndXcodeHelpersAreGuarded() throws {
    let postgres = try row("PostgreSQL :5432")
    #expect(postgres.guarded)
    #expect(Set(postgres.pids) == [500, 501, 502])
    #expect(try row("SourceKitService").guarded)  // Xcode is open
    #expect(try row("api-db-1").guarded)
    #expect(try !row("api-worker-1").guarded)
}

@Test func dockerVMIsCountedOnceAndContainersLiveInsideIt() throws {
    let vm = try row("OrbStack")
    #expect(Set(vm.pids) == [700, 701])
    #expect(vm.stop == nil)
    let worker = try row("api-worker-1")
    #expect(!worker.counted)
    #expect(worker.project == "api")
    #expect(worker.stop == .containers(["c2"]))
}

@Test func appsAndDaemonsAreNotDevServers() {
    let owned = Set(items.flatMap(\.pids))
    #expect(!owned.contains(800))
    #expect(!owned.contains(801))
    #expect(items.contains { $0.title == "ngrok" && $0.kind == .tunnel })
}

@Test func trackerTellsBuildingFromIdle() {
    var tracker = Tracker()
    var item = Item(id: "gradle:1", key: "gradle", kind: .gradle, title: "Gradle", pids: [1])
    let start = Date()
    _ = tracker.update([item], at: start)
    item.cpuTime = 4_000_000_000  // 4 s of CPU in 5 s
    #expect(tracker.update([item], at: start + 5).first?.building == true)
    // Then nothing for 11 minutes.
    var idle: Item?
    for minute in 1...11 { idle = tracker.update([item], at: start + 5 + Double(minute) * 60).first }
    #expect(idle?.building == false)
    #expect(idle?.idleSince == start + 5)
}

@Test func dockerOutputParses() {
    let ps = #"{"ID":"abc","Names":"api-db-1","Image":"postgres:16","Labels":"com.docker.compose.project=api,com.docker.compose.service=db"}"#
    let stats = #"{"ID":"abc","Name":"api-db-1","MemUsage":"56.5MiB / 7.75GiB"}"#
    let containers = Tools.parseContainers(ps: Data(ps.utf8), stats: Data(stats.utf8))
    #expect(containers == [Container(id: "abc", name: "api-db-1", image: "postgres:16", project: "api", memory: UInt64(56.5 * 1_048_576))])
    #expect(Tools.parseSize("1.2GB") == 1_200_000_000)
}

@Test func theLoginShellIsAskedOnceADayPerMissingTool() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A suite named by a path keeps its plist there, out of ~/Library/Preferences.
    let defaults = try #require(UserDefaults(suiteName: dir.appendingPathComponent("defaults").path))
    // A login shell that never finds anything and counts how often it's asked.
    let shell = dir.appendingPathComponent("shell"), log = dir.appendingPathComponent("asked")
    try "#!/bin/sh\necho >> '\(log.path)'\nexit 1\n".write(to: shell, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    func asked() -> Int { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").count }

    // Which tools are missing depends on this Mac; the usual places are looked in first.
    let missing = Set(Tools.names).subtracting(await Tools.locate(defaults: defaults, shell: shell.path).paths.keys)
    #expect(asked() == missing.count)
    _ = await Tools.locate(defaults: defaults, shell: shell.path)
    #expect(asked() == missing.count)
    defaults.set(Dictionary(uniqueKeysWithValues: missing.map { ($0, Date(timeIntervalSinceNow: -2 * 86400)) }), forKey: "toolMisses")
    _ = await Tools.locate(defaults: defaults, shell: shell.path)
    #expect(asked() == 2 * missing.count)
    // A path set by hand that doesn't work asks the shell again at once.
    if let name = missing.first {
        _ = await Tools.locate(overrides: [name: "/nonexistent"], defaults: defaults, shell: shell.path)
        #expect(asked() == 2 * missing.count + 1)
    }
}

@Test func pythonFromAFrameworkIsAServerNotAnApp() throws {
    let python = "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
    let items = detect(World(snapshot: Snapshot(procs: [
        p(100, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        p(101, 100, "/bin/zsh", ["-zsh"], cwd: "/p/blog"),
        p(102, 101, python, ["python3", "manage.py", "runserver"], cwd: "/p/blog", mb: 60, ports: [8000]),
    ])))
    let server = try #require(items.first { $0.kind == .server })
    #expect(server.title == "Django :8000")
    #expect(server.pids == [102])
    #expect(server.startedBy == "Terminal")
}

/// Stop on a dev server ends the command that started it, never the agent or editor it was started from.
@Test func stopNeverClimbsIntoAnAgentOrAnEditor() throws {
    let python = "/opt/homebrew/Cellar/python@3.14/3.14.0/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
    let world = World(snapshot: Snapshot(procs: [
        // Claude Code from its native installer: the binary is named after its version, argv[0] says claude.
        p(900, 1, "/Users/me/.local/share/claude/versions/2.1.296", ["claude"], cwd: "/p/x", mb: 300),
        p(901, 900, "/bin/zsh", ["/bin/zsh", "-c", "python3 -m http.server 8000"], cwd: "/p/x"),
        p(902, 901, python, ["python3", "-m", "http.server", "8000"], cwd: "/p/x", ports: [8000]),
        // nvim's :!npm run dev, from the same folder.
        p(910, 1, "/opt/homebrew/bin/nvim", ["nvim", "."], cwd: "/p/y", mb: 80),
        p(911, 910, "/bin/zsh", ["/bin/zsh", "-c", "npm run dev"], cwd: "/p/y"),
        p(912, 911, "/opt/homebrew/bin/node", ["node", "/p/y/node_modules/.bin/vite"], cwd: "/p/y", ports: [5173]),
        // Apple's python3, from Xcode's developer folder.
        p(920, 1, "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
          ["/usr/bin/python3", "-m", "http.server", "9000"], cwd: "/p/z", ports: [9000]),
    ]))
    let items = detect(world)
    let python3 = try #require(items.first { $0.ports == [8000] })
    #expect(python3.pids.sorted() == [901, 902])
    #expect(python3.startedBy == "Claude Code")
    #expect(python3.agentPID == 900)
    #expect(items.contains { $0.kind == .agent && $0.pids == [900] })
    let vite = try #require(items.first { $0.ports == [5173] })
    #expect(!vite.pids.contains(910))
    #expect(items.contains { $0.ports == [9000] && $0.kind == .server })
}
