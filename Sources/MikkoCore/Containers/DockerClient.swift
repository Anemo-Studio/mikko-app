import Darwin
import Foundation

public struct DockerError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    /// Parses a complete HTTP/1.1 response read until the peer closed the connection.
    public static func parse(_ raw: Data) -> HTTPResponse? {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var body = Data(raw[split.upperBound...])
        if lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }) {
            body = dechunk(body)
        }
        return HTTPResponse(status: status, body: body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex, let lineEnd = data.range(of: crlf, in: i..<data.endIndex) {
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = min(start + size, data.endIndex)
            out.append(data[start..<end])
            i = min(end + 2, data.endIndex)
        }
        return out
    }
}

/// Talks to a Docker-compatible engine over its unix socket. No dependencies.
public struct DockerClient: Sendable {
    public var socketPath: String
    public var runtimeName: String
    public init(socketPath: String, runtimeName: String) { self.socketPath = socketPath; self.runtimeName = runtimeName }

    /// C-1: every engine found on this Mac (Docker Desktop, OrbStack, Colima, Rancher, Podman).
    public static func discover(home: String = NSHomeDirectory(),
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [DockerClient] {
        var candidates: [(String, String)] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") { candidates.append(("Docker", String(host.dropFirst(7)))) }
        candidates += [("Docker Desktop", "\(home)/.docker/run/docker.sock"), ("OrbStack", "\(home)/.orbstack/run/docker.sock"),
                       ("Rancher Desktop", "\(home)/.rd/docker.sock"),
                       ("Podman", "\(home)/.local/share/containers/podman/machine/podman.sock")]
        for profile in (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/.colima")) ?? [] where !profile.hasPrefix("_") {
            candidates.append((profile == "default" ? "Colima" : "Colima (\(profile))", "\(home)/.colima/\(profile)/docker.sock"))
        }
        var seen = Set<String>()
        return candidates.compactMap { name, path in
            guard FileManager.default.fileExists(atPath: path), let real = PathCanon.real(path), seen.insert(real).inserted else { return nil }
            return DockerClient(socketPath: path, runtimeName: name)
        }
    }

    public func request(_ method: String, _ path: String, timeout: Int = 15) throws -> HTTPResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError(description: "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        // A write to a socket the engine just closed must return an error, not kill the app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < capacity else { throw DockerError(description: "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            socketPath.withCString { _ = strlcpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw DockerError(description: "\(runtimeName) is not running") }
        let req = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        let sent = req.withCString { write(fd, $0, strlen($0)) }
        guard sent > 0 else { throw DockerError(description: "write failed") }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                // A timeout is not the end of the answer: the engine may still be working.
                throw DockerError(description: errno == EAGAIN ? "\(runtimeName) did not answer within \(timeout) s; the operation may still be running" : "read failed")
            }
            if n == 0 { break }
            out.append(buf, count: n)
        }
        guard let response = HTTPResponse.parse(out) else { throw DockerError(description: "no response from \(runtimeName)") }
        return response
    }

    func json(_ method: String, _ path: String, timeout: Int = 15) throws -> Any {
        let r = try request(method, path, timeout: timeout)
        guard (200..<300).contains(r.status) else {
            let message = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["message"] as? String
            throw DockerError(description: message ?? "HTTP \(r.status)")
        }
        return r.body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: r.body)
    }

    public var isReachable: Bool { (try? request("GET", "/_ping", timeout: 3))?.status == 200 }

    // MARK: Containers (C-1)

    public func containers() throws -> [DockerContainer] {
        guard let list = try json("GET", "/containers/json?all=1") as? [[String: Any]] else { return [] }
        return list.compactMap { DockerContainer($0, runtime: runtimeName) }
    }

    public func stats(id: String) -> (cpuPercent: Double, memory: Int64)? {
        guard let s = try? json("GET", "/containers/\(id)/stats?stream=false", timeout: 8) as? [String: Any] else { return nil }
        let mem = ((s["memory_stats"] as? [String: Any])?["usage"] as? NSNumber)?.int64Value ?? 0
        func total(_ key: String) -> (cpu: Double, system: Double, cpus: Double) {
            let c = s[key] as? [String: Any]
            let usage = ((c?["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?.doubleValue ?? 0
            return (usage, (c?["system_cpu_usage"] as? NSNumber)?.doubleValue ?? 0, (c?["online_cpus"] as? NSNumber)?.doubleValue ?? 1)
        }
        let now = total("cpu_stats"), before = total("precpu_stats")
        let sys = now.system - before.system
        let cpu = sys > 0 && before.cpu > 0 ? (now.cpu - before.cpu) / sys * now.cpus * 100 : 0
        return (max(cpu, 0), mem)
    }

    /// `stop`, never `rm`: the container's data stays (R-6).
    public func stop(id: String) throws { _ = try json("POST", "/containers/\(id)/stop?t=10", timeout: 30) }
    public func start(id: String) throws { _ = try json("POST", "/containers/\(id)/start", timeout: 30) }
    public func restart(id: String) throws { _ = try json("POST", "/containers/\(id)/restart?t=10", timeout: 40) }

    // MARK: Disk (C-2, C-3)

    public func diskUsage() throws -> DockerDiskUsage {
        guard let df = try json("GET", "/system/df", timeout: 60) as? [String: Any] else { return DockerDiskUsage() }
        return DockerDiskUsage(df)
    }

    static func filters(_ f: [String: [String]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: f)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    func reclaimed(_ any: Any) -> Int64 { ((any as? [String: Any])?["SpaceReclaimed"] as? NSNumber)?.int64Value ?? 0 }

    public func pruneDanglingImages() throws -> Int64 {
        reclaimed(try json("POST", "/images/prune?filters=\(Self.filters(["dangling": ["true"]]))", timeout: 300))
    }
    public func pruneUnusedImages() throws -> Int64 {
        reclaimed(try json("POST", "/images/prune?filters=\(Self.filters(["dangling": ["false"]]))", timeout: 300))
    }
    public func pruneBuildCache() throws -> Int64 { reclaimed(try json("POST", "/build/prune", timeout: 300)) }
    public func pruneStoppedContainers() throws -> Int64 { reclaimed(try json("POST", "/containers/prune", timeout: 300)) }

    /// Volumes are removed one named volume at a time — never a blanket prune (C-3).
    public func removeVolume(name: String) throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try json("DELETE", "/volumes/\(encoded)", timeout: 60)
    }
}

public struct DockerContainer: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var isRunning: Bool
    public var status: String
    public var ports: [UInt16]
    public var composeProject: String?
    public var created: Date
    public var runtime: String

    init?(_ d: [String: Any], runtime: String) {
        guard let id = d["Id"] as? String else { return nil }
        self.id = id
        name = ((d["Names"] as? [String])?.first ?? id.prefix(12).description).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        image = d["Image"] as? String ?? ""
        isRunning = (d["State"] as? String) == "running"
        status = d["Status"] as? String ?? ""
        ports = Array(Set(((d["Ports"] as? [[String: Any]]) ?? []).compactMap { ($0["PublicPort"] as? NSNumber)?.uint16Value })).sorted()
        composeProject = (d["Labels"] as? [String: String])?["com.docker.compose.project"]
        created = Date(timeIntervalSince1970: (d["Created"] as? NSNumber)?.doubleValue ?? 0)
        self.runtime = runtime
    }
}

public struct DockerVolume: Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var bytes: Int64
    /// Containers (running or stopped) that reference it. nil = the engine did not say.
    public var refCount: Int?
}

