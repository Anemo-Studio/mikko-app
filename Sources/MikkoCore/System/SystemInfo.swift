import Foundation

public struct DiskSpace: Sendable, Equatable {
    public var total: Int64
    public var free: Int64
    public init(total: Int64, free: Int64) { self.total = total; self.free = free }
    public var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }

    /// Free space as Finder reports it (includes purgeable space).
    public static func current(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSpace(total: Int64(total), free: free)
    }
}

public enum ByteFormat {
    /// "38 GB", "1.2 GB", "640 MB" — decimal units, matching Finder.
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useKB]
        return f.string(fromByteCount: bytes)
    }
}
