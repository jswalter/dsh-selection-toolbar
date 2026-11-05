import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func focusedElement(_ application: AXUIElement, pid: pid_t) -> AXUIElement? {
    if let focused = elementAttribute(application, kAXFocusedUIElementAttribute) { return focused }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.06)
    guard let focused = elementAttribute(system, kAXFocusedUIElementAttribute) else { return nil }
    var owner: pid_t = 0
    guard AXUIElementGetPid(focused, &owner) == .success, owner == pid else { return nil }
    return focused
}
func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
    return range
}
func canSet(_ element: AXUIElement, _ key: String) -> Bool {
    var result: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(element, key as CFString, &result) == .success && result.boolValue
}
func matchesRange(_ value: String, _ text: String, _ range: CFRange) -> Bool {
    let ns = value as NSString
    guard range.location >= 0, range.length >= 0, range.location <= ns.length,
          range.length <= ns.length - range.location else { return false }
    return ns.substring(with: NSRange(location: range.location, length: range.length)) == text
}
func replacing(_ value: String, _ text: String, _ range: CFRange, _ replacement: String) -> String? {
    guard matchesRange(value, text, range) else { return nil }
    return (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
}
func selectedText(_ element: AXUIElement) -> String? {
    if let text = attribute(element, kAXSelectedTextAttribute) as? String, !text.isEmpty { return text }
    if let range = selectedRange(element), range.length > 0, let value = attribute(element, kAXValueAttribute) as? String {
        let ns = value as NSString
        if range.location <= ns.length, range.length <= ns.length - range.location {
            return ns.substring(with: NSRange(location: range.location, length: range.length))
        }
    }
    // WebKit/Chromium rich editors may expose a text marker instead of an integer range.
    if let marker = attribute(element, "AXSelectedTextMarkerRange") {
        var text: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, marker, &text) == .success { return text as? String }
    }
    return nil
}
func parameterizedAttribute(_ element: AXUIElement, _ key: String, _ parameter: CFTypeRef) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(element, key as CFString, parameter, &result) == .success else { return nil }
    return result
}
func screenRect(_ value: CFTypeRef?) -> NSRect? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(value as! AXValue, .cgRect, &rect), usableSelectionRect(rect),
          let primary = NSScreen.screens.first else { return nil }
    return appKitRect(rect, primaryHeight: primary.frame.maxY)
}
func selectionBounds(_ element: AXUIElement) -> NSRect? {
    if var range = selectedRange(element), range.length > 0, let value = AXValueCreate(.cfRange, &range),
       let rect = screenRect(parameterizedAttribute(element, kAXBoundsForRangeParameterizedAttribute, value)) { return rect }
    if let marker = attribute(element, "AXSelectedTextMarkerRange"),
       let rect = screenRect(parameterizedAttribute(element, "AXBoundsForTextMarkerRange", marker)) { return rect }
    return nil
}
func matchingSelectionBounds(_ element: AXUIElement, text: String) -> NSRect? {
    guard selectedText(element) == text else { return nil }
    return selectionBounds(element)
}
func eventScreenPoint(_ event: NSEvent) -> NSPoint? {
    guard let point = event.cgEvent?.location, let primary = NSScreen.screens.first else { return nil }
    return NSPoint(x: point.x, y: primary.frame.maxY - point.y)
}
func isSecure(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<8 {
        guard let node = current else { break }
        if attribute(node, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return true }
        current = elementAttribute(node, kAXParentAttribute)
    }
    return false
}
func editable(_ element: AXUIElement) -> Bool {
    guard !isSecure(element), attribute(element, kAXEnabledAttribute) as? Bool != false else { return false }
    if let flag = attribute(element, "AXEditable") as? Bool { return flag }
    if canSet(element, kAXSelectedTextAttribute) || canSet(element, kAXValueAttribute) { return true }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
}
func related(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
    func ancestor(_ child: AXUIElement, _ parent: AXUIElement) -> Bool {
        var node: AXUIElement? = child
        for _ in 0..<12 {
            guard let current = node else { break }
            if CFEqual(current, parent) { return true }
            node = elementAttribute(current, kAXParentAttribute)
        }
        return false
    }
    return ancestor(a, b) || ancestor(b, a)
}
func markerSelectionIsWithin(_ source: AXUIElement, _ target: AXUIElement) -> Bool {
    guard let marker = attribute(source, "AXSelectedTextMarkerRange") else { return false }
    return ["AXStartTextMarkerForTextMarkerRange", "AXEndTextMarkerForTextMarkerRange"].allSatisfy { key in
        guard let endpoint = parameterizedAttribute(source, key, marker),
              let value = parameterizedAttribute(source, "AXUIElementForTextMarker", endpoint),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        // A marker resolving to a common web-area ancestor is not evidence that
        // the selection is inside the focused editor. Require a descendant.
        var node: AXUIElement? = (value as! AXUIElement)
        for _ in 0..<12 {
            guard let current = node else { break }
            if CFEqual(current, target) { return true }
            node = elementAttribute(current, kAXParentAttribute)
        }
        return false
    }
}

