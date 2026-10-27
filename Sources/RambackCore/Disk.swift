import Foundation

/// The kinds of leftovers the Disk tab finds (plan 2.6).
public enum DiskCategory: String, CaseIterable, Codable, Sendable {
    case runtimes, unavailableSimulators, derivedData, deviceSupport, previews, archives, avds, systemImages, gradle, docker, packageCaches, nodeModules

    /// Deleted for good by the tool's own command; everything else goes to the Trash. All of these download or rebuild again.
    public var permanent: Bool { [.runtimes, .unavailableSimulators, .previews, .docker, .packageCaches].contains(self) }

    /// Why it can't be cleaned right now, or nil.
    public func blocked(xcodeOpen: Bool, gradleRunning: Bool) -> String? {
        switch self {
        case .previews where xcodeOpen: "Quit Xcode first"
        case .gradle where gradleRunning: "Stop the Gradle daemons first"
        default: nil
        }
    }
}

/// One thing the Disk tab can clean: a DerivedData folder, a runtime, a cache.
public struct DiskEntry: Identifiable, Sendable, Hashable {
    public var id: String
    public var category: DiskCategory
    public var title: String
    /// Bytes on disk.
    public var size: UInt64
    public var lastUsed: Date?
    /// Selected by default.
    public var selected: Bool
    public var cleanup: Cleanup
}

public enum Cleanup: Sendable, Hashable {
    /// The user's own files, moved to the Trash. Ramback never empties it.
    case trash([URL])
    /// `xcrun simctl …` or `docker …`, which delete for good.
    case tool(String, [String])
    /// A package manager's own command (for Homebrew, rm on its cache), run in the login shell so it's found the way Terminal finds it.
    case shell(String)
}

public struct DiskResult: Sendable, Hashable {
    public var trashed: UInt64 = 0
    public var deleted: UInt64 = 0
    public var cleaned: Set<String> = []
    /// "Build cache: docker failed", one per entry that couldn't be cleaned.
    public var failures: [String] = []
}

/// Where the Disk tab looks. Nothing outside these folders is ever moved to the Trash.
public struct DiskPlaces: Sendable {
    public var home: URL
    public var androidSDK: URL?
    /// Folders the user picked to look for old node_modules in.
    public var projects: [URL]

    public init(home: URL = URL(fileURLWithPath: Tools.home), projects: [String] = [],
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.projects = projects.map { URL(fileURLWithPath: $0) }
        androidSDK = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], home.path + "/Library/Android/sdk"]
            .compactMap { $0 }.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var xcode: URL { home.appendingPathComponent("Library/Developer/Xcode") }
    var derivedData: URL { xcode.appendingPathComponent("DerivedData") }
    var deviceSupport: URL { xcode.appendingPathComponent("iOS DeviceSupport") }
    var previews: URL { xcode.appendingPathComponent("UserData/Previews") }
    var archives: URL { xcode.appendingPathComponent("Archives") }
    var avd: URL { home.appendingPathComponent(".android/avd") }
    var systemImages: URL? { androidSDK?.appendingPathComponent("system-images") }
    var gradleDists: URL { home.appendingPathComponent(".gradle/wrapper/dists") }
    var gradleCaches: URL { home.appendingPathComponent(".gradle/caches") }

    /// The only folders each category may move things out of. Tool commands trash nothing.
    func roots(_ category: DiskCategory) -> [URL] {
        switch category {
        case .derivedData: [derivedData]
        case .deviceSupport: [deviceSupport]
        case .archives: [archives]
        case .avds: [avd]
        case .systemImages: systemImages.map { [$0] } ?? []
        case .gradle: [gradleDists, gradleCaches]
        case .nodeModules: projects
        default: []
        }
    }
}

public enum Disk {
    public typealias Finder = @Sendable () async -> [DiskEntry]

    /// One finder per place. The app runs them one at a time at background priority and shows each as it lands.
    public static func finders(tools: Tools, places: DiskPlaces, now: Date = Date()) -> [Finder] {
        let finders: [Finder] = [
            { await simulators(tools: tools) },
            { derivedData(places, now: now) },
            { deviceSupport(places) },
            { previews(places) },
            { archives(places) },
            { android(places, now: now) },
            { gradle(places) },
            { await docker(tools: tools) },
            { packageCaches(places) },
            { nodeModules(places, now: now) },
        ]
        return finders.map { finder in { await finder().filter { $0.size > 0 } } }
    }

