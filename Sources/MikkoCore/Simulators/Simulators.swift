import Foundation

public struct SimDevice: Sendable, Identifiable, Hashable {
    public var id: String { udid }
    public var udid: String
    public var name: String
    public var runtimeID: String
    public var runtimeName: String
    public var isBooted: Bool
    /// false when the OS version it needs is no longer installed.
    public var isAvailable: Bool
    public var dataPath: String?
    public var dataBytes: Int64
    public var lastUsed: Date?
    /// Lives in Xcode's separate Previews device set (SIM-5).
    public var isPreview: Bool

    public func unused(forDays days: Int, now: Date = .now) -> Bool {
        // "Never booted" is not "unused for 60 days": a device with no date is left alone.
        guard !isBooted, let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) > Double(days) * 86_400
    }
}

public struct SimRuntime: Sendable, Identifiable, Hashable {
    public var id: String
    public var runtimeID: String
    public var name: String
    public var sizeBytes: Int64
    public var deletable: Bool
    public var lastUsed: Date?
    public var deviceCount: Int
}

public enum Simctl {
    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0"
    public static func runtimeName(_ id: String) -> String {
        let tail = id.split(separator: ".").last.map(String.init) ?? id
        let parts = tail.split(separator: "-")
        guard parts.count >= 2 else { return tail }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }

    /// Parses `xcrun simctl list --json devices`.
    public static func parseDevices(_ data: Data, isPreview: Bool = false) -> [SimDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return byRuntime.flatMap { runtimeID, devices in
            devices.compactMap { d -> SimDevice? in
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return SimDevice(udid: udid, name: name, runtimeID: runtimeID, runtimeName: runtimeName(runtimeID),
                                 isBooted: (d["state"] as? String) == "Booted", isAvailable: (d["isAvailable"] as? Bool) ?? false,
                                 dataPath: d["dataPath"] as? String, dataBytes: (d["dataPathSize"] as? NSNumber)?.int64Value ?? 0,
                                 lastUsed: date(d["lastUsedAt"]), isPreview: isPreview)
            }
        }
        .sorted { ($0.runtimeName, $0.name) < ($1.runtimeName, $1.name) }
    }

    /// Parses `xcrun simctl runtime list --json` (a dictionary keyed by image UUID).
    public static func parseRuntimes(_ data: Data, devices: [SimDevice]) -> [SimRuntime] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [] }
        return root.compactMap { id, r -> SimRuntime? in
            guard let runtimeID = r["runtimeIdentifier"] as? String else { return nil }
            let version = (r["version"] as? String).map { " (\($0))" } ?? ""
            return SimRuntime(id: id, runtimeID: runtimeID, name: runtimeName(runtimeID) + version,
                              sizeBytes: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                              deletable: (r["deletable"] as? Bool) ?? false, lastUsed: date(r["lastUsedAt"]),
                              deviceCount: devices.filter { $0.runtimeID == runtimeID && !$0.isPreview }.count)
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: "/usr/bin/xcrun") && ToolDetector().detect().contains(.xcode) }

    /// Runs `xcrun simctl …`. Returns stdout, or nil on failure.
    @discardableResult
    public static func run(_ args: [String], timeout: TimeInterval = 120) -> Data? {
        Subprocess.run("/usr/bin/xcrun", ["simctl"] + args, timeout: timeout)
    }

    public static func listDevices() -> [SimDevice] {
        let main = run(["list", "--json", "devices"]).map { parseDevices($0) } ?? []
        let previews = run(["--set", "previews", "list", "--json", "devices"]).map { parseDevices($0, isPreview: true) } ?? []
        return main + previews
    }

    public static func listRuntimes(devices: [SimDevice]) -> [SimRuntime] {
        run(["runtime", "list", "--json"]).map { parseRuntimes($0, devices: devices) } ?? []
    }

    static func setArgs(_ d: SimDevice) -> [String] { d.isPreview ? ["--set", "previews"] : [] }

    // SIM-2 / SIM-3: every action goes through Apple's own tool, never `kill` or `rm`.
    public static func boot(_ d: SimDevice) -> Bool { run(setArgs(d) + ["boot", d.udid]) != nil }
    public static func shutdown(_ d: SimDevice) -> Bool { run(setArgs(d) + ["shutdown", d.udid]) != nil }
    public static func erase(_ d: SimDevice) -> Bool { run(setArgs(d) + ["erase", d.udid]) != nil }
    public static func delete(_ d: SimDevice) -> Bool { run(setArgs(d) + ["delete", d.udid]) != nil }
    public static func shutdownAll() -> Bool { run(["shutdown", "all"]) != nil }
    public static func shutdownPreviews() -> Bool { run(["--set", "previews", "shutdown", "all"]) != nil }
    public static func deleteUnavailable() -> Bool { run(["delete", "unavailable"]) != nil }
    public static func deleteRuntime(_ r: SimRuntime) -> Bool { run(["runtime", "delete", r.id]) != nil }
}