struct SelectionSnapshot {
    let element: AXUIElement
    let window: AXUIElement?
    let pid: pid_t
    let appName: String
    let bundleID: String
    let text: String
    let range: CFRange?
    let value: String?
    var clipboardBased = false
    var clipboardPolicy: ClipboardSelectionPolicy = .standard
    var anchor: NSRect? = nil
    var selectionSource: AXUIElement? = nil
    var fixedAnchor = false
    let created = Date()
    var identity: String { "\(pid):\(CFHash(element)):\(range?.location ?? -1):\(range?.length ?? -1):\(text)" }
    var replaceable: Bool { editable(element) }
    var fullValue: String? {
        guard let value, let range, matchesRange(value, text, range) else { return nil }
        return value
    }
    var currentAnchor: NSRect? {
        if clipboardBased || fixedAnchor { return anchor }
        return matchingSelectionBounds(selectionSource ?? element, text: text) ?? anchor
    }
    func validate() -> String? {
        guard Date().timeIntervalSince(created) < 900 else { return "选区已超过 15 分钟，请重新划词。" }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated, app.bundleIdentifier == bundleID else { return "原应用已退出，请重新划词。" }
        if let value = fullValue, attribute(element, kAXValueAttribute) as? String != value { return "原文已经改变，未替换。请重新划词。" }
        if let window {
            guard let current = elementAttribute(element, kAXWindowAttribute), CFEqual(window, current) else { return "原窗口已经改变，未替换。" }
        }
        guard replaceable else { return "这是只读内容，无法写回；请复制译文或修正稿。" }
        return nil
    }
    func liveSelectionMatches() -> Bool {
        if let source = selectionSource, !CFEqual(source, element), !markerSelectionIsWithin(source, element) { return false }
        guard selectedText(selectionSource ?? element) == text else { return false }
        if let range {
            guard let current = selectedRange(element), current.location == range.location, current.length == range.length else { return false }
        }
        return true
    }
}