    /// Cleans one entry at a time; one failing doesn't stop the rest. Xcode and Gradle are checked again right before.
    public static func clean(_ entries: [DiskEntry], tools: Tools, places: DiskPlaces) async -> DiskResult {
        let busy = running()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var result = DiskResult()
        for entry in entries {
            var error = entry.category.blocked(xcodeOpen: busy.xcode, gradleRunning: busy.gradle)
            if error == nil {
                switch entry.cleanup {
                case let .trash(urls):
                    error = trash(urls, roots: places.roots(entry.category), nodeModules: entry.category == .nodeModules)
                case let .tool(name, args):
                    if let path = tools[name] {
                        // "simctl failed" says more than "xcrun failed".
                        if await Tools.run(path, args, timeout: 600)?.status != 0 { error = "\(name == "xcrun" ? args.first ?? name : name) failed" }
                    } else {
                        error = "\(name) not found"
                    }
                case let .shell(command):
                    if await Tools.run(shell, ["-lc", command], timeout: 600)?.status != 0 { error = "\(command) failed" }
                }
            }
            if let error {
                result.failures.append("\(entry.title): \(error)")
            } else {
                result.cleaned.insert(entry.id)
                if entry.category.permanent { result.deleted += entry.size } else { result.trashed += entry.size }
            }
        }
        return result
    }

