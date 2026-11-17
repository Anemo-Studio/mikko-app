import Foundation

/// Ollama stores each model as a small manifest plus content-addressed blobs in one shared
/// folder; models built on the same base share blobs. A model's row is its manifest and the
/// blobs no other model uses — removing it frees exactly that, and never a shared layer.
public enum OllamaModels {
    public struct Model: Sendable, Equatable {
        public var name: String
        public var manifestPath: String
        /// Blobs only this model references.
        public var uniqueBlobs: [String]
        public var uniqueBytes: Int64
        /// Bytes in blobs that other models also use (stay on disk when this one is removed).
        public var sharedBytes: Int64
        public var modified: Date?
    }

    /// `root` is `~/.ollama/models`.
    public static func list(root: String) -> [Model] {
        let fm = FileManager.default
        let manifests = "\(root)/manifests"
        guard let walker = fm.enumerator(atPath: manifests) else { return [] }
        var entries: [(name: String, path: String, blobs: [String], modified: Date?)] = []
        while let rel = walker.nextObject() as? String {
            let path = "\(manifests)/\(rel)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, !PathCanon.isSymlink(path),
                  let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var digests: [String] = []
            if let config = json["config"] as? [String: Any], let d = config["digest"] as? String { digests.append(d) }
            for layer in (json["layers"] as? [[String: Any]]) ?? [] { if let d = layer["digest"] as? String { digests.append(d) } }
            let blobs = digests.compactMap(blobPath(root: root))
            guard !blobs.isEmpty else { continue }
            let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            entries.append((displayName(rel), path, blobs, modified))
        }
        var users: [String: Int] = [:]
        for e in entries { for b in Set(e.blobs) { users[b, default: 0] += 1 } }
        return entries.map { e in
            let unique = Set(e.blobs).filter { users[$0] == 1 }
            let shared = Set(e.blobs).subtracting(unique)
            return Model(name: e.name, manifestPath: e.path, uniqueBlobs: unique.sorted(),
                         uniqueBytes: unique.reduce(0) { $0 + size($1) }, sharedBytes: shared.reduce(0) { $0 + size($1) },
                         modified: e.modified)
        }
        .sorted { $0.uniqueBytes > $1.uniqueBytes }
    }

    /// "sha256:abc…" → "<root>/blobs/sha256-abc…", only for well-formed digests that exist.
    static func blobPath(root: String) -> (String) -> String? {
        { digest in
            let parts = digest.split(separator: ":")
            guard parts.count == 2, parts[0] == "sha256", parts[1].count == 64,
                  parts[1].allSatisfy({ $0.isHexDigit }) else { return nil }
            let path = "\(root)/blobs/sha256-\(parts[1])"
            return FileManager.default.fileExists(atPath: path) && !PathCanon.isSymlink(path) ? path : nil
        }
    }

    /// "registry.ollama.ai/library/llama3.2/latest" → "llama3.2:latest";
    /// other namespaces and registries stay visible ("me/coder:7b", "hf.co/org/model:q4").
    static func displayName(_ rel: String) -> String {
        var parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return rel }
        let tag = parts.removeLast()
        if parts.first == "registry.ollama.ai" { parts.removeFirst() }
        if parts.first == "library" { parts.removeFirst() }
        return parts.joined(separator: "/") + ":" + tag
    }

    static func size(_ path: String) -> Int64 {
        var st = stat()
        return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : 0
    }
}
