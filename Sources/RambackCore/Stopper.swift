import Darwin
import Foundation

public enum Stopper {
    public enum Result: Sendable, Equatable {
        case stopped
        /// Still there after the grace period; offer Force stop (never done automatically).
        case stillRunning
        case failed(String)
    }

    /// Stops politely and waits up to `grace` seconds. `force` sends SIGKILL to whatever is left.
    public static func stop(_ item: Item, tools: Tools, force: Bool = false, grace: TimeInterval = 5) async -> Result {
        guard let method = item.stop else { return .failed("\(item.title) isn't stopped by Ramback.") }
        let pids = item.pids.filter(safeToSignal)
        if force {
            // Containers have no host processes to kill; an empty list would read as "gone" and log a stop that never happened.
            if case let .containers(ids) = method {
                guard let docker = tools["docker"] else { return .failed("docker not found.") }
                return await Tools.run(docker, ["kill"] + ids, timeout: 20)?.status == 0 ? .stopped : .failed("docker kill failed.")
            }
            guard !pids.isEmpty else { return .failed("\(item.title) belongs to the system or another user.") }
            pids.forEach { kill($0, SIGKILL) }
            return await gone(pids, within: grace) ? .stopped : .stillRunning
        }
        switch method {
        case .signal:
            guard !pids.isEmpty else { return .failed("\(item.title) belongs to the system or another user.") }
            // EPERM for our own process only happens inside the App Sandbox (Lite), when it may not signal others.
            if pids.map({ kill($0, SIGTERM) == -1 && errno == EPERM }).allSatisfy({ $0 }) {
                return .failed("macOS doesn't let this version stop \(item.title). Stop it in Terminal.")
            }
        case let .simulator(udid, previews):
            guard let xcrun = tools["xcrun"] else { return .failed("xcrun not found.") }
            let set = previews ? ["--set", "previews"] : []
            let out = await Tools.run(xcrun, ["simctl"] + set + ["shutdown", udid], timeout: 30)
            if out?.status != 0 { return .failed("simctl couldn't shut down \(item.title).") }
        case let .emulator(serial):
            if let adb = tools["adb"], let serial, await Tools.run(adb, ["-s", serial, "emu", "kill"])?.status == 0 {
                break
            }
            pids.prefix(1).forEach { kill($0, SIGTERM) }
        case let .containers(ids):
            guard let docker = tools["docker"] else { return .failed("docker not found.") }
            // docker stop waits 10 s itself before killing.
            let out = await Tools.run(docker, ["stop"] + ids, timeout: 20)
            return out?.status == 0 ? .stopped : .failed("docker stop failed.")
        }
        return await gone(pids, within: grace) ? .stopped : .stillRunning
    }

    /// Brings back what a stop took down: boots the simulator, relaunches the AVD, starts the containers.
    public static func undo(_ undo: Undo, tools: Tools) async -> Bool {
        switch undo {
        case let .boot(udid):
            guard let xcrun = tools["xcrun"], await Tools.run(xcrun, ["simctl", "boot", udid], timeout: 60)?.status == 0 else { return false }
            _ = await Tools.run("/usr/bin/open", ["-a", "Simulator"])
            return true
        case let .avd(name):
            guard let emulator = tools["emulator"] else { return false }
            return Tools.launch(emulator, ["-avd", name])
        case let .start(ids):
            guard let docker = tools["docker"] else { return false }
            return await Tools.run(docker, ["start"] + ids, timeout: 30)?.status == 0
        }
    }

    /// Only the user's own processes, never Apple's, never launchd, never ourselves.
    public static func safeToSignal(_ pid: Int32) -> Bool {
        guard pid > 1, pid != getpid(), pid != getppid() else { return false }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == getuid() else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(nulTerminated: buffer)
        return !path.hasPrefix("/System/") && !path.hasPrefix("/usr/libexec/") && !path.hasPrefix("/sbin/")
    }

    /// Gone or a zombie. Asks PROC_PIDTBSDINFO rather than `kill(pid, 0)`, which the App Sandbox answers with EPERM forever.
    static func gone(_ pids: [Int32], within seconds: TimeInterval) async -> Bool {
        func alive(_ pid: Int32) -> Bool {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size && bsd.pbi_status != UInt32(SZOMB)
        }
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if !pids.contains(where: alive) { return true }
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
