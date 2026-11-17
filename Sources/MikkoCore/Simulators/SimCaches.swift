import Foundation

/// "Clear simulator caches" (SIM-2): the caches of a simulator and of every app installed on it.
/// Only the contents move to the Trash — the folders stay, because apps expect them to exist —
/// and only while the simulator is shut down.
public enum SimCaches {
    /// Cache and temp folders inside a simulator's data folder.
    public static func folders(dataPath: String) -> [String] {
        let fm = FileManager.default
        var out = ["\(dataPath)/Library/Caches", "\(dataPath)/tmp"]
        let apps = "\(dataPath)/Containers/Data/Application"
        for app in (try? fm.contentsOfDirectory(atPath: apps)) ?? [] {
            out += ["\(apps)/\(app)/Library/Caches", "\(apps)/\(app)/tmp"]
        }
        return out.filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue && !PathCanon.isSymlink($0) }
    }

    public static func bytes(dataPath: String) -> Int64 {
        folders(dataPath: dataPath).reduce(0) { $0 + DirectorySizer.allocatedSize(of: URL(fileURLWithPath: $1)) }
    }

    /// Moves what is inside each cache folder to the Trash. Returns the bytes moved.
    @discardableResult
    public static func clear(dataPath: String,
                             trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int64 {
        let fm = FileManager.default
        var moved: Int64 = 0
        for folder in folders(dataPath: dataPath) {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                let size = DirectorySizer.allocatedSize(of: url)
                if (try? trash(url)) != nil { moved += size }
            }
        }
        return moved
    }
}
