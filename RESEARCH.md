# 调研与实现依据

初始调研日期：2026-10-30。此文记录实现时的资料与接口依据，链接对应项目可能继续演进。

## 公开方案检索

检索关键词包括 `DeepSeek Harness plugin`、`dsh 划词`、`dsh selection`、`macOS selection grammar toolbar`、`PopClip DeepSeek`。核实以下作者仓库或官方资料，未使用目录网站的插件评分作为依据。

| 方案 | 已核实能力 | 与本次需求的差别 |
|---|---|---|
| [dsh-selection-ask](https://github.com/lzbaclz/dsh-selection-ask) | DSH 聊天选区旁显示“询问 DeepSeek”，通过 `inputActions.setDraft` 将 Markdown 引用追加到输入框 | 范围是 DSH 对话页面，不读取其他应用选区，也没有原应用替换 |
| [dsh-select-to-chat](https://github.com/mewmind-chen/dsh-select-to-chat) | DSH Web 页面内划词批注、编号、收集到下一条消息 | 属于页面内批注，不是全局桌面划词 |
| [dsh-ui-quote-selection](https://github.com/nekogpt/dsh-ui-quote-selection) | DSH 聊天选区引用，显示紧凑引用预览 | 没有跨应用监控与替换 |
| [Typer On](https://github.com/notime2/Typer-on-macos) | macOS 原生浮动工具栏、语法修正、翻译、解释、流式结果、继续修改和替换；Accessibility 取词 | 独立应用，使用自身模型接入；许可为个人使用授权，未复制其源码 |
| [Pot](https://github.com/pot-app/pot-desktop) | 跨平台快捷键划词翻译、输入翻译、OCR、剪贴板监听与服务插件 | 独立翻译客户端，不提供本次所需的 DSH 宿主生命周期 |
| [Bob-PopClip](https://github.com/ripperhe/Bob-PopClip) | PopClip 选词自动弹出按钮，通过扩展调用 Bob | 需要另外的 PopClip/Bob 应用，并非 DSH 插件 |

本次检索没有找到已核实同时提供“全局自动划词 + 三个操作 + DSH 模型复用 + 原位替换”的现成 DSH 插件。这是检索结果，不代表可以断言所有公开仓库都不存在类似实现。

## 当前 DSH 接口

实现时检查了官方应用的 `/Applications/DeepSeek Harness.app/Contents/Resources/app.asar` 中的程序与包文档，版本为 **0.2.1-rc.5**，commit `d4db512a969fccf0c5cc7ec8fe38e9c1d27af916`。

- `lib/main.js` 启动独立 Node 子进程运行 `dsh-desktop-host`。Host 插件不能直接把 Electron 的 `BrowserWindow` 当作宿主 API 使用。
- renderer 的 `nodeIntegration: false`、`contextIsolation: true`；`lib/preload-app.cjs` 没有向普通插件公开全局选区、任意原生窗口或剪贴板接口。
- `@deepseek-ai/dsh-llm` 文档指定 `ctx.llm` 为插件调用已配置 adapter 的入口。使用 `prepareCall`、`BlockAssembler`，按 `finish.kind` 检查完整成功，错误或截断不启用替换。
- `@deepseek-ai/dsh-agent-default-model` 提供 `agentDefaultModel.currentSelection()`；`llm.listProviders()` / `listModels()` 提供模型目录。
- `@deepseek-ai/dsh-session` 当前实验性 `appendPluginRecord` 明确不允许外部插件调用。本实现不调用它，而将独立划词对话的精确请求/响应保存在插件自己的私有日志。
- 原生辅助程序使用 Apple [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement) 与 [NSPanel](https://developer.apple.com/documentation/appkit/nspanel)。只在显式替换时写入原应用。

本实现没有复制或安装上述第三方项目，不修改 DSH 应用包，不依赖 CDP 或私有 React/DOM 结构。

## 2026-11-05 OpenCode 会话请求头

[OpenCode Go 官方说明](https://opencode.ai/v2/docs/console/go/#where-can-i-use-it)要求每段对话发送稳定的 `x-opencode-session`，并以客户端自身的 User-Agent 标识请求。

在 DSH Desktop 0.2.2-rc.1 中核对了 `@deepseek-ai/dsh-llm`、`@deepseek-ai/dsh-llm-pi-ai` 与 `@earendil-works/pi-ai`：`GenerateOptions.sessionId` 经内置 `opencode` / `opencode-go` 适配器转换为该请求头；自定义服务商或显式 `api` 覆盖会绕过内置包装器。本插件将划词对话 ID 传给 `sessionId`，并通过公开的 `llm-pi-ai/request-headers` 同步事件补齐后者的请求头。事件只处理本插件当前对话的 OpenCode 请求，按服务商 ID 或接口 URL 的主机名识别，保留已有同名头。User-Agent 由 DSH 统一提供，不伪装为其他客户端。

## 2026-10-30 编辑器兼容补充

Electron 官方文档说明，macOS 辅助技术可通过 `AXManualAccessibility` 请求应用公开辅助功能树：https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md 。本插件对当前前台应用采用此方式。VS Code 的编辑区还受屏幕阅读器优化模式影响；当前插件对 VS Code 使用下文的原生复制取词。

## 0.1.3 原生 VS Code 取词

使用原生选择手势后的临时复制，不安装 VS Code 扩展，不修改编辑器设置。通过 VS Code 写入的 `isFromEmptySelection`、`isBlock`、`multicursorText` 排除整行复制和多个选区；读取 Chromium 原生自定义数据格式，解析有界 Pickle 映射。

- [VS Code 剪贴板标记生成](https://github.com/microsoft/vscode/blob/main/src/vs/editor/browser/controller/editContext/clipboardUtils.ts)
- [Chromium macOS 剪贴板类型](https://github.com/chromium/chromium/blob/main/ui/base/clipboard/clipboard_constants_mac.mm)
- [Chromium 自定义数据序列化](https://github.com/chromium/chromium/blob/main/ui/base/clipboard/custom_data_helper.cc)

这些是本实现依据，不据此推断豆包的内部实现。

## 0.1.5 选区锚点与网页兼容

- Apple 的 [AXBoundsForRange](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute) 用于读取选定范围的屏幕矩形；本实现将 AX 的主屏左上原点转换为 AppKit 坐标，按选区选择显示器并避让文本。
- WebKit 的 [macOS accessibility wrapper](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm) 提供 text marker 相关接口。插件兼容 `AXBoundsForTextMarkerRange`，并在网页祖先提供选文时核对 marker 两端是否位于目标编辑控件内。
- 无可读 AX 选文时，普通文本控件的原生复制只由已完成的选择手势触发；这属于兼容回退，不能据此声称所有网页编辑器均支持。

## 0.1.6 鼠标事件坐标

Apple 文档说明 [全局事件监听的回调异步交付](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))，因此回调执行时的 `NSEvent.mouseLocation` 不等同于事件发生位置。手势锚点改读事件本身的 `CGEvent.location`，再转换为 AppKit 屏幕坐标；复制选文与 AX 选文不一致时，不采信该 AX 范围的矩形。定位不能通过整行/整控件矩形推断实际文字边缘。
