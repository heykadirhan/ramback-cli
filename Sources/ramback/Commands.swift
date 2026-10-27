import Darwin
import Foundation
#if canImport(RambackCore)
import RambackCore
#endif

// MARK: - Commands

func status(json: Bool) async -> Int32 {
    let scanner = Scanner(tools: await Tools.locate())
    let started = Date()
    let items = await scanner.scan()
    let elapsed = Date().timeIntervalSince(started)
    if json {
        print(encode(items))
        return 0
    }
    let pins = pins()
    let total = items.filter(\.counted).reduce(0) { $0 + $1.memory }
    print("Dev stack \(gb(total)) · pressure \(Pressure.current) · swap \(gb(Memory.swapUsed)) · scanned in \(Int(elapsed * 1000)) ms\n")
    for (group, rows) in Dictionary(grouping: items, by: { $0.project ?? $0.kind.group }).sorted(by: { $0.key < $1.key }) {
        print(group)
        for item in rows.sorted(by: { $0.memory > $1.memory }) {
            let by = item.startedBy.map { " · started by \($0)" } ?? ""
            let flags = (pins[item.key] != nil ? " · pinned" : "") + (item.guarded ? " · guarded" : "") + (item.stop == nil ? " · not stoppable" : "")
            print("  \(item.title.padding(toLength: 34, withPad: " ", startingAt: 0)) \(gb(item.memory).leftPad(8))  \(item.kind.rawValue)\(by)\(flags) · \(item.pids.count) proc · \(item.id)")
        }
    }
    return 0
}

func stop(_ target: String, confirmed: Bool, force: Bool, dryRun: Bool, json: Bool) async -> Int32 {
    let tools = await Tools.locate()
    let (rows, exact) = Item.match(target, in: await scanTwice(Scanner(tools: tools)))
    guard !rows.isEmpty else {
        FileHandle.standardError.write(Data("Nothing running matches \(target). `ramback status` lists ids, ports and projects.\n".utf8))
        if json { print("[]") }
        return 2
    }
    let pins = pins()
    var outcomes: [Outcome] = []
    var chosen: [Item] = []
    for row in rows {
        let pinned = pins[row.key] != nil
        if let reason = exact ? row.handRefusal(pinned: pinned, confirmed: confirmed) : row.sweepRefusal(pinned: pinned) {
            outcomes.append(Outcome(row, .skipped, reason))
        } else {
            chosen.append(row)
        }
    }
    if dryRun {
        outcomes += chosen.map { Outcome($0, .wouldStop) }
    } else {
        outcomes += await stopRows(chosen, force: force, reason: "ramback stop", tools: tools)
    }
    print(json ? encode(outcomes) : lines(outcomes, cli: true).joined(separator: "\n"))
    // Picked by hand but pinned or a database: the one refusal --yes lifts.
    if exact, chosen.isEmpty, rows[0].stop != nil {
        if !json { print("Pass --yes to stop it anyway.") }
        return 3
    }
    return exitCode(outcomes)
}

func free(_ target: Double, dryRun: Bool, json: Bool) async -> Int32 {
    let tools = await Tools.locate()
    let items = await scanTwice(Scanner(tools: tools))
    let pins = pins()
    // Nobody confirms these stops, so only rows doing nothing right now, never a simulator someone is using.
    let stoppable = items.filter { $0.sweepRefusal(pinned: pins[$0.key] != nil) == nil && $0.quiet }
    // ponytail: a one-shot CLI has watched for a second, so nothing looks idle yet and only devices and daemons qualify;
    // ask the running app for its idle times if idle dev servers should count too.
    let picked = Pressure.suggestion(stoppable, target: UInt64(target * 1e9), minimum: 0) ?? []
    guard !picked.isEmpty else {
        print(json ? "[]" : "Nothing to free: no simulators, emulators or daemons that aren't pinned or building.")
        return 2
    }
    let outcomes = dryRun ? picked.map { Outcome($0, .wouldStop) } : await stopRows(picked, force: false, reason: "ramback free", tools: tools)
    print(json ? encode(outcomes) : lines(outcomes, cli: true).joined(separator: "\n"))
    let planned = picked.filter(\.counted).reduce(0) { $0 + $1.memory }
    if !json, Double(planned) < target * 1e9 {
        print("That's \(gb(planned)) of the \(gb(UInt64(target * 1e9))) asked; the rest is in use, pinned or a database.")
    }
    return exitCode(outcomes)
}

