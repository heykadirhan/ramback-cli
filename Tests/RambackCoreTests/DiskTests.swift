import Foundation
import Testing
@testable import RambackCore

private func runtime(_ id: String, _ version: String, platform: String = "iphonesimulator", deletable: Bool = true) -> String {
    let os = platform == "watchsimulator" ? "watchOS" : "iOS"
    return """
    "\(id)": { "identifier": "\(id)", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.\(os)-\(version.replacingOccurrences(of: ".", with: "-"))",
      "version": "\(version)", "platformIdentifier": "com.apple.platform.\(platform)", "sizeBytes": 8494282293,
      "deletable": \(deletable), "state": "Ready", "lastUsedAt": "2026-10-17T01:54:04Z", "kind": "Patchable Cryptex Disk Image" }
    """
}

@Test func onlyOldUnusedRuntimesAreOffered() {
    let runtimes = Disk.parseRuntimes(Data("""
    { \(runtime("A", "26.5")), \(runtime("B", "18.6")), \(runtime("C", "17.5")), \(runtime("D", "27.0")),
      \(runtime("E", "10.5", platform: "watchsimulator", deletable: false)), \(runtime("F", "17.0", platform: "xrsimulator")) }
    """.utf8))
    // The SDK's own build isn't installed here (23F81a vs 23F77); the version is what matches.
    let sdks = Disk.parseSDKs(Data("""
    { "iphoneos26.5": { "chosenRuntimeBuild": "23F81a", "platform": "com.apple.platform.iphoneos", "sdkBuild": "23F81a", "sdkVersion": "26.5.1" },
      "watchos26.5": { "platform": "com.apple.platform.watchos", "sdkVersion": "26.5" } }
    """.utf8))
    #expect(runtimes.count == 6)
    #expect(sdks == ["com.apple.platform.iphonesimulator": [26, 5], "com.apple.platform.watchsimulator": [26, 5]])
    // A = the SDK's, B has simulators, D is a newer beta, E isn't deletable, F's platform has no SDK in this Xcode.
    let old = Disk.oldRuntimes(runtimes, sdks: sdks, inUse: ["com.apple.CoreSimulator.SimRuntime.iOS-18-6"])
    #expect(old.map(\.identifier) == ["C"])
    #expect(old.first?.sizeBytes == 8_494_282_293)
    #expect(old.first?.lastUsedAt != nil)
}

