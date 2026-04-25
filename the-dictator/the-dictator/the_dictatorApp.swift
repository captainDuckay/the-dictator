import SwiftUI

@main
struct TheDictatorApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("The Dictator", systemImage: appModel.menuBarSymbolName) {
            MenuBarMenuView(appModel: appModel)
        }

        Settings {
            SettingsView(
                settingsModule: appModel.settingsModule,
                onAppear: appModel.settingsWindowDidAppear,
                onDisappear: appModel.settingsWindowDidDisappear
            )
        }
        .windowResizability(.contentSize)
    }
}
