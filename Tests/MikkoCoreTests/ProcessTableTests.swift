import Foundation
import Testing
@testable import MikkoCore

@Test func snapshotSeesThisProcessWithDetails() {
    let snap = ProcessTable().snapshot()
    let me = snap.records.first { $0.pid == getpid() }
    #expect(me != nil)
    #expect(me?.path?.isEmpty == false && me?.argv.isEmpty == false && me?.cwd != nil)
    #expect((me?.footprint ?? 0) > 1_000_000)
    #expect(me?.identity == ProcessTable.identity(of: getpid()))
    #expect(snap.records.count > 50)
    #expect(ProcessTable.identity(of: 999_999) == nil)
}

@Test func snapshotFindsAListeningSocket() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(bound == 0 && listen(fd, 1) == 0)
    var out = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let port = UInt16(bigEndian: out.sin_port)

    let me = ProcessTable().snapshot().records.first { $0.pid == getpid() }
    let l = me?.listeners.first { $0.port == port }
    #expect(l != nil && l?.isLoopback == true && l?.exposedToLAN == false)
}

@Test func memoryStatusIsPlausible() {
    let m = MemoryStatus.current()
    #expect(m.total > 1_000_000_000 && m.used > 0 && m.used <= m.total)
}
