import Foundation

/// Process table → recognisable items. Shared by the app, the CLI and the MCP server.
public final class RunningScanner: Sendable {
    private let table = ProcessTable()
    private let resolver: ProjectResolver

    /// `blocking: false` never waits on the file system (or a folder-access prompt):
    /// unknown projects are looked up in the background and appear on a later scan.
    public init(blocking: Bool = true) { resolver = ProjectResolver(blocking: blocking) }

    public func scan() -> (items: [RunningItem], snapshot: ProcessSnapshot) {
        let snapshot = table.snapshot()
        let resolver = resolver
        let classifier = RunningClassifier(
            projectFor: { resolver.project(for: $0) },
            simulatorName: { Self.simulatorName(udid: $0) })
        return (classifier.classify(snapshot), snapshot)
    }

    static func simulatorName(udid: String) -> String? {
        let path = "\(NSHomeDirectory())/Library/Developer/CoreSimulator/Devices/\(udid)/device.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["name"] as? String
    }
}

extension ProcessSnapshot {
    /// Names of the user's running tools, for "is this cache in use right now" checks.
    public func toolMarkers(uid: UInt32 = getuid()) -> Set<String> {
        var out = Set<String>()
        for r in records where r.uid == uid {
            out.insert(r.name)
            if RunningClassifier.interpreters.contains(r.name) || RunningClassifier.packageRunners.contains(r.name) {
                let title = RunningClassifier.commandTitle(name: r.name, argv: r.argv)
                if let first = title.split(separator: " ").first { out.insert(String(first)) }
            }
            if r.argv.contains(where: { $0.contains("GradleDaemon") }) { out.insert("GradleDaemon") }
        }
        return out
    }
}

public enum DurationFormat {
    /// "3h", "12m", "2d" — compact age for lists.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
