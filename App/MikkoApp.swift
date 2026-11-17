import MikkoCore
import SwiftUI

@main
struct MikkoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("mikko", id: "main") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
