import AppKit
import MikkoCore
import Observation

@Observable
final class SimulatorsModel {
    private(set) var devices: [SimDevice] = []
    private(set) var runtimes: [SimRuntime] = []
    private(set) var avds: [AndroidAVD] = []
    private(set) var images: [AndroidSystemImage] = []
    private(set) var isLoading = false
    private(set) var busy: Set<String> = []
    var message: String?
    /// Names of AVDs with a running emulator, supplied by the Running module.
    var runningAVDs: () -> [String: UInt16] = { [:] }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let running = runningAVDs()
        Task {
            let result = await Task.detached(priority: .utility) {
                let devices = Simctl.isInstalled ? Simctl.listDevices() : []
                let runtimes = Simctl.isInstalled ? Simctl.listRuntimes(devices: devices) : []
                let avds = AndroidEmulators.list(runningAVDs: Set(running.keys))
                return (devices, runtimes, avds, AndroidEmulators.systemImages(sdk: AndroidEmulators.sdkRoot(), avds: avds))
            }.value
            (devices, runtimes, avds, images) = result
            isLoading = false
        }
    }

    var booted: [SimDevice] { devices.filter(\.isBooted) }
    var unavailable: [SimDevice] { devices.filter { !$0.isAvailable } }
    func unused(days: Int = 60) -> [SimDevice] { devices.filter { $0.isAvailable && !$0.isPreview && $0.unused(forDays: days) } }

    /// Runs one official-tool action off the main thread, then reloads.
    func perform(_ key: String, failure: String, _ action: @escaping @Sendable () -> Bool) {
        busy.insert(key)
        Task {
            let ok = await Task.detached(priority: .userInitiated) { action() }.value
            busy.remove(key)
            message = ok ? nil : failure
            refresh()
        }
    }

    func boot(_ d: SimDevice) { perform(d.udid, failure: "Could not boot \(d.name).") { Simctl.boot(d) } }
    /// Caches of the simulator and its apps go to the Trash; only while it is shut down.
    func clearCaches(_ d: SimDevice) {
        guard !d.isBooted, let path = d.dataPath else { return }
        perform(d.udid, failure: "Could not clear the caches of \(d.name).") {
            SimCaches.clear(dataPath: path)
            return true
        }
    }
    func shutdown(_ d: SimDevice) { perform(d.udid, failure: "Could not shut down \(d.name).") { Simctl.shutdown(d) } }
    func erase(_ d: SimDevice) { perform(d.udid, failure: "Could not erase \(d.name). Shut it down first.") { Simctl.erase(d) } }
    func delete(_ d: SimDevice) { perform(d.udid, failure: "Could not delete \(d.name).") { Simctl.delete(d) } }
    func shutdownAll() {
        perform("all", failure: "Could not shut down simulators.") {
            let main = Simctl.shutdownAll()
            _ = Simctl.shutdownPreviews() // an empty or missing previews set is not a failure
            return main
        }
    }
    func shutdownPreviews() { perform("previews", failure: "Could not stop preview simulators.") { Simctl.shutdownPreviews() } }
    func deleteUnavailable() { perform("unavailable", failure: "Could not delete unavailable simulators.") { Simctl.deleteUnavailable() } }
    func deleteUnused(days: Int = 60) {
        let confirmed = Set(unused(days: days).map(\.udid))
        perform("unused", failure: "Some simulators could not be deleted.") {
            // Re-read the list now: a simulator booted or used since the list was shown must not be deleted.
            let fresh = Simctl.listDevices().filter { confirmed.contains($0.udid) && $0.isAvailable && !$0.isPreview && $0.unused(forDays: days) }
            return fresh.map { Simctl.delete($0) }.allSatisfy { $0 }
        }
    }
    func deleteRuntime(_ r: SimRuntime) { perform(r.id, failure: "Could not remove \(r.name).") { Simctl.deleteRuntime(r) } }

    func stop(_ avd: AndroidAVD) {
        guard let port = runningAVDs()[avd.name] else { return }
        perform(avd.name, failure: "Could not stop \(avd.displayName).") {
            AndroidEmulators.stop(consolePort: port, sdk: AndroidEmulators.sdkRoot())
        }
    }

    /// AVD files go to the Trash, so a wipe or delete can still be put back by hand (P-3).
    func wipe(_ avd: AndroidAVD) {
        perform(avd.name, failure: "Could not wipe \(avd.displayName). Stop the emulator first.") {
            // Checked now, not from the list on screen: wiping under a live emulator corrupts it.
            guard !AndroidEmulators.isRunning(avdName: avd.name) else { return false }
            return AndroidEmulators.userDataFiles(avd).allSatisfy { (try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil)) != nil }
        }
    }

    func delete(_ avd: AndroidAVD) {
        perform(avd.name, failure: "Could not delete \(avd.displayName). Stop the emulator first.") {
            guard avd.path.hasSuffix(".avd"), avd.iniPath.hasSuffix(".ini"), !AndroidEmulators.isRunning(avdName: avd.name) else { return false }
            let ok = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: avd.path), resultingItemURL: nil)) != nil
            return ok && (try? FileManager.default.trashItem(at: URL(fileURLWithPath: avd.iniPath), resultingItemURL: nil)) != nil
        }
    }

    func delete(_ image: AndroidSystemImage) {
        perform(image.path, failure: "Could not remove the system image.") {
            guard image.path.contains("/system-images/"), image.usedByAVDs == 0 else { return false }
            return (try? FileManager.default.trashItem(at: URL(fileURLWithPath: image.path), resultingItemURL: nil)) != nil
        }
    }
}

