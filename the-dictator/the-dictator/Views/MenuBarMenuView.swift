import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }

            Button("Paste Last Transcript") {
                appModel.pasteLastTranscript()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}
