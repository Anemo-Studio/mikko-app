import Foundation
import Testing
@testable import MikkoCore

@Test func parsesPlainAndChunkedHTTP() {
    let plain = HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK".utf8))
    #expect(plain?.status == 200 && plain?.body == Data("OK".utf8))
    let chunked = HTTPResponse.parse(Data("HTTP/1.1 404 Not Found\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
    #expect(chunked?.status == 404 && chunked?.body == Data("hello world".utf8))
    #expect(HTTPResponse.parse(Data("junk".utf8)) == nil)
}

@Test func parsesContainersAndDiskUsage() throws {
    let c = try JSONSerialization.jsonObject(with: Data("""
    {"Id":"abc123def4567890","Names":["/shop-db-1"],"Image":"postgres:16","State":"running","Status":"Up 2 hours",
     "Ports":[{"PrivatePort":5432,"PublicPort":5432},{"PrivatePort":5432,"PublicPort":5432,"IP":"::"},{"PrivatePort":80}],
     "Labels":{"com.docker.compose.project":"shop"},"Created":1700000000}
    """.utf8)) as! [String: Any]
    let container = DockerContainer(c, runtime: "Docker Desktop")
    #expect(container?.name == "shop-db-1" && container?.isRunning == true && container?.ports == [5432])
    #expect(container?.composeProject == "shop")

    let df = try JSONSerialization.jsonObject(with: Data("""
    {"Images":[{"Size":100,"Containers":1,"RepoTags":["a:1"]},{"Size":40,"Containers":0,"RepoTags":["b:1"]},
               {"Size":7,"Containers":0,"RepoTags":["<none>:<none>"]}],
     "Containers":[{"SizeRw":5,"State":"running"},{"SizeRw":9,"State":"exited"}],
     "Volumes":[{"Name":"pgdata","UsageData":{"Size":900,"RefCount":1}},{"Name":"old","UsageData":{"Size":300,"RefCount":0}},
                {"Name":"unknown1","UsageData":{"Size":0,"RefCount":-1}},{"Name":"unknown2"}],
     "BuildCache":[{"Size":50,"InUse":false},{"Size":20,"InUse":true}]}
    """.utf8)) as! [String: Any]
    let u = DockerDiskUsage(df)
    #expect(u.imagesBytes == 147 && u.unusedImagesBytes == 40 && u.danglingImagesBytes == 7)
    #expect(u.stoppedContainersBytes == 9 && u.buildCacheBytes == 50 && u.volumesBytes == 1200)
    // A volume a container still references — or whose references are unknown — is never offered (C-3).
    #expect(u.unusedVolumes.map(\.name) == ["old"])
}

@Test func talksToAnEngineOverAUnixSocket() throws {
    let path = "/tmp/mk-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(path) }
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(server) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in path.withCString { _ = strlcpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, 104) } }
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    #expect(bound == 0 && listen(server, 4) == 0)

    let received = Box2()
    Thread.detachNewThread {
        for _ in 0..<2 {
            let c = accept(server, nil, nil)
            guard c >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(c, &buf, buf.count)
            let req = String(decoding: buf.prefix(max(n, 0)), as: UTF8.self)
            received.add(req.components(separatedBy: "\r\n").first ?? "")
            let body = req.hasPrefix("GET /_ping") ? "OK" : "[{\"Id\":\"x1\",\"Names\":[\"/web\"],\"State\":\"exited\"}]"
            let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = resp.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }
    let client = DockerClient(socketPath: path, runtimeName: "Mock")
    #expect(client.isReachable)
    let list = try client.containers()
    #expect(list.map(\.name) == ["web"] && list[0].isRunning == false && list[0].runtime == "Mock")
    #expect(received.values == ["GET /_ping HTTP/1.1", "GET /containers/json?all=1 HTTP/1.1"])
    #expect(throws: DockerError.self) { _ = try DockerClient(socketPath: "/tmp/nope.sock", runtimeName: "Gone").containers() }
}

private final class Box2: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
