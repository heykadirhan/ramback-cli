import Foundation

/// Where xcrun, adb, emulator and docker live. GUI apps don't get the shell's PATH, so look in the usual places
/// first and ask the login shell once only for what's still missing.
public struct Tools: Sendable {
    public static let names = ["xcrun", "adb", "emulator", "docker"]
    /// The user's home. NSHomeDirectory() is the app's container inside the App Sandbox (Lite).
    public static let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    public private(set) var paths: [String: String] = [:]

    /// `overrides` are the paths set by hand in Settings > Tools. What the login shell didn't find is remembered in
    /// `defaults` for a day, so the CLI, the MCP server and each app launch don't start a login shell for it again.
    public static func locate(overrides: [String: String] = [:], defaults: UserDefaults? = nil,
                              shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") async -> Tools {
        // The app's own defaults are .standard; asking for its bundle id as a suite doesn't work.
        let defaults = defaults ?? (Bundle.main.bundleIdentifier == "app.ramback.mac" ? .standard : UserDefaults(suiteName: "app.ramback.mac") ?? .standard)
        var misses = defaults.dictionary(forKey: "toolMisses") as? [String: Date] ?? [:]
        let env = ProcessInfo.processInfo.environment
        let home = Tools.home
        let sdks = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"], home + "/Library/Android/sdk"].compactMap { $0 }
        let candidates: [String: [String]] = [
            "xcrun": ["/usr/bin/xcrun"],
            "adb": sdks.map { $0 + "/platform-tools/adb" },
            "emulator": sdks.map { $0 + "/emulator/emulator" },
            "docker": ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", home + "/.orbstack/bin/docker",
                       "/Applications/Docker.app/Contents/Resources/bin/docker"],
        ]
        var tools = Tools()
        for name in names {
            if let path = overrides[name], FileManager.default.isExecutableFile(atPath: path) {
                tools.paths[name] = path
            } else if let path = candidates[name]?.first(where: FileManager.default.isExecutableFile) {
                tools.paths[name] = path
            } else if overrides[name] == nil, let missed = misses[name], Date().timeIntervalSince(missed) < 86_400 {
                continue  // the login shell didn't know it today either; a path set by hand asks again
            } else if let out = await run(shell, ["-lc", "command -v \(name)"]), out.status == 0,
                      case let path = String(decoding: out.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      FileManager.default.isExecutableFile(atPath: path) {
                tools.paths[name] = path
                misses[name] = nil
            } else {
                misses[name] = Date()
            }
        }
        defaults.set(misses, forKey: "toolMisses")
        return tools
    }

    public subscript(name: String) -> String? { paths[name] }

    public struct Output: Sendable {
        public var status: Int32
        public var data: Data
    }

    /// Runs a tool off the main thread. Output goes to a temp file rather than a pipe, so a chatty tool can't fill
    /// the pipe and a daemon it forks (adb's server) can't hold it open. nil on launch failure or timeout.
    public static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) async -> Output? {
        await withCheckedContinuation { continuation in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: file) else { return continuation.resume(returning: nil) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { process in
                try? handle.close()
                let data = (try? Data(contentsOf: file)) ?? Data()
                try? FileManager.default.removeItem(at: file)
                continuation.resume(returning: process.terminationReason == .exit ? Output(status: process.terminationStatus, data: data) : nil)
            }
            do {
                try process.run()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: file)
                return continuation.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }

    /// Starts something long-running (an emulator) without waiting for it.
    public static func launch(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return (try? process.run()) != nil
    }
}

// MARK: - Docker

extension Tools {
    /// Running containers with their memory inside the VM, from `docker ps` and `docker stats`.
    public func containers() async -> [Container] {
        guard let docker = self["docker"],
              let ps = await Self.run(docker, ["ps", "--no-trunc", "--format", "{{json .}}"]), ps.status == 0,
              let stats = await Self.run(docker, ["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"], timeout: 10)
        else { return [] }
        return Self.parseContainers(ps: ps.data, stats: stats.data)
    }

