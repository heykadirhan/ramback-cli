import Foundation

public struct Container: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    /// `com.docker.compose.project` label.
    public var project: String?
    public var memory: UInt64

    public init(id: String, name: String, image: String, project: String? = nil, memory: UInt64 = 0) {
        self.id = id
        self.name = name
        self.image = image
        self.project = project
        self.memory = memory
    }
}

/// Everything detection looks at. Detection itself is a pure function of this, so it runs on fixtures in tests.
public struct World: Sendable {
    public var snapshot: Snapshot
    /// Simulator UDID → device name, from each device's device.plist.
    public var simulators: [String: String]
    public var containers: [Container]

    public init(snapshot: Snapshot, simulators: [String: String] = [:], containers: [Container] = []) {
        self.snapshot = snapshot
        self.simulators = simulators
        self.containers = containers
    }
}

/// Turns processes into rows. Each pid goes to the first detector that claims it, in this order:
/// simulators, Android, Docker, JVM daemons, Xcode helpers, agents (themselves only), bundlers, databases,
/// tunnels, web servers, and last the agents again, which keep whatever they started that nobody else claimed.
public func detect(_ world: World) -> [Item] {
    var detection = Detection(world)
    return detection.run()
}

struct Detection {
    let world: World
    let procs: [Int32: Proc]
    let children: [Int32: [Int32]]
    /// Ordered by pid so results don't depend on the snapshot's order.
    let all: [Proc]
    var claimed = Set<Int32>()
    var items: [Item] = []

    init(_ world: World) {
        self.world = world
        let procs = Dictionary(world.snapshot.procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        self.procs = procs
        children = Dictionary(grouping: procs.keys, by: { procs[$0]!.ppid })
        all = procs.values.sorted { $0.pid < $1.pid }
    }

    func unclaimed(_ p: Proc) -> Bool { !claimed.contains(p.pid) }

    mutating func run() -> [Item] {
        simulators()
        emulators()
        docker()
        jvmDaemons()
        xcodeHelpers()
        let agents = all.filter { unclaimed($0) && Self.agentName($0) != nil }.map(\.pid)
        claimed.formUnion(agents)
        bundlers()
        databases()
        tunnels()
        servers()
        for pid in agents {
            let p = procs[pid]!
            claimed.remove(pid)
            add(.agent, id: "agent:\(pid)", key: "agent:\(p.cwd)", title: Self.agentName(p)!, root: pid, cwd: p.cwd, guarded: true)
        }
#if LITE
        // Every detector still claims its processes, so a Gradle daemon's port never shows up as a dev server.
        return items.filter { Item.Kind.lite.contains($0.kind) }
#else
        return items
#endif
    }

    // MARK: Detectors

    mutating func simulators() {
        for p in all where p.name == "launchd_sim" {
            guard let udid = p.args.dropFirst().first.flatMap(Self.udid) else { continue }
            let previews = p.args[1].contains("/Previews/")
            let name = world.simulators[udid] ?? "Simulator"
            add(.simulator, id: "sim:\(udid)", key: "sim:\(udid)", title: previews ? "Xcode Previews · \(name)" : name,
                root: p.pid, stop: .simulator(udid: udid, previews: previews))
        }
        for p in all where p.path.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") {
            add(.simulatorApp, id: "simapp:\(p.pid)", key: "simulator-app", title: "Simulator app", root: p.pid)
        }
    }

    mutating func emulators() {
        for p in all where p.name.hasPrefix("qemu-system-") {
            guard let i = p.args.firstIndex(of: "-avd"), i + 1 < p.args.count else { continue }
            let avd = p.args[i + 1]
            // The console listens on an even port from 5554; adb calls the emulator by it.
            let console = p.listening.first { (5554...5682).contains($0) && $0 % 2 == 0 }
            add(.emulator, id: "avd:\(p.pid)", key: "avd:\(avd)", title: avd.replacingOccurrences(of: "_", with: " "),
                root: p.pid, stop: .emulator(serial: console.map { "emulator-\($0)" }))
        }
    }

