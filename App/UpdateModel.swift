import AppKit
import MikkoCore
import SwiftUI

/// Checks GitHub Releases once a day for a newer mikko. Off with one toggle in
/// Settings › General; nothing about the person or the Mac is sent.
@Observable
final class UpdateModel {
    private(set) var available: UpdateCheck.Release?
    private(set) var lastChecked: Date?
    private var task: Task<Void, Never>?

    static let enabledKey = "checkForUpdates"
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); newValue ? start() : stop() }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    init() { if enabled { start() } }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        available = nil
    }

    func checkNow() async {
        let release = await UpdateCheck.latest()
        lastChecked = .now
        if let release, UpdateCheck.isNewer(release.version, than: currentVersion) {
            available = release
        } else if release != nil {
            available = nil
        }
    }

    /// The disk image when the release has one, otherwise the release page.
    func download() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }
}
