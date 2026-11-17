import Foundation

/// The once-a-day "new version available" check. mikko is distributed from GitHub
/// Releases, so the latest release is the source of truth. The request carries no
/// identifiers: no install ID, no system details, just a GET for a public JSON file.
public enum UpdateCheck {
    public static let repository = "Anemo-Studio/mikko-app"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    public struct Release: Equatable, Sendable {
        public let version: String
        public let pageURL: URL
        public let downloadURL: URL?
    }

    /// Reads GitHub's "latest release" JSON. Drafts and pre-releases are never offered.
    public static func parse(_ data: Data) -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.draft != true, p.prerelease != true else { return nil }
        let dmg = p.assets?.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        return Release(version: normalized(p.tag_name), pageURL: p.html_url, downloadURL: dmg)
    }

    /// "v1.2.0" → "1.2.0".
    public static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// True when `candidate` is a newer dotted version than `current` ("1.10" > "1.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalized(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalized(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Fetches the latest release. Returns nil on any failure: an update check must
    /// never show an error to someone who is offline.
    public static func latest(session: URLSession = .shared) async -> Release? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("mikko", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
