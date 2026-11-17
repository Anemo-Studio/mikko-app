import Foundation
import Testing
@testable import MikkoCore

@Test func parsesSimctlDevicesAndRuntimes() {
    let devices = Data("""
    {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
      {"udid":"A","name":"iPhone 17","state":"Booted","isAvailable":true,"dataPath":"/d/A/data","dataPathSize":1000,"lastUsedAt":"2026-11-10T10:00:00Z"},
      {"udid":"B","name":"iPad","state":"Shutdown","isAvailable":true,"dataPathSize":5}],
     "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
      {"udid":"C","name":"Old","state":"Shutdown","isAvailable":false,"lastUsedAt":"2026-01-01T00:00:00Z"}]}}
    """.utf8)
    let d = Simctl.parseDevices(devices)
    #expect(d.count == 3)
    let a = d.first { $0.udid == "A" }!
    #expect(a.isBooted && a.runtimeName == "iOS 26.0" && a.dataBytes == 1000 && a.lastUsed != nil)
    let now = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!
    #expect(!a.unused(forDays: 60, now: now))                               // booted is never "unused"
    #expect(!d.first { $0.udid == "B" }!.unused(forDays: 60, now: now))     // never booted is not "unused for 60 days"
    #expect(d.first { $0.udid == "C" }!.unused(forDays: 60, now: now) && !d.first { $0.udid == "C" }!.isAvailable)

    let runtimes = Data("""
    {"X1":{"runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","sizeBytes":8000000000,"deletable":true,"version":"26.0","lastUsedAt":"2026-11-10T10:00:00Z"},
     "X2":{"runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-5","sizeBytes":7000000000,"deletable":true,"version":"17.5"}}
    """.utf8)
    let r = Simctl.parseRuntimes(runtimes, devices: d)
    #expect(r.map(\.id) == ["X1", "X2"] && r[0].deviceCount == 2 && r[1].deviceCount == 0 && r[0].name == "iOS 26.0 (26.0)")
    #expect(Simctl.parseDevices(Data("garbage".utf8)).isEmpty)
}

@Test func listsAVDsFromIniFiles() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-avd-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: home) }
    let avd = home.appendingPathComponent(".android/avd")
    try FileManager.default.createDirectory(at: avd.appendingPathComponent("Medium_Phone.avd/snapshots"), withIntermediateDirectories: true)
    try "path=\(avd.path)/Medium_Phone.avd\ntarget=android-36\n".write(to: avd.appendingPathComponent("Medium_Phone_API_36.ini"), atomically: true, encoding: .utf8)
    try "avd.ini.displayname = Medium Phone API 36\nimage.sysdir.1=system-images/android-36/google_apis/arm64-v8a/\n"
        .write(to: avd.appendingPathComponent("Medium_Phone.avd/config.ini"), atomically: true, encoding: .utf8)
    try Data(repeating: 1, count: 9000).write(to: avd.appendingPathComponent("Medium_Phone.avd/userdata-qemu.img"))
    try "path=/gone\n".write(to: avd.appendingPathComponent("Stale.ini"), atomically: true, encoding: .utf8)

    let list = AndroidEmulators.list(home: home.path, environment: [:], runningAVDs: ["Medium_Phone_API_36"])
    #expect(list.count == 1)
    #expect(list[0].name == "Medium_Phone_API_36" && list[0].displayName == "Medium Phone API 36")
    #expect(list[0].isRunning && list[0].bytes >= 9000 && list[0].target == "android-36")
    #expect(Set(AndroidEmulators.userDataFiles(list[0]).map { ($0 as NSString).lastPathComponent }) == ["userdata-qemu.img", "snapshots"])
    let qemu = ProcRecord(identity: .init(pid: 5, startSec: 1, startUsec: 0), ppid: 1, uid: 501, name: "qemu-system-aarch64",
                          argv: ["qemu-system-aarch64", "-avd", "Medium_Phone_API_36"])
    #expect(AndroidEmulators.isRunning(avdName: "Medium_Phone_API_36", records: [qemu]))
    #expect(!AndroidEmulators.isRunning(avdName: "Other", records: [qemu]))
}

@Test func simulatorCachesAreTheContentsOfCacheFoldersOnly() throws {
    let data = FileManager.default.temporaryDirectory.appendingPathComponent("mikko-sim-\(UUID().uuidString)/data").path
    defer { try? FileManager.default.removeItem(atPath: (data as NSString).deletingLastPathComponent) }
    let fm = FileManager.default
    for dir in ["Library/Caches/com.apple.x", "Containers/Data/Application/A1/Library/Caches/img", "Containers/Data/Application/A1/Documents"] {
        try fm.createDirectory(atPath: "\(data)/\(dir)", withIntermediateDirectories: true)
    }
    fm.createFile(atPath: "\(data)/Containers/Data/Application/A1/Library/Caches/img/a.bin", contents: Data(count: 50_000))
    fm.createFile(atPath: "\(data)/Containers/Data/Application/A1/Documents/keep.db", contents: Data(count: 50_000))
    #expect(SimCaches.folders(dataPath: data).count == 2)
    let names = SimCacheNames()
    _ = SimCaches.clear(dataPath: data) { names.add($0.lastPathComponent) }
    #expect(Set(names.values) == ["com.apple.x", "img"])   // Documents is never touched
}

private final class SimCacheNames: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return v }
}
