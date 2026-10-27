import Darwin
import Foundation

// Stopping from outside the app: `ramback stop`, `ramback free` and the MCP server share these rules.

extension Item {
    /// `ramback stop <target>` and the MCP `stop` tool: an exact id or a port picks one row (`exact`);
    /// anything else is a project name and picks that project's rows. No rows when nothing matches.
    public static func match(_ target: String, in items: [Item]) -> (rows: [Item], exact: Bool) {
        if let item = items.first(where: { $0.id == target }) { return ([item], true) }
        if let port = UInt16(target.hasPrefix(":") ? String(target.dropFirst()) : target),
           let item = items.first(where: { $0.ports.contains(port) }) { return ([item], true) }
        return (items.filter { $0.project?.caseInsensitiveCompare(target) == .orderedSame }, false)
    }

    /// Why Clean slate, `ramback stop <project>` and `ramback free` leave this row alone; nil when they may stop it.
    public func sweepRefusal(pinned: Bool) -> String? {
        if stop == nil { return "Ramback doesn't stop it" }
        if let reason = protection(pinned: pinned) { return reason }
        return building ? "building" : nil
    }

    /// A row picked by hand (`ramback stop <id|port>`) stops even mid-build; a pinned or guarded one only when `confirmed`.
    public func handRefusal(pinned: Bool, confirmed: Bool) -> String? {
        if stop == nil { return "Ramback doesn't stop it" }
        return confirmed ? nil : protection(pinned: pinned)
    }

    private func protection(pinned: Bool) -> String? {
        if pinned { return "pinned" }
        guard guarded else { return nil }
        return switch kind {
        case .xcode: "in use by Xcode"
        case .agent: "an agent session"
        default: "a database"
        }
    }

    /// The MCP boundary: everything Clean slate leaves alone, plus whatever another agent started.
    /// `owner` is the pid of the agent that started this row (`agentPID`), `caller` the agent on the other end of `ramback mcp`;
    /// an unknown caller owns nothing. A row started by an agent Ramback has no pid for (Claude's desktop app runs preview
    /// servers itself, so they say "started by Claude Code") belongs to nobody who asks. Disk cleanup never goes through MCP at all.
    public func agentRefusal(pinned: Bool, owner: Int32?, caller: Int32?) -> String? {
        if let reason = sweepRefusal(pinned: pinned) { return reason }
        if owner.map({ $0 != caller }) ?? startedByAgent { return "started by another agent (\(startedBy ?? "unknown"))" }
        return nil
    }
}

extension Snapshot {
    /// The agent on the other end of `ramback mcp`: the nearest agent up the parent chain, unless an app comes first
    /// (the same walk as `startedBy`). By pid rather than name, so one Claude Code session can't stop another's server.
    public func agent(above pid: Int32) -> (pid: Int32, name: String)? {
        let procs = Dictionary(self.procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current = procs[pid]?.ppid
        while let ppid = current, let p = procs[ppid] {
            if let name = Detection.agentName(p) { return (p.pid, name) }
            if Detection.appName(p.path) != nil { return nil }
            current = p.ppid
        }
        return nil
    }
}

public enum Ports {
    /// The first port from `start` that nothing listens on. Both wildcard binds must work: a server on ::1 only
    /// leaves 0.0.0.0 bindable, and one on 127.0.0.1 leaves :: bindable.
    public static func firstFree(from start: UInt16) -> UInt16? {
        (start...UInt16.max).first { port in
            var v4 = sockaddr_in()
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = port.bigEndian
            var v6 = sockaddr_in6()
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = port.bigEndian
            return bindable(v4, family: AF_INET) && bindable(v6, family: AF_INET6)
        }
    }

    /// Zeroed addresses are the wildcard ones (INADDR_ANY, in6addr_any).
    static func bindable<Address>(_ address: Address, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<Address>.size)) }
        } == 0
    }
}
