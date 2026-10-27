import Darwin
import Foundation

/// The built-in automations. Each has a switch and at most one number; there's no rule editor.
public enum Rule: String, CaseIterable, Codable, Sendable {
    case xcodeQuit, studioQuit, battery, sleep, idleDaemons, idleServers, maxDevices, agentEnded, folderDeleted, endOfDay

    public var onByDefault: Bool { [.xcodeQuit, .studioQuit, .idleDaemons].contains(self) }

    /// The rule's one number, and the choices offered for it.
    /// battery: percent (100 = as soon as it's unplugged) · idleDaemons: minutes · idleServers: hours ·
    /// maxDevices: devices of each kind · endOfDay: minutes after midnight.
    public var value: (default: Int, choices: [Int])? {
        switch self {
        case .battery: (100, [100, 50, 30, 20])
        case .idleDaemons: (60, [15, 30, 60, 120])
        case .idleServers: (3, [1, 3, 6, 12])
        case .maxDevices: (1, [1, 2, 3])
        case .endOfDay: (18 * 60, [17 * 60, 18 * 60, 19 * 60, 20 * 60, 22 * 60])
        default: nil
        }
    }

    public enum Trigger: Sendable, Equatable {
        case quit(bundleID: String)
        case sleep
        /// On battery at this percent, sent once when it gets there.
        case battery(Int)
        /// After every scan.
        case scan
    }

    /// What this rule stops now. `stoppable` already leaves out pins, databases, anything building or mid-stop;
    /// `all` is every row, for counting devices. endOfDay only suggests, so it stops nothing here.
    public func stops(on trigger: Trigger, value: Int, stoppable: [Item], all: [Item], agentEnded: Set<String> = [],
                      now: Date = Date(), folderGone: (String) -> Bool = Rule.folderGone) -> [Item] {
        func idle(_ item: Item, for seconds: TimeInterval) -> Bool {
            item.idleSince.map { now.timeIntervalSince($0) >= seconds } ?? false
        }
        let devices: Set<Item.Kind> = [.simulator, .simulatorApp, .emulator]
        let web: Set<Item.Kind> = [.server, .bundler, .tunnel]
        switch (self, trigger) {
        case let (.xcodeQuit, .quit(id)) where id == "com.apple.dt.Xcode":
            return stoppable.filter { [.simulator, .simulatorApp].contains($0.kind) }
        case let (.studioQuit, .quit(id)) where id.hasPrefix("com.google.android.studio"):
            return stoppable.filter { [.emulator, .gradle, .kotlin].contains($0.kind) }
        case let (.battery, .battery(percent)) where percent <= value:
            return stoppable.filter { devices.contains($0.kind) }
        case (.sleep, .sleep):
            return stoppable
        case (.idleDaemons, .scan):
            return stoppable.filter { [.gradle, .kotlin].contains($0.kind) && idle($0, for: Double(value) * 60) }
        case (.idleServers, .scan):
            return stoppable.filter { web.contains($0.kind) && idle($0, for: Double(value) * 3600) }
        case (.maxDevices, .scan):
            // Over the limit: the oldest idle ones go, never one in use. Xcode Previews devices don't count: Xcode boots them again.
            func counts(_ item: Item, _ kind: Item.Kind) -> Bool {
                guard item.kind == kind else { return false }
                if case .simulator(_, true) = item.stop { return false }
                return true
            }
            return [Item.Kind.simulator, .emulator].flatMap { kind -> [Item] in
                let extra = all.filter { counts($0, kind) }.count - value
                guard extra > 0 else { return [] }
                return stoppable.filter { counts($0, kind) && $0.idleSince != nil }
                    .sorted { ($0.started ?? now) < ($1.started ?? now) }
                    .prefix(extra).map { $0 }
            }
        case (.agentEnded, .scan):
            // `agentEnded`: rows whose agent process is gone. By pid, not by "started by" turning empty, which also
            // happens while the agent runs, when it backgrounds a server and the shell in between exits.
            return stoppable.filter { agentEnded.contains($0.id) }
        case (.folderDeleted, .scan):
            return stoppable.filter { web.contains($0.kind) && $0.cwd.map(folderGone) == true }
        default:
            return []
        }
    }

