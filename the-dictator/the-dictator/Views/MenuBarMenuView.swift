import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button("Settings…") {
                openWindow(id: "settings")
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
