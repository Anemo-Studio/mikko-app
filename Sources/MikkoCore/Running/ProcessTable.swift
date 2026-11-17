import Darwin
import Foundation

/// A PID alone is reused by the OS; pid + start time is a stable identity (R-6).
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public var pid: Int32
    public var startSec: Int64
    public var startUsec: Int64
    public init(pid: Int32, startSec: Int64, startUsec: Int64) {
        self.pid = pid; self.startSec = startSec; self.startUsec = startUsec
    }
    public var startDate: Date { Date(timeIntervalSince1970: Double(startSec) + Double(startUsec) / 1e6) }
    public var key: String { "\(pid):\(startSec).\(startUsec)" }
}

public struct Listener: Hashable, Sendable, Codable {
    public var port: UInt16
    public var address: String
    public var isWildcard: Bool
    public var isLoopback: Bool
    public init(port: UInt16, address: String, isWildcard: Bool, isLoopback: Bool) {
        self.port = port; self.address = address; self.isWildcard = isWildcard; self.isLoopback = isLoopback
    }
    /// Reachable from other machines on the network (R-8). `::` is dual-stack, so it counts.
    public var exposedToLAN: Bool { !isLoopback }
}

public struct ProcRecord: Sendable {
    public var identity: ProcessIdentity
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    public var argv: [String]
    /// Only the few marker variables mikko needs — never the full environment.
    public var environment: [String: String]
    public var cwd: String?
    public var footprint: UInt64
    public var cpuNs: UInt64
    public var listeners: [Listener]

    public var pid: Int32 { identity.pid }

    public init(identity: ProcessIdentity, ppid: Int32, pgid: Int32 = 0, uid: UInt32, name: String, path: String? = nil,
                argv: [String] = [], environment: [String: String] = [:], cwd: String? = nil,
                footprint: UInt64 = 0, cpuNs: UInt64 = 0, listeners: [Listener] = []) {
        self.identity = identity; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.name = name
        self.path = path; self.argv = argv; self.environment = environment; self.cwd = cwd
        self.footprint = footprint; self.cpuNs = cpuNs; self.listeners = listeners
    }
}

public struct ProcessSnapshot: Sendable {
    public var records: [ProcRecord]
    /// Live (ESTABLISHED) TCP connections per local port — the "is anyone using this server" signal.
    public var establishedByLocalPort: [UInt16: Int]
    public var takenAt: Date
    public init(records: [ProcRecord], establishedByLocalPort: [UInt16: Int] = [:], takenAt: Date = .now) {
        self.records = records; self.establishedByLocalPort = establishedByLocalPort; self.takenAt = takenAt
    }
}