/// Serves MCP over stdin/stdout until the client closes stdin. Logs nothing to stdout: that's the protocol's channel.
func mcp() async -> Int32 {
    var cache: [Int32: (Date, [String])] = [:]
    let caller = Snapshot.take(argsCache: &cache).agent(above: getpid())
    // Finding tools may ask the login shell; do it while the client says hello.
    let scanner = Task.detached { Scanner(tools: await Tools.locate()) }
    let reason = "\(caller?.name ?? "An agent") via MCP"
    let version = appVersion()
    let run: @Sendable (MCP.Call) async -> MCP.Reply = { call in
        await perform(call, scanner: await scanner.value, caller: caller?.pid, reason: reason)
    }
    while let line = readLine() {
        guard !line.isEmpty, let reply = await MCP.handle(Data(line.utf8), serverVersion: version, run: run) else { continue }
        FileHandle.standardOutput.write(reply + Data("\n".utf8))
    }
    return 0
}

/// One MCP tool call. The agent boundary lives in `Item.agentRefusal`; this only gathers what it needs.
func perform(_ call: MCP.Call, scanner: Scanner, caller: Int32?, reason: String) async -> MCP.Reply {
    /// Every row with why the calling agent may not stop it, if it may not.
    func look() async -> [(item: Item, refusal: String?)] {
        let items = await scanTwice(scanner)
        let pins = pins()
        return items.map { item in (item, item.agentRefusal(pinned: pins[item.key] != nil, owner: item.agentPID, caller: caller)) }
    }
    switch call {
    case .listRunning:
        let rows = await look()
        let total = rows.map(\.item).filter(\.counted).reduce(0) { $0 + $1.memory }
        let running = Running(pressure: "\(Pressure.current)", devStackGB: (Double(total) / 1e8).rounded() / 10,
                              rows: rows.map { AgentRow($0.item, refusal: $0.refusal) })
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys  // same rows, same text: kinder to prompt caches
        return MCP.Reply(String(decoding: (try? encoder.encode(running)) ?? Data(), as: UTF8.self))
    case let .stop(target):
        let rows = await look()
        let matched = Set(Item.match(target, in: rows.map(\.item)).rows.map(\.id))
        guard !matched.isEmpty else { return MCP.Reply("Nothing running matches \(target). list_running shows ids, ports and projects.", isError: true) }
        let picked = rows.filter { matched.contains($0.item.id) }
        let skipped = picked.compactMap { row in row.refusal.map { Outcome(row.item, .skipped, $0) } }
        let allowed = picked.filter { $0.refusal == nil }.map(\.item)
        let outcomes = await stopRows(allowed, force: false, reason: reason, tools: await scanner.tools)
        return MCP.Reply(lines(skipped + outcomes, cli: false).joined(separator: "\n"), isError: exitCode(outcomes) != 0)
    case let .freeMemory(gb, dryRun):
        let stoppable = await look().filter { $0.refusal == nil && $0.item.quiet }.map(\.item)
        let picked = Pressure.suggestion(stoppable, target: UInt64(gb * 1e9), minimum: 0) ?? []
        guard !picked.isEmpty else { return MCP.Reply("Nothing to free: no simulators, emulators or daemons you may stop.") }
        let outcomes = dryRun ? picked.map { Outcome($0, .wouldStop) } : await stopRows(picked, force: false, reason: reason, tools: await scanner.tools)
        return MCP.Reply(lines(outcomes, cli: false).joined(separator: "\n"), isError: exitCode(outcomes) != 0)
    case let .findFreePort(start):
        return Ports.firstFree(from: start).map { MCP.Reply("Port \($0) is free.") } ?? MCP.Reply("No free port from \(start) up.", isError: true)
    }
}

// MARK: - Stopping

struct Outcome: Encodable {
    enum State: String, Encodable {
        case stopped, stillRunning = "still-running", failed, skipped, wouldStop = "would-stop"
    }

    var id: String
    var title: String
    var kind: Item.Kind
    var memory: UInt64
    var state: State
    var reason: String?

