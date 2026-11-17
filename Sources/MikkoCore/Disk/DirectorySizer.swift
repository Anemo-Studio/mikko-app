import Foundation

public enum DirectorySizer {
    /// On-disk (allocated) size of a file or directory tree. Does not follow
    /// symlinks or cross volumes; hard-linked files are counted once.
    public static func allocatedSize(of url: URL, isCancelled: () -> Bool = { Task.isCancelled }) -> Int64 {
        guard let cPath = strdup(url.path) else { return 0 }
        defer { free(cPath) }
        var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var seenLinks = Set<UInt64>()
        var n = 0
        while let entry = fts_read(fts) {
            n &+= 1
            if n & 0x3FF == 0, isCancelled() { break }
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_D || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT,
                  let st = entry.pointee.fts_statp else { continue }
            if info == FTS_F, st.pointee.st_nlink > 1, !seenLinks.insert(st.pointee.st_ino).inserted { continue }
            total += Int64(st.pointee.st_blocks) * 512
        }
        return total
    }
}