public enum Subprocess {
    /// Runs a tool with a time limit; returns stdout when it exits 0.
    public static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationReason == .exit && p.terminationStatus == 0 ? data : nil
    }
}

// MARK: - Android

public struct AndroidAVD: Sendable, Identifiable, Hashable {
    public var id: String { name }
    /// The name `emulator -avd` uses: the .ini file's base name.
    public var name: String
    public var displayName: String
    public var iniPath: String
    public var path: String
    public var target: String?
    public var bytes: Int64
    public var lastUsed: Date?
    public var isRunning: Bool
}

public struct AndroidSystemImage: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bytes: Int64
    public var usedByAVDs: Int
}

public enum AndroidEmulators {
    public static func sdkRoot(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk"]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
    }

    static func parseINI(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// SIM-6: AVDs come from the `<Name>.ini` files; the folder name may differ.
    public static func list(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment,
                            runningAVDs: Set<String> = [], measure: Bool = true) -> [AndroidAVD] {
        let avdHome = environment["ANDROID_AVD_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.android/avd"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: avdHome) else { return [] }
        return names.filter { $0.hasSuffix(".ini") }.compactMap { file -> AndroidAVD? in
            let iniPath = "\(avdHome)/\(file)"
            let ini = parseINI(iniPath)
            let name = String(file.dropLast(4))
            let path = ini["path"] ?? ini["path.rel"].map { "\(home)/.android/\($0)" } ?? "\(avdHome)/\(name).avd"
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let config = parseINI("\(path)/config.ini")
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return AndroidAVD(name: name, displayName: config["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
                              iniPath: iniPath, path: path, target: ini["target"] ?? config["target"],
                              bytes: measure ? DirectorySizer.allocatedSize(of: URL(fileURLWithPath: path)) : 0,
                              lastUsed: modified, isRunning: runningAVDs.contains(name))
        }
        .sorted { $0.displayName < $1.displayName }
    }

    public static func systemImages(sdk: String?, avds: [AndroidAVD]) -> [AndroidSystemImage] {
        guard let sdk else { return [] }
        let root = "\(sdk)/system-images"
        let fm = FileManager.default
        var out: [AndroidSystemImage] = []
        for api in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !api.hasPrefix(".") {
            for tag in (try? fm.contentsOfDirectory(atPath: "\(root)/\(api)")) ?? [] where !tag.hasPrefix(".") {
                for abi in (try? fm.contentsOfDirectory(atPath: "\(root)/\(api)/\(tag)")) ?? [] where !abi.hasPrefix(".") {
                    let rel = "system-images/\(api)/\(tag)/\(abi)"
                    let used = avds.filter { parseINI("\($0.path)/config.ini")["image.sysdir.1"]?.contains(rel) ?? false }.count
                    out.append(AndroidSystemImage(name: "\(api) · \(tag) · \(abi)", path: "\(sdk)/\(rel)",
                                                  bytes: DirectorySizer.allocatedSize(of: URL(fileURLWithPath: "\(sdk)/\(rel)")),
                                                  usedByAVDs: used))
                }
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Whether an emulator for this AVD is running right now — checked at the moment of a
    /// destructive action, never taken from an older list.
    public static func isRunning(avdName: String, records: [ProcRecord]? = nil) -> Bool {
        (records ?? ProcessTable().snapshot().records).contains { r in
            r.name.hasPrefix("qemu-system") && (r.argv.contains(avdName) || r.argv.contains("@\(avdName)"))
        }
    }

    /// Files that hold an AVD's user data; removing them is "Wipe data".
    public static func userDataFiles(_ avd: AndroidAVD) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: avd.path)) ?? []
        return names.filter { $0.hasPrefix("userdata-qemu.img") || $0 == "snapshots" || $0.hasPrefix("cache.img") || $0.hasPrefix("sdcard.img.qcow2") }
            .map { "\(avd.path)/\($0)" }
    }

    /// Graceful stop through the emulator console; the serial is `emulator-<console port>`.
    public static func stop(consolePort: UInt16, sdk: String?) -> Bool {
        guard let sdk else { return false }
        return Subprocess.run("\(sdk)/platform-tools/adb", ["-s", "emulator-\(consolePort)", "emu", "kill"], timeout: 15) != nil
    }
}