    init(_ item: Item, _ state: State, _ reason: String? = nil) {
        id = item.id
        title = item.title
        kind = item.kind
        memory = item.counted ? item.memory : 0
        self.state = state
        self.reason = reason
    }
}

/// Stops side by side like the app does, logs what stopped to Activity, and says how each went.
func stopRows(_ rows: [Item], force: Bool, reason: String, tools: Tools) async -> [Outcome] {
    let results = await withTaskGroup(of: (Item, Stopper.Result).self) { group in
        for item in rows { group.addTask { (item, await Stopper.stop(item, tools: tools, force: force)) } }
        return await group.reduce(into: []) { $0.append($1) }
    }
    let stopped = results.filter { $0.1 == .stopped }.map { Activity($0.0, reason: reason) }
    if !stopped.isEmpty { ActivityLog().update { $0 + stopped } }
    return results.map { item, result in
        switch result {
        case .stopped: Outcome(item, .stopped)
        case .stillRunning: Outcome(item, .stillRunning, "still running after 5 s")
        case let .failed(message): Outcome(item, .failed, message)
        }
    }
}

/// One sentence per row, then what it freed. The CLI can offer --force; an agent never forces, the user decides.
func lines(_ outcomes: [Outcome], cli: Bool) -> [String] {
    var lines = outcomes.map { o in
        switch o.state {
        case .stopped: "Stopped \(o.title) (\(gb(o.memory)))."
        case .wouldStop: "Would stop \(o.title) (\(gb(o.memory)))."
        case .stillRunning: "\(o.title) is still running after 5 s. " + (cli ? "`ramback stop \(o.id) --force` kills it." : "The user can force-stop it in Ramback.")
        case .failed: "Couldn't stop \(o.title): \(o.reason ?? "unknown error")"
        case .skipped: "Left \(o.title) alone: \(o.reason ?? "protected")."
        }
    }
    let freed = outcomes.filter { $0.state == .stopped }.reduce(0) { $0 + $1.memory }
    if freed > 0 { lines.append("Freed \(gb(freed)).") }
    return lines
}

/// 0 when everything chosen stopped (or would), 1 when something failed or held on, 2 when nothing was chosen.
func exitCode(_ outcomes: [Outcome]) -> Int32 {
    if outcomes.contains(where: { $0.state == .failed || $0.state == .stillRunning }) { return 1 }
    return outcomes.contains { $0.state == .stopped || $0.state == .wouldStop } ? 0 : 2
}

// MARK: - MCP rows

struct Running: Encodable {
    var pressure: String
    var devStackGB: Double
    var rows: [AgentRow]
}

/// What list_running shows an agent: enough to decide, without pids or CPU counters.
struct AgentRow: Encodable {
    var id: String
    var title: String
    var kind: Item.Kind
    var project: String?
    var memoryMB: Int
    var ports: [UInt16]
    var startedBy: String?
    var building: Bool
    var canStop: Bool
    var whyNot: String?

    init(_ item: Item, refusal: String?) {
        id = item.id
        title = item.title
        kind = item.kind
        project = item.project
        memoryMB = Int(item.memory / 1_000_000)
        ports = item.ports
        startedBy = item.startedBy
        building = item.building
        canStop = refusal == nil
        whyNot = refusal
    }
}

// MARK: - Helpers

/// Pinned item keys, from the app's own defaults. Read fresh each time: the user may pin something meanwhile.
func pins() -> [String: String] {
    UserDefaults(suiteName: "app.ramback.mac")?.dictionary(forKey: "pins") as? [String: String] ?? [:]
}

/// Two scans two seconds apart: `building` and `quiet` need CPU history before anything decides what's safe to stop.
// ponytail: a short sample can still catch a build between bursts; asking the running app for its Tracker state is the fix.
func scanTwice(_ scanner: Scanner) async -> [Item] {
    _ = await scanner.scan()
    try? await Task.sleep(for: .seconds(2))
    return await scanner.scan()
}

/// The enclosing app's version when the CLI runs from Ramback.app/Contents/Helpers (Homebrew links it there), else "dev".
func appVersion() -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return "dev" }
    let contents = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        .deletingLastPathComponent().deletingLastPathComponent()
    return NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))?["CFBundleShortVersionString"] as? String ?? "dev"
}

func encode<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

extension String {
    func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