    static func parseContainers(ps: Data, stats: Data) -> [Container] {
        func lines(_ data: Data) -> [[String: Any]] {
            String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        var memory: [String: UInt64] = [:]
        for row in lines(stats) {
            guard let id = row["ID"] as? String, let usage = row["MemUsage"] as? String else { continue }
            memory[id] = parseSize(String(usage.split(separator: "/").first ?? ""))
        }
        return lines(ps).compactMap { row in
            guard let id = row["ID"] as? String, let name = row["Names"] as? String else { return nil }
            let labels = (row["Labels"] as? String ?? "").split(separator: ",").map { $0.split(separator: "=", maxSplits: 1) }
            let project = labels.first { $0.first == "com.docker.compose.project" }.flatMap { $0.count > 1 ? String($0[1]) : nil }
            return Container(id: id, name: name, image: row["Image"] as? String ?? "", project: project, memory: memory[id] ?? 0)
        }
    }

    /// "56.2MiB" → bytes.
    static func parseSize(_ text: String) -> UInt64 {
        let text = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("KiB", 0x1p10), ("MiB", 0x1p20), ("GiB", 0x1p30), ("TiB", 0x1p40),
                                         ("kB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("B", 1)]
        for (unit, scale) in units where text.hasSuffix(unit) {
            return UInt64((Double(text.dropLast(unit.count)) ?? 0) * scale)
        }
        return 0
    }
}

// MARK: - Scanner

/// The live loop: snapshot, ask Docker and CoreSimulator what they know, detect, then name projects and track idle time.
public actor Scanner {
    public private(set) var tools: Tools
    private var argsCache: [Int32: (Date, [String])] = [:]
    private var tracker = Tracker()
    private var projects: [String: String?] = [:]
    private var simulatorNames: [String: String] = [:]
    private var containers: [Container] = []
    private var containersAt = Date.distantPast
    private var refreshingContainers = false

    public init(tools: Tools) { self.tools = tools }

    public func use(_ tools: Tools) { self.tools = tools }

    public func scan() async -> [Item] {
        let snapshot = Snapshot.take(argsCache: &argsCache)
        // `docker stats` takes a second or two; ask at most every 10 s, and only while a runtime is up. It runs on its own
        // so the panel's loop keeps the last answer meanwhile; only the first scan waits, for a one-shot `ramback status`.
        let runtimeUp = snapshot.procs.contains { Detection.runtimeName($0) != nil }
        if !runtimeUp {
            containers = []
        } else if !refreshingContainers, snapshot.taken.timeIntervalSince(containersAt) > 10 {
            let first = containersAt == .distantPast
            containersAt = snapshot.taken
            refreshingContainers = true
            let refresh = Task { await self.refreshContainers() }
            if first { await refresh.value }
        }
        for p in snapshot.procs where p.name == "launchd_sim" {
            guard let path = p.args.dropFirst().first, let udid = Detection.udid(path), simulatorNames[udid] == nil else { continue }
            simulatorNames[udid] = Self.simulatorName(launchdPath: path, udid: udid)
        }
        var items = detect(World(snapshot: snapshot, simulators: simulatorNames, containers: containers))
        for i in items.indices where items[i].project == nil {
            items[i].project = items[i].cwd.flatMap(project)
        }
        return tracker.update(items, at: snapshot.taken)
    }

    private func refreshContainers() async {
        containers = await tools.containers()
        refreshingContainers = false
    }

    /// The device folder sits right before /data/ in launchd_sim's bootstrap path; its device.plist has the name.
    static func simulatorName(launchdPath: String, udid: String) -> String? {
        guard let range = launchdPath.range(of: "/\(udid)/") else { return nil }
        let plist = URL(fileURLWithPath: String(launchdPath[..<range.upperBound]) + "device.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["name"] as? String
    }

    /// Git root's folder name, else the folder's own name. Home and / aren't projects.
    private func project(_ cwd: String) -> String? {
        if let cached = projects[cwd] { return cached }
        let home = Tools.home
        var name: String?
        if cwd != "/", cwd != home {
            var url = URL(fileURLWithPath: cwd)
            name = url.lastPathComponent
            while url.path != home, url.path != "/" {
                // .git is a folder in a clone and a file in a worktree.
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    name = url.lastPathComponent
                    break
                }
                url.deleteLastPathComponent()
            }
        }
        projects[cwd] = name
        return name
    }
}