    /// Only a missing folder counts. A folder macOS won't let us look into (Desktop, Documents) isn't gone.
    public static func folderGone(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == -1 && errno == ENOENT
    }
}

extension Item {
    public static let agentNames: Set<String> = Set(Detection.agents.values)

    public var startedByAgent: Bool { startedBy.map(Item.agentNames.contains) ?? false }

    /// How to bring it back after a stop. Dev servers have none: their command and environment can't be rebuilt safely.
    public var undo: Undo? {
        switch stop {
        case let .simulator(udid, previews) where !previews: .boot(udid: udid)
        case .emulator where key.hasPrefix("avd:"): .avd(String(key.dropFirst(4)))
        case let .containers(ids): .start(ids)
        default: nil
        }
    }
}

public enum Undo: Codable, Sendable, Hashable {
    case boot(udid: String)
    case avd(String)
    case start([String])
}

// MARK: - Memory pressure

extension Pressure {
    /// What to offer when memory gets tight: the biggest idle rows first, then devices and daemons people forget,
    /// until `target` is reached. Never a busy dev server; nil when there isn't enough to bother.
    // ponytail: greedy by size, fine for a dozen rows.
    public static func suggestion(_ stoppable: [Item], target: UInt64, minimum: UInt64 = 500_000_000) -> [Item]? {
        let forgettable: Set<Item.Kind> = [.simulator, .simulatorApp, .emulator, .gradle, .kotlin, .xcode]
        let ranked = stoppable.filter { $0.counted && ($0.idleSince != nil || forgettable.contains($0.kind)) }
            .sorted { ($0.idleSince != nil ? 1 : 0, $0.memory) > ($1.idleSince != nil ? 1 : 0, $1.memory) }
        var picked: [Item] = []
        var freed: UInt64 = 0
        for item in ranked where freed < target {
            picked.append(item)
            freed += item.memory
        }
        return freed >= minimum ? picked : nil
    }
}

// MARK: - Activity

/// One stop, by hand, by Clean slate, by a rule or by the pressure assistant.
public struct Activity: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var date: Date
    public var title: String
    public var kind: Item.Kind
    public var memory: UInt64
    /// "You", "Clean slate", "Memory pressure", or the rule's id.
    public var reason: String
    public var undo: Undo?
    public var undone = false

    public init(_ item: Item, reason: String, date: Date = Date()) {
        self.date = date
        title = item.title
        kind = item.kind
        memory = item.counted ? item.memory : 0
        self.reason = reason
        undo = item.undo
    }
}

/// `Application Support/Ramback/activity.jsonl`, newest last, the last 2000 entries.
public struct ActivityLog: Sendable {
    public static let limit = 2000
    public let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ramback/activity.jsonl")) {
        self.url = url
    }

    public func load() -> [Activity] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Activity.self, from: Data($0)) }
    }

    /// The app, the CLI and the MCP server all write here, so change the log only through this: it loads, changes and
    /// saves under an advisory lock on a sidecar file, and nobody's entries get lost. Unlocked if the lock can't be had.
    public func update(_ change: ([Activity]) -> [Activity]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_RDWR | O_CREAT, 0o644)
        defer { if lock >= 0 { close(lock) } }  // closing releases the lock
        if lock >= 0 { flock(lock, LOCK_EX) }
        save(change(load()))
    }

    /// Rewrites the whole file: entries change when undone, and 2000 short lines are nothing. Use `update` to add to it.
    public func save(_ entries: [Activity]) {
        let encoder = JSONEncoder()
        let lines = entries.suffix(Self.limit).compactMap { try? encoder.encode($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(lines.joined(separator: Data("\n".utf8))).write(to: url, options: .atomic)
    }

    /// Memory freed since the start of this week.
    public static func freedThisWeek(_ entries: [Activity], now: Date = Date(), calendar: Calendar = .current) -> UInt64 {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        return entries.filter { $0.date >= start && !$0.undone }.reduce(0) { $0 + $1.memory }
    }
}