public struct DockerDiskUsage: Sendable {
    public var imagesBytes: Int64 = 0
    public var danglingImagesBytes: Int64 = 0
    public var unusedImagesBytes: Int64 = 0
    public var containersBytes: Int64 = 0
    public var stoppedContainersBytes: Int64 = 0
    public var buildCacheBytes: Int64 = 0
    public var volumes: [DockerVolume] = []
    public var volumesBytes: Int64 { volumes.reduce(0) { $0 + max($1.bytes, 0) } }
    /// Only volumes the engine positively reports as unreferenced are ever offered for removal.
    public var unusedVolumes: [DockerVolume] { volumes.filter { $0.refCount == 0 } }

    public init() {}

    init(_ df: [String: Any]) {
        func n(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
        for image in (df["Images"] as? [[String: Any]]) ?? [] {
            let size = n(image["Size"])
            imagesBytes += size
            let unused = n(image["Containers"]) == 0
            let dangling = ((image["RepoTags"] as? [String]) ?? []).allSatisfy { $0 == "<none>:<none>" }
            if unused, dangling { danglingImagesBytes += size } else if unused { unusedImagesBytes += size }
        }
        for c in (df["Containers"] as? [[String: Any]]) ?? [] {
            let size = n(c["SizeRw"])
            containersBytes += size
            if (c["State"] as? String) != "running" { stoppedContainersBytes += size }
        }
        for b in (df["BuildCache"] as? [[String: Any]]) ?? [] where (b["InUse"] as? Bool) != true { buildCacheBytes += n(b["Size"]) }
        volumes = ((df["Volumes"] as? [[String: Any]]) ?? []).compactMap { v in
            guard let name = v["Name"] as? String else { return nil }
            let usage = v["UsageData"] as? [String: Any]
            let refs = (usage?["RefCount"] as? NSNumber)?.intValue
            return DockerVolume(name: name, bytes: n(usage?["Size"]), refCount: refs.flatMap { $0 >= 0 ? $0 : nil })
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

/// C-4: the VM disk file is sparse — what matters is what it really occupies.
public struct VMDisk: Sendable, Equatable {
    public var path: String
    public var logicalBytes: Int64
    public var allocatedBytes: Int64

    public static func dockerDesktop(home: String = NSHomeDirectory()) -> VMDisk? {
        at("\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    }

    public static func at(_ path: String) -> VMDisk? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return VMDisk(path: path, logicalBytes: Int64(st.st_size), allocatedBytes: Int64(st.st_blocks) * 512)
    }
}