/// Reads the process table with libproc/sysctl. No root, no entitlement, no subprocesses.
public final class ProcessTable: @unchecked Sendable {
    public static let markerKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "AI_AGENT",
        "CODEX_THREAD_ID", "CODEX_SANDBOX", "CURSOR_AGENT", "CURSOR_TRACE_ID", "TERM_PROGRAM",
    ]

    private struct Static { var path: String?; var argv: [String]; var env: [String: String] }
    private var cache: [ProcessIdentity: Static] = [:]
    private let lock = NSLock()
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public init() {}

    public func snapshot() -> ProcessSnapshot {
        lock.lock(); defer { lock.unlock() }
        let me = getuid()
        var records: [ProcRecord] = []
        var established: [UInt16: Int] = [:]
        var alive = Set<ProcessIdentity>()

        for k in Self.allKinfo() {
            let pid = k.kp_proc.p_pid
            guard pid > 0 else { continue }
            let start = k.kp_proc.p_un.__p_starttime
            let identity = ProcessIdentity(pid: pid, startSec: Int64(start.tv_sec), startUsec: Int64(start.tv_usec))
            let uid = k.kp_eproc.e_ucred.cr_uid
            var rec = ProcRecord(identity: identity, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid, uid: uid,
                                 name: withUnsafeBytes(of: k.kp_proc.p_comm) {
                                     String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                                 })
            if uid == me {
                alive.insert(identity)
                let st: Static
                // The path is re-read every time: a process that exec()s keeps its identity
                // but becomes a different program, and the cached argv would be wrong.
                let livePath = Self.exePath(pid)
                if let cached = cache[identity], cached.path == livePath {
                    st = cached
                } else {
                    let args = Self.procArgs(pid)
                    st = Static(path: livePath, argv: args?.argv ?? [], env: args?.env ?? [:])
                    cache[identity] = st
                }
                rec.path = st.path
                rec.argv = st.argv
                rec.environment = st.env
                if let p = st.path { rec.name = (p as NSString).lastPathComponent }
                rec.cwd = Self.cwd(pid)
                if let u = Self.usage(pid) {
                    rec.footprint = u.ri_phys_footprint
                    rec.cpuNs = (u.ri_user_time + u.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
                }
                let sockets = Self.tcpSockets(pid)
                rec.listeners = sockets.listeners
                for port in sockets.established { established[port, default: 0] += 1 }
            }
            records.append(rec)
        }
        cache = cache.filter { alive.contains($0.key) }
        return ProcessSnapshot(records: records, establishedByLocalPort: established)
    }

    /// Current identity of a pid, or nil if it is gone. Used to re-validate before every signal.
    public static func identity(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A zombie still has an entry but is no longer running.
        if info.pbi_status == UInt32(SZOMB) { return nil }
        return ProcessIdentity(pid: pid, startSec: Int64(info.pbi_start_tvsec), startUsec: Int64(info.pbi_start_tvusec))
    }

    // MARK: - libproc / sysctl

    static func allKinfo() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return Array(buf.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    static func exePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : nil
    }

    static func procArgs(_ pid: Int32) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var p = 4
        func cstr() -> String {
            let s = p
            while p < size, buf[p] != 0 { p += 1 }
            return String(decoding: buf[s..<p], as: UTF8.self)
        }
        _ = cstr() // executable path
        while p < size, buf[p] == 0 { p += 1 }
        var argv: [String] = []
        for _ in 0..<max(argc, 0) where p < size { argv.append(cstr()); p += 1 }
        var env: [String: String] = [:]
        while p < size {
            let entry = cstr(); p += 1
            if entry.isEmpty { break }
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            if markerKeys.contains(key) { env[key] = String(entry[entry.index(after: eq)...]) }
        }
        return (argv, env)
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return s.isEmpty ? nil : s
    }

    static func usage(_ pid: Int32) -> rusage_info_v4? {
        var r = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &r) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? r : nil
    }

    static func tcpSockets(_ pid: Int32) -> (listeners: [Listener], established: [UInt16]) {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return ([], []) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        var listeners: [Listener] = []
        var established: [UInt16] = []
        for fd in fds.prefix(Int(max(got, 0)) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let ssz = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, ssz) == ssz,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            let ini = tcp.tcpsi_ini
            let port = UInt16(truncatingIfNeeded: ini.insi_lport).byteSwapped
            if tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) { established.append(port); continue }
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN), port != 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var wildcard = false, loopback = false
            if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
                var a = ini.insi_laddr.ina_6
                inet_ntop(AF_INET6, &a, &text, socklen_t(text.count))
                let s = text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                wildcard = s == "::"; loopback = s == "::1"
            } else {
                var a = ini.insi_laddr.ina_46.i46a_addr4
                inet_ntop(AF_INET, &a, &text, socklen_t(text.count))
                let host = UInt32(bigEndian: a.s_addr)
                wildcard = host == 0; loopback = (host >> 24) == 127
            }
            let l = Listener(port: port, address: text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isWildcard: wildcard, isLoopback: loopback)
            if !listeners.contains(l) { listeners.append(l) }
        }
        return (listeners, established)
    }
}
