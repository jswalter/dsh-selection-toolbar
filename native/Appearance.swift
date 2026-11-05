import AppKit

// The entire heading is a drag handle except for its actual buttons. Labels
// remain accessible, but neither their text nor their empty bounds take clicks.
final class PanelTitlebar: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// Use the same vertically centered text rect for placeholder, text and field editor.
final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.drawingRect(forBounds: rect)
        let height = min(textRect.height, cellSize(forBounds: rect).height)
        textRect.origin.y += (textRect.height - height) / 2
        textRect.size.height = height
        return textRect
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}

// The reference captures are Retina (2×). All geometry here uses logical points.
enum Palette {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    static let surface = color(0xffffff, 0x373737)
    static let border = color(0xdddddd, 0x555555)
    static let divider = color(0xeaeaea, 0x4a4a4a)
    static let text = color(0x262626, 0xf0f0f0)
    static let secondary = color(0x808080, 0xa6a6a6)
    static let hover = color(0xf1f1f1, 0x484848)
    static let input = color(0xf6f6f6, 0x454545)
    static let accent = color(0x585bd7, 0xb8baff)
}

final class SurfaceView: NSView {
    var fill: NSColor = Palette.surface
    var stroke: NSColor = Palette.border
    var radius: CGFloat = 11
    var strokeWidth: CGFloat = 0.5
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor; layer?.borderColor = stroke.cgColor
        layer?.borderWidth = strokeWidth; layer?.cornerRadius = radius
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class ActionButton: NSButton {
    var callback: (() -> Void)?
    var symbol: String?
    var symbolSize: CGFloat = 15
    var selected = false { didSet { needsDisplay = true } }
    var circular = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    convenience init(_ title: String, symbol: String? = nil, help: String? = nil, _ callback: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.symbol = symbol; self.callback = callback; target = self; action = #selector(invoke)
        isBordered = false; font = .systemFont(ofSize: 13, weight: .medium)
        toolTip = help ?? title; setAccessibilityLabel(help ?? title)
    }
    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: title.isEmpty ? 30 : ceil(textWidth) + (symbol == nil ? 20 : 41), height: 30)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if circular || (isEnabled && (hovering || isHighlighted || selected)) {
            Palette.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: circular ? bounds.height / 2 : 7, yRadius: circular ? bounds.height / 2 : 7).fill()
        }
        let color = isEnabled ? (selected ? Palette.accent : Palette.text) : Palette.secondary
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let groupWidth = textSize.width + (symbol == nil ? 0 : symbolSize + (title.isEmpty ? 0 : 7))
        let x = (bounds.width - groupWidth) / 2
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let configured = image.withSymbolConfiguration(config) ?? image
            let scale = min(symbolSize / configured.size.width, symbolSize / configured.size.height)
            let size = NSSize(width: configured.size.width * scale, height: configured.size.height * scale)
            configured.draw(in: NSRect(x: x + (symbolSize - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        if !title.isEmpty {
            (title as NSString).draw(at: NSPoint(x: x + (symbol == nil ? 0 : symbolSize + 7), y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        }
    }
    @objc func invoke() { callback?() }
}

final class BrandMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // A restrained, original selection mark; no borrowed brand artwork.
        Palette.accent.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.6; path.lineCapStyle = .round
        for x: CGFloat in [4, 14] {
            path.move(to: NSPoint(x: x + (x < 10 ? 2 : -2), y: 4)); path.line(to: NSPoint(x: x, y: 4))
            path.line(to: NSPoint(x: x, y: 14)); path.line(to: NSPoint(x: x + (x < 10 ? 2 : -2), y: 14))
        }
        path.move(to: NSPoint(x: 7, y: 9)); path.line(to: NSPoint(x: 11, y: 9)); path.stroke()
    }
}
