import AppKit
import SwiftUI

@MainActor
final class IndicatorService {
    private var windowController: NSWindowController?

    func update(for state: AppWorkflowState) {
        switch state {
        case .recording:
            showPlaceholderIndicator(text: "Recording…")
        default:
            hideIndicator()
        }
    }

    private func showPlaceholderIndicator(text: String) {
        if let windowController,
           let hostingView = windowController.window?.contentView as? NSHostingView<RecordingIndicatorPlaceholderView> {
            hostingView.rootView = RecordingIndicatorPlaceholderView(text: text)
            windowController.showWindow(nil)
            return
        }

        let view = RecordingIndicatorPlaceholderView(text: text)
        let hostingView = NSHostingView(rootView: view)

        let window = NSPanel(
            contentRect: NSRect(x: 140, y: 140, width: 180, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isFloatingPanel = true
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let controller = NSWindowController(window: window)
        self.windowController = controller
        controller.showWindow(nil)
    }

    private func hideIndicator() {
        windowController?.close()
        windowController = nil
    }
}

private struct RecordingIndicatorPlaceholderView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text(text)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .padding(6)
    }
}
