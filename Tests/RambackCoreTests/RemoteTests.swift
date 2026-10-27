import Darwin
import Foundation
import Testing
@testable import RambackCore

private func row(_ id: String, _ kind: Item.Kind = .server, project: String? = nil, ports: [UInt16] = [], by: String? = nil,
                 guarded: Bool = false, building: Bool = false, stop: Stop? = .signal) -> Item {
    var item = Item(id: id, key: id, kind: kind, title: id, project: project, startedBy: by, pids: [1], stop: stop)
    item.ports = ports
    item.guarded = guarded
    item.building = building
    return item
}

// MARK: - Matching and refusals

@Test func targetsMatchIdThenPortThenProject() {
    let items = [row("server:10", project: "web", ports: [3000]), row("bundler:11", .bundler, project: "web", ports: [8081]),
                 row("db:12", .database, project: "api", ports: [5432])]
    #expect(Item.match("bundler:11", in: items).rows.map(\.id) == ["bundler:11"])
    #expect(Item.match("bundler:11", in: items).exact)
    #expect(Item.match("3000", in: items).rows.map(\.id) == ["server:10"])
    #expect(Item.match(":5432", in: items).rows.map(\.id) == ["db:12"])
    let project = Item.match("WEB", in: items)
    #expect(project.rows.map(\.id) == ["server:10", "bundler:11"] && !project.exact)
    #expect(Item.match("9999", in: items).rows.isEmpty)
    #expect(Item.match("nope", in: items).rows.isEmpty)
}

@Test func cleanSlateRulesAndHandPicks() {
    #expect(row("a").sweepRefusal(pinned: false) == nil)
    #expect(row("a").sweepRefusal(pinned: true) == "pinned")
    #expect(row("db", .database, guarded: true).sweepRefusal(pinned: false) == "a database")
    #expect(row("x", .xcode, guarded: true).sweepRefusal(pinned: false) == "in use by Xcode")
    #expect(row("b", building: true).sweepRefusal(pinned: false) == "building")
    #expect(row("agent", .agent, guarded: true).sweepRefusal(pinned: false) == "an agent session")
    #expect(row("agent", .agent, guarded: true).agentRefusal(pinned: false, owner: nil, caller: nil) == "an agent session")
    // By hand: a build may stop, pins, databases and agents need --yes.
    #expect(row("b", building: true).handRefusal(pinned: false, confirmed: false) == nil)
    #expect(row("a").handRefusal(pinned: true, confirmed: false) == "pinned")
    #expect(row("db", .database, guarded: true).handRefusal(pinned: false, confirmed: true) == nil)
    #expect(row("agent", .agent, guarded: true).handRefusal(pinned: false, confirmed: false) == "an agent session")
    #expect(row("agent", .agent, guarded: true).handRefusal(pinned: false, confirmed: true) == nil)
}

@Test func agentsStopOnlyTheirOwnUnprotectedRows() {
    let mine = row("mine", by: "Claude Code")
    #expect(mine.agentRefusal(pinned: false, owner: 200, caller: 200) == nil)
    #expect(mine.agentRefusal(pinned: false, owner: 300, caller: 200) == "started by another agent (Claude Code)")
    // An agent Ramback can't identify owns nothing.
    #expect(mine.agentRefusal(pinned: false, owner: 300, caller: nil) != nil)
    // Nobody's leftovers are fair game; pins, databases and builds never are, even the agent's own.
    #expect(row("orphan").agentRefusal(pinned: false, owner: nil, caller: nil) == nil)
    // Claude's desktop app runs preview servers itself: "started by Claude Code" with no agent pid, so no agent's to stop.
    #expect(mine.agentRefusal(pinned: false, owner: nil, caller: 200) == "started by another agent (Claude Code)")
    #expect(mine.agentRefusal(pinned: true, owner: 200, caller: 200) == "pinned")
    #expect(row("db", .database, guarded: true).agentRefusal(pinned: false, owner: 200, caller: 200) == "a database")
    #expect(row("b", building: true).agentRefusal(pinned: false, owner: 200, caller: 200) == "building")
}