final class SelectionReader {
    var diagnostic = "waiting"
    private var clipboardSnapshot: SelectionSnapshot?
    // Last AX read for the current gesture. Long WebKit selections (e.g. Outlook mail)
    // can intermittently exceed the AX timeout, which must not reset a found selection.
    private var axSnapshot: SelectionSnapshot?
    private var axConfirmed = false
    private var axAttempts = 0
    private var gesture = 0
    private var pendingGesture = false
    private var mouseDrag = MouseDragSelection()
    private var gestureBounds: NSRect?
    private var gesturePID: pid_t?
    var hasMouseSelection: Bool { gesturePID != nil && gestureBounds != nil }
    private var monitor: Any?
    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != selectionEventTag else { return }
            if event.type == .leftMouseDragged {
                self.mouseDrag.drag(to: eventScreenPoint(event))
            } else if event.type == .leftMouseUp {
                if let bounds = self.mouseDrag.finish(at: eventScreenPoint(event)) {
                    self.pendingGesture = true; self.gesturePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    // Fixed at selection completion, never updated by later mouse movement.
                    self.gestureBounds = bounds
                }
            } else {
                self.gesture += 1; self.clipboardSnapshot = nil; self.pendingGesture = false
                self.axSnapshot = nil; self.axConfirmed = false; self.axAttempts = 0
                self.gestureBounds = nil; self.gesturePID = nil
                if event.type == .leftMouseDown { self.mouseDrag.begin(at: eventScreenPoint(event), clickCount: event.clickCount) }
                else { self.mouseDrag.cancel() }
            }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    private var enabledPIDs = Set<pid_t>()
    let exclusions: Set<String> = ["com.apple.systempreferences", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop"]
    func capture() -> SelectionSnapshot? {
        diagnostic = "waiting-for-mouse-selection"
        guard hasMouseSelection else { return nil }
        diagnostic = "no-foreground"
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundle = app.bundleIdentifier, !exclusions.contains(bundle), gesturePID == app.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        let isVSCode = bundle == "com.microsoft.VSCode" || bundle == "com.microsoft.VSCodeInsiders"
        if !isVSCode && !enabledPIDs.contains(app.processIdentifier) {
            // Electron's documented assistive-technology switch (also used by VS Code).
            // Only the foreground application is touched; no user settings file is changed.
            _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(app.processIdentifier)
        }
        let deadline = Date().addingTimeInterval(0.5)
        diagnostic = "no-focused-element"
        let window = elementAttribute(application, kAXFocusedWindowAttribute)
        guard let focused = focusedElement(application, pid: app.processIdentifier) ?? window, !isSecure(focused) else { return nil }
        if let cached = clipboardSnapshot, cached.pid == app.processIdentifier, related(cached.element, focused) {
            diagnostic = "native-copy-selection"; return cached
        }
        diagnostic = isVSCode ? ClipboardSelection.shared.diagnostic : "no-readable-selection"
        // Selection changes need a new mouse/key gesture, which clears this cache.
        // Bounded retries keep slow or unreadable apps from blocking every tick.
        if axConfirmed || axAttempts >= 6 {
            guard let cached = axSnapshot, cached.pid == app.processIdentifier else { return nil }
            diagnostic = cached.replaceable ? "selection-editable" : "selection-readonly"; return cached
        }
        axAttempts += 1
        // WebKit can put the selected marker on a non-editable AXWebArea ancestor.
        // Read that ancestor itself, but don't fan out into its unrelated siblings.
        var queue = [focused]
        var scopedAncestors: [AXUIElement] = []
        var ancestor = elementAttribute(focused, kAXParentAttribute)
        for _ in 0..<8 {
            guard let node = ancestor else { break }
            if attribute(node, kAXRoleAttribute) as? String == kAXWindowRole { break }
            scopedAncestors.append(node)
            if editable(node) { queue.insert(node, at: 0) }
            ancestor = elementAttribute(node, kAXParentAttribute)
        }
        var copyTarget = queue.first(where: { editable($0) }) ?? focused
        // A click in a web page may leave AX focus on the window. Hit-test only
        // the last selection gesture, restricted to this foreground process.
        if gesturePID == app.processIdentifier, let bounds = gestureBounds, let primary = NSScreen.screens.first {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(application, Float(bounds.midX), Float(primary.frame.maxY - bounds.midY), &hit) == .success,
               let hit, !isSecure(hit) { queue.insert(hit, at: 0) }
        }
        var visited = Set<CFHashCode>()
        let roots = queue
        var ancestorReads = roots + scopedAncestors
        queue = []
        while (!queue.isEmpty || !ancestorReads.isEmpty) && visited.count < 96 && Date() < deadline {
            let onlyRead = !ancestorReads.isEmpty
            let element = onlyRead ? ancestorReads.removeFirst() : queue.removeFirst()
            guard visited.insert(CFHash(element)).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, 0.25)
            if isSecure(element) { continue }
            if !editable(copyTarget), editable(element), related(element, focused) { copyTarget = element }
            if !isVSCode, let text = selectedText(element), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard text.utf16.count <= 24000 else { pendingGesture = false; diagnostic = "selection-too-long"; return nil }
                pendingGesture = false
                let target = !editable(element) && editable(copyTarget) && markerSelectionIsWithin(element, copyTarget) ? copyTarget : element
                diagnostic = editable(target) ? "selection-editable" : "selection-readonly"
                let value = attribute(target, kAXValueAttribute) as? String
                let snapshot = SelectionSnapshot(element: target, window: elementAttribute(target, kAXWindowAttribute),
                    pid: app.processIdentifier, appName: app.localizedName ?? bundle, bundleID: bundle,
                    text: text, range: CFEqual(target, element) ? selectedRange(element) : nil, value: value.flatMap { $0.utf16.count <= 500000 ? $0 : nil },
                    anchor: matchingSelectionBounds(element, text: text) ?? fallbackAnchor(pid: app.processIdentifier), selectionSource: element)
                // Two identical reads confirm the settled selection; later ticks reuse it.
                // Its anchor is then frozen: re-reading a long selection every tick is slow and flaky.
                if let previous = axSnapshot, previous.identity == snapshot.identity {
                    axConfirmed = true; axSnapshot?.fixedAnchor = true
                } else { axSnapshot = snapshot }
                return axSnapshot
            }
            if !onlyRead || roots.contains(where: { CFEqual($0, element) }),
               let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(48)) }
        }
        if let cached = axSnapshot, cached.pid == app.processIdentifier {
            diagnostic = cached.replaceable ? "selection-editable" : "selection-readonly"; return cached
        }
        // One native copy per completed selection gesture, only after AX fails.
        // This covers ordinary rich editors without requiring VS Code metadata.
        let role = attribute(copyTarget, kAXRoleAttribute) as? String ?? ""
        let textSurface = editable(copyTarget) || [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole, "AXWebArea"].contains(role) ||
            scopedAncestors.contains { attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }
        if pendingGesture, gesturePID == app.processIdentifier, !ClipboardSelection.shared.busy, textSurface {
            pendingGesture = false
            let generation = gesture
            let policy: ClipboardSelectionPolicy = isVSCode ? .vscode : .standard
            let pointerAnchor = fallbackAnchor(pid: app.processIdentifier)
            ClipboardSelection.shared.read(pid: app.processIdentifier, policy: policy, valid: { [weak self] in
                guard let self, self.gesture == generation, !isSecure(copyTarget),
                      let current = focusedElement(application, pid: app.processIdentifier) ?? elementAttribute(application, kAXFocusedWindowAttribute) else { return false }
                return related(current, focused)
            }) { [weak self] text in
                guard let self, self.gesture == generation, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 24000 else { return }
                let range = selectedRange(copyTarget), value = attribute(copyTarget, kAXValueAttribute) as? String
                let reliableRange = range.flatMap { range in value.map { matchesRange($0, text, range) } == true ? range : nil }
                self.clipboardSnapshot = SelectionSnapshot(element: copyTarget, window: elementAttribute(copyTarget, kAXWindowAttribute),
                    pid: app.processIdentifier, appName: app.localizedName ?? bundle, bundleID: bundle,
                    text: text, range: reliableRange, value: value.flatMap { $0.utf16.count <= 500000 ? $0 : nil },
                    clipboardBased: true, clipboardPolicy: policy,
                    anchor: resolvedSelectionAnchor(pointer: pointerAnchor, matchingAX: matchingSelectionBounds(copyTarget, text: text)))
            }
        }
        return nil
    }
    private func fallbackAnchor(pid: pid_t) -> NSRect? {
        gesturePID == pid ? gestureBounds : nil
    }
}

