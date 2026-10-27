import Foundation

/// `ramback mcp`: a Model Context Protocol server over stdio, so coding agents can check the dev stack before booting
/// another device and stop their own leftovers. Dual-era: per-request `_meta` (2026-07-28) and the older
/// `initialize` handshake. Everything here is pure; `run` does the work, so tests drive it with a fake.
public enum MCP {
    public static let version = "2026-07-28"
    /// Handshake-era versions, newest first.
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// A tools/call whose arguments passed the checks.
    public enum Call: Sendable, Equatable {
        case listRunning
        case stop(target: String)
        case freeMemory(gb: Double, dryRun: Bool)
        case findFreePort(start: UInt16)
    }

    public struct Reply: Sendable, Equatable {
        public var text: String
        public var isError: Bool

        public init(_ text: String, isError: Bool = false) {
            self.text = text
            self.isError = isError
        }
    }

    /// One newline-delimited message in, the line to answer with out; nil for notifications, which get no answer.
    // ponytail: one request at a time and no cancellation; a stop takes at most ~6 s, fine for agents.
    public static func handle(_ line: Data, serverVersion: String, run: @Sendable (Call) async -> Reply) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: line) else { return error(-32700, "Parse error", id: nil) }
        guard let request = message as? [String: Any] else { return error(-32600, "Invalid request", id: nil) }
        guard let id = request["id"], !(id is NSNull) else { return nil }
        guard let method = request["method"] as? String else { return error(-32600, "Invalid request", id: id) }
        let params = request["params"] as? [String: Any] ?? [:]
        let requested = (params["_meta"] as? [String: Any])?["io.modelcontextprotocol/protocolVersion"] as? String
        if let requested, !([version] + legacy).contains(requested) {
            return error(-32022, "Unsupported protocol version", id: id, data: ["supported": [version] + legacy, "requested": requested])
        }
        let info = ["name": "ramback", "version": serverVersion]
        let capabilities = ["tools": [String: Any]()]
        var result: [String: Any]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": legacy.contains(asked) ? asked : legacy[0], "capabilities": capabilities,
                      "serverInfo": info, "instructions": instructions]
        case "server/discover":
            result = ["supportedVersions": [version] + legacy, "capabilities": capabilities, "instructions": instructions]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": tools]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard tools.contains(where: { $0["name"] as? String == name }) else { return error(-32602, "Unknown tool: \(name)", id: id) }
            var reply = Reply("Invalid arguments for \(name); see its inputSchema.", isError: true)
            if let call = call(name, params["arguments"] as? [String: Any] ?? [:]) { reply = await run(call) }
            result = ["content": [["type": "text", "text": reply.text]], "isError": reply.isError]
        default:
            return error(-32601, "Method not found: \(method)", id: id)
        }
        if requested != nil || method == "server/discover" {
            result["resultType"] = "complete"
            result["_meta"] = ["io.modelcontextprotocol/serverInfo": info]
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Checks a call's arguments against its schema; nil when they don't fit.
    static func call(_ name: String, _ args: [String: Any]) -> Call? {
        switch name {
        case "list_running":
            return .listRunning
        case "stop":
            // Agents sometimes send a port as a number.
            guard let target = args["target"] as? String ?? (args["target"] as? Int).map(String.init), !target.isEmpty else { return nil }
            return .stop(target: target)
        case "free_memory":
            guard let gb = args["gb"] as? Double, gb > 0, gb < 1024 else { return nil }
            return .freeMemory(gb: gb, dryRun: args["dry_run"] as? Bool ?? false)
        case "find_free_port":
            guard let start = args["start"] == nil ? 3000 : args["start"] as? Int, let port = UInt16(exactly: start), port > 0 else { return nil }
            return .findFreePort(start: port)
        default:
            return nil
        }
    }

    static let instructions = """
        Ramback sees the Mac's dev stack: simulators, emulators, Gradle and Kotlin daemons, Docker containers, \
        bundlers, dev servers and databases, with their RAM. Call list_running before booting another simulator or \
        emulator, free_memory when memory is tight, find_free_port before starting a server, and stop your own dev \
        server when you're done. Agents can't stop pinned rows, databases, anything building, or what another agent started.
        """

    static var tools: [[String: Any]] {
        [
            ["name": "list_running", "title": "List running dev stack",
             "description": "Simulators, emulators, daemons, containers, dev servers and databases running now, with RAM, ports, "
                 + "who started them, and whether you may stop them (can_stop, why_not).",
             "inputSchema": ["type": "object", "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "openWorldHint": false]],
            ["name": "stop", "title": "Stop a row or a project",
             "description": "Stops politely (simctl, adb, docker stop, SIGTERM) and waits 5 s. An id or port from list_running stops "
                 + "that row; a project name stops that project's rows. Never stops pinned rows, databases, builds, or what another agent started.",
             "inputSchema": ["type": "object", "additionalProperties": false, "required": ["target"],
                             "properties": ["target": ["type": "string", "description": "An id or port from list_running, or a project name."]]],
             "annotations": ["destructiveHint": true, "idempotentHint": true, "openWorldHint": false]],
            ["name": "free_memory", "title": "Free memory",
             "description": "Stops idle simulators, emulators and daemons, biggest first, until about this much RAM is freed.",
             "inputSchema": ["type": "object", "additionalProperties": false, "required": ["gb"],
                             "properties": ["gb": ["type": "number", "exclusiveMinimum": 0, "description": "Gigabytes to free."],
                                            "dry_run": ["type": "boolean", "description": "Only say what would stop."]]],
             "annotations": ["destructiveHint": true, "openWorldHint": false]],
            ["name": "find_free_port", "title": "Find a free port",
             "description": "The first TCP port from `start` that nothing listens on, over IPv4 or IPv6.",
             "inputSchema": ["type": "object", "additionalProperties": false,
                             "properties": ["start": ["type": "integer", "minimum": 1, "maximum": 65535, "default": 3000]]],
             "annotations": ["readOnlyHint": true, "openWorldHint": false]],
        ]
    }

    static func error(_ code: Int, _ message: String, id: Any?, data: [String: Any]? = nil) -> Data? {
        var error: [String: Any] = ["code": code, "message": message]
        error["data"] = data
        return encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    /// One line: JSONSerialization never pretty-prints unless asked, and escapes newlines inside strings.
    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
