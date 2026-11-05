import AppKit
import ApplicationServices

let selectionEventTag: Int64 = 0x44534853454c
func sendKey(_ pid: pid_t, _ key: CGKeyCode, _ flags: CGEventFlags = []) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
    for event in [down, up] {
        event.flags = flags; event.setIntegerValueField(.eventSourceUserData, value: selectionEventTag); event.postToPid(pid)
    }
    return true
}
struct ClipboardContents {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var result: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { result[type] = item.data(forType: type) }
            return result
        }
    }
    func restore(ifUnchanged count: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == count else { return }
        board.clearContents()
        let restored = items.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}
// Chromium Pickle: payload-size header, entry count, aligned UTF-16 key/value pairs.
func vscodeClipboardMetadata(_ data: Data) -> [String: Any]? {
    let bytes = [UInt8](data); var offset = 0
    func number() -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
        offset += 4; return Int(value)
    }
    func string() -> String? {
        guard let count = number(), count <= 500000, count * 2 <= bytes.count - offset else { return nil }
        let value = String(data: Data(bytes[offset..<(offset + count * 2)]), encoding: .utf16LittleEndian)
        offset += count * 2; offset = (offset + 3) & ~3; return value
    }
    guard let size = number(), size == bytes.count - 4, let count = number(), count <= 64 else { return nil }
    for _ in 0..<count {
        guard let key = string(), let value = string() else { return nil }
        if key == "vscode-editor-data", let json = value.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        }
    }
    return nil
}
func actualVSCodeSelection(_ metadata: [String: Any]) -> Bool {
    metadata["isFromEmptySelection"] as? Bool == false && metadata["isBlock"] as? Bool != true &&
        (metadata["multicursorText"] == nil || metadata["multicursorText"] is NSNull)
}
enum ClipboardSelectionPolicy {
    case standard, vscode
}
func acceptsCopiedSelection(_ policy: ClipboardSelectionPolicy, customData: Data?) -> Bool {
    if let customData, let metadata = vscodeClipboardMetadata(customData) {
        // Also protects Monaco-based editors outside VS Code from whole-line copy.
        return actualVSCodeSelection(metadata)
    }
    return policy == .standard
}
final class ClipboardSelection {
    static let shared = ClipboardSelection()
    var busy = false
    var diagnostic = "native-copy-idle"
    func read(pid: pid_t, policy: ClipboardSelectionPolicy, valid: @escaping () -> Bool, completion: @escaping (String?) -> Void) {
        guard !busy, valid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { completion(nil); return }
        busy = true; diagnostic = "native-copy-pending"
        var interrupted = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != selectionEventTag { interrupted = true }
        }
        func finish(_ text: String?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            self.busy = false; completion(text)
        }
        let saved = ClipboardContents(), initial = NSPasteboard.general.changeCount
        guard sendKey(pid, 8, .maskCommand) else { finish(nil); return }
        func poll(_ attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let board = NSPasteboard.general
                guard !interrupted, valid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    self.diagnostic = "native-copy-interrupted"; finish(nil); return
                }
                if board.changeCount == initial, attempts > 0 { poll(attempts - 1); return }
                let count = board.changeCount
                guard count != initial else {
                    self.diagnostic = "native-copy-no-change"
                    finish(nil); return
                }
                let data = board.data(forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data"))
                let text = acceptsCopiedSelection(policy, customData: data) ? board.string(forType: .string) : nil
                saved.restore(ifUnchanged: count)
                self.diagnostic = text == nil ? "native-copy-empty-or-multiple" : "native-copy-ok"
                finish(text)
            }
        }
        poll(7)
    }
}