final class TextReplacer {
    private var busy = false
    func replace(_ snapshot: SelectionSnapshot, with text: String, completion: @escaping (String?, Bool) -> Void) {
        guard !busy else { completion("替换正在进行", false); return }
        guard !text.isEmpty else { completion("没有可替换的文字", false); return }
        if let error = snapshot.validate() { completion(error, false); return }
        guard let app = NSRunningApplication(processIdentifier: snapshot.pid) else { completion("原应用已退出", false); return }
        let expected = snapshot.fullValue.flatMap { replacing($0, snapshot.text, snapshot.range!, text) }
        busy = true
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
                self.busy = false; completion("未能切回原应用，未替换。", false); return
            }
            if let error = snapshot.validate() { self.busy = false; completion(error, false); return }
            let application = AXUIElementCreateApplication(snapshot.pid)
            guard let focused = focusedElement(application, pid: snapshot.pid), related(focused, snapshot.element), !isSecure(focused) else {
                self.busy = false; completion("原应用的焦点已改变，未替换。请重新划词。", false); return
            }
            if snapshot.clipboardBased {
                self.replaceClipboard(snapshot, text, completion); return
            }
            // Many web/Electron editors cannot SET the range but retain the selection.
            // Restore only when a full unchanged value proves the saved offsets still apply.
            if !snapshot.liveSelectionMatches(), snapshot.fullValue != nil, var range = snapshot.range,
               canSet(snapshot.element, kAXSelectedTextRangeAttribute), let ax = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, ax)
            }
            guard snapshot.liveSelectionMatches() else {
                self.busy = false; completion("原选区已改变或丢失，未替换。请重新划词。", false); return
            }
            // Chromium/Monaco can return AX success while leaving the document unchanged.
            // Use the editor's own paste command for both actual edits and native undo.
            let pasteboard = NSPasteboard.general, saved = ClipboardContents()
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
            let ownedCount = pasteboard.changeCount
            guard sendKey(snapshot.pid, 9, .maskCommand) else {
                saved.restore(ifUnchanged: ownedCount); self.busy = false; completion("无法发送粘贴操作", false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                saved.restore(ifUnchanged: ownedCount)
                self.verify(snapshot, expected, text, completion)
            }
        }
    }
    private func replaceClipboard(_ snapshot: SelectionSnapshot, _ text: String, _ completion: @escaping (String?, Bool) -> Void) {
        func valid() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
                  let focused = focusedElement(AXUIElementCreateApplication(snapshot.pid), pid: snapshot.pid),
                  related(focused, snapshot.element), !isSecure(focused) else { return false }
            return snapshot.validate() == nil
        }
        ClipboardSelection.shared.read(pid: snapshot.pid, policy: snapshot.clipboardPolicy, valid: valid) { original in
            guard valid(), original == snapshot.text else { self.busy = false; completion("原选区已改变，未替换。请重新划词。", false); return }
            let saved = ClipboardContents(), board = NSPasteboard.general
            board.clearContents(); board.setString(text, forType: .string)
            let count = board.changeCount
            guard sendKey(snapshot.pid, 9, .maskCommand) else {
                saved.restore(ifUnchanged: count); self.busy = false; completion("无法发送粘贴操作", false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                saved.restore(ifUnchanged: count)
                // Passive AX reads only. Never replay Shift+Left for every
                // inserted character: that visibly flashes and can move a new
                // user selection, especially with Unicode or long answers.
                let expected = snapshot.fullValue.flatMap { replacing($0, snapshot.text, snapshot.range!, text) }
                self.verify(snapshot, expected, text, completion)
            }
        }
    }
    private func verify(_ snapshot: SelectionSnapshot, _ expected: String?, _ text: String, _ completion: @escaping (String?, Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.busy = false
            let value = attribute(snapshot.element, kAXValueAttribute) as? String
            if let expected, let original = snapshot.fullValue, let value, value == original, value != expected {
                completion("原应用内容尚未改变，未能确认替换。请检查原文；不会自动重试。", false)
                return
            }
            let verified: Bool
            if let expected { verified = value == expected }
            else if let range = snapshot.range, let value {
                verified = matchesRange(value, text, CFRange(location: range.location, length: text.utf16.count))
            } else { verified = false }
            // Completion means the paste was sent, not that every editor exposes
            // a readable result. Keep that distinction in the non-activating UI.
            completion(verified ? nil : "已发送替换，请检查原文（应用未提供可核实的结果，不会自动重试）。", true)
        }
    }
}
