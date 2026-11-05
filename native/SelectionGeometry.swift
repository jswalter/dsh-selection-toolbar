import AppKit

// AX uses the primary display's top-left origin; AppKit uses its bottom-left.
// NSScreen.main is the active window's screen, not necessarily the primary one.
func appKitRect(_ rect: CGRect, primaryHeight: CGFloat) -> NSRect {
    NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

func usableSelectionRect(_ rect: CGRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite } && rect.width > 0 && rect.height > 0
}

func pointerSelectionBounds(from start: NSPoint, to end: NSPoint) -> NSRect {
    NSRect(x: min(start.x, end.x) - 4, y: min(start.y, end.y) - 12,
           width: abs(end.x - start.x) + 8, height: abs(end.y - start.y) + 24)
}

struct MouseDragSelection {
    private var start: NSPoint?
    private var dragged = false
    mutating func begin(at point: NSPoint?, clickCount: Int) {
        start = clickCount == 1 ? point : nil
        dragged = false
    }
    mutating func drag(to point: NSPoint?) {
        guard let start, let point else { return }
        if hypot(point.x - start.x, point.y - start.y) > 3 { dragged = true }
    }
    mutating func finish(at point: NSPoint?) -> NSRect? {
        defer { cancel() }
        guard dragged, let start, let point, hypot(point.x - start.x, point.y - start.y) > 3 else { return nil }
        return pointerSelectionBounds(from: start, to: point)
    }
    mutating func cancel() { start = nil; dragged = false }
}

// A clipboard selection has no trustworthy AX range unless AX independently
// reports the same text. A completed pointer gesture is its own local anchor;
// never let a hidden editor input or the full control replace it afterward.
func resolvedSelectionAnchor(pointer: NSRect?, matchingAX: NSRect?) -> NSRect? {
    if let pointer, usableSelectionRect(pointer) { return pointer }
    if let matchingAX, usableSelectionRect(matchingAX) { return matchingAX }
    return nil
}

func toolbarFrame(around selection: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
    let available = visibleFrame.insetBy(dx: 8, dy: 8)
    let anchor = selection.intersection(visibleFrame)
    let bounds = anchor.isNull || anchor.isEmpty ? selection : anchor
    func clamp(_ point: NSPoint) -> NSRect {
        NSRect(x: max(available.minX, min(point.x, available.maxX - size.width)),
               y: max(available.minY, min(point.y, available.maxY - size.height)),
               width: size.width, height: size.height)
    }
    let alignedX = bounds.minX
    let centeredY = bounds.midY - size.height / 2
    let candidates = [
        clamp(NSPoint(x: alignedX, y: bounds.maxY + 8)),
        clamp(NSPoint(x: alignedX, y: bounds.minY - size.height - 8)),
        clamp(NSPoint(x: bounds.maxX + 8, y: centeredY)),
        clamp(NSPoint(x: bounds.minX - size.width - 8, y: centeredY))
    ]
    // Keep preference order for ties: above, below, right, left. At screen edges
    // choose the least overlap instead of clamping the preferred side over text.
    func overlap(_ rect: NSRect) -> CGFloat {
        let intersection = rect.intersection(bounds.insetBy(dx: -4, dy: -4))
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    return candidates.dropFirst().reduce(candidates[0]) { best, next in
        overlap(next) < overlap(best) ? next : best
    }
}