@Observable
final class ContainersModel {
    struct Engine: Identifiable {
        var id: String { client.socketPath }
        var client: DockerClient
        var reachable: Bool
        var containers: [DockerContainer] = []
        var usage: DockerDiskUsage?
        var error: String?
    }

    private(set) var engines: [Engine] = []
    private(set) var stats: [String: (cpuPercent: Double, memory: Int64)] = [:]
    private(set) var vmDisk: VMDisk?
    private(set) var isLoading = false
    private(set) var busy: Set<String> = []
    var message: String?

    var containers: [DockerContainer] { engines.flatMap(\.containers) }
    var hasEngine: Bool { !engines.isEmpty }

    func refresh(includeDisk: Bool = true) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let (engines, stats, disk) = await Task.detached(priority: .utility) { () -> ([Engine], [String: (Double, Int64)], VMDisk?) in
                var stats: [String: (Double, Int64)] = [:]
                let engines = DockerClient.discover().map { client -> Engine in
                    guard client.isReachable else { return Engine(client: client, reachable: false) }
                    var engine = Engine(client: client, reachable: true)
                    do {
                        engine.containers = try client.containers()
                        if includeDisk { engine.usage = try client.diskUsage() }
                    } catch {
                        engine.error = "\(error)"
                    }
                    for c in engine.containers where c.isRunning { if let s = client.stats(id: c.id) { stats[c.id] = s } }
                    return engine
                }
                var all = engines
                // An installed engine that is switched off has no socket; say so instead of "nothing found".
                let home = NSHomeDirectory()
                for (app, name, socket) in [("/Applications/Docker.app", "Docker Desktop", "\(home)/.docker/run/docker.sock"),
                                            ("/Applications/OrbStack.app", "OrbStack", "\(home)/.orbstack/run/docker.sock")]
                where FileManager.default.fileExists(atPath: app) && !all.contains(where: { $0.client.runtimeName == name }) {
                    all.append(Engine(client: DockerClient(socketPath: socket, runtimeName: name), reachable: false))
                }
                return (all, stats, VMDisk.dockerDesktop())
            }.value
            self.engines = engines
            self.stats = stats.mapValues { (cpuPercent: $0.0, memory: $0.1) }
            self.vmDisk = disk
            isLoading = false
        }
    }

    func client(for c: DockerContainer) -> DockerClient? { engines.first { $0.containers.contains(c) }?.client }

    func perform(_ key: String, _ action: @escaping @Sendable () throws -> String?) {
        busy.insert(key)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do { return try action() } catch { return "Failed: \(error)" }
            }.value
            busy.remove(key)
            message = result
            refresh()
        }
    }

    func stop(_ c: DockerContainer) { guard let cl = client(for: c) else { return }; perform(c.id) { try cl.stop(id: c.id); return nil } }
    func start(_ c: DockerContainer) { guard let cl = client(for: c) else { return }; perform(c.id) { try cl.start(id: c.id); return nil } }
    func restart(_ c: DockerContainer) { guard let cl = client(for: c) else { return }; perform(c.id) { try cl.restart(id: c.id); return nil } }

    /// Stops a compose project in the engine that owns the clicked container only.
    func stopProject(_ project: String, of container: DockerContainer) {
        guard let engine = engines.first(where: { $0.containers.contains(container) }) else { return }
        let ids = engine.containers.filter { $0.composeProject == project && $0.isRunning }.map(\.id)
        let cl = engine.client
        perform("project:\(project)") { for id in ids { try cl.stop(id: id) }; return nil }
    }

    enum Cleanup: String, CaseIterable, Identifiable {
        case dangling, buildCache, stoppedContainers, unusedImages
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dangling: "Remove dangling images"
            case .buildCache: "Clear build cache"
            case .stoppedContainers: "Remove stopped containers"
            case .unusedImages: "Remove unused images"
            }
        }
        var risk: RiskLevel { self == .dangling || self == .buildCache ? .safe : .caution }
        var whatYouLose: String {
            switch self {
            case .dangling: "Unused intermediate layers. Nothing you can run is affected."
            case .buildCache: "The next build is slower."
            case .stoppedContainers: "Data stored inside stopped containers (not in volumes) is lost for good."
            case .unusedImages: "Images no container uses are downloaded or rebuilt when needed again."
            }
        }
        func bytes(_ u: DockerDiskUsage) -> Int64 {
            switch self {
            case .dangling: u.danglingImagesBytes
            case .buildCache: u.buildCacheBytes
            case .stoppedContainers: u.stoppedContainersBytes
            case .unusedImages: u.unusedImagesBytes
            }
        }
    }

    func run(_ cleanup: Cleanup, on engine: Engine) {
        let cl = engine.client
        let title = cleanup.title
        perform("\(engine.id):\(cleanup.rawValue)") {
            let freed: Int64 = switch cleanup {
            case .dangling: try cl.pruneDanglingImages()
            case .buildCache: try cl.pruneBuildCache()
            case .stoppedContainers: try cl.pruneStoppedContainers()
            case .unusedImages: try cl.pruneUnusedImages()
            }
            return "\(title): \(ByteFormat.string(freed)) removed."
        }
    }

    func removeVolumes(_ names: [String], on engine: Engine) {
        let cl = engine.client
        perform("\(engine.id):volumes") {
            var removed: [String] = [], failed: [String] = []
            for n in names {
                do { try cl.removeVolume(name: n); removed.append(n) } catch { failed.append("\(n) (\(error))") }
            }
            return "Removed \(removed.count) volume\(removed.count == 1 ? "" : "s")."
                + (failed.isEmpty ? "" : " Not removed: \(failed.joined(separator: ", ")).")
        }
    }
}