@Test func devicesTellRuntimesInUseAndUnavailableSimulators() throws {
    let devices = try #require(Disk.parseDevices(Data("""
    { "devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
        { "udid": "1", "name": "iPhone 17 Pro", "isAvailable": true, "state": "Shutdown", "dataPathSize": 1221025792, "lastBootedAt": "2026-10-15T00:10:13Z" } ],
      "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
        { "udid": "2", "name": "iPhone 14", "isAvailable": false, "availabilityError": "runtime profile not found", "dataPathSize": 300000000, "logPathSize": 4096 } ],
      "com.apple.CoreSimulator.SimRuntime.iOS-18-6": []
    } }
    """.utf8)))
    #expect(devices.inUse == ["com.apple.CoreSimulator.SimRuntime.iOS-26-5", "com.apple.CoreSimulator.SimRuntime.iOS-16-4"])
    #expect(devices.unavailable.map(\.udid) == ["2"])
    #expect(devices.unavailable.first?.logPathSize == 4096)
    #expect(Disk.parseDevices(Data("not json".utf8)) == nil)
}

@Test func dockerReclaimableSizes() {
    let df = Data("""
    {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
    {"Active":"0","Reclaimable":"512.5MB","Size":"512.5MB","TotalCount":"31","Type":"Build Cache"}
    """.utf8)
    let dangling = Data("""
    {"ID":"a1","Repository":"<none>","Size":"1.1GB","Tag":"<none>"}
    {"ID":"b2","Repository":"<none>","Size":"250MB","Tag":"<none>"}
    """.utf8)
    let sizes = Disk.parseDocker(df: df, dangling: dangling)
    #expect(sizes.images == 1_350_000_000)
    #expect(sizes.buildCache == 512_500_000)
    #expect(Disk.parseDocker(df: Data(), dangling: Data()).buildCache == 0)
}

@Test func avdConfigNamesItsSystemImage() {
    let ini = """
    avd.ini.encoding=UTF-8
    hw.lcd.density = 420
    image.sysdir.1 = system-images/android-35/google_apis/arm64-v8a/
    tag.id=google_apis
    """
    #expect(Disk.avdImage(ini) == "system-images/android-35/google_apis/arm64-v8a")
    #expect(Disk.avdImage("hw.ramSize=2048") == nil)
}

@Test func newestVersionsAreKept() {
    let support = ["iPhone15,2 17.1 (21B80)", "17.5 (21F79)", "iPhone16,1 18.0 (22A3354)", "iPhone17,1 18.0 (22A3354)", "iPhone17,1 18.1 (22B83)", "Notes"]
    #expect(Disk.newest(support, count: 2) == ["iPhone16,1 18.0 (22A3354)", "iPhone17,1 18.0 (22A3354)", "iPhone17,1 18.1 (22B83)", "Notes"])
    // 8.10 is newer than 8.9; shared caches have no version and never count as old.
    #expect(Disk.newest(["gradle-8.9-bin", "gradle-8.10.2-all", "gradle-8.4-bin"], count: 1) == ["gradle-8.10.2-all"])
    #expect(Disk.version("modules-2") == nil)
    #expect(Disk.versionText("gradle-8.10.2-all") == "8.10.2")
}

@Test func derivedDataNamesAndAge() {
    #expect(Disk.projectName("Komma-dsfwfnegnmohgsdefgkfwqanvnaf") == "Komma")
    #expect(Disk.projectName("My-App-abcdefghijklmnopqrstuvwxyzab") == "My-App")
    #expect(Disk.projectName("ModuleCache.noindex") == "ModuleCache.noindex")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Disk.stale(now.addingTimeInterval(-31 * 86400), days: 30, now: now))
    #expect(!Disk.stale(now.addingTimeInterval(-29 * 86400), days: 30, now: now))
    #expect(!Disk.stale(nil, days: 30, now: now))
}

@Test func trashStaysInsideItsFolders() {
    #expect(Disk.isInside("/Users/me/Library/Developer/Xcode/DerivedData/App-x", "/Users/me/Library/Developer/Xcode/DerivedData"))
    #expect(!Disk.isInside("/Users/me/Library/Developer/Xcode/DerivedData", "/Users/me/Library/Developer/Xcode/DerivedData"))
    #expect(!Disk.isInside("/Users/me/Library/Developer/Xcode/DerivedData/../../..", "/Users/me/Library/Developer/Xcode/DerivedData"))
    #expect(!Disk.isInside("/Users/me/projects-old/a/node_modules", "/Users/me/projects"))
    let places = DiskPlaces(home: URL(fileURLWithPath: "/Users/me"), projects: ["/Users/me/code"], environment: [:])
    #expect(places.roots(.nodeModules).map(\.path) == ["/Users/me/code"])
    #expect(places.roots(.runtimes).isEmpty)
    #expect(Disk.trash([URL(fileURLWithPath: "/etc/hosts")], roots: places.roots(.derivedData), nodeModules: false) != nil)
}

@Test func previewsAndGradleWait() {
    #expect(DiskCategory.previews.blocked(xcodeOpen: true, gradleRunning: false) != nil)
    #expect(DiskCategory.previews.blocked(xcodeOpen: false, gradleRunning: true) == nil)
    #expect(DiskCategory.gradle.blocked(xcodeOpen: false, gradleRunning: true) != nil)
    #expect(DiskCategory.allCases.filter(\.permanent) == [.runtimes, .unavailableSimulators, .previews, .docker, .packageCaches])
}

@Test func symlinkedNodeModulesAreLeftAlone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let shared = root.appendingPathComponent("a/node_modules"), linked = root.appendingPathComponent("b/node_modules")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: shared)
    for project in ["a", "b"] {
        let git = root.appendingPathComponent("\(project)/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100 * 86400)], ofItemAtPath: git.path)
    }
    let places = DiskPlaces(home: root, projects: [root.path])
    #expect(Disk.nodeModules(places, now: Date()).map(\.title) == ["a"])
    #expect(Disk.trash([linked], roots: places.roots(.nodeModules), nodeModules: true) != nil)
    #expect(FileManager.default.fileExists(atPath: shared.path))
}

@Test func homebrewCleansOnlyItsDownloadCache() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("ramback-test-\(UUID().uuidString)/it's me")
    defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
    let cache = home.appendingPathComponent("Library/Caches/Homebrew"), other = home.appendingPathComponent("Library/Caches/Other")
    try FileManager.default.createDirectory(at: cache.appendingPathComponent("downloads"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let brew = try #require(Disk.packageCaches(DiskPlaces(home: home)).first { $0.title == "Homebrew" })
    guard case let .shell(command) = brew.cleanup else { Issue.record("not a shell command"); return }
    #expect(await Tools.run("/bin/sh", ["-c", command])?.status == 0)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
}
