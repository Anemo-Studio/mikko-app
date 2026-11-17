import Foundation

/// S-6: optional copies of agent transcripts, so a session survives the agent's own cleanup
/// (Claude Code deletes transcripts after `cleanupPeriodDays`, 30 by default). Copies mirror
/// the original layout under mikko's own folder, readable by the owner only. Originals are
/// only ever read.
public struct SessionArchive: Sendable {
    public var root: String
    public var home: String

    public init(root: String = SessionArchive.defaultRoot, home: String = NSHomeDirectory()) {
        self.root = root; self.home = home
    }

    public static var defaultRoot: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? "\(NSHomeDirectory())/Library/Application Support"
        return "\(base)/mikko/Session Copies"
    }

    static let enabledKey = "keepSessionCopies"
    /// Opt-in; read by both the app and the indexer.
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Where the copy of an original lives. nil for anything outside the home folder.
    public func copyPath(for original: String) -> String? {
        guard original.hasPrefix(home + "/") else { return nil }
        return root + "/" + original.dropFirst(home.count + 1)
    }

    /// The copy, if one exists.
    public func existingCopy(of original: String) -> String? {
        copyPath(for: original).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    /// Copies the file if the copy is missing or differs in size or modification time.
    @discardableResult
    public func keep(_ original: String) -> Bool {
        let fm = FileManager.default
        guard let dest = copyPath(for: original), !PathCanon.isSymlink(original),
              let src = try? fm.attributesOfItem(atPath: original) else { return false }
        if let have = try? fm.attributesOfItem(atPath: dest),
           (have[.size] as? Int64) == (src[.size] as? Int64), (have[.modificationDate] as? Date) == (src[.modificationDate] as? Date) {
            return true
        }
        let dir = (dest as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dest + ".partial"
            try? fm.removeItem(atPath: tmp)
            try fm.copyItem(atPath: original, toPath: tmp)
            try fm.setAttributes([.posixPermissions: 0o600, .modificationDate: src[.modificationDate] ?? Date()], ofItemAtPath: tmp)
            if fm.fileExists(atPath: dest) { _ = try fm.replaceItemAt(URL(fileURLWithPath: dest), withItemAt: URL(fileURLWithPath: tmp)) }
            else { try fm.moveItem(atPath: tmp, toPath: dest) }
            return true
        } catch {
            return false
        }
    }

    /// Bytes the copies take.
    public var bytes: Int64 { DirectorySizer.allocatedSize(of: URL(fileURLWithPath: root)) }
}