    mutating func docker() {
        var runtimes: [String: [Int32]] = [:]
        for p in all {
            if let name = Self.runtimeName(p) {
                runtimes[name, default: []].append(p.pid)
            } else if p.path.contains("com.apple.Virtualization.VirtualMachine"),
                      let owner = p.responsible.flatMap({ procs[$0] }), let name = Self.runtimeName(owner) {
                // Virtualization.framework runs the VM in its own XPC service; macOS knows which app it's for.
                runtimes[name, default: []].append(p.pid)
            }
        }
        for (name, pids) in runtimes.sorted(by: { $0.key < $1.key }) {
            var owned: [Int32] = []
            for pid in pids where !claimed.contains(pid) { owned += claimTree(pid) }
            // ponytail: the VM row can't be stopped yet; quitting the runtime (orbctl stop, colima stop) comes later.
            items.append(item(.docker, id: "docker:\(name)", key: "docker:\(name)", title: name, pids: owned, stop: nil))
        }
        for c in world.containers {
            var row = Item(id: "container:\(c.id)", key: "container:\(c.name)", kind: .container, title: c.name,
                           project: c.project, memory: c.memory, stop: .containers([c.id]))
            row.counted = false
            row.guarded = Self.databaseImages.contains { c.image.lowercased().contains($0) }
            items.append(row)
        }
    }

    mutating func jvmDaemons() {
        // Kotlin first: the Gradle daemon is often its parent, and it deserves its own row.
        for p in all where unclaimed(p) && p.args.contains("org.jetbrains.kotlin.daemon.KotlinCompileDaemon") {
            add(.kotlin, id: "kotlin:\(p.pid)", key: "kotlin", title: "Kotlin daemon", root: p.pid)
        }
        for p in all where unclaimed(p) {
            guard let i = p.args.firstIndex(of: "org.gradle.launcher.daemon.bootstrap.GradleDaemon") else { continue }
            let version = p.args.dropFirst(i + 1).first.map { " \($0)" } ?? ""
            add(.gradle, id: "gradle:\(p.pid)", key: "gradle\(version)", title: "Gradle daemon\(version)", root: p.pid)
        }
    }

    mutating func xcodeHelpers() {
        let xcodeRunning = procs.values.contains { $0.name == "Xcode" && $0.path.contains(".app/Contents/MacOS/") }
        for p in all where unclaimed(p) && Self.xcodeHelpers.contains(p.name) {
            add(.xcode, id: "xcode:\(p.pid)", key: "xcode:\(p.name)", title: p.name, root: p.pid, guarded: xcodeRunning)
        }
    }

    mutating func bundlers() {
        for p in all where unclaimed(p) {
            guard let title = Self.bundlerTitle(p) else { continue }
            let root = root(of: p)
            add(.bundler, id: "bundler:\(root)", key: "bundler:\(p.cwd):\(title)", title: title, root: root, cwd: p.cwd)
        }
    }

    mutating func databases() {
        for p in all where unclaimed(p) {
            guard let title = Self.databases[p.name], procs[p.ppid]?.name != p.name else { continue }
            add(.database, id: "db:\(p.pid)", key: "db:\(p.name)", title: title, root: p.pid, guarded: true)
        }
    }

    mutating func tunnels() {
        for p in all where unclaimed(p) {
            let title: String
            if p.name == "ngrok" || p.name == "cloudflared" {
                title = p.name
            } else if p.name == "kubectl", let i = p.args.firstIndex(of: "port-forward") {
                title = (["kubectl"] + p.args[i...].prefix(3)).joined(separator: " ")
            } else { continue }
            add(.tunnel, id: "tunnel:\(p.pid)", key: "tunnel:\(p.args.joined(separator: " "))", title: title, root: p.pid, cwd: p.cwd)
        }
    }

