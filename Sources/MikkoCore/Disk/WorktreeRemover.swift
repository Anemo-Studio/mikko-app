import Foundation

/// D-4: an agent's finished worktree, removed as a whole. Only a clean linked worktree
/// qualifies: the branch and its commits stay in the main repository, the folder goes to
/// the Trash (recoverable), and git's record of the worktree is pruned afterwards.
public enum WorktreeRemover {
    public enum Outcome: Equatable, Sendable {
        case removed(mainRepository: String)
        case refused(String)
    }

    /// The main checkout a linked worktree belongs to, from its gitdir's `commondir`.
    public static func mainRepository(of root: String) -> String? {
        guard let gitDir = GitInfo.gitDir(root: root), gitDir.contains("/worktrees/") else { return nil }
        let common: String
        if let text = try? String(contentsOfFile: "\(gitDir)/commondir", encoding: .utf8) {
            let rel = text.trimmingCharacters(in: .whitespacesAndNewlines)
            common = rel.hasPrefix("/") ? rel : (gitDir as NSString).appendingPathComponent(rel)
        } else {
            // ".../.git/worktrees/<name>" → ".../.git"
            common = ((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        }
        guard let real = PathCanon.real(common), (real as NSString).lastPathComponent == ".git" else { return nil }
        return (real as NSString).deletingLastPathComponent
    }

    /// Re-checks everything at the moment of the action; refuses rather than guesses.
    public static func remove(root: String,
                              trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                              prune: (String) -> Bool = { GitInfo.run(["worktree", "prune"], root: $0)?.status == 0 }) -> Outcome {
        guard !PathCanon.isSymlink(root), let real = PathCanon.real(root) else { return .refused("The folder no longer exists.") }
        guard GitInfo.read(root: real).isWorktree, let main = mainRepository(of: real) else {
            return .refused("This is not a linked git worktree.")
        }
        guard main != real, !real.hasPrefix(main + "/.git") else { return .refused("This is the main checkout, not a worktree.") }
        switch GitInfo.hasUncommittedChanges(root: real) {
        case .some(false): break
        case .some(true): return .refused("It has uncommitted or untracked changes. Commit or discard them first.")
        case .none: return .refused("git could not check it for changes, so it was left alone.")
        }
        do { try trash(URL(fileURLWithPath: real)) } catch { return .refused(error.localizedDescription) }
        _ = prune(main)
        return .removed(mainRepository: main)
    }
}