@Test func theCallingAgentIsTheNearestAgentBelowAnyApp() {
    func p(_ pid: Int32, _ ppid: Int32, _ path: String) -> Proc { Proc(pid: pid, ppid: ppid, path: path, args: [path]) }
    let snapshot = Snapshot(procs: [
        p(100, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"), p(101, 100, "/bin/zsh"),
        p(200, 101, "/Users/me/.local/bin/claude"), p(201, 200, "/opt/homebrew/bin/ramback"),
        p(202, 200, "/bin/zsh"), p(203, 202, "/opt/homebrew/bin/node"),
        p(300, 101, "/opt/homebrew/bin/node"),
        // Claude's desktop app launching an MCP server is an app, not an agent Ramback knows.
        p(400, 1, "/Applications/Claude.app/Contents/MacOS/Claude"), p(401, 400, "/opt/homebrew/bin/ramback"),
    ])
    #expect(snapshot.agent(above: 201)?.pid == 200)
    #expect(snapshot.agent(above: 201)?.name == "Claude Code")
    #expect(snapshot.agent(above: 203)?.pid == 200)
    #expect(snapshot.agent(above: 300) == nil)
    #expect(snapshot.agent(above: 401) == nil)
}

@Test func freePortSkipsOneTakenOnlyOverIPv6() throws {
    let port = try #require(Ports.firstFree(from: 41_000))
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr.__u6_addr.__u6_addr8.15 = 1  // ::1
    let bound = withUnsafePointer(to: address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
    }
    try #require(bound == 0 && listen(fd, 1) == 0)
    #expect(Ports.firstFree(from: port) != port)
}

// MARK: - MCP

private func send(_ json: String, run: @escaping @Sendable (MCP.Call) async -> MCP.Reply = { MCP.Reply("ran \($0)") }) async -> [String: Any]? {
    guard let data = await MCP.handle(Data(json.utf8), serverVersion: "1.1", run: run) else { return nil }
    #expect(!data.contains(UInt8(ascii: "\n")))
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func text(_ response: [String: Any]?) -> (String?, Bool?) {
    let result = response?["result"] as? [String: Any]
    return (((result?["content"] as? [[String: Any]])?.first?["text"] as? String), result?["isError"] as? Bool)
}

private func code(_ response: [String: Any]?) -> Int? { (response?["error"] as? [String: Any])?["code"] as? Int }

@Test func mcpHandshakeEchoesSupportedVersions() async throws {
    let hello = try #require(await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#))
    let result = try #require(hello["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "1.1")
    #expect(result["resultType"] == nil)
    let future = await send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
    #expect((future?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    #expect(await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect((await send(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#))?["id"] as? String == "p")
}

@Test func mcpModernRequestsCarryTheirVersion() async {
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
    let discover = await send(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(meta)}}"#)
    let result = discover?["result"] as? [String: Any]
    #expect(result?["resultType"] as? String == "complete")
    #expect((result?["supportedVersions"] as? [String])?.first == "2026-07-28")
    let list = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(meta)}}"#)
    #expect((list?["result"] as? [String: Any])?["resultType"] as? String == "complete")
    let old = await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#)
    #expect(code(old) == -32022)
}

@Test func mcpToolsAreListedAndCalled() async {
    let list = await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    #expect(tools.compactMap { $0["name"] as? String } == ["list_running", "stop", "free_memory", "find_free_port"])
    #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })

    #expect(text(await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_running"}}"#)).0 == "ran listRunning")
    // Ports often arrive as numbers.
    let stop = await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stop","arguments":{"target":3000}}}"#)
    #expect(text(stop).0 == #"ran stop(target: "3000")"#)
    let free = await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"free_memory","arguments":{"gb":2,"dry_run":true}}}"#)
    #expect(text(free).0 == "ran freeMemory(gb: 2.0, dryRun: true)")
    let port = await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"find_free_port","arguments":{}}}"#)
    #expect(text(port).0 == "ran findFreePort(start: 3000)")
    let failed = await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"stop","arguments":{"target":"x"}}}"#) { _ in
        MCP.Reply("Left it alone", isError: true)
    }
    #expect(text(failed).1 == true)
}

@Test func mcpRejectsBadInputWithoutRunning() async {
    for args in [#"{"gb":-1}"#, #"{"gb":"two"}"#, #"{}"#] {
        let reply = text(await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"free_memory","arguments":\#(args)}}"#))
        #expect(reply.1 == true && reply.0?.hasPrefix("Invalid arguments") == true)
    }
    #expect(text(await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"find_free_port","arguments":{"start":70000}}}"#)).1 == true)
    #expect(text(await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stop","arguments":{"target":""}}}"#)).1 == true)
    #expect(code(await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"clean_disk"}}"#)) == -32602)
    #expect(code(await send(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)) == -32601)
    let garbage = await send("not json")
    #expect(code(garbage) == -32700 && garbage?["id"] is NSNull)
    #expect(code(await send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)) == -32600)
}