    /// Anything else listening on a TCP port that was started from a project folder rather than being an app.
    mutating func servers() {
        for p in all where unclaimed(p) && !p.listening.isEmpty {
            guard !Self.isApp(p.path), p.cwd != "/", !p.cwd.isEmpty,
                  !["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains(where: p.path.hasPrefix) else { continue }
            let root = root(of: p)
            let tree = [root] + descendants(of: root)
            let stack = Self.stack(tree.compactMap { procs[$0] }, listener: p)
            add(.server, id: "server:\(root)", key: "server:\(p.cwd):\(stack)", title: stack, root: root, cwd: p.cwd)
        }
    }

    // MARK: Building rows

    mutating func add(_ kind: Item.Kind, id: String, key: String, title: String, root: Int32, cwd: String? = nil,
                      stop: Stop? = .signal, guarded: Bool = false) {
        var row = item(kind, id: id, key: key, title: title, pids: claimTree(root), stop: stop)
        row.cwd = cwd
        row.guarded = guarded
        if row.startedBy == title { row.startedBy = nil }  // Claude Code started by Claude Code
        // Ports in the title, where the port is what you'd look for: "Next.js :3000".
        if let port = row.ports.first, [.bundler, .server, .database].contains(kind) { row.title += " :\(port)" }
        items.append(row)
    }

    func item(_ kind: Item.Kind, id: String, key: String, title: String, pids: [Int32], stop: Stop?) -> Item {
        let owned = pids.compactMap { procs[$0] }
        let starter = pids.first.flatMap(starter)
        var row = Item(id: id, key: key, kind: kind, title: title, startedBy: starter?.name,
                       pids: pids, memory: owned.reduce(0) { $0 + $1.footprint }, started: owned.first?.started, stop: stop)
        row.agentPID = starter?.agent
        row.cpuTime = owned.reduce(0) { $0 + $1.cpu }
        row.ports = Set(owned.flatMap(\.listening)).sorted()
        row.inbound = owned.reduce(0) { $0 + $1.inbound }
        return row
    }

    /// The root and its descendants that nobody owns yet.
    mutating func claimTree(_ root: Int32) -> [Int32] {
        guard unclaimed(procs[root]!) else { return [] }
        var owned: [Int32] = []
        var queue = [root]
        while let pid = queue.popLast() {
            guard !claimed.contains(pid) else { continue }
            claimed.insert(pid)
            owned.append(pid)
            queue += children[pid] ?? []
        }
        return owned
    }

    func descendants(of root: Int32) -> [Int32] {
        var found: [Int32] = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            if claimed.contains(pid) { continue }
            found.append(pid)
            queue += children[pid] ?? []
        }
        return found
    }

    /// Climbs from a server to the command that started it (`npm run dev` over `next dev` over `next-server`),
    /// staying in the same folder and stopping below shells, apps and agents, so Stop ends the whole command and nothing else.
    func root(of p: Proc) -> Int32 {
        var current = p
        while let parent = procs[current.ppid], parent.pid > 1, parent.cwd == p.cwd, unclaimed(parent), !Self.isBoundary(parent) {
            current = parent
        }
        return current.pid
    }

    /// The nearest agent or app up the parent chain, with the agent's pid when it's an agent.
    func starter(_ pid: Int32) -> (name: String, agent: Int32?)? {
        var current = procs[pid]?.ppid
        while let ppid = current, let p = procs[ppid] {
            if let agent = Self.agentName(p) { return (agent, p.pid) }
            if let app = Self.appName(p.path) { return (Self.launchers[app] ?? app, nil) }
            current = p.ppid
        }
        return nil
    }

    // MARK: Matching

    static let databases = ["postgres": "PostgreSQL", "redis-server": "Redis", "mysqld": "MySQL", "mariadbd": "MariaDB",
                            "mongod": "MongoDB", "valkey-server": "Valkey"]
    static let databaseImages = ["postgres", "redis", "mysql", "mariadb", "mongo", "valkey", "supabase/postgres", "timescale",
                                 "pgvector", "postgis", "clickhouse", "elasticsearch", "opensearch", "cassandra", "couchdb",
                                 "neo4j", "influxdb", "cockroach", "minio", "rabbitmq", "kafka", "redpanda"]
    static let launchers = ["Claude": "Claude Code", "Visual Studio Code": "VS Code", "iTerm": "iTerm"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "nu", "tcsh", "csh", "ksh", "pwsh", "xonsh", "elvish"]
    /// Editors and terminal multiplexers start servers through `sh -c` from the project folder; Stop must not climb into them.
    static let hosts: Set<String> = ["nvim", "vim", "vi", "emacs", "hx", "helix", "kak", "micro", "nano", "tmux", "screen", "zellij"]

    static let xcodeHelpers: Set<String> = ["SourceKitService", "XCBBuildService", "SWBBuildService"]
    static let agents = ["claude": "Claude Code", "codex": "Codex", "cursor-agent": "Cursor Agent", "gemini": "Gemini CLI"]

    static func agentName(_ p: Proc) -> String? {
        if let name = agents[p.name] { return name }
        // Claude Code's native installer runs ~/.local/share/claude/versions/2.1.296, a binary named after its version;
        // argv[0] still says `claude`. Homebrew's Codex is codex-aarch64-apple-darwin.
        if let first = p.args.first, let name = agents[(first as NSString).lastPathComponent] { return name }
        if p.path.contains("/claude/versions/") { return "Claude Code" }
        if p.name.hasPrefix("codex-") { return "Codex" }
        // Script installs: `node /opt/homebrew/bin/gemini`, `node ~/.local/share/cursor-agent/versions/<v>/index.js`.
        if ["node", "bun"].contains(p.name), p.args.count > 1 {
            if p.args[1].contains("/cursor-agent/") { return "Cursor Agent" }
            return agents[(p.args[1] as NSString).lastPathComponent]
        }
        return nil
    }

