import SwiftUI
import UserNotifications

/// Each permission is granted separately; a module without its permission explains, never errors.
struct PermissionsView: View {
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var fullDisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Headline(title: "Permissions", subtitle: "Both optional. mikko never asks for your administrator password.")
            row("bell", "Notifications", "Low disk space, idle servers, limits running out.",
                granted: notifications == .authorized) {
                if notifications == .denied {
                    // Once declined, macOS only lets the person change it in System Settings.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    return
                }
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    await load()
                }
            }
            row("externaldrive.badge.checkmark", "Full Disk Access",
                "Needed only to size a few protected folders. Granted in System Settings.", granted: fullDisk ? true : nil) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        // Readable only with Full Disk Access; opening it changes nothing.
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        fullDisk = fd >= 0
        if fd >= 0 { close(fd) }
    }

    private func row(_ symbol: String, _ title: String, _ why: String, granted: Bool?,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted == true {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(granted == nil ? "Open Settings" : "Allow", action: action)
            }
        }
    }
}
