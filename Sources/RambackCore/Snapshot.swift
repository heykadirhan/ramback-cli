import Darwin
import Foundation

/// One of the user's processes, as seen in a single pass over libproc.
public struct Proc: Codable, Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Executable path.
    public var path: String
    /// argv, including argv[0] (which a process may have retitled, e.g. "next-server (v16)").
    public var args: [String]
    public var cwd: String
    /// Bytes; the "Memory" column in Activity Monitor.
    public var footprint: UInt64
    /// User + system CPU time in nanoseconds.
    public var cpu: UInt64
    public var started: Date
    public var listening: [UInt16] = []
    /// Established TCP connections into one of `listening`.
    public var inbound: Int = 0
    /// The app macOS holds responsible, when it isn't the process itself (XPC services such as VM hosts).
    public var responsible: Int32?
    /// Executable name; stored because every detector asks for it.
    public var name: String

    public init(pid: Int32, ppid: Int32, path: String, args: [String], cwd: String = "/", footprint: UInt64 = 0, cpu: UInt64 = 0,
                started: Date = .distantPast, listening: [UInt16] = [], inbound: Int = 0, responsible: Int32? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        name = (path as NSString).lastPathComponent
        self.args = args
        self.cwd = cwd
        self.footprint = footprint
        self.cpu = cpu
        self.started = started
        self.listening = listening
        self.inbound = inbound
        self.responsible = responsible
    }
}

public struct Snapshot: Codable, Sendable {
    public var procs: [Proc]
    public var taken: Date

    public init(procs: [Proc], taken: Date = Date()) {
        self.procs = procs
        self.taken = taken
    }
}

// MARK: - Live

#if !LITE
// Private: never in the App Store build (guideline 2.5.1).
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t
#endif

extension Snapshot {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctl(&mib, 2, &value, &size, nil, 0)
        return Int(value)
    }()

    /// Every process owned by the current user, in one pass. No `ps`, no `lsof`.
    /// `argsCache` keeps argv per pid and start time, since argv rarely changes and costs a sysctl.
    public static func take(argsCache: inout [Int32: (Date, [String])]) -> Snapshot {
        let uid = getuid()
        var procs: [Proc] = []
        var seen = Set<Int32>()
#if LITE
        let tcp = tcpTable()
#endif

        for pid in allPids() where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbi_uid == uid else { continue }
            let started = Date(timeIntervalSince1970: Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1e6)

            let args: [String]
            if let cached = argsCache[pid], cached.0 == started {
                args = cached.1
            } else {
                args = arguments(pid)
                argsCache[pid] = (started, args)
            }
            seen.insert(pid)

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(nulTerminated: pathBuffer) : (args.first ?? "")

            let (footprint, ticks) = usage(pid)
            var proc = Proc(pid: pid, ppid: Int32(bsd.pbi_ppid), path: path, args: args, cwd: cwd(pid), footprint: footprint,
                            cpu: ticks * timebase.numer / timebase.denom, started: started)
#if LITE
            proc.listening = Set(tcp.filter { $0.pid == pid && $0.state == TSI_S_LISTEN }.map(\.port)).sorted()
            proc.inbound = tcp.filter { $0.pid == pid && $0.state == TSI_S_ESTABLISHED && proc.listening.contains($0.port) }.count
#else
            let owner = responsiblePid(pid)
            if owner > 0, owner != pid { proc.responsible = owner }
            // Apple's own daemons never host a dev server; skipping them keeps the pass fast.
            if !path.hasPrefix("/System/"), !path.hasPrefix("/usr/libexec/") { sockets(pid, into: &proc) }
#endif
            procs.append(proc)
        }
        argsCache = argsCache.filter { seen.contains($0.key) }
        return Snapshot(procs: procs)
    }

#if LITE
    /// The App Sandbox denies proc_listallpids, proc_pid_rusage and per-fd socket info for other processes (see
    /// Spike/LiteSpike/RESULTS.md); these are the calls it allows instead.
    private static func allPids() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        let stride = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map(\.kp_proc.p_pid)
    }

    /// Footprint from TASK_VM_INFO on the task *name* port (the same number as rusage), CPU from PROC_PIDTASKINFO.
    private static func usage(_ pid: Int32) -> (footprint: UInt64, ticks: UInt64) {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let ticks = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? task.pti_total_user + task.pti_total_system : 0
        var name: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return (task.pti_resident_size, ticks) }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(name, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return (result == KERN_SUCCESS ? info.phys_footprint : task.pti_resident_size, ticks)
    }

    /// Every TCP socket with its owner, from net.inet.tcp.pcblist_n (what `netstat -anv` prints). Records are (len, kind)
    /// tagged and 8-byte aligned; offsets measured on macOS 26: xinpcb_n lport@18, xsocket_n last_pid@68, xtcpcb_n t_state@36.
    // ponytail: xnu-private layouts; a record of unexpected length ends the walk (no ports rather than wrong ones).
    static func tcpTable() -> [(pid: Int32, port: UInt16, state: Int32)] {
        var size = 0
        guard sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0) == 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size + 16384)
        size = buffer.count
        guard sysctlbyname("net.inet.tcp.pcblist_n", &buffer, &size, nil, 0) == 0 else { return [] }
        func u32(_ offset: Int) -> UInt32 { buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) } }
        let expected: [UInt32: Int] = [0x10: 104, 0x01: 104, 0x20: 204]
        var rows: [(pid: Int32, port: UInt16, state: Int32)] = []
        let header = Int(u32(0))
        var offset = header
        while offset + 8 <= size {
            let length = Int(u32(offset)), kind = u32(offset + 4)
            guard length > 8, length != header, offset + length <= size else { break }  // the trailing xinpgen ends the list
            if let want = expected[kind], want != length { return [] }
            switch kind {
            case 0x10: rows.append((0, UInt16(buffer[offset + 18]) << 8 | UInt16(buffer[offset + 19]), -1))  // a socket starts
            case 0x01 where !rows.isEmpty: rows[rows.count - 1].pid = Int32(bitPattern: u32(offset + 68))
            case 0x20 where !rows.isEmpty: rows[rows.count - 1].state = Int32(bitPattern: u32(offset + 36))
            default: break
            }
            offset += (length + 7) & ~7
        }
        return rows
    }
#else
    private static func allPids() -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return Array(pids.prefix(max(0, count)))
    }

    /// Footprint is the "Memory" column in Activity Monitor; CPU is in mach ticks.
    private static func usage(_ pid: Int32) -> (footprint: UInt64, ticks: UInt64) {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        } == 0
        return ok ? (usage.ri_phys_footprint, usage.ri_user_time + usage.ri_system_time) : (0, 0)
    }
#endif

    /// argv from KERN_PROCARGS2: argc, the exec path, padding, then argc NUL-terminated strings.
    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // exec path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func cwd(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "/" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Listening TCP ports, and how many established connections came in on them.
    private static func sockets(_ pid: Int32, into proc: inout Proc) {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard used > 0 else { return }

        var listening = Set<UInt16>()
        var established: [UInt16] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            switch tcp.tcpsi_state {
            case TSI_S_LISTEN: listening.insert(port)
            case TSI_S_ESTABLISHED: established.append(port)
            default: break
            }
        }
        proc.listening = listening.sorted()
        proc.inbound = established.filter(listening.contains).count
    }
}

// MARK: - Memory pressure

public enum Pressure: Int, Codable, Sendable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }

    public static var current: Pressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Pressure(rawValue: Int(level)) ?? .normal
    }
}

public enum Memory {
    /// Bytes of swap in use.
    public static var swapUsed: UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}

extension String {
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
