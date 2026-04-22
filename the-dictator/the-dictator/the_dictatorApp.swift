import SwiftUI

@main
struct TheDictatorApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("The Dictator", systemImage: appModel.menuBarSymbolName) {
            MenuBarMenuView(appModel: appModel)
        }

        Settings {
            SettingsView(settingsStore: appModel.settingsStore, appModel: appModel)
        }
        .windowResizability(.contentSize)
    }
}
