import Foundation

/// One row in the Running tab: a simulator, a daemon, a container, a dev server…
public struct Item: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case simulator, simulatorApp, emulator, gradle, kotlin, xcode, bundler, docker, container, database, tunnel, server, agent
    }

    /// Unique for this running instance.
    public var id: String
    /// Survives restarts (pins): the simulator's UDID, the AVD, the container name, the server's folder and stack.
    public var key: String
    public var kind: Kind
    public var title: String
    public var cwd: String?
    /// Git root's folder name, or the compose project for containers.
    public var project: String?
    /// The nearest app or agent up the parent chain: "Claude Code", "Xcode", "Terminal"…
    public var startedBy: String?
    /// The agent process behind `startedBy`, when that's an agent.
    public var agentPID: Int32?
    /// Owned processes, root first. Every pid belongs to one item, so memory is never counted twice.
    public var pids: [Int32]
    /// Bytes.
    public var memory: UInt64
    /// Part of the dev-stack total. Containers aren't: their memory is already inside the VM row.
    public var counted = true
    public var started: Date?
    public var ports: [UInt16] = []
    public var inbound = 0
    /// nil when Ramback doesn't stop it (the Docker VM).
    public var stop: Stop?
    /// Databases, agents, and Xcode's helpers while Xcode runs: never stopped automatically, confirmed by hand.
    public var guarded = false
    /// Summed CPU time of `pids` in nanoseconds; the Tracker turns it into `cpu`, `building` and `idleSince`.
    public var cpuTime: UInt64 = 0

    public var cpu = 0.0
    public var building = false
    public var idleSince: Date?

    public init(id: String, key: String, kind: Kind, title: String, cwd: String? = nil, project: String? = nil, startedBy: String? = nil,
                pids: [Int32] = [], memory: UInt64 = 0, started: Date? = nil, stop: Stop? = .signal) {
        self.id = id
        self.key = key
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.project = project
        self.startedBy = startedBy
        self.pids = pids
        self.memory = memory
        self.started = started
        self.stop = stop
    }

    /// Not doing anything right now, for stops nobody confirms (`ramback free`, MCP free_memory): idle, or a device or
    /// daemon at next to no CPU with nobody connected.
    public var quiet: Bool { idleSince != nil || (!building && cpu < 0.05 && inbound == 0) }
}

public enum Stop: Codable, Sendable, Hashable {
    /// SIGTERM to every owned process.
    case signal
    case simulator(udid: String, previews: Bool)
    /// `adb -s <serial> emu kill`; SIGTERM when there's no adb or serial.
    case emulator(serial: String?)
    case containers([String])
}

// MARK: - Tracker

/// Remembers recent CPU per item to tell "building" from "idle 2h".
public struct Tracker: Sendable {
    /// CPU share of one core above which an item counts as building.
    // ponytail: fixed thresholds, tune from beta snapshots.
    public static let buildingCPU = 0.2
    public static let activeCPU = 0.01
    /// Quiet for this long before a row says "idle".
    public static let idleAfter: TimeInterval = 10 * 60
    static let window: TimeInterval = 10

    private var samples: [String: [(at: Date, cpu: UInt64)]] = [:]
    private var lastActive: [String: Date] = [:]

    public init() {}

    public mutating func update(_ items: [Item], at now: Date) -> [Item] {
        var next: [String: [(at: Date, cpu: UInt64)]] = [:]
        let updated = items.map { item -> Item in
            var item = item
            guard !item.pids.isEmpty else { return item }  // containers: no host processes to watch
            var history = samples[item.id] ?? []
            // Keep the 10 s window, plus one older sample so a slow refresh still has something to compare with.
            while history.count > 1, now.timeIntervalSince(history[1].at) > Self.window { history.removeFirst() }
            if let first = history.first, now > first.at {
                let used = item.cpuTime > first.cpu ? Double(item.cpuTime - first.cpu) : 0
                item.cpu = used / 1e9 / now.timeIntervalSince(first.at)
            }
            // Mid-build a Gradle daemon can sit at no CPU (downloads, waiting on Kotlin), but the client stays connected.
            item.building = item.cpu > Self.buildingCPU || (item.kind == .gradle && item.inbound > 0)
            // First sighting counts as active: never call something idle without having watched it.
            if history.isEmpty || item.cpu > Self.activeCPU || item.inbound > 0 { lastActive[item.id] = now }
            let quietSince = lastActive[item.id] ?? now
            item.idleSince = now.timeIntervalSince(quietSince) >= Self.idleAfter ? quietSince : nil
            history.append((now, item.cpuTime))
            next[item.id] = history
            return item
        }
        samples = next
        lastActive = lastActive.filter { next[$0.key] != nil }
        return updated
    }
}