    /// Moves each to the Trash, symlinks resolved first, and only from inside its category's folders. Missing ones are skipped.
    static func trash(_ urls: [URL], roots: [URL], nodeModules: Bool) -> String? {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let resolved = url.resolvingSymlinksInPath()
            // A symlinked node_modules may point at another project's, which isn't stale.
            guard roots.contains(where: { isInside(resolved.path, $0.resolvingSymlinksInPath().path) }),
                  !nodeModules || (resolved.lastPathComponent == "node_modules" && isDirectory(url))
            else { return "outside the folders Ramback cleans" }
            do {
                try FileManager.default.trashItem(at: resolved, resultingItemURL: nil)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// Strictly inside `root`, never `root` itself, after `..` is resolved.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardized.path
        let root = URL(fileURLWithPath: root).standardized.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Xcode, a Gradle daemon and a Docker runtime, from one pass over the processes.
    static func running() -> (xcode: Bool, gradle: Bool, docker: Bool) {
        var cache: [Int32: (Date, [String])] = [:]
        let procs = Snapshot.take(argsCache: &cache).procs
        return (procs.contains { $0.name == "Xcode" && $0.path.contains(".app/Contents/MacOS/") },
                procs.contains { $0.args.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") },
                procs.contains { Detection.runtimeName($0) != nil })
    }
}

// MARK: - Simulators

extension Disk {
    struct Runtime: Decodable, Hashable {
        var identifier: String
        var runtimeIdentifier: String
        var version: String
        var platformIdentifier: String?
        var sizeBytes: UInt64?
        var deletable: Bool?
        var state: String?
        var lastUsedAt: Date?
    }

    struct Device: Decodable, Hashable {
        var udid: String
        var name: String
        var isAvailable: Bool
        var dataPathSize: UInt64?
        var logPathSize: UInt64?
        var lastBootedAt: Date?
    }

    static func simulators(tools: Tools) async -> [DiskEntry] {
        guard let xcrun = tools["xcrun"],
              let list = await Tools.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 20), list.status == 0,
              let devices = parseDevices(list.data) else { return [] }
        var entries = devices.unavailable.map { device in
            DiskEntry(id: "sim:\(device.udid)", category: .unavailableSimulators, title: device.name,
                      size: (device.dataPathSize ?? 0) + (device.logPathSize ?? 0), lastUsed: device.lastBootedAt, selected: true,
                      cleanup: .tool("xcrun", ["simctl", "delete", device.udid]))
        }
        // Without the SDK list there's no telling which runtime Xcode needs, so none is offered.
        if let runtimes = await Tools.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 20), runtimes.status == 0,
           let match = await Tools.run(xcrun, ["simctl", "runtime", "match", "list", "-j"], timeout: 20), match.status == 0 {
            entries += oldRuntimes(parseRuntimes(runtimes.data), sdks: parseSDKs(match.data), inUse: devices.inUse).map { runtime in
                let os = runtime.runtimeIdentifier.split(separator: ".").last?.split(separator: "-").first.map(String.init) ?? "Runtime"
                return DiskEntry(id: "runtime:\(runtime.identifier)", category: .runtimes, title: "\(os) \(runtime.version)",
                                 size: runtime.sizeBytes ?? 0, lastUsed: runtime.lastUsedAt, selected: true,
                                 cleanup: .tool("xcrun", ["simctl", "runtime", "delete", runtime.identifier]))
            }
        }
        return entries
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `simctl runtime list -j`: disk image runtimes by their identifier.
    static func parseRuntimes(_ data: Data) -> [Runtime] {
        ((try? decoder.decode([String: Runtime].self, from: data)) ?? [:]).values.sorted { $0.identifier < $1.identifier }
    }

    /// `simctl runtime match list -j`: the installed Xcode's SDK version per simulator platform, as major.minor.
    static func parseSDKs(_ data: Data) -> [String: [Int]] {
        struct SDK: Decodable { var platform: String; var sdkVersion: String }
        var sdks: [String: [Int]] = [:]
        for sdk in ((try? decoder.decode([String: SDK].self, from: data)) ?? [:]).values {
            guard let version = version(sdk.sdkVersion).map({ Array($0.prefix(2)) }) else { continue }
            // com.apple.platform.iphoneos → com.apple.platform.iphonesimulator
            let platform = sdk.platform.hasSuffix("os") ? String(sdk.platform.dropLast(2)) + "simulator" : sdk.platform
            if sdks[platform].map({ $0.lexicographicallyPrecedes(version) }) ?? true { sdks[platform] = version }
        }
        return sdks
    }

    /// `simctl list devices -j`: runtimes that still have simulators, and the simulators whose runtime is gone.
    static func parseDevices(_ data: Data) -> (inUse: Set<String>, unavailable: [Device])? {
        struct List: Decodable { var devices: [String: [Device]] }
        guard let list = try? decoder.decode(List.self, from: data) else { return nil }
        return (Set(list.devices.filter { !$0.value.isEmpty }.keys),
                list.devices.values.flatMap { $0 }.filter { !$0.isAvailable }.sorted { $0.name < $1.name })
    }

    /// Runtimes older than the installed Xcode's SDK for their platform that no simulator uses. The SDK's own runtime,
    /// betas newer than it, and platforms this Xcode has no SDK for are never offered.
    static func oldRuntimes(_ runtimes: [Runtime], sdks: [String: [Int]], inUse: Set<String>) -> [Runtime] {
        runtimes.filter { runtime in
            guard runtime.deletable == true, runtime.state ?? "Ready" == "Ready", !inUse.contains(runtime.runtimeIdentifier),
                  let sdk = runtime.platformIdentifier.flatMap({ sdks[$0] }),
                  let version = version(runtime.version) else { return false }
            return Array(version.prefix(2)).lexicographicallyPrecedes(sdk)
        }
    }
}

// MARK: - Xcode

extension Disk {
    static func derivedData(_ places: DiskPlaces, now: Date) -> [DiskEntry] {
        let folders = contents(places.derivedData).filter(isDirectory)
        return zip(folders, sizes(folders)).map { folder, size in
            let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist"))
            let used = info?["LastAccessedDate"] as? Date ?? modified(folder)
            let title = (info?["WorkspacePath"] as? String).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? projectName(folder.lastPathComponent)
            return DiskEntry(id: folder.path, category: .derivedData, title: title, size: size, lastUsed: used,
                             selected: stale(used, days: 30, now: now), cleanup: .trash([folder]))
        }
    }

    /// "Komma-dsfwfnegnmohgsdefgkfwqanvnaf" → "Komma". Xcode's own caches keep their names.
    static func projectName(_ folder: String) -> String {
        folder.range(of: "-[a-z]{28}$", options: .regularExpression).map { String(folder[..<$0.lowerBound]) } ?? folder
    }

    /// Every version but the newest two is selected.
    static func deviceSupport(_ places: DiskPlaces) -> [DiskEntry] {
        let folders = contents(places.deviceSupport).filter(isDirectory)
        let keep = newest(folders.map(\.lastPathComponent), count: 2)
        return zip(folders, sizes(folders)).map { folder, size in
            DiskEntry(id: folder.path, category: .deviceSupport, title: folder.lastPathComponent, size: size, lastUsed: modified(folder),
                      selected: !keep.contains(folder.lastPathComponent), cleanup: .trash([folder]))
        }
    }

    static func previews(_ places: DiskPlaces) -> [DiskEntry] {
        guard FileManager.default.fileExists(atPath: places.previews.path) else { return [] }
        return [DiskEntry(id: "previews", category: .previews, title: "Preview simulators", size: size(places.previews), lastUsed: nil,
                          selected: true, cleanup: .tool("xcrun", ["simctl", "--set", "previews", "delete", "all"]))]
    }

    /// Archives/<date>/<name>.xcarchive. Never selected: their dSYMs may be needed for crash reports.
    static func archives(_ places: DiskPlaces) -> [DiskEntry] {
        let archives = contents(places.archives).filter(isDirectory).flatMap(contents).filter { $0.pathExtension == "xcarchive" }
        return zip(archives, sizes(archives)).map { archive, size in
            DiskEntry(id: archive.path, category: .archives, title: archive.deletingPathExtension().lastPathComponent, size: size,
                      lastUsed: modified(archive), selected: false, cleanup: .trash([archive]))
        }
    }
}

// MARK: - Android, Gradle

extension Disk {
    /// AVDs not opened for 30 days, and system images no AVD uses.
    static func android(_ places: DiskPlaces, now: Date) -> [DiskEntry] {
        let avds = contents(places.avd).filter { $0.pathExtension == "avd" }
        var used = Set<String>()
        var readAll = true
        for avd in avds {
            let ini = try? String(contentsOf: avd.appendingPathComponent("config.ini"), encoding: .utf8)
            if let image = ini.flatMap(avdImage) { used.insert(image) } else { readAll = false }
        }
        // The emulator writes into the AVD folder whenever it runs.
        let opened = Dictionary(uniqueKeysWithValues: avds.map { ($0, contents($0).compactMap(modified).max()) })
        let stale = avds.filter { self.stale(opened[$0] ?? nil, days: 30, now: now) }
        var entries = zip(stale, sizes(stale)).map { avd, size in
            DiskEntry(id: avd.path, category: .avds, title: avd.deletingPathExtension().lastPathComponent, size: size,
                      lastUsed: opened[avd] ?? nil, selected: false, cleanup: .trash([avd, avd.deletingPathExtension().appendingPathExtension("ini")]))
        }
        // An AVD whose image can't be read might use any of them.
        guard readAll, let root = places.systemImages else { return entries }
        let images = contents(root).filter(isDirectory).flatMap(contents).filter(isDirectory).flatMap(contents).filter(isDirectory)
        let unused = images.filter { !used.contains("system-images/" + $0.pathComponents.suffix(3).joined(separator: "/")) }
        entries += zip(unused, sizes(unused)).map { image, size in
            DiskEntry(id: image.path, category: .systemImages, title: image.pathComponents.suffix(3).joined(separator: " · "), size: size,
                      lastUsed: nil, selected: true, cleanup: .trash([image]))
        }
        return entries
    }

    /// `image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/` from an AVD's config.ini.
    static func avdImage(_ ini: String) -> String? {
        for line in ini.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "image.sysdir.1" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return nil
    }

    /// Wrapper distributions and version caches older than the newest. Shared caches (modules-2…) are left alone.
    static func gradle(_ places: DiskPlaces) -> [DiskEntry] {
        func old(_ folders: [URL], _ kind: String) -> [DiskEntry] {
            let versioned = folders.filter { isDirectory($0) && version($0.lastPathComponent) != nil }
            let keep = newest(versioned.map(\.lastPathComponent), count: 1)
            let old = versioned.filter { !keep.contains($0.lastPathComponent) }
            return zip(old, sizes(old)).map { folder, size in
                DiskEntry(id: folder.path, category: .gradle, title: "Gradle \(versionText(folder.lastPathComponent) ?? "") \(kind)", size: size,
                          lastUsed: modified(folder), selected: true, cleanup: .trash([folder]))
            }
        }
        return old(contents(places.gradleDists), "wrapper") + old(contents(places.gradleCaches), "caches")
    }

    /// "17.1" from "iPhone15,2 17.1 (21B80)", "8.4" from "gradle-8.4-bin".
    static func versionText(_ name: String) -> String? {
        name.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(name[$0]) }
    }

    static func version(_ name: String) -> [Int]? {
        versionText(name).map { $0.split(separator: ".").compactMap { Int($0) } }
    }

    /// Names whose version is among the newest `count` distinct versions. Names without one are kept too.
    static func newest(_ names: [String], count: Int) -> Set<String> {
        let top = Set(Set(names.compactMap(version)).sorted { $1.lexicographicallyPrecedes($0) }.prefix(count))
        return Set(names.filter { version($0).map(top.contains) ?? true })
    }
}

// MARK: - Docker, package caches, node_modules

extension Disk {
    /// Only while a Docker runtime is up: asking would otherwise start the VM, the opposite of what Ramback is for.
    static func docker(tools: Tools) async -> [DiskEntry] {
        guard let docker = tools["docker"], running().docker,
              let df = await Tools.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 30), df.status == 0,
              let dangling = await Tools.run(docker, ["image", "ls", "--filter", "dangling=true", "--format", "{{json .}}"], timeout: 30),
              dangling.status == 0 else { return [] }
        let sizes = parseDocker(df: df.data, dangling: dangling.data)
        return [
            DiskEntry(id: "docker:images", category: .docker, title: "Dangling images", size: sizes.images, lastUsed: nil, selected: false,
                      cleanup: .tool("docker", ["image", "prune", "--force"])),
            DiskEntry(id: "docker:build", category: .docker, title: "Build cache", size: sizes.buildCache, lastUsed: nil, selected: false,
                      cleanup: .tool("docker", ["builder", "prune", "--all", "--force"])),
        ]
    }