    /// The outermost app bundle in a path: ".../Visual Studio Code.app/Contents/Frameworks/Code Helper.app/..." → "Visual Studio Code".
    static func appName(_ path: String) -> String? {
        guard isApp(path), let range = path.range(of: ".app/") else { return nil }
        return path[..<range.lowerBound].split(separator: "/").last.map(String.init)
    }

    static func isBoundary(_ p: Proc) -> Bool {
        agentName(p) != nil || isApp(p.path) || hosts.contains(p.name) || (shells.contains(p.name) && !p.args.contains("-c"))
    }

    /// Inside an app bundle. Python from python.org and Homebrew runs as `Python.framework/.../Python.app/Contents/MacOS/Python`
    /// (Apple's /usr/bin/python3 as `Python3.framework/...`), which is an interpreter, not an app: without this, http.server,
    /// Django and uvicorn never got a row. Xcode's command-line tools (xcodebuild) aren't the Xcode app either.
    static func isApp(_ path: String) -> Bool {
        path.contains(".app/Contents/") && !["/Python.framework/", "/Python3.framework/", "/Contents/Developer/usr/"].contains(where: path.contains)
    }

    static func runtimeName(_ p: Proc) -> String? {
        if p.path.contains("/OrbStack.app/") { return "OrbStack" }
        if p.path.contains("/Docker.app/") { return "Docker Desktop" }
        if p.name == "limactl" || p.name == "colima" { return "Colima" }
        return nil
    }

    static func udid(_ path: String) -> String? {
        guard let range = path.range(of: #"/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/"#, options: .regularExpression) else { return nil }
        return String(path[range].dropFirst().dropLast())
    }

    static func bundlerTitle(_ p: Proc) -> String? {
        guard ["node", "bun"].contains(p.name) || p.name.hasPrefix("dart") else { return nil }
        let line = p.args.joined(separator: " ")
        if let i = p.args.firstIndex(where: { $0.hasSuffix("flutter_tools.snapshot") }) {
            return "flutter " + (p.args.dropFirst(i + 1).first ?? "run")
        }
        if line.contains("react-native start") || line.contains("react-native/cli.js start") { return "Metro" }
        if line.contains("expo start") || line.contains("expo/bin/cli start") { return "Expo" }
        return nil
    }

    /// "Next.js", "Vite", "Rails"… from the command line, else the listener's runtime.
    static func stack(_ tree: [Proc], listener: Proc) -> String {
        let words = Set(tree.flatMap { $0.args.map { ($0 as NSString).lastPathComponent.lowercased() } })
        let known: [(String, String)] = [
            ("next", "Next.js"), ("vite", "Vite"), ("nuxt", "Nuxt"), ("nuxi", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"),
            ("storybook", "Storybook"), ("webpack", "webpack"), ("webpack-dev-server", "webpack"), ("wrangler", "Wrangler"),
            ("vercel", "Vercel"), ("netlify", "Netlify"), ("firebase", "Firebase"), ("convex", "Convex"),
            ("rails", "Rails"), ("puma", "Rails"), ("runserver", "Django"), ("uvicorn", "uvicorn"), ("gunicorn", "gunicorn"),
            ("flask", "Flask"), ("hugo", "Hugo"), ("jekyll", "Jekyll"), ("artisan", "Laravel"), ("phx.server", "Phoenix"),
        ]
        if words.contains(where: { $0.hasPrefix("next-server") }) { return "Next.js" }
        if let match = known.first(where: { words.contains($0.0) }) { return match.1 }
        let runtimes = ["node": "Node", "bun": "Bun", "deno": "Deno", "ruby": "Ruby", "java": "Java", "php": "PHP"]
        let name = listener.name
        if name.lowercased().hasPrefix("python") { return "Python" }
        return runtimes[name] ?? name
    }
}

extension Item.Kind {
    /// What Ramback Lite (the App Store edition) shows: dev servers, bundlers, databases and tunnels.
    public static let lite: Set<Item.Kind> = [.server, .bundler, .database, .tunnel]

    /// Section title by type, and for rows without a project.
    public var group: String {
        switch self {
        case .simulator, .simulatorApp: "Simulators"
        case .emulator: "Android"
        case .gradle, .kotlin: "Gradle & Kotlin"
        case .xcode: "Xcode"
        case .bundler: "Bundlers"
        case .docker, .container: "Docker"
        case .database: "Databases"
        case .tunnel: "Tunnels"
        case .server: "Dev servers"
        case .agent: "Agents"
        }
    }
}
