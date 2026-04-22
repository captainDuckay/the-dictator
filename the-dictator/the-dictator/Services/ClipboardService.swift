import AppKit
import Foundation

struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
}

@MainActor
final class ClipboardService {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func snapshot() -> ClipboardSnapshot {
        let snapshots: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }

            return dataByType
        } ?? []

        return ClipboardSnapshot(items: snapshots)
    }

    func setString(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return true
        }

        let items = snapshot.items.compactMap { dictionary -> NSPasteboardItem? in
            let item = NSPasteboardItem()
            var hasValue = false

            for (type, data) in dictionary {
                if item.setData(data, forType: type) {
                    hasValue = true
                }
            }

            return hasValue ? item : nil
        }

        guard !items.isEmpty else {
            return false
        }

        return pasteboard.writeObjects(items)
    }
}