    /// Dangling images from `docker image ls`, and build cache Docker can drop from `docker system df`.
    static func parseDocker(df: Data, dangling: Data) -> (images: UInt64, buildCache: UInt64) {
        func rows(_ data: Data) -> [[String: Any]] {
            String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        let images = rows(dangling).reduce(0) { $0 + Tools.parseSize($1["Size"] as? String ?? "") }
        // "1.2GB (50%)"
        let cache = rows(df).first { $0["Type"] as? String == "Build Cache" }?["Reclaimable"] as? String ?? ""
        return (images, Tools.parseSize(String(cache.split(separator: " ").first ?? "")))
    }

    // ponytail: sized by folder; pnpm store prune can free a little less than shown.
    static func packageCaches(_ places: DiskPlaces) -> [DiskEntry] {
        // Not `brew cleanup`: it also deletes old versions from the Cellar, which the size shown doesn't count.
        let brew = places.home.appendingPathComponent("Library/Caches/Homebrew").path.replacingOccurrences(of: "'", with: #"'\''"#)
        let caches = [("npm", ".npm/_cacache", "npm cache clean --force"), ("pnpm", "Library/pnpm/store", "pnpm store prune"),
                      ("Yarn", "Library/Caches/Yarn", "yarn cache clean"), ("CocoaPods", "Library/Caches/CocoaPods", "pod cache clean --all"),
                      ("Homebrew", "Library/Caches/Homebrew", "rm -rf '\(brew)'")]
            .map { (title: $0.0, url: places.home.appendingPathComponent($0.1), command: $0.2) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        return zip(caches, sizes(caches.map(\.url))).map { cache, size in
            DiskEntry(id: "cache:\(cache.title)", category: .packageCaches, title: cache.title, size: size, lastUsed: nil, selected: false,
                      cleanup: .shell(cache.command))
        }
    }

    /// node_modules of git projects untouched for 90 days, up to three folders down in each picked folder.
    // ponytail: only the project's top node_modules; nested workspace ones stay until someone misses them.
    static func nodeModules(_ places: DiskPlaces, now: Date) -> [DiskEntry] {
        func projects(_ folder: URL, depth: Int) -> [URL] {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return [folder] }
            guard depth > 0 else { return [] }
            return contents(folder).filter { isDirectory($0) && $0.lastPathComponent != "node_modules" }.flatMap { projects($0, depth: depth - 1) }
        }
        // git touches .git/index on commit, checkout and status, so its date says when the project was last worked on.
        func touched(_ project: URL) -> Date? {
            modified(project.appendingPathComponent(".git/index")) ?? modified(project.appendingPathComponent(".git"))
        }
        let found = Set(places.projects.flatMap { projects($0, depth: 3) }).sorted { $0.path < $1.path }
            .filter { isDirectory($0.appendingPathComponent("node_modules")) && stale(touched($0), days: 90, now: now) }
        let folders = found.map { $0.appendingPathComponent("node_modules") }
        return zip(found, sizes(folders)).map { project, size in
            DiskEntry(id: project.path + "/node_modules", category: .nodeModules, title: project.lastPathComponent, size: size,
                      lastUsed: touched(project), selected: false, cleanup: .trash([project.appendingPathComponent("node_modules")]))
        }
    }
}

// MARK: - Files

extension Disk {
    static func stale(_ date: Date?, days: Double, now: Date) -> Bool {
        date.map { now.timeIntervalSince($0) >= days * 86400 } ?? false
    }

    static func contents(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                      options: .skipsHiddenFiles)) ?? []
    }

    /// A real folder; symlinks don't count, so nothing outside is walked.
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Allocated bytes, folders measured side by side.
    static func sizes(_ folders: [URL]) -> [UInt64] {
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: folders.count)
        buffer.initialize(repeating: 0)
        defer { buffer.deallocate() }
        // Each iteration writes only its own slot.
        nonisolated(unsafe) let sizes = buffer
        DispatchQueue.concurrentPerform(iterations: folders.count) { sizes[$0] = size(folders[$0]) }
        return Array(buffer)
    }

    /// Allocated bytes in a folder, symlinks not followed. About 45k files a second, so a 40 GB DerivedData takes seconds.
    static func size(_ folder: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [],
                                                         errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
