import AppKit
import ApplicationServices

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    let reader = SelectionReader()
    let replacer = TextReplacer()
    let demo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "local.dsh.selection-toolbar.preview"
    let bridge = CommandLine.arguments.contains("--bridge")
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var snapshot: SelectionSnapshot?
    var lastIdentity = ""
    var dismissedIdentity = ""
    var pendingIdentity = ""
    var toolbarAnchor: NSRect?
    var expanded = false
    var paused = false
    var trusted = false
    var connected = false
    var busy = false
    var currentID: String?
    var conversation = ""
    var action = "grammar"
    var sourceText = ""
    var result = ""
    var transcript = ""
    var turnPrefix = ""
    var previousTurns: [[String: String]] = []
    var models: [[String: String]] = []
    let languages = [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "英语"), ("ja", "日本語")]
    var sourceLanguage = "auto"
    var targetLanguage = "zh-Hans"
    var sourcePicker: NSPopUpButton?
    var targetPicker: NSPopUpButton?
    var swapButton: ActionButton?
    var pairTarget = false
    var selectedRoute: [String: String]?
    var defaultRoute: [String: String]?
    var modelWarnings: [String] = []
    var settingsWindow: NSWindow?
    var settingsPicker: NSPopUpButton?
    var settingsStatus: NSTextField?
    var surface: SurfaceView!
    var quote: NSTextField!
    var quoteBar: SurfaceView!
    var divider: SurfaceView!
    var inputShell: SurfaceView!
    var actions: [NSView] = []
    var pinned = false
    var pinButton: ActionButton!
    var moreButton: ActionButton!
    var outsideMonitor: Any?
    var output: MarkdownView!
    var statusLabel: NSTextField!
    var followup: NSTextField!
    var replaceButton: NSButton!
    var copyButton: NSButton!
    var sendButton: NSButton!
    var stopButton: NSButton!
    var retryButton: NSButton!
    var permissionWindow: NSWindow?
    var inputSource: DispatchSourceRead?
    var inputBuffer = Data()
    var diagnosticTicks = 0
    var replacementNotice = 0
    let parentPID = getppid()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Standard responder-chain shortcuts for the field editor and rendered text.
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出划词工具栏", action: #selector(quitHelper), keyEquivalent: "q")
        quitItem.target = self; applicationMenu.addItem(quitItem); applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                       ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        restoreLanguages()
        if let stored = UserDefaults.standard.dictionary(forKey: "route") as? [String: String], stored["provider"] != nil, stored["model"] != nil { selectedRoute = stored }
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 52),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.delegate = self
        createMenu()
        trusted = AXIsProcessTrusted()
        if bridge { connectInput(); send(["type": "hello"]) }
        if demo {
            connected = true; sourceText = "This are a simple test. She go to school yesterday."
            showToolbar(at: NSPoint(x: 600, y: 700))
            // Reproducible visual fixtures for the separate preview bundle only.
            if let scene = Bundle.main.object(forInfoDictionaryKey: "DSHPreviewScene") as? String {
                if scene == "settings" { showSettings() }
                else {
                    begin(scene == "translate" ? "translate" : "grammar")
                    if ["long", "light", "error", "markdown"].contains(scene) {
                        let item = NSMenuItem(); item.tag = scene == "long" ? 0 : scene == "light" ? 3 : scene == "markdown" ? 4 : 2
                        previewState(item)
                    }
                }
            }
        } else if !trusted { showPermission() }
        else if !bridge { showMessage("请通过 DSH 插件启动", "辅助程序由 DSH 插件自动管理。请先安装插件并启动 DeepSeek Harness。") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePanel(); return nil }
            return event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.expanded, !self.pinned, self.panel.isVisible,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.closePanel()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return true
    }
    func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "划词"
        let menu = NSMenu()
        let title = NSMenuItem(title: "DSH AI 划词工具栏", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "暂停划词", action: #selector(togglePause(_:)), keyEquivalent: ""); pause.target = self; menu.addItem(pause)
        let permissions = NSMenuItem(title: "辅助功能权限…", action: #selector(openPermissions), keyEquivalent: ""); permissions.target = self; menu.addItem(permissions)
        let refresh = NSMenuItem(title: "刷新模型列表", action: #selector(refreshModels), keyEquivalent: ""); refresh.target = self; menu.addItem(refresh)
        let settings = NSMenuItem(title: "划词设置…", action: #selector(showSettings), keyEquivalent: ""); settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出划词工具栏", action: #selector(quitHelper), keyEquivalent: ""); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }
    @objc func togglePause(_ item: NSMenuItem) {
        paused.toggle(); item.title = paused ? "恢复划词" : "暂停划词"
        statusItem.button?.title = paused ? "划词 ∥" : "划词"
        if paused { closePanel() }
    }
    @objc func refreshModels() {
        settingsStatus?.stringValue = "正在读取 DSH 模型列表…"
        send(["type": "models"])
        if demo { populateModels() }
    }
    @objc func quitHelper() { send(["type": "cancel"]); NSApp.terminate(nil) }
    @objc func openPermissions() {
        // Only user clicks request the OS permission dialog; never grant permission programmatically.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func showPermission() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 230), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "启用 DSH 划词工具栏"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let text = NSTextField(wrappingLabelWithString: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 DSH Selection。\n\n它用于读取选区和在你点击“替换原文”时写回文字。只有点击语法修正、翻译或解释后，所选文字才会发送给 DSH 的模型。")
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(ActionButton("打开辅助功能设置") { [weak self] in self?.openPermissions() })
        window.contentView = stack; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        permissionWindow = window
    }
    func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    func tick() {
        if bridge && getppid() != parentPID { NSApp.terminate(nil); return }
        let nowTrusted = AXIsProcessTrusted()
        diagnosticTicks += 1
        if diagnosticTicks % 10 == 0 { send(["type": "status", "trusted": nowTrusted, "connected": connected, "paused": paused, "expanded": expanded, "selectionStatus": reader.diagnostic, "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "mouseButtons": NSEvent.pressedMouseButtons, "panelVisible": panel.isVisible]) }
        if nowTrusted != trusted {
            trusted = nowTrusted
            if trusted { permissionWindow?.close(); permissionWindow = nil }
            else { closePanel(); showPermission() }
        }
        guard !demo, bridge, connected, trusted, !paused, !expanded else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        if !reader.hasMouseSelection {
            panel.orderOut(nil); lastIdentity = ""; pendingIdentity = ""; dismissedIdentity = ""; return
        }
        if panel.isVisible && panel.frame.contains(NSEvent.mouseLocation) { return }
        guard let candidate = reader.capture() else {
            panel.orderOut(nil); lastIdentity = ""; pendingIdentity = ""; dismissedIdentity = ""; return
        }
        guard let candidateAnchor = candidate.currentAnchor else {
            // Missing text geometry is not permission to anchor at the editor
            // or screen centre. Await a selection whose location is known.
            panel.orderOut(nil); lastIdentity = ""; pendingIdentity = ""; return
        }
        if candidate.identity == dismissedIdentity { return }
        if candidate.identity == lastIdentity {
            snapshot = candidate
            if candidateAnchor != toolbarAnchor { positionToolbar(candidateAnchor, size: panel.frame.size) }
            return
        }
        // Two samples allow the mouse selection to settle before showing UI.
        if candidate.identity != pendingIdentity { pendingIdentity = candidate.identity; return }
        snapshot = candidate; sourceText = candidate.text; lastIdentity = candidate.identity
        showToolbar(around: candidateAnchor)
    }
    func label(_ text: String, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: small ? 12 : 13)
        label.textColor = small ? Palette.secondary : Palette.text
        return label
    }
    func newSurface() -> SurfaceView {
        let view = SurfaceView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = view; surface = view; return view
    }
    func line(_ color: NSColor = Palette.divider) -> SurfaceView {
        let view = SurfaceView(frame: .zero); view.fill = color; view.strokeWidth = 0; view.radius = 1
        return view
    }
    func position(_ point: NSPoint, _ size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!
        let frame = screen.visibleFrame
        let x = min(max(frame.minX + 8, point.x - size.width / 2), frame.maxX - size.width - 8)
        let desiredY = point.y - size.height - 8
        let y = min(max(frame.minY + 8, desiredY), frame.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }
    func positionToolbar(_ anchor: NSRect, size: NSSize) {
        toolbarAnchor = anchor
        let selection = anchor
        let screen = NSScreen.screens.max { a, b in
            func area(_ frame: NSRect) -> CGFloat {
                let overlap = frame.intersection(selection)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            return area(a.frame) < area(b.frame)
        } ?? NSScreen.main!
        let frame = toolbarFrame(around: selection, size: size, visibleFrame: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    func showToolbar(at point: NSPoint) {
        showToolbar(around: NSRect(x: point.x, y: point.y, width: 1, height: 1))
    }
    func showToolbar(around anchor: NSRect) {
        expanded = false; pinned = false
        let view = newSurface(); view.radius = 10
        let buttons = [
            ActionButton("语法修正", symbol: "wand.and.stars") { [weak self] in self?.begin("grammar") },
            ActionButton("翻译", symbol: "translate") { [weak self] in self?.begin("translate") },
            ActionButton("解释", symbol: "book.closed") { [weak self] in self?.begin("explain") }
        ]
        var x: CGFloat = 6
        for button in buttons {
            button.frame = NSRect(x: x, y: 6, width: button.intrinsicContentSize.width, height: 30)
            view.addSubview(button); x += button.frame.width + 4
        }
        let separator = line(Palette.border); separator.frame = NSRect(x: x + 3, y: 16, width: 1, height: 10)
        view.addSubview(separator); x += 10
        moreButton = ActionButton("", symbol: "ellipsis", help: "更多选项") {}
        moreButton.target = self; moreButton.action = #selector(showOptions(_:))
        moreButton.frame = NSRect(x: x, y: 6, width: 30, height: 30); view.addSubview(moreButton)
        positionToolbar(anchor, size: NSSize(width: x + 36, height: 42)); panel.orderFrontRegardless()
    }
    func restoreLanguages() {
        let allowed = languages.map { $0.0 }
        if let code = UserDefaults.standard.string(forKey: "sourceLanguage"), (["auto"] + allowed).contains(code) { sourceLanguage = code }
        if let code = UserDefaults.standard.string(forKey: "targetLanguage"), allowed.contains(code) { targetLanguage = code }
    }
    func begin(_ chosen: String) {
        action = chosen; expanded = true; result = ""; conversation = ""; transcript = ""
        send(["type": "clear"])
        // Toolbar translation starts from the saved pair; the bridge may flip zh/en without saving it.
        if chosen == "translate" { restoreLanguages(); pairTarget = true }
        showChat(); submit(initial: true)
    }
    func showChat() {
        pinned = demo
        let origin = NSPoint(x: panel.frame.midX, y: panel.frame.maxY + 8)
        let view = newSurface()
        sourcePicker = nil; targetPicker = nil; swapButton = nil
        if action == "translate" {
            let source = NSPopUpButton(frame: NSRect(x: 16, y: 62, width: 158, height: 30))
            source.addItems(withTitles: ["自动检测"] + languages.map { $0.1 })
            source.selectItem(at: (["auto"] + languages.map { $0.0 }).firstIndex(of: sourceLanguage) ?? 0)
            source.font = .systemFont(ofSize: 13); source.target = self; source.action = #selector(languageChanged)
            source.setAccessibilityLabel("原始语言"); view.addSubview(source); sourcePicker = source
            let target = NSPopUpButton(frame: NSRect(x: 226, y: 62, width: 158, height: 30))
            target.addItems(withTitles: languages.map { $0.1 }); target.selectItem(at: languages.firstIndex { $0.0 == targetLanguage } ?? 0)
            target.font = .systemFont(ofSize: 13); target.target = self; target.action = #selector(languageChanged)
            target.setAccessibilityLabel("目标语言"); view.addSubview(target); targetPicker = target
            let swap = ActionButton("", symbol: "arrow.left.arrow.right", help: "交换原始语言和目标语言") { [weak self] in self?.swapLanguages() }
            swap.frame = NSRect(x: 185, y: 62, width: 30, height: 30); view.addSubview(swap); swapButton = swap
        }
        let title = ["grammar": "语法修正", "translate": "翻译", "explain": "解释"][action] ?? "AI 对话"
        let titlebar = PanelTitlebar(frame: NSRect(x: 0, y: 0, width: view.bounds.width, height: 47))
        titlebar.autoresizingMask = [.width]; view.addSubview(titlebar)
        let brand = BrandMark(frame: NSRect(x: 16, y: 15, width: 18, height: 18)); titlebar.addSubview(brand)
        let header = label(title, small: true); header.font = .systemFont(ofSize: 13)
        header.isSelectable = false; header.isEditable = false
        header.frame = NSRect(x: 40, y: 15, width: 190, height: 20)
        header.toolTip = demo ? "界面预览 · 不调用模型，不修改其他应用" : "DSH AI 划词工具栏"
        titlebar.addSubview(header)
        let grip = line(Palette.secondary); grip.frame = NSRect(x: 195, y: 7, width: 10, height: 1); titlebar.addSubview(grip)
        pinButton = ActionButton("", symbol: "pin", help: "固定面板：点击外部时保留") { [weak self] in
            guard let self else { return }; self.pinned.toggle(); self.pinButton.selected = self.pinned
            self.pinButton.toolTip = self.pinned ? "取消固定" : "固定面板：点击外部时保留"
        }
        pinButton.symbolSize = 13; pinButton.frame = NSRect(x: 328, y: 9, width: 28, height: 30); titlebar.addSubview(pinButton)
        pinButton.selected = pinned
        let close = ActionButton("", symbol: "xmark", help: "关闭 (Esc)") { [weak self] in self?.closePanel() }
        close.symbolSize = 11; close.frame = NSRect(x: 362, y: 9, width: 24, height: 30); titlebar.addSubview(close)
        divider = line(); divider.frame = NSRect(x: 16, y: 47, width: 368, height: 0.5); view.addSubview(divider)
        let excerpt = sourceText.replacingOccurrences(of: "\n", with: " ")
        quote = label(String(excerpt.prefix(220)) + (excerpt.count > 220 ? "…" : ""), small: true)
        quote.isHidden = action == "translate"
        quote.font = .systemFont(ofSize: 13); quote.maximumNumberOfLines = 2
        quote.cell?.lineBreakMode = .byTruncatingTail
        quote.toolTip = "\(snapshot?.appName ?? "界面预览") · \(sourceText.count) 字符"
        quoteBar = line(Palette.secondary); quoteBar.isHidden = action == "translate"; view.addSubview(quoteBar); view.addSubview(quote)
        output = MarkdownView(frame: NSRect(x: 16, y: 100, width: 368, height: 24))
        output.onHeightChange = { [weak self] in self?.layoutChat() }; view.addSubview(output)
        statusLabel = label("", small: true); statusLabel.maximumNumberOfLines = 2; view.addSubview(statusLabel)
        replaceButton = ActionButton("", symbol: "arrow.up.arrow.down", help: "替换原文") { [weak self] in self?.replaceAnswer() }
        replaceButton.isHidden = !["grammar", "translate"].contains(action)
        copyButton = ActionButton("", symbol: "doc.on.doc", help: "复制回答") { [weak self] in self?.copyAnswer() }
        retryButton = ActionButton("", symbol: "arrow.clockwise", help: "重新生成") { [weak self] in self?.retry() }
        stopButton = ActionButton("", symbol: "stop.circle", help: "停止生成") { [weak self] in self?.send(["type": "cancel"]) }
        moreButton = ActionButton("", symbol: "ellipsis", help: "更多选项与模型") {}
        moreButton.target = self; moreButton.action = #selector(showOptions(_:))
        actions = [replaceButton, copyButton, retryButton, stopButton, moreButton]
        actions.forEach { view.addSubview($0) }
        inputShell = SurfaceView(frame: .zero); inputShell.fill = Palette.input; inputShell.radius = 12; view.addSubview(inputShell)
        followup = NSTextField(); followup.cell = CenteredTextFieldCell(textCell: "")
        followup.isEditable = true; followup.isSelectable = true
        followup.cell?.usesSingleLineMode = true; followup.cell?.isScrollable = true
        followup.placeholderString = "继续提问"; followup.delegate = self
        followup.isBordered = false; followup.drawsBackground = false; followup.focusRingType = .none
        followup.target = self; followup.action = #selector(sendFollowup); followup.font = .systemFont(ofSize: 13)
        followup.textColor = Palette.text
        followup.placeholderAttributedString = NSAttributedString(string: "继续提问", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.secondary
        ])
        inputShell.addSubview(followup)
        let send = ActionButton("", symbol: "arrow.up", help: "发送追问") { [weak self] in self?.sendFollowup() }
        send.circular = true; send.symbolSize = 14; sendButton = send; inputShell.addSubview(send)
        populateModels()
        position(origin, NSSize(width: 400, height: 240)); layoutChat(); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(followup)
    }
    // Keep the top edge still while streaming. Only long text receives a scrollbar.
    func layoutChat() {
        guard expanded, output != nil, quote != nil else { return }
        let width: CGFloat = 400, inner: CGFloat = 368
        let quoteHeight: CGFloat = action == "translate" ? 31 : min(38, max(19, ceil(quote.sizeThatFits(NSSize(width: inner - 9, height: 100)).height)))
        quote.frame = NSRect(x: 25, y: 62, width: inner - 9, height: quoteHeight)
        quoteBar.frame = NSRect(x: 16, y: 64, width: 2, height: quoteHeight - 3)
        let textHeight = output.contentHeight
        let screen = panel.screen ?? NSScreen.main!
        let statusHeight: CGFloat = statusLabel.stringValue.isEmpty ? 0 : min(34, max(17, ceil(statusLabel.sizeThatFits(NSSize(width: inner, height: 50)).height))) + 6
        let maximumHeight = min(352, screen.visibleFrame.height - 32)
        let outputHeight = min(textHeight, max(24, maximumHeight - 182 - quoteHeight - statusHeight))
        let outputY = 76 + quoteHeight
        output.frame = NSRect(x: 16, y: outputY, width: inner, height: outputHeight)
        let actionY = outputY + outputHeight + 10
        var x: CGFloat = 13
        for button in actions where !button.isHidden {
            button.frame = NSRect(x: x, y: actionY, width: 30, height: 30); x += 34
        }
        statusLabel.isHidden = statusHeight == 0
        statusLabel.frame = NSRect(x: 16, y: actionY + 32, width: inner, height: max(0, statusHeight - 6))
        let inputY = actionY + 42 + statusHeight
        inputShell.frame = NSRect(x: 16, y: inputY, width: inner, height: 38)
        followup.frame = NSRect(x: 12, y: 0, width: inner - 58, height: 38)
        sendButton.frame = NSRect(x: inner - 34, y: 7, width: 24, height: 24)
        let height = inputY + 54
        let oldFrame = panel.frame
        let y = max(screen.visibleFrame.minY + 8, oldFrame.maxY - height)
        panel.setFrame(NSRect(x: oldFrame.minX, y: y, width: width, height: height), display: true)
    }
    func renderOutput(scrollToEnd: Bool = false) {
        output.render(previousTurns + (result.isEmpty ? [] : [["role": "assistant", "text": result]]), scrollToEnd: scrollToEnd)
        layoutChat()
    }
    func showStatus(_ text: String) { statusLabel?.stringValue = text; if expanded { layoutChat() } }
    func populateModels() {
        moreButton?.toolTip = selectedRoute.map { "当前模型：\($0["model"] ?? "")" } ?? "跟随 DSH 默认模型 · 更多选项"
        settingsPicker?.removeAllItems()
        let defaultTitle = defaultRoute?["model"].map { "跟随 DSH 默认模型（\($0)）" } ?? "跟随 DSH 默认模型"
        settingsPicker?.addItem(withTitle: defaultTitle)
        for model in models { settingsPicker?.addItem(withTitle: model["name"] ?? model["model"] ?? "模型") }
        if let selectedRoute {
            if let index = models.firstIndex(where: { $0["provider"] == selectedRoute["provider"] && $0["model"] == selectedRoute["model"] }) {
                settingsPicker?.selectItem(at: index + 1)
            } else {
                settingsPicker?.addItem(withTitle: "暂不可用：\(selectedRoute["model"] ?? "")")
                settingsPicker?.lastItem?.isEnabled = false; settingsPicker?.selectItem(at: models.count + 1)
            }
        } else { settingsPicker?.selectItem(at: 0) }
        let count = Set(models.compactMap { $0["provider"] }).count
        settingsStatus?.stringValue = modelWarnings.isEmpty ? "DSH 已配置 \(count) 个服务商、\(models.count) 个模型" : "以下服务商暂时无法读取模型，请刷新重试：\(modelWarnings.joined(separator: "、"))"
    }
    @objc func showSettings() {
        if let settingsWindow { populateModels(); settingsWindow.makeKeyAndOrderFront(nil); refreshModels(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 232), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "划词设置"; window.isReleasedWhenClosed = false; window.level = .floating
        let view = SurfaceView(frame: NSRect(x: 0, y: 0, width: 420, height: 232)); view.radius = 0; view.strokeWidth = 0
        let title = label("划词使用的模型"); title.font = .systemFont(ofSize: 14, weight: .medium)
        title.frame = NSRect(x: 20, y: 20, width: 380, height: 22); view.addSubview(title)
        let picker = NSPopUpButton(frame: NSRect(x: 18, y: 53, width: 384, height: 28))
        picker.font = .systemFont(ofSize: 12); picker.target = self; picker.action = #selector(settingsModelChanged(_:))
        view.addSubview(picker); settingsPicker = picker
        let status = label("正在读取 DSH 模型列表…", small: true)
        status.frame = NSRect(x: 20, y: 90, width: 380, height: 34); status.maximumNumberOfLines = 2; view.addSubview(status); settingsStatus = status
        let note = label("模型直接来自 DSH 的服务商配置。选择自动保存；当前对话保持原模型，重新生成或再次划词时使用新选择。", small: true)
        note.frame = NSRect(x: 20, y: 130, width: 380, height: 40); view.addSubview(note)
        let refresh = ActionButton("刷新列表", symbol: "arrow.clockwise") { [weak self] in self?.refreshModels() }
        refresh.frame = NSRect(x: 13, y: 184, width: 105, height: 30); view.addSubview(refresh)
        let done = ActionButton("完成") { [weak window] in window?.close() }
        done.frame = NSRect(x: 340, y: 184, width: 60, height: 30); view.addSubview(done)
        window.contentView = view; settingsWindow = window; populateModels()
        window.center(); window.makeKeyAndOrderFront(nil); refreshModels()
    }
    @objc func settingsModelChanged(_ sender: NSPopUpButton) {
        saveModel(index: sender.indexOfSelectedItem)
    }
    @objc func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "划词设置…", action: #selector(showSettings), keyEquivalent: ""); settings.target = self; menu.addItem(settings)
        let modelMenu = NSMenu()
        let defaultItem = NSMenuItem(title: "跟随 DSH 默认模型", action: #selector(selectModel(_:)), keyEquivalent: "")
        defaultItem.target = self; defaultItem.tag = 0; defaultItem.state = selectedRoute == nil ? .on : .off
        modelMenu.addItem(defaultItem)
        for (index, model) in models.enumerated() {
            let item = NSMenuItem(title: model["name"] ?? model["model"] ?? "模型", action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self; item.tag = index + 1
            item.state = selectedRoute?["provider"] == model["provider"] && selectedRoute?["model"] == model["model"] ? .on : .off
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "选择模型", action: nil, keyEquivalent: ""); modelItem.submenu = modelMenu; modelItem.isEnabled = !busy
        menu.addItem(modelItem)
        let refresh = NSMenuItem(title: "刷新模型列表", action: #selector(refreshModels), keyEquivalent: ""); refresh.target = self; menu.addItem(refresh)
        menu.addItem(.separator())
        if demo {
            let note = NSMenuItem(title: "界面预览 · 不调用模型或修改原文", action: nil, keyEquivalent: ""); note.isEnabled = false; menu.addItem(note)
            if expanded {
                for (index, title) in ["预览长回答", "预览生成中", "预览错误提示", "切换预览明暗外观", "预览 Markdown"].enumerated() {
                    let item = NSMenuItem(title: title, action: #selector(previewState(_:)), keyEquivalent: ""); item.target = self; item.tag = index; menu.addItem(item)
                }
            }
        }
        let note = NSMenuItem(title: "点击操作后发送选区 · 对话保存在本机", action: nil, keyEquivalent: ""); note.isEnabled = false; menu.addItem(note)
        let close = NSMenuItem(title: "关闭", action: #selector(closeFromMenu), keyEquivalent: ""); close.target = self; menu.addItem(close)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 3), in: sender)
    }
    @objc func closeFromMenu() { closePanel() }
    @objc func selectModel(_ item: NSMenuItem) {
        guard !busy else { return }
        saveModel(index: item.tag)
    }
    func saveModel(index: Int) {
        guard index >= 0 && index <= models.count else { return }
        if index > 0 && index <= models.count {
            selectedRoute = ["provider": models[index - 1]["provider"]!, "model": models[index - 1]["model"]!]
            UserDefaults.standard.set(selectedRoute, forKey: "route")
        } else { selectedRoute = nil; UserDefaults.standard.removeObject(forKey: "route") }
        populateModels()
        if expanded { showStatus("模型将在重新生成或下次划词时生效") }
    }
    @objc func previewState(_ item: NSMenuItem) {
        guard demo else { return }
        if item.tag == 3 {
            panel.appearance = NSAppearance(named: panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .aqua : .darkAqua)
            return
        }
        if item.tag == 4 {
            turnPrefix = ""; previousTurns = []
            result = """
            ## Markdown 排版
            **重点**、*强调*、~~删除线~~与 `inline code`。

            > 引用文字会独立排版。

            1. 第一项
            2. 第二项
               - 嵌套列表

            ```swift
            let message = "你好，Markdown"
            print(message)
            ```

            | 功能 | 显示 | 替换 |
            | --- | --- | --- |
            | 标题 | 渲染后的标题 | 保留井号 |
            | 粗体 | **加粗** | 保留星号 |

            [示例链接](https://example.com)
            """
            transcript = result; renderOutput(); setBusy(false); showStatus("")
        } else if item.tag == 0 {
            turnPrefix = ""; previousTurns = []
            result = (1...18).map { "\($0). 这是一段用于检查长回答排版的示例文字。面板保持固定宽度，超过可见区域的内容可以滚动阅读，避免挡住正在浏览的页面。" }.joined(separator: "\n\n")
            transcript = result; renderOutput(); setBusy(false); showStatus("")
            output.scrollToBeginning()
        } else if item.tag == 1 { setBusy(true); showStatus("正在生成…") }
        else { setBusy(false); showStatus("暂时无法连接所选模型，请稍后重新生成。") }
    }
    @objc func languageChanged() {
        guard !busy, let sourcePicker, let targetPicker else { return }
        sourceLanguage = (["auto"] + languages.map { $0.0 })[sourcePicker.indexOfSelectedItem]
        targetLanguage = languages[targetPicker.indexOfSelectedItem].0
        UserDefaults.standard.set(sourceLanguage, forKey: "sourceLanguage")
        UserDefaults.standard.set(targetLanguage, forKey: "targetLanguage")
        retry()
    }
    func swapLanguages() {
        guard !busy, let sourceIndex = languages.firstIndex(where: { $0.0 == sourceLanguage }), let targetIndex = languages.firstIndex(where: { $0.0 == targetLanguage }) else { return }
        sourcePicker?.selectItem(at: targetIndex + 1); targetPicker?.selectItem(at: sourceIndex); languageChanged()
    }
    func setBusy(_ value: Bool) {
        sourcePicker?.isEnabled = !value; targetPicker?.isEnabled = !value; swapButton?.isEnabled = !value && sourceLanguage != "auto"
        busy = value; copyButton?.isEnabled = !value && !result.isEmpty
        replaceButton?.isEnabled = false; stopButton?.isEnabled = value; stopButton?.isHidden = !value
        retryButton?.isHidden = value
        sendButton?.isEnabled = !value && !conversation.isEmpty && !transcript.isEmpty; retryButton?.isEnabled = !value
        if expanded { layoutChat() }
    }
    func submit(initial: Bool, text: String = "") {
        if initial { previousTurns = [] }
        else {
            if !result.isEmpty { previousTurns.append(["role": "assistant", "text": result]) }
            previousTurns.append(["role": "user", "text": text])
        }
        let id = UUID().uuidString; currentID = id; result = ""
        setBusy(true)
        turnPrefix = transcript + (initial ? "" : "\n\n你：\(text)\n\n")
        renderOutput(); showStatus("正在生成…")
        var request: [String: Any] = ["type": initial ? "ask" : "followup", "id": id, "text": initial ? sourceText : text]
        if initial {
            request["action"] = action
            if action == "translate" { request["sourceLanguage"] = sourceLanguage; request["targetLanguage"] = targetLanguage; request["autoTarget"] = pairTarget }
            pairTarget = false
            if let selectedRoute { request["route"] = selectedRoute }
        } else { request["conversation"] = conversation }
        if demo {
            conversation = "demo"
            let answer = action == "grammar" ? "This is a simple test. She went to school yesterday." : action == "translate" ? "这是一个简单的测试。她昨天去了学校。" : "这段话描述了一次简单测试，并提到她昨天去上学。原文有两处语法问题：This are 应为 This is，表示昨天的动作应将 go 改为 went。"
            receive(["type": "done", "id": id, "text": answer, "replaceable": false]); return
        }
        send(request)
    }
    @objc func sendFollowup() {
        guard !busy, !transcript.isEmpty else { return }
        let text = followup.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf16.count <= 8000 else { showStatus("追问超过 8000 字符"); return }
        followup.stringValue = ""; submit(initial: false, text: text)
    }
    func retry() { guard !busy else { return }; transcript = ""; conversation = ""; send(["type": "clear"]); submit(initial: true) }
    func copyAnswer() {
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
        showStatus("已复制回答")
    }
    func replaceAnswer() {
        guard !busy, ["grammar", "translate"].contains(action), let snapshot, !result.isEmpty else { return }
        replaceButton.isEnabled = false; panel.orderOut(nil)
        replacer.replace(snapshot, with: result) { [weak self] error, success in
            guard let self else { return }
            if success {
                self.closePanel()
                if let error {
                    // Status stays in the menu bar; do not reopen the answer panel
                    // and steal focus after a paste whose result is unavailable.
                    self.replacementNotice += 1
                    let notice = self.replacementNotice
                    self.statusItem.button?.title = "划词 · 已发送替换"
                    self.statusItem.button?.toolTip = error
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard self.replacementNotice == notice else { return }
                        self.statusItem.button?.title = self.paused ? "划词 ∥" : "划词"
                        self.statusItem.button?.toolTip = nil
                    }
                }
            }
            else { self.panel.makeKeyAndOrderFront(nil); self.showStatus(error ?? "未完成替换") }
        }
    }
    func closePanel() {
        send(["type": "clear"]); currentID = nil; conversation = ""; busy = false
        dismissedIdentity = lastIdentity; panel.orderOut(nil); expanded = false; pinned = false
        snapshot = nil; sourceText = ""; result = ""; transcript = ""; previousTurns = []
    }
    func send(_ value: [String: Any]) {
        guard bridge, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        var line = data; line.append(10)
        try? FileHandle.standardOutput.write(contentsOf: line)
    }
    func connectInput() {
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { NSApp.terminate(nil); return }
            self.inputBuffer.append(data)
            if self.inputBuffer.count > 2000000 { NSApp.terminate(nil); return }
            while let end = self.inputBuffer.firstIndex(of: 10) {
                let line = self.inputBuffer.prefix(upTo: end)
                if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { self.receive(value) }
                self.inputBuffer.removeSubrange(...end)
            }
        }
        inputSource = source; source.resume()
    }
    func receive(_ value: [String: Any]) {
        let type = value["type"] as? String ?? ""
        if type == "ready" {
            connected = true; models = value["models"] as? [[String: String]] ?? []
            defaultRoute = value["defaultRoute"] as? [String: String]
            modelWarnings = value["warnings"] as? [String] ?? []
            populateModels(); return
        }
        if type == "notice" {
            let message = value["message"] as? String ?? "DSH 暂不可用"
            settingsStatus?.stringValue = message; showStatus(message); return
        }
        guard expanded, let id = value["id"] as? String, id == currentID else { return }
        switch type {
        case "started":
            conversation = value["conversation"] as? String ?? ""
            if action == "translate", let code = value["targetLanguage"] as? String, code != targetLanguage, let index = languages.firstIndex(where: { $0.0 == code }) {
                targetLanguage = code; targetPicker?.selectItem(at: index)
            }
            if let route = value["route"] as? [String: String] { showStatus("\(route["model"] ?? "模型") · 正在生成…") }
        case "delta":
            result += value["text"] as? String ?? ""; renderOutput(scrollToEnd: true)
        case "done":
            result = value["text"] as? String ?? ""; transcript = turnPrefix + result; renderOutput()
            setBusy(false)
            let canReplace = !demo && (value["replaceable"] as? Bool == true) && snapshot?.replaceable == true
            replaceButton.isEnabled = canReplace
            replaceButton.toolTip = canReplace ? "替换原文（写回前核对选区）" : "当前选区只支持复制"
            showStatus("")
        case "error":
            setBusy(false); copyButton.isEnabled = !result.isEmpty
            showStatus(value["message"] as? String ?? "请求失败")
            // Failed/truncated content is visible for inspection, never replaceable.
        default: break
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); inputSource?.cancel()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    var checkCount = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checkCount += 1
        if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
    }
    check(matchesRange("A😀中文B", "😀中文", CFRange(location: 1, length: 4)), "UTF16 selected range")
    check(replacing("A😀中文B", "😀中文", CFRange(location: 1, length: 4), "完成") == "A完成B", "Unicode replacement")
    check(!matchesRange("changed", "old", CFRange(location: 0, length: 3)), "stale text refused")
    check(!matchesRange("abc", "a", CFRange(location: Int.max, length: 1)), "overflow refused")
    check(!matchesRange("abc", "a", CFRange(location: -1, length: 1)), "negative range refused")
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let toolbarSize = NSSize(width: 320, height: 44)
    let singleLine = NSRect(x: 500, y: 400, width: 180, height: 20)
    let above = toolbarFrame(around: singleLine, size: toolbarSize, visibleFrame: screen)
    check(above.minY >= singleLine.maxY + 8 && !above.intersects(singleLine), "single-line toolbar stays above selection without overlap")
    let topLine = NSRect(x: 500, y: 872, width: 180, height: 20)
    let below = toolbarFrame(around: topLine, size: toolbarSize, visibleFrame: screen)
    check(below.maxY <= topLine.minY - 8 && screen.contains(below), "top-edge toolbar moves below selection")
    let bottomLine = NSRect(x: 500, y: 8, width: 180, height: 20)
    let bottomToolbar = toolbarFrame(around: bottomLine, size: toolbarSize, visibleFrame: screen)
    check(screen.contains(bottomToolbar) && !bottomToolbar.intersects(bottomLine), "bottom-edge toolbar stays on screen without overlap")
    let multipleLines = NSRect(x: 350, y: 280, width: 620, height: 180)
    let multilineToolbar = toolbarFrame(around: multipleLines, size: toolbarSize, visibleFrame: screen)
    check(multilineToolbar.minY >= multipleLines.maxY + 8 && screen.contains(multilineToolbar), "multiline toolbar stays above full selection bounds")
    let leftScreen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
    let leftSelection = NSRect(x: -1900, y: 450, width: 160, height: 20)
    let leftToolbar = toolbarFrame(around: leftSelection, size: toolbarSize, visibleFrame: leftScreen)
    check(leftScreen.contains(leftToolbar) && leftToolbar.maxX < 0 && !leftToolbar.intersects(leftSelection), "negative-coordinate display preserves toolbar screen bounds")
    check(appKitRect(CGRect(x: 250, y: -500, width: 180, height: 20), primaryHeight: 900) == NSRect(x: 250, y: 1380, width: 180, height: 20), "vertical secondary display AX coordinates convert using primary height")
    check(!usableSelectionRect(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 20)), "NaN selection bounds refused")
    check(!usableSelectionRect(CGRect(x: 0, y: 0, width: 0, height: 20)), "zero-width selection bounds refused")
    let shortLeftSelection = NSRect(x: 80, y: 400, width: 80, height: 20)
    let shortLeftToolbar = toolbarFrame(around: shortLeftSelection, size: toolbarSize, visibleFrame: screen)
    check(shortLeftToolbar.minX == shortLeftSelection.minX, "short left selection aligns toolbar to selection left edge")
    let rightEdgeSelection = NSRect(x: 1380, y: 400, width: 50, height: 20)
    let rightEdgeToolbar = toolbarFrame(around: rightEdgeSelection, size: toolbarSize, visibleFrame: screen)
    check(rightEdgeToolbar.maxX == screen.maxX - 8 && screen.contains(rightEdgeToolbar), "right-edge toolbar clamps inside visible screen")
    let dragStart = NSPoint(x: 84, y: 412)
    let dragEnd = NSPoint(x: 156, y: 412)
    let pointerAnchor = pointerSelectionBounds(from: dragStart, to: dragEnd)
    var dragGesture = MouseDragSelection()
    dragGesture.begin(at: dragStart, clickCount: 1)
    check(dragGesture.finish(at: dragEnd) == nil, "click or shift-click without drag event cannot activate")
    dragGesture.begin(at: dragStart, clickCount: 2); dragGesture.drag(to: dragEnd)
    check(dragGesture.finish(at: dragEnd) == nil, "double click cannot activate even with motion")
    dragGesture.begin(at: dragStart, clickCount: 3); dragGesture.drag(to: dragEnd)
    check(dragGesture.finish(at: dragEnd) == nil, "triple click cannot activate even with motion")
    dragGesture.begin(at: dragStart, clickCount: 1); dragGesture.drag(to: dragEnd)
    check(dragGesture.finish(at: dragEnd) == pointerAnchor, "single left-button drag activates with its recorded bounds")
    dragGesture.begin(at: dragStart, clickCount: 1); dragGesture.drag(to: NSPoint(x: dragStart.x + 2, y: dragStart.y))
    check(dragGesture.finish(at: NSPoint(x: dragStart.x + 2, y: dragStart.y)) == nil, "two-point click jitter cannot activate")
    dragGesture.begin(at: dragStart, clickCount: 1); dragGesture.drag(to: dragEnd); dragGesture.cancel()
    check(dragGesture.finish(at: dragEnd) == nil, "keyboard cancellation prevents a pending drag from activating")
    check(pointerAnchor == pointerSelectionBounds(from: dragEnd, to: dragStart), "forward and reverse pointer drags produce identical bounds")
    let multilinePointer = pointerSelectionBounds(from: NSPoint(x: 84, y: 300), to: NSPoint(x: 156, y: 440))
    check(multilinePointer.minX == 80 && multilinePointer.width == 80 && multilinePointer.height == 164, "multiline pointer bounds retain gesture width instead of control width")
    let distantAXLine = NSRect(x: 500, y: 700, width: 900, height: 24)
    check(resolvedSelectionAnchor(pointer: pointerAnchor, matchingAX: distantAXLine) == pointerAnchor, "pointer anchor takes precedence over distant AX line bounds")
    check(resolvedSelectionAnchor(pointer: nil, matchingAX: distantAXLine) == distantAXLine, "matching AX anchor accepted without pointer")
    check(resolvedSelectionAnchor(pointer: nil, matchingAX: nil) == nil, "missing pointer and AX anchors return nil")
    check(resolvedSelectionAnchor(pointer: NSRect(x: 80, y: 400, width: 0, height: 20), matchingAX: distantAXLine) == distantAXLine, "invalid pointer anchor falls back to valid matching AX bounds")
    // Chromium custom_data_helper.cc writes a uint32 count followed by
    // WriteString16 key/value pairs. Pickle uses a four-byte payload header,
    // UTF-16 code-unit lengths, and four-byte field alignment.
    func uint32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    func pickle(_ entries: [(String, String)]) -> Data {
        var payload = uint32(UInt32(entries.count))
        for (key, value) in entries {
            for string in [key, value] {
                let units = Array(string.utf16)
                payload += uint32(UInt32(units.count))
                for unit in units {
                    payload += [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)]
                }
                while payload.count % 4 != 0 { payload.append(0) }
            }
        }
        return Data(uint32(UInt32(payload.count)) + payload)
    }
    func metadata(_ json: String) -> [String: Any]? {
        vscodeClipboardMetadata(pickle([("odd", "值😀"), ("vscode-editor-data", json)]))
    }
    let selectedJSON = #"{"isFromEmptySelection":false,"isBlock":false,"mode":"plaintext"}"#
    let selected = metadata(selectedJSON)
    check(selected != nil && actualVSCodeSelection(selected!), "aligned Chromium map selected metadata")
    check(actualVSCodeSelection(metadata(#"{"isFromEmptySelection":false,"multicursorText":null}"#)!), "null multicursor accepted")
    check(!actualVSCodeSelection(metadata(#"{"isFromEmptySelection":true,"isBlock":false}"#)!), "empty-selection line copy refused")
    check(!actualVSCodeSelection(metadata(#"{"isFromEmptySelection":false,"isBlock":true}"#)!), "block selection refused")
    check(!actualVSCodeSelection(metadata(#"{"isFromEmptySelection":false,"multicursorText":["one","two"]}"#)!), "multiple cursors refused")
    check(!actualVSCodeSelection([:]), "missing selection flag refused")
    let unicode = metadata(#"{"isFromEmptySelection":false,"mode":"中文😀","note":"é𠮷"}"#)
    check(unicode?["mode"] as? String == "中文😀" && unicode?["note"] as? String == "é𠮷", "UTF16 Unicode metadata round trip")
    check(vscodeClipboardMetadata(pickle([("unrelated", selectedJSON)])) == nil, "missing metadata key refused")
    check(metadata("not JSON") == nil, "malformed JSON refused")
    check(metadata("[]") == nil, "non-object metadata refused")
    check(vscodeClipboardMetadata(Data()) == nil, "empty Pickle refused")
    let validPickle = pickle([("vscode-editor-data", selectedJSON)])
    check(acceptsCopiedSelection(.standard, customData: nil), "standard copy accepts missing VS Code metadata")
    check(!acceptsCopiedSelection(.vscode, customData: nil), "VS Code copy refuses missing metadata")
    for policy in [ClipboardSelectionPolicy.standard, .vscode] {
        check(acceptsCopiedSelection(policy, customData: validPickle), "\(policy) accepts selected-text metadata")
        let wholeLine = pickle([("vscode-editor-data", #"{"isFromEmptySelection":true,"isBlock":false}"#)])
        check(!acceptsCopiedSelection(policy, customData: wholeLine), "\(policy) refuses whole-line copy metadata")
        let multipleCursors = pickle([("vscode-editor-data", #"{"isFromEmptySelection":false,"multicursorText":["one","two"]}"#)])
        check(!acceptsCopiedSelection(policy, customData: multipleCursors), "\(policy) refuses multiple-cursor metadata")
    }
    check((0..<validPickle.count).allSatisfy { vscodeClipboardMetadata(Data(validPickle.prefix($0))) == nil }, "every truncated Pickle prefix refused")
    var badSize = validPickle; badSize[0] ^= 1
    check(vscodeClipboardMetadata(badSize) == nil, "incorrect payload size refused")
    check(vscodeClipboardMetadata(Data(uint32(4) + uint32(UInt32.max))) == nil, "excessive map count refused")
    check(vscodeClipboardMetadata(Data(uint32(8) + uint32(1) + uint32(UInt32.max))) == nil, "excessive UTF16 length refused")
    check(vscodeClipboardMetadata(Data(uint32(12) + uint32(1) + uint32(2) + [65, 0, 0, 0])) == nil, "missing map value refused")
    print("PASS: \(checkCount) native selection and Chromium clipboard checks")
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate(); application.delegate = delegate
    application.run()
}
