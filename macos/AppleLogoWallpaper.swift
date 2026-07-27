import AppKit
import CoreGraphics
import ServiceManagement
import WebKit

private let backgroundColor = NSColor(calibratedWhite: 248.0 / 255.0, alpha: 1)
private let settingsChangedNotification = Notification.Name("WallpaperSettingsChanged")
private let transitionPreviewRequestedNotification = Notification.Name("TransitionPreviewRequested")
private let dockVisibilityChangedNotification = Notification.Name("DockVisibilityChanged")
private let menuBarVisibilityChangedNotification = Notification.Name("MenuBarVisibilityChanged")
private let dockIconCyclingChangedNotification = Notification.Name("DockIconCyclingChanged")

private func clamp<T: Comparable>(_ value: T, _ minimum: T, _ maximum: T) -> T {
    min(max(value, minimum), maximum)
}

final class ApplicationPreferences {
    struct State: Equatable {
        var launchAtLogin: Bool
        var showInDock: Bool
        var showInMenuBar: Bool
        var cycleDockIcon: Bool

        static let defaults = State(
            launchAtLogin: false,
            showInDock: false,
            showInMenuBar: true,
            cycleDockIcon: false
        )
    }

    static let shared = ApplicationPreferences()

    private enum Key {
        static let showInDock = "showInDockAndAppSwitcher"
        static let showInMenuBar = "showInMenuBar"
        static let cycleDockIcon = "cycleDockIcon"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var state: State {
        State(
            launchAtLogin: launchAtLogin,
            showInDock: showInDock,
            showInMenuBar: showInMenuBar,
            cycleDockIcon: cycleDockIcon
        )
    }

    var showInDock: Bool { defaults.bool(forKey: Key.showInDock) }

    var showInMenuBar: Bool {
        defaults.object(forKey: Key.showInMenuBar) == nil
            ? true
            : defaults.bool(forKey: Key.showInMenuBar)
    }

    var cycleDockIcon: Bool { defaults.bool(forKey: Key.cycleDockIcon) }

    var launchAtLogin: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            guard !launchAtLogin else { return }
            try SMAppService.mainApp.register()
        } else {
            guard launchAtLogin else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    func setShowInDock(_ enabled: Bool) {
        guard showInDock != enabled else { return }
        defaults.set(enabled, forKey: Key.showInDock)
        NotificationCenter.default.post(name: dockVisibilityChangedNotification, object: self)
    }

    func setShowInMenuBar(_ enabled: Bool) {
        guard showInMenuBar != enabled else { return }
        defaults.set(enabled, forKey: Key.showInMenuBar)
        NotificationCenter.default.post(name: menuBarVisibilityChangedNotification, object: self)
    }

    func setCycleDockIcon(_ enabled: Bool) {
        guard cycleDockIcon != enabled else { return }
        defaults.set(enabled, forKey: Key.cycleDockIcon)
        NotificationCenter.default.post(name: dockIconCyclingChangedNotification, object: self)
    }

    func apply(_ newState: State) throws {
        var launchAtLoginError: Error?
        do {
            try setLaunchAtLogin(newState.launchAtLogin)
        } catch {
            launchAtLoginError = error
        }
        setShowInDock(newState.showInDock)
        setShowInMenuBar(newState.showInMenuBar)
        setCycleDockIcon(newState.cycleDockIcon)
        if let launchAtLoginError { throw launchAtLoginError }
    }
}

struct DisplayInfo: Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let frame: NSRect
    let menuBarInset: Double

    static func connected() -> [DisplayInfo] {
        let screens = NSScreen.screens
        let coordinateTop = screens.first(where: { $0.frame.contains(NSPoint.zero) })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let menuBars = windowInfo.compactMap { window -> NSRect? in
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowName as String] as? String == "Menubar",
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return NSRect(x: x, y: y, width: width, height: height)
        }

        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(displayID)
            let identifier: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
               let value = CFUUIDCreateString(nil, uuid) {
                identifier = value as String
            } else {
                identifier = String(displayID)
            }
            let expectedMenuBarOrigin = NSPoint(
                x: screen.frame.minX,
                y: coordinateTop - screen.frame.maxY
            )
            let menuBarInset = menuBars.first(where: {
                abs($0.minX - expectedMenuBarOrigin.x) < 1
                    && abs($0.minY - expectedMenuBarOrigin.y) < 1
                    && abs($0.width - screen.frame.width) < 1
            })?.height ?? 0
            return DisplayInfo(
                id: identifier,
                name: screen.localizedName,
                width: mode?.pixelWidth ?? Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                height: mode?.pixelHeight ?? Int((screen.frame.height * screen.backingScaleFactor).rounded()),
                frame: screen.frame,
                menuBarInset: menuBarInset
            )
        }
    }
}

struct DisplayConfiguration: Codable, Equatable {
    var name: String
    var width: Int
    var height: Int
    var rows: Int
    var columns: Int
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case name, width, height, rows, columns, enabled
    }

    init(name: String, width: Int, height: Int, rows: Int, columns: Int, enabled: Bool = true) {
        self.name = name
        self.width = width
        self.height = height
        self.rows = rows
        self.columns = columns
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        rows = try container.decode(Int.self, forKey: .rows)
        columns = try container.decode(Int.self, forKey: .columns)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

enum ParameterValue: Codable, Equatable {
    case number(Double)
    case boolean(Bool)
    case vector([Double])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .vector(try container.decode([Double].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .vector(let value): try container.encode(value)
        }
    }
}

struct TransitionMetadata: Codable {
    let name: String
    let paramsTypes: [String: String]
    let defaultParams: [String: ParameterValue]
}

struct WallpaperSettings: Codable, Equatable {
    var rows: Int
    var columns: Int
    var transitionGapSeconds: Double
    var fadeDurationSeconds: Double
    var topInsetPixels: Double
    var transitionStyle: String
    var randomTransitionNames: [String]
    var transitionParameters: [String: [String: ParameterValue]]
    var displayConfigurations: [String: DisplayConfiguration]

    enum CodingKeys: String, CodingKey {
        case rows, columns, transitionGapSeconds, persistenceSeconds, fadeDurationSeconds, topInsetPixels
        case transitionStyle, randomTransitionNames, transitionParameters, displayConfigurations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 4
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 8
        fadeDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeDurationSeconds) ?? 0.42
        if let gap = try container.decodeIfPresent(Double.self, forKey: .transitionGapSeconds) {
            transitionGapSeconds = gap
        } else if let refreshCycle = try container.decodeIfPresent(Double.self, forKey: .persistenceSeconds) {
            transitionGapSeconds = (refreshCycle / Double(max(rows * columns, 1))) - fadeDurationSeconds
        } else {
            transitionGapSeconds = 0.5
        }
        topInsetPixels = try container.decodeIfPresent(Double.self, forKey: .topInsetPixels) ?? 28
        transitionStyle = try container.decodeIfPresent(String.self, forKey: .transitionStyle) ?? "fade"
        randomTransitionNames = try container.decodeIfPresent([String].self, forKey: .randomTransitionNames) ?? []
        transitionParameters = try container.decodeIfPresent(
            [String: [String: ParameterValue]].self,
            forKey: .transitionParameters
        ) ?? [:]
        displayConfigurations = try container.decodeIfPresent(
            [String: DisplayConfiguration].self,
            forKey: .displayConfigurations
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(columns, forKey: .columns)
        try container.encode(transitionGapSeconds, forKey: .transitionGapSeconds)
        try container.encode(fadeDurationSeconds, forKey: .fadeDurationSeconds)
        try container.encode(topInsetPixels, forKey: .topInsetPixels)
        try container.encode(transitionStyle, forKey: .transitionStyle)
        try container.encode(randomTransitionNames, forKey: .randomTransitionNames)
        try container.encode(transitionParameters, forKey: .transitionParameters)
        try container.encode(displayConfigurations, forKey: .displayConfigurations)
    }

    init(
        rows: Int = 4,
        columns: Int = 8,
        transitionGapSeconds: Double = 0.5,
        fadeDurationSeconds: Double = 0.42,
        topInsetPixels: Double = 28,
        transitionStyle: String = "fade",
        randomTransitionNames: [String] = [],
        transitionParameters: [String: [String: ParameterValue]] = [:],
        displayConfigurations: [String: DisplayConfiguration] = [:]
    ) {
        self.rows = rows
        self.columns = columns
        self.transitionGapSeconds = transitionGapSeconds
        self.fadeDurationSeconds = fadeDurationSeconds
        self.topInsetPixels = topInsetPixels
        self.transitionStyle = transitionStyle
        self.randomTransitionNames = randomTransitionNames
        self.transitionParameters = transitionParameters
        self.displayConfigurations = displayConfigurations
    }
}

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaultsKey = "wallpaperSettingsV2"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    let transitionMetadata: [TransitionMetadata]
    let transitionNames: [String]
    private(set) var settings: WallpaperSettings

    private init() {
        transitionMetadata = Self.loadTransitionMetadata()
        transitionNames = transitionMetadata.map(\.name)
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? decoder.decode(WallpaperSettings.self, from: data) {
            settings = decoded
        } else if let url = Bundle.main.url(forResource: "DefaultSettings", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(WallpaperSettings.self, from: data) {
            settings = decoded
        } else {
            settings = WallpaperSettings()
        }
        normalize()
    }

    private static func loadTransitionMetadata() -> [TransitionMetadata] {
        guard let url = Bundle.main.url(forResource: "transition-metadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode([TransitionMetadata].self, from: data) else {
            return [TransitionMetadata(name: "fade", paramsTypes: [:], defaultParams: [:])]
        }
        return metadata.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reconcile(displays: [DisplayInfo]) {
        for display in displays {
            var configuration = settings.displayConfigurations[display.id] ?? DisplayConfiguration(
                name: display.name,
                width: display.width,
                height: display.height,
                rows: settings.rows,
                columns: settings.columns
            )
            configuration.name = display.name
            configuration.width = display.width
            configuration.height = display.height
            settings.displayConfigurations[display.id] = configuration
        }
        save(notify: false)
    }

    func update(_ newSettings: WallpaperSettings) {
        settings = newSettings
        normalize()
        save(notify: true)
    }

    func reset(displays: [DisplayInfo]) {
        settings = WallpaperSettings(randomTransitionNames: transitionNames)
        reconcile(displays: displays)
        save(notify: true)
    }

    private func normalize() {
        settings.rows = clamp(settings.rows, 1, 20)
        settings.columns = clamp(settings.columns, 1, 32)
        settings.transitionGapSeconds = clamp(settings.transitionGapSeconds, -86_400, 86_400)
        settings.fadeDurationSeconds = max(settings.fadeDurationSeconds, 0)
        settings.topInsetPixels = clamp(settings.topInsetPixels, 0, 200)
        if settings.transitionStyle != "random" && !transitionNames.contains(settings.transitionStyle) {
            settings.transitionStyle = transitionNames.contains("fade") ? "fade" : transitionNames.first ?? "fade"
        }
        let validRandomNames = transitionNames.filter(Set(settings.randomTransitionNames).contains)
        settings.randomTransitionNames = validRandomNames.isEmpty ? transitionNames : validRandomNames
        let metadataByName = Dictionary(uniqueKeysWithValues: transitionMetadata.map { ($0.name, $0) })
        settings.transitionParameters = settings.transitionParameters.reduce(into: [:]) { result, entry in
            guard let metadata = metadataByName[entry.key] else { return }
            let validParameters = entry.value.filter { metadata.defaultParams[$0.key] != nil }
            if !validParameters.isEmpty { result[entry.key] = validParameters }
        }
        for (id, var configuration) in settings.displayConfigurations {
            configuration.rows = clamp(configuration.rows, 1, 20)
            configuration.columns = clamp(configuration.columns, 1, 32)
            settings.displayConfigurations[id] = configuration
        }
    }

    private func save(notify: Bool) {
        if let data = try? encoder.encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if notify {
            NotificationCenter.default.post(name: settingsChangedNotification, object: self)
        }
    }
}

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BundleWebSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let decodedPath = requestURL.path.removingPercentEncoding else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let relativePath = String(decodedPath.drop(while: { $0 == "/" }))
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        let allowedPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(allowedPrefix),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeTypes = [
            "html": "text/html", "css": "text/css", "js": "text/javascript",
            "json": "application/json", "png": "image/png", "jpg": "image/jpeg",
            "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"
        ]
        let mimeType = mimeTypes[fileURL.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = URLResponse(
            url: requestURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class DockIconFrameHandler: NSObject, WKScriptMessageHandler {
    private let receiveFrame: (Data) -> Void

    init(receiveFrame: @escaping (Data) -> Void) {
        self.receiveFrame = receiveFrame
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dataURL = message.body as? String,
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return }
        receiveFrame(data)
    }
}

final class WallpaperRendererBridge {
    private struct Bootstrap: Encodable {
        let displayID: String
        let topInsetPixels: Double
        let settings: WallpaperSettings
        let dockIconSource: Bool
        let dockIconCycling: Bool
    }

    private weak var webView: WKWebView?
    private static let encoder = JSONEncoder()

    init(webView: WKWebView) {
        self.webView = webView
    }

    static func bootstrapScript(
        display: DisplayInfo,
        settings: WallpaperSettings,
        dockIconSource: Bool,
        dockIconCycling: Bool
    ) -> String {
        let bootstrap = Bootstrap(
            displayID: display.id,
            topInsetPixels: display.menuBarInset,
            settings: settings,
            dockIconSource: dockIconSource,
            dockIconCycling: dockIconCycling
        )
        guard let data = try? encoder.encode(bootstrap),
              let json = String(data: data, encoding: .utf8) else {
            return "window.NATIVE_WALLPAPER_BOOTSTRAP={};"
        }
        return "window.NATIVE_WALLPAPER_BOOTSTRAP=\(json);"
    }

    func apply(settings: WallpaperSettings) {
        evaluate(function: "applyNativeWallpaperSettings", argument: settings)
    }

    func setDockIconPublishing(_ enabled: Bool) {
        evaluate(function: "setDockIconPublishing", argument: enabled)
    }

    func previewSelectedTransition() {
        webView?.evaluateJavaScript("window.previewNativeTransition?.()")
    }

    private func evaluate<Value: Encodable>(function: String, argument: Value) {
        guard let data = try? Self.encoder.encode(argument),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.\(function)?.(\(json))")
    }
}

final class WallpaperSurface: NSObject, WKNavigationDelegate {
    let display: DisplayInfo
    let window: WallpaperWindow
    let webView: WKWebView
    private let webRoot: URL
    private let schemeHandler: BundleWebSchemeHandler
    private let dockIconFrameHandler: DockIconFrameHandler?
    private let rendererBridge: WallpaperRendererBridge
    private var retryWorkItem: DispatchWorkItem?

    init?(
        display: DisplayInfo,
        settings: WallpaperSettings,
        dockIconCyclingEnabled: Bool,
        dockIconFrameReceiver: ((Data) -> Void)? = nil
    ) {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) else {
            return nil
        }
        self.display = display
        webRoot = root
        schemeHandler = BundleWebSchemeHandler(root: root)
        dockIconFrameHandler = dockIconFrameReceiver.map(DockIconFrameHandler.init(receiveFrame:))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "wallpaper")
        if let dockIconFrameHandler {
            configuration.userContentController.add(dockIconFrameHandler, name: "dockIconFrame")
        }
        let source = WallpaperRendererBridge.bootstrapScript(
            display: display,
            settings: settings,
            dockIconSource: dockIconFrameHandler != nil,
            dockIconCycling: dockIconCyclingEnabled
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        rendererBridge = WallpaperRendererBridge(webView: webView)
        window = WallpaperWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = backgroundColor
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.backgroundColor = backgroundColor
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        placeWindow()
        load()
    }

    deinit {
        retryWorkItem?.cancel()
    }

    func invalidate() {
        retryWorkItem?.cancel()
        webView.stopLoading()
        window.orderOut(nil)
    }

    func placeWindow() {
        window.setFrame(display.frame, display: true)
        window.orderFrontRegardless()
    }

    func load() {
        retryWorkItem?.cancel()
        guard let indexURL = URL(string: "wallpaper://local/index.html") else { return }
        webView.load(URLRequest(url: indexURL))
    }

    func apply(settings: WallpaperSettings) {
        rendererBridge.apply(settings: settings)
    }

    func setDockIconPublishing(_ enabled: Bool) {
        rendererBridge.setDockIconPublishing(enabled)
    }

    func previewSelectedTransition() {
        rendererBridge.previewSelectedTransition()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryWorkItem?.cancel()
        placeWindow()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        scheduleRetry()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.load() }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

}

final class SettingsPanelWindow: NSWindow {
    var keyViewOrderProvider: (() -> [NSView])?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let contentView,
           let hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)),
           !isInteractiveControl(hitView) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    private func isInteractiveControl(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate, current !== contentView {
            if let field = current as? NSTextField, field.isEditable || field is NSSearchField {
                return true
            }
            if current is NSButton || current is NSSlider || current is NSTableView || current is NSScroller {
                return true
            }
            candidate = current.superview
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 48,
           !event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false,
           let keyViewOrderProvider {
            let order = keyViewOrderProvider().filter { $0.window === self && !$0.isHidden }
            guard !order.isEmpty else { return super.performKeyEquivalent(with: event) }
            let focusedView: NSView?
            if let fieldEditor = firstResponder as? NSTextView {
                focusedView = fieldEditor.delegate as? NSView
            } else {
                focusedView = firstResponder as? NSView
            }
            let currentIndex = focusedView.flatMap { focused in
                order.firstIndex(where: { $0 === focused })
            }
            let movesBackward = event.modifierFlags.contains(.shift)
            let nextIndex: Int
            if let currentIndex {
                nextIndex = movesBackward
                    ? (currentIndex - 1 + order.count) % order.count
                    : (currentIndex + 1) % order.count
            } else {
                nextIndex = movesBackward ? order.count - 1 : 0
            }
            let target = order[nextIndex]
            target.scrollToVisible(target.bounds)
            makeFirstResponder(target)
            return true
        }
        if event.keyCode == 53 {
            makeFirstResponder(nil)
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if modifiers.contains(.shift) {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class NumericTextField: NSTextField {
    var stepValue = 1.0

    func applyStep(direction: Double, modifiers: NSEvent.ModifierFlags) {
        var step = stepValue
        if modifiers.contains(.shift) { step *= 10 }
        if modifiers.contains(.option) { step /= 10 }
        doubleValue += direction * step
        stringValue = String(format: "%.8g", doubleValue)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 125 || event.keyCode == 126 else {
            super.keyDown(with: event)
            return
        }
        applyStep(direction: event.keyCode == 126 ? 1 : -1, modifiers: event.modifierFlags)
        sendAction(action, to: target)
    }
}

final class KeyboardNavigableSwitch: NSSwitch {
    override var acceptsFirstResponder: Bool { true }
}

final class KeyboardNavigableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let store: SettingsStore
    private let preferences: ApplicationPreferences
    private var displays: [DisplayInfo]
    private var displayFields: [String: (rows: NSTextField, columns: NSTextField)] = [:]
    private var displayEnabledSwitches: [String: NSSwitch] = [:]
    private var displayGridRows: [String: NSView] = [:]
    private var transitionGapField = NSTextField()
    private var fadeField = NSTextField()
    private var showInDockSwitch = NSSwitch()
    private var showInMenuBarSwitch = NSSwitch()
    private var cycleDockIconSwitch = NSSwitch()
    private var launchAtLoginSwitch = NSSwitch()
    private weak var cycleDockIconRow: NSGridRow?
    private var applicationPanelHeightConstraint: NSLayoutConstraint?
    private var resetAllButton = NSButton()
    private var quitApplicationButton = NSButton()
    private let transitionTable = NSTableView()
    private var randomizeSwitch = NSSwitch()
    private var transitionSearchField = NSSearchField()
    private var randomColumn: NSTableColumn?
    private var transitionInspector = NSView()
    private var selectedTransitionName: String?
    private let settingsUndoManager = UndoManager()
    private var draftSettings: WallpaperSettings
    private var saveWorkItem: DispatchWorkItem?
    private var isLoading = false
    private var selectedSettingsTab = 0
    private var numericFieldsByIdentifier: [String: NumericTextField] = [:]
    private var numericSteppersByIdentifier: [String: NSStepper] = [:]

    init(
        store: SettingsStore,
        preferences: ApplicationPreferences = .shared,
        displays: [DisplayInfo]
    ) {
        self.store = store
        self.preferences = preferences
        self.displays = displays
        draftSettings = store.settings
        let window = SettingsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Apple Logo Wallpaper Settings"
        window.minSize = NSSize(width: 760, height: 520)
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.center()
        super.init(window: window)
        window.keyViewOrderProvider = { [weak self] in
            self?.currentKeyViewOrder() ?? []
        }
        window.delegate = self
        settingsUndoManager.levelsOfUndo = 100
        buildInterface()
        loadSettings()
    }

    required init?(coder: NSCoder) { nil }

    func refresh(displays: [DisplayInfo]) {
        self.displays = displays
        store.reconcile(displays: displays)
        buildInterface()
        loadSettings()
    }

    private func buildInterface() {
        if let tabs = window?.contentViewController as? NSTabViewController {
            selectedSettingsTab = max(0, tabs.selectedTabViewItemIndex)
        }
        displayFields.removeAll()
        displayEnabledSwitches.removeAll()
        displayGridRows.removeAll()

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tabItem(
            label: "General",
            symbol: "gearshape",
            viewController: buildGeneralPane()
        ))
        tabs.addTabViewItem(tabItem(
            label: "Transitions",
            symbol: "rectangle.3.group",
            viewController: buildTransitionsPane()
        ))
        tabs.selectedTabViewItemIndex = min(selectedSettingsTab, tabs.tabViewItems.count - 1)
        window?.contentViewController = tabs
        window?.recalculateKeyViewLoop()
        configureGeneralKeyViewLoop()
        configureTransitionKeyViewLoop()
    }

    private func tabItem(label: String, symbol: String, viewController: NSViewController) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: viewController)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private func scrollablePane(containing stack: NSStackView) -> NSViewController {
        let viewController = NSViewController()
        let root = NSView()
        viewController.view = root

        let outerScroll = NSScrollView()
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.hasVerticalScroller = true
        outerScroll.drawsBackground = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        outerScroll.documentView = document
        root.addSubview(outerScroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        document.addSubview(stack)

        NSLayoutConstraint.activate([
            outerScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outerScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outerScroll.topAnchor.constraint(equalTo: root.topAnchor),
            outerScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: outerScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: outerScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: outerScroll.contentView.topAnchor),
            document.bottomAnchor.constraint(equalTo: outerScroll.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: outerScroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        return viewController
    }

    private func buildGeneralPane() -> NSViewController {
        let stack = NSStackView()
        stack.spacing = 16

        let displaysHeading = sectionLabel("Displays")
        stack.addArrangedSubview(displaysHeading)
        stack.setCustomSpacing(8, after: displaysHeading)
        let displayStack = NSStackView()
        displayStack.orientation = .horizontal
        displayStack.alignment = .top
        displayStack.distribution = .fillEqually
        displayStack.spacing = 14
        for display in displays {
            let monitor = NSStackView()
            monitor.orientation = .vertical
            monitor.alignment = .leading
            monitor.spacing = 10
            let name = NSTextField(labelWithString: display.name)
            name.font = .systemFont(ofSize: 15, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            let enabledSwitch = KeyboardNavigableSwitch()
            enabledSwitch.controlSize = .small
            enabledSwitch.refusesFirstResponder = false
            enabledSwitch.identifier = NSUserInterfaceItemIdentifier("display.\(display.id).enabled")
            enabledSwitch.target = self
            enabledSwitch.action = #selector(displayEnabledChanged(_:))
            enabledSwitch.setAccessibilityLabel("Enable wallpaper on \(display.name)")
            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .centerY
            header.addArrangedSubview(name)
            let headerSpacer = NSView()
            headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            header.addArrangedSubview(headerSpacer)
            header.addArrangedSubview(enabledSwitch)
            let resolution = NSTextField(labelWithString: "\(display.width)×\(display.height)")
            resolution.textColor = .secondaryLabelColor
            monitor.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: monitor.widthAnchor).isActive = true
            monitor.addArrangedSubview(resolution)

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let rows = numericField(identifier: "display.\(display.id).rows", width: 58)
            let columns = numericField(identifier: "display.\(display.id).columns", width: 58)
            let gridLabel = NSTextField(labelWithString: "Grid")
            gridLabel.textColor = .secondaryLabelColor
            row.addArrangedSubview(gridLabel)
            row.addArrangedSubview(spinControl(for: rows, minimum: 1, maximum: 20))
            let multiplication = NSTextField(labelWithString: "×")
            multiplication.textColor = .secondaryLabelColor
            row.addArrangedSubview(multiplication)
            row.addArrangedSubview(spinControl(for: columns, minimum: 1, maximum: 32))
            monitor.addArrangedSubview(row)
            let card = boxedView(containing: monitor)
            displayStack.addArrangedSubview(card)
            displayFields[display.id] = (rows, columns)
            displayEnabledSwitches[display.id] = enabledSwitch
            displayGridRows[display.id] = row
        }
        stack.addArrangedSubview(displayStack)

        let applicationHeading = sectionLabel("Application")
        stack.addArrangedSubview(applicationHeading)
        stack.setCustomSpacing(8, after: applicationHeading)
        let launchAtLoginLabel = NSTextField(labelWithString: "Launch at Login")
        launchAtLoginSwitch = KeyboardNavigableSwitch()
        launchAtLoginSwitch.controlSize = .small
        launchAtLoginSwitch.refusesFirstResponder = false
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged(_:))
        launchAtLoginSwitch.setAccessibilityLabel("Launch at Login")

        let showInDockLabel = NSTextField(labelWithString: "Show in Dock")
        showInDockSwitch = KeyboardNavigableSwitch()
        showInDockSwitch.controlSize = .small
        showInDockSwitch.refusesFirstResponder = false
        showInDockSwitch.target = self
        showInDockSwitch.action = #selector(showInDockChanged(_:))
        showInDockSwitch.setAccessibilityLabel("Show in Dock")

        let showInMenuBarLabel = NSTextField(labelWithString: "Show in Menu Bar")
        showInMenuBarSwitch = KeyboardNavigableSwitch()
        showInMenuBarSwitch.controlSize = .small
        showInMenuBarSwitch.refusesFirstResponder = false
        showInMenuBarSwitch.target = self
        showInMenuBarSwitch.action = #selector(showInMenuBarChanged(_:))
        showInMenuBarSwitch.setAccessibilityLabel("Show in Menu Bar")

        let cycleDockIconLabel = NSTextField(labelWithString: "Cycle icon in Dock")
        cycleDockIconSwitch = KeyboardNavigableSwitch()
        cycleDockIconSwitch.controlSize = .small
        cycleDockIconSwitch.refusesFirstResponder = false
        cycleDockIconSwitch.target = self
        cycleDockIconSwitch.action = #selector(cycleDockIconChanged(_:))
        cycleDockIconSwitch.setAccessibilityLabel("Cycle icon in Dock")

        let applicationGrid = NSGridView(views: [
            [launchAtLoginLabel, launchAtLoginSwitch, NSView()],
            [showInDockLabel, showInDockSwitch, NSView()],
            [cycleDockIconLabel, cycleDockIconSwitch, NSView()],
            [showInMenuBarLabel, showInMenuBarSwitch, NSView()]
        ])
        cycleDockIconRow = applicationGrid.row(at: 2)
        applicationGrid.rowSpacing = 10
        applicationGrid.columnSpacing = 10
        applicationGrid.column(at: 0).xPlacement = .leading
        applicationGrid.column(at: 1).xPlacement = .leading
        applicationGrid.column(at: 2).xPlacement = .fill
        for rowIndex in 0..<applicationGrid.numberOfRows {
            applicationGrid.row(at: rowIndex).yPlacement = .center
            if let spacer = applicationGrid.cell(atColumnIndex: 2, rowIndex: rowIndex).contentView {
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }
        }

        let applicationPanel = boxedView(containing: applicationGrid)
        applicationPanel.setContentHuggingPriority(.required, for: .vertical)
        applicationPanelHeightConstraint = applicationPanel.heightAnchor.constraint(equalToConstant: 134)
        applicationPanelHeightConstraint?.isActive = true
        stack.addArrangedSubview(applicationPanel)

        resetAllButton = KeyboardNavigableButton(
            title: "Reset All Settings…",
            target: self,
            action: #selector(resetDefaults)
        )
        resetAllButton.refusesFirstResponder = false
        quitApplicationButton = KeyboardNavigableButton(
            title: "Quit Application…",
            target: self,
            action: #selector(confirmQuitApplication)
        )
        quitApplicationButton.refusesFirstResponder = false
        let applicationActions = NSStackView()
        applicationActions.orientation = .horizontal
        applicationActions.alignment = .centerY
        applicationActions.addArrangedSubview(resetAllButton)
        let applicationActionSpacer = NSView()
        applicationActionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        applicationActions.addArrangedSubview(applicationActionSpacer)
        applicationActions.addArrangedSubview(quitApplicationButton)
        stack.setCustomSpacing(8, after: applicationPanel)
        stack.addArrangedSubview(applicationActions)

        [displayStack, applicationPanel, applicationActions].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scrollablePane(containing: stack)
    }

    private func configureGeneralKeyViewLoop() {
        let controls = generalKeyViewOrder()
        guard controls.count > 1 else { return }
        for index in controls.indices {
            controls[index].nextKeyView = controls[(index + 1) % controls.count]
        }
    }

    private func generalKeyViewOrder() -> [NSView] {
        var controls: [NSView] = []
        for display in displays {
            guard let fields = displayFields[display.id] else { continue }
            if let enabledSwitch = displayEnabledSwitches[display.id] {
                controls.append(enabledSwitch)
            }
            if displayGridRows[display.id]?.isHidden != true {
                controls.append(fields.rows)
                controls.append(fields.columns)
            }
        }
        controls.append(launchAtLoginSwitch)
        controls.append(showInDockSwitch)
        if cycleDockIconRow?.isHidden != true {
            controls.append(cycleDockIconSwitch)
        }
        controls.append(showInMenuBarSwitch)
        controls.append(resetAllButton)
        controls.append(quitApplicationButton)

        return controls
    }

    private func buildTransitionsPane() -> NSViewController {
        let stack = NSStackView()
        stack.spacing = 8

        let timingGrid = NSGridView()
        timingGrid.rowSpacing = 8
        timingGrid.columnSpacing = 10
        timingGrid.rowAlignment = .firstBaseline
        transitionGapField = numericField(identifier: "shared.transitionGap", width: 90, step: 0.1)
        fadeField = numericField(identifier: "shared.fade", width: 90, step: 0.1)
        let gapUnit = NSTextField(labelWithString: "seconds")
        gapUnit.textColor = .secondaryLabelColor
        let durationUnit = NSTextField(labelWithString: "seconds")
        durationUnit.textColor = .secondaryLabelColor
        let gapInfo = NSButton()
        gapInfo.isBordered = false
        gapInfo.imagePosition = .imageOnly
        gapInfo.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: "Transition gap information"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        gapInfo.contentTintColor = .secondaryLabelColor
        gapInfo.toolTip = "Negative values overlap transitions; positive values wait after each transition finishes. Zero starts the next transition immediately."
        gapInfo.setAccessibilityLabel("Transition gap information")
        gapInfo.refusesFirstResponder = true
        gapInfo.widthAnchor.constraint(equalToConstant: 18).isActive = true
        gapInfo.heightAnchor.constraint(equalToConstant: 18).isActive = true
        timingGrid.addRow(with: [
            NSTextField(labelWithString: "Gap"),
            spinControl(for: transitionGapField, minimum: -1e12, maximum: 1e12),
            gapUnit,
            gapInfo
        ])
        timingGrid.addRow(with: [
            NSTextField(labelWithString: "Duration"),
            spinControl(for: fadeField, minimum: 0, maximum: 1e12),
            durationUnit,
            NSView()
        ])
        timingGrid.column(at: 0).xPlacement = .trailing
        timingGrid.column(at: 1).xPlacement = .fill
        timingGrid.column(at: 2).xPlacement = .leading
        timingGrid.column(at: 3).xPlacement = .leading
        timingGrid.cell(for: gapInfo)?.rowAlignment = .none
        timingGrid.cell(for: gapInfo)?.yPlacement = .center
        let timingPanel = boxedView(containing: timingGrid)
        timingPanel.setContentHuggingPriority(.required, for: .vertical)
        timingPanel.heightAnchor.constraint(equalToConstant: 84).isActive = true
        stack.addArrangedSubview(timingPanel)
        stack.setCustomSpacing(14, after: timingPanel)

        randomizeSwitch = KeyboardNavigableSwitch()
        randomizeSwitch.controlSize = .small
        randomizeSwitch.target = self
        randomizeSwitch.action = #selector(randomizeChanged(_:))
        randomizeSwitch.setAccessibilityLabel("Randomize transitions")

        transitionSearchField = NSSearchField()
        transitionSearchField.placeholderString = "Filter \(store.transitionNames.count) transitions"
        transitionSearchField.sendsSearchStringImmediately = true
        transitionSearchField.target = self
        transitionSearchField.action = #selector(filterTransitions(_:))
        transitionSearchField.setAccessibilityLabel("Filter transitions")

        let transitionScroll = NSScrollView()
        transitionScroll.hasVerticalScroller = true
        transitionScroll.borderType = .bezelBorder
        transitionScroll.translatesAutoresizingMaskIntoConstraints = false
        transitionTable.tableColumns.forEach { transitionTable.removeTableColumn($0) }
        let tableHeader = NSTableHeaderView()
        transitionTable.headerView = tableHeader
        transitionTable.usesAlternatingRowBackgroundColors = true
        transitionTable.allowsEmptySelection = false
        transitionTable.allowsMultipleSelection = false
        transitionTable.selectionHighlightStyle = .regular
        transitionTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        transitionTable.dataSource = self
        transitionTable.delegate = self
        let transitionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transition"))
        transitionColumn.title = "Transition"
        transitionColumn.width = 220
        transitionColumn.minWidth = 180
        let randomColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("random"))
        randomColumn.title = "Include in Randomization"
        let randomHeaderWidth = ceil((randomColumn.title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ]).width) + 28
        randomColumn.width = randomHeaderWidth
        randomColumn.minWidth = randomHeaderWidth
        randomColumn.maxWidth = randomHeaderWidth
        randomColumn.resizingMask = []
        self.randomColumn = randomColumn
        transitionTable.addTableColumn(transitionColumn)
        transitionTable.addTableColumn(randomColumn)
        transitionScroll.documentView = transitionTable

        let transitionSearchRow = NSStackView()
        transitionSearchRow.orientation = .horizontal
        transitionSearchRow.alignment = .centerY
        transitionSearchRow.addArrangedSubview(transitionSearchField)
        let transitionSearchSpacer = NSView()
        transitionSearchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transitionSearchRow.addArrangedSubview(transitionSearchSpacer)
        let randomizeControl = NSStackView()
        randomizeControl.orientation = .horizontal
        randomizeControl.alignment = .centerY
        randomizeControl.spacing = 6
        let randomizeLabel = NSTextField(labelWithString: "Randomize")
        randomizeLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        randomizeControl.addArrangedSubview(randomizeLabel)
        randomizeControl.addArrangedSubview(randomizeSwitch)
        transitionSearchRow.addArrangedSubview(randomizeControl)
        stack.addArrangedSubview(transitionSearchRow)

        transitionInspector = NSView()
        transitionInspector.wantsLayer = true
        transitionInspector.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        transitionInspector.layer?.cornerRadius = 10
        transitionInspector.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        transitionInspector.layer?.borderWidth = 1
        transitionInspector.layer?.borderColor = NSColor.separatorColor.cgColor

        let transitionSplit = NSSplitView()
        transitionSplit.translatesAutoresizingMaskIntoConstraints = false
        transitionSplit.isVertical = true
        transitionSplit.dividerStyle = .thin
        transitionSplit.addArrangedSubview(transitionScroll)
        transitionSplit.addArrangedSubview(transitionInspector)
        transitionSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        transitionScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        transitionInspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        transitionSplit.heightAnchor.constraint(equalToConstant: 320).isActive = true
        stack.addArrangedSubview(transitionSplit)
        transitionSearchField.widthAnchor.constraint(equalTo: transitionScroll.widthAnchor).isActive = true

        [timingPanel, transitionSearchRow, transitionSplit].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scrollablePane(containing: stack)
    }

    private func configureTransitionKeyViewLoop() {
        let controls = transitionKeyViewOrder()
        for index in controls.indices {
            controls[index].nextKeyView = controls[(index + 1) % controls.count]
        }
    }

    private func transitionKeyViewOrder() -> [NSView] {
        [
            transitionGapField,
            fadeField,
            randomizeSwitch,
            transitionSearchField,
            transitionTable
        ]
    }

    private func currentKeyViewOrder() -> [NSView] {
        guard let tabs = window?.contentViewController as? NSTabViewController else { return [] }
        return tabs.selectedTabViewItemIndex == 0 ? generalKeyViewOrder() : transitionKeyViewOrder()
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }

    private func boxedView(containing content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        box.contentViewMargins = NSSize(width: 16, height: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let container = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        return box
    }

    private func sectionView(title: String, content: NSView) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        section.addArrangedSubview(label)

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        panel.layer?.cornerRadius = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        section.addArrangedSubview(panel)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalTo: section.widthAnchor),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14)
        ])
        return section
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        settingsUndoManager
    }

    private func numericField(identifier: String, width: CGFloat, step: Double = 1) -> NSTextField {
        let field = NumericTextField()
        field.stepValue = step
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        numericFieldsByIdentifier[identifier] = field
        return field
    }

    private func spinControl(
        for field: NSTextField,
        minimum: Double,
        maximum: Double
    ) -> NSView {
        guard let numericField = field as? NumericTextField,
              let identifier = field.identifier?.rawValue else { return field }
        let stepper = NSStepper()
        stepper.controlSize = .small
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = numericField.stepValue
        stepper.doubleValue = min(max(field.doubleValue, minimum), maximum)
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.identifier = field.identifier
        stepper.target = self
        stepper.action = #selector(numericStepperChanged(_:))
        stepper.setAccessibilityLabel(field.identifier?.rawValue ?? "Numeric value")
        numericFieldsByIdentifier[identifier] = numericField
        numericSteppersByIdentifier[identifier] = stepper

        let control = NSStackView(views: [field, stepper])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 2
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    private func syncNumericStepper(for field: NSTextField) {
        guard let identifier = field.identifier?.rawValue,
              let stepper = numericSteppersByIdentifier[identifier] else { return }
        stepper.doubleValue = min(max(field.doubleValue, stepper.minValue), stepper.maxValue)
    }

    private func syncAllNumericSteppers() {
        numericFieldsByIdentifier.values.forEach(syncNumericStepper)
    }

    @objc private func numericStepperChanged(_ sender: NSStepper) {
        guard let identifier = sender.identifier?.rawValue,
              let field = numericFieldsByIdentifier[identifier] else { return }
        field.doubleValue = sender.doubleValue
        field.stringValue = String(format: "%.8g", sender.doubleValue)
        fieldCommitted(field)
    }

    private func loadSettings() {
        isLoading = true
        let settings = store.settings
        draftSettings = settings
        for display in displays {
            let configuration = settings.displayConfigurations[display.id]
            displayFields[display.id]?.rows.integerValue = configuration?.rows ?? settings.rows
            displayFields[display.id]?.columns.integerValue = configuration?.columns ?? settings.columns
            let enabled = configuration?.enabled ?? true
            displayEnabledSwitches[display.id]?.state = enabled ? .on : .off
            displayGridRows[display.id]?.isHidden = !enabled
        }
        transitionGapField.doubleValue = settings.transitionGapSeconds
        fadeField.doubleValue = settings.fadeDurationSeconds
        syncAllNumericSteppers()
        let applicationState = preferences.state
        launchAtLoginSwitch.state = applicationState.launchAtLogin ? .on : .off
        showInDockSwitch.state = applicationState.showInDock ? .on : .off
        showInMenuBarSwitch.state = applicationState.showInMenuBar ? .on : .off
        cycleDockIconSwitch.state = applicationState.cycleDockIcon ? .on : .off
        updateDockCycleRowVisibility()
        randomizeSwitch.state = settings.transitionStyle == "random" ? .on : .off
        updateRandomColumnVisibility()
        if selectedTransitionName == nil || !store.transitionNames.contains(selectedTransitionName!) {
            selectedTransitionName = settings.transitionStyle == "random"
                ? settings.randomTransitionNames.first ?? store.transitionNames.first
                : settings.transitionStyle
        }
        transitionTable.reloadData()
        if let row = selectedTransitionName.flatMap(rowForTransition) {
            transitionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            transitionTable.scrollRowToVisible(row)
        }
        rebuildTransitionInspector()
        isLoading = false
        configureGeneralKeyViewLoop()
    }

    @objc private func displayEnabledChanged(_ sender: NSSwitch) {
        guard let identifier = sender.identifier?.rawValue,
              let displayID = displays.first(where: {
                  identifier == "display.\($0.id).enabled"
              })?.id else { return }
        displayGridRows[displayID]?.isHidden = sender.state == .off
        configureGeneralKeyViewLoop()
        save(collectSettings(), immediately: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleTransitionNames.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier,
              let name = transitionName(forRow: row) else { return nil }
        if identifier.rawValue == "transition" {
            let label = NSTextField(labelWithString: name)
            label.lineBreakMode = .byTruncatingTail
            return topAlignedCell(label)
        }
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(randomInclusionClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("random|\(name)")
        button.state = draftSettings.randomTransitionNames.contains(name) ? .on : .off
        button.toolTip = "Include \(name) when randomizing"
        button.setAccessibilityLabel("Include \(name) when randomizing")
        return topAlignedCell(button, centered: true)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        30
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isLoading, transitionTable.selectedRow >= 0 else { return }
        selectTransition(row: transitionTable.selectedRow)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if !isLoading, row == tableView.selectedRow {
            selectTransition(row: row)
        }
        return true
    }

    @objc private func randomInclusionClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue.split(separator: "|", maxSplits: 1).last.map(String.init),
              store.transitionNames.contains(name) else { return }
        var settings = collectSettings()
        if sender.state == .on {
            if !settings.randomTransitionNames.contains(name) {
                settings.randomTransitionNames.append(name)
            }
        } else {
            settings.randomTransitionNames.removeAll { $0 == name }
        }
        if settings.randomTransitionNames.isEmpty {
            settings.randomTransitionNames = [name]
            sender.state = .on
        }
        save(settings, immediately: true)
    }

    private func selectTransition(row: Int) {
        guard let name = transitionName(forRow: row) else { return }
        selectedTransitionName = name
        rebuildTransitionInspector()
        guard randomizeSwitch.state == .off else { return }
        var settings = collectSettings()
        settings.transitionStyle = name
        save(settings, immediately: true)
        NotificationCenter.default.post(name: transitionPreviewRequestedNotification, object: nil)
    }

    @objc private func randomizeChanged(_ sender: NSSwitch) {
        var settings = collectSettings()
        if sender.state == .on {
            settings.transitionStyle = "random"
        } else {
            let fallback = selectedTransitionName
                ?? settings.randomTransitionNames.first
                ?? store.transitionNames.first
                ?? "fade"
            selectedTransitionName = fallback
            settings.transitionStyle = fallback
        }
        updateRandomColumnVisibility()
        transitionTable.reloadData()
        if let row = selectedTransitionName.flatMap(rowForTransition) {
            transitionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        save(settings, immediately: true)
    }

    @objc private func filterTransitions(_ sender: NSSearchField) {
        transitionTable.reloadData()
        if let row = selectedTransitionName.flatMap(rowForTransition) {
            transitionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            transitionTable.scrollRowToVisible(row)
        }
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        do {
            try preferences.setLaunchAtLogin(sender.state == .on)
            sender.state = preferences.launchAtLogin ? .on : .off
        } catch {
            sender.state = preferences.launchAtLogin ? .on : .off
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to change Launch at Login"
            if let window {
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func showInDockChanged(_ sender: NSSwitch) {
        let showInDock = sender.state == .on
        updateDockCycleRowVisibility()
        // Changing activation policy during the switch's mouse event can interrupt
        // its native tracking animation. Apply it on the next main-loop turn.
        DispatchQueue.main.async {
            self.preferences.setShowInDock(showInDock)
        }
    }

    private func updateDockCycleRowVisibility() {
        let showsDock = showInDockSwitch.state == .on
        cycleDockIconRow?.isHidden = !showsDock
        applicationPanelHeightConstraint?.constant = showsDock ? 134 : 106
        configureGeneralKeyViewLoop()
    }

    @objc private func showInMenuBarChanged(_ sender: NSSwitch) {
        DispatchQueue.main.async {
            self.preferences.setShowInMenuBar(sender.state == .on)
        }
    }

    @objc private func cycleDockIconChanged(_ sender: NSSwitch) {
        preferences.setCycleDockIcon(sender.state == .on)
    }

    private var visibleTransitionNames: [String] {
        let query = transitionSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.transitionNames }
        return store.transitionNames.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func transitionName(forRow row: Int) -> String? {
        let names = visibleTransitionNames
        guard names.indices.contains(row) else { return nil }
        return names[row]
    }

    private func rowForTransition(_ name: String) -> Int? {
        visibleTransitionNames.firstIndex(of: name)
    }

    private func updateRandomColumnVisibility() {
        randomColumn?.isHidden = randomizeSwitch.state == .off
    }

    private func rebuildTransitionInspector() {
        transitionInspector.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        transitionInspector.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: transitionInspector.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: transitionInspector.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: transitionInspector.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: transitionInspector.bottomAnchor, constant: -16)
        ])
        guard let name = selectedTransitionName,
              let metadata = store.transitionMetadata.first(where: { $0.name == name }) else {
            let empty = NSTextField(wrappingLabelWithString: "Select a transition to inspect its parameters.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        guard !metadata.defaultParams.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No configurable parameters.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        stack.addArrangedSubview(parameterEditor(for: metadata))
    }

    private func parameterEditor(for metadata: TransitionMetadata) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        for name in metadata.defaultParams.keys.sorted() {
            guard let defaultValue = metadata.defaultParams[name] else { continue }
            let value = draftSettings.transitionParameters[metadata.name]?[name] ?? defaultValue
            let parameterStack = NSStackView()
            parameterStack.orientation = .vertical
            parameterStack.alignment = .leading
            parameterStack.spacing = 4
            let type = metadata.paramsTypes[name] ?? "value"
            let label = NSTextField(labelWithString: "\(name)  \(type)")
            label.textColor = .secondaryLabelColor
            parameterStack.addArrangedSubview(label)
            switch value {
            case .boolean(let enabled):
                let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(parameterBooleanChanged(_:)))
                checkbox.identifier = parameterIdentifier(transition: metadata.name, name: name, component: nil)
                checkbox.state = enabled ? .on : .off
                parameterStack.addArrangedSubview(checkbox)
            case .number(let number):
                parameterStack.addArrangedSubview(parameterNumberEditor(
                    value: number,
                    defaultValue: defaultValue,
                    parameterName: name,
                    identifier: parameterIdentifier(transition: metadata.name, name: name, component: nil),
                    componentLabel: nil
                ))
            case .vector(let numbers):
                for (index, number) in numbers.enumerated() {
                    parameterStack.addArrangedSubview(parameterNumberEditor(
                        value: number,
                        defaultValue: defaultValue,
                        parameterName: name,
                        identifier: parameterIdentifier(transition: metadata.name, name: name, component: index),
                        componentLabel: ["x", "y", "z", "w"][index]
                    ))
                }
            }
            stack.addArrangedSubview(parameterStack)
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetTransitionParameters(_:)))
        reset.identifier = NSUserInterfaceItemIdentifier("reset|\(metadata.name)")
        reset.controlSize = .small
        stack.addArrangedSubview(reset)
        return stack
    }

    private func topAlignedCell(_ content: NSView, centered: Bool = false) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        var constraints = [
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4)
        ]
        if centered {
            constraints.append(content.centerXAnchor.constraint(equalTo: container.centerXAnchor))
        } else {
            constraints.append(content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4))
            constraints.append(content.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func parameterNumberField(
        value: Double,
        identifier: NSUserInterfaceItemIdentifier,
        step: Double
    ) -> NSTextField {
        let field = NumericTextField(string: String(format: "%.4g", value))
        field.stepValue = step
        field.identifier = identifier
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted)
        field.widthAnchor.constraint(equalToConstant: 68).isActive = true
        numericFieldsByIdentifier[identifier.rawValue] = field
        return field
    }

    private func parameterNumberEditor(
        value: Double,
        defaultValue: ParameterValue,
        parameterName: String,
        identifier: NSUserInterfaceItemIdentifier,
        componentLabel: String?
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        if let componentLabel {
            let component = NSTextField(labelWithString: componentLabel)
            component.textColor = .tertiaryLabelColor
            component.widthAnchor.constraint(equalToConstant: 12).isActive = true
            row.addArrangedSubview(component)
        }
        let bounds = sliderBounds(parameterName: parameterName, defaultValue: defaultValue, currentValue: value)
        let slider = NSSlider(
            value: clamp(value, bounds.minimum, bounds.maximum),
            minValue: bounds.minimum,
            maxValue: bounds.maximum,
            target: self,
            action: #selector(parameterSliderChanged(_:))
        )
        slider.identifier = identifier
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        slider.toolTip = "Suggested range: \(String(format: "%.4g", bounds.minimum)) to \(String(format: "%.4g", bounds.maximum))"
        row.addArrangedSubview(slider)
        let range = bounds.maximum - bounds.minimum
        let step = range <= 2 ? 0.01 : max(1, niceUpperBound(range) / 100)
        let numberField = parameterNumberField(value: value, identifier: identifier, step: step)
        row.addArrangedSubview(spinControl(
            for: numberField,
            minimum: bounds.minimum,
            maximum: bounds.maximum
        ))
        return row
    }

    private func numericFieldDescendant(of view: NSView) -> NumericTextField? {
        if let field = view as? NumericTextField { return field }
        for subview in view.subviews {
            if let field = numericFieldDescendant(of: subview) { return field }
        }
        return nil
    }

    private func enclosingParameterRow(for view: NSView) -> NSStackView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let stack = current as? NSStackView,
               stack.arrangedSubviews.contains(where: { $0 is NSSlider }) {
                return stack
            }
            ancestor = current.superview
        }
        return nil
    }

    private func sliderBounds(
        parameterName: String,
        defaultValue: ParameterValue,
        currentValue: Double
    ) -> (minimum: Double, maximum: Double) {
        let defaults: [Double]
        switch defaultValue {
        case .number(let value): defaults = [value]
        case .vector(let values): defaults = values
        case .boolean: return (0, 1)
        }
        let lowercaseName = parameterName.lowercased()
        if lowercaseName.contains("direction") || lowercaseName.contains("center") {
            return (-1, 1)
        }
        let largestMagnitude = max(defaults.map(abs).max() ?? 0, abs(currentValue))
        let allNormalized = defaults.allSatisfy { $0 >= 0 && $0 <= 1 }
        if allNormalized { return (0, 1) }
        if defaults.contains(where: { $0 < 0 }) {
            let limit = niceUpperBound(max(largestMagnitude * 2, 1))
            return (-limit, limit)
        }
        return (0, niceUpperBound(max(largestMagnitude * 2, 1)))
    }

    private func niceUpperBound(_ value: Double) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let rounded: Double
        if normalized <= 1 { rounded = 1 }
        else if normalized <= 2 { rounded = 2 }
        else if normalized <= 5 { rounded = 5 }
        else { rounded = 10 }
        return rounded * magnitude
    }

    private func parameterIdentifier(
        transition: String,
        name: String,
        component: Int?
    ) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("parameter|\(transition)|\(name)|\(component.map(String.init) ?? "scalar")")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        if let field = notification.object as? NSTextField,
           Double(field.stringValue) != nil {
            syncNumericStepper(for: field)
        }
        if let field = notification.object as? NSTextField,
           field.identifier?.rawValue.hasPrefix("parameter|") == true {
            updateParameter(from: field, immediately: false)
            return
        }
        save(collectSettings(), immediately: false)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isLoading, let field = notification.object as? NSTextField else { return }
        if field.identifier?.rawValue.hasPrefix("parameter|") == true {
            updateParameter(from: field, immediately: true)
        } else {
            save(collectSettings(), immediately: true)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let field = control as? NumericTextField,
              commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveDown(_:)) else {
            return false
        }
        let direction = commandSelector == #selector(NSResponder.moveUp(_:)) ? 1.0 : -1.0
        field.applyStep(direction: direction, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        textView.string = field.stringValue
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        fieldCommitted(field)
        return true
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        syncNumericStepper(for: sender)
        if sender.identifier?.rawValue.hasPrefix("parameter|") == true {
            updateParameter(from: sender, immediately: true)
        } else {
            save(collectSettings(), immediately: true)
        }
    }

    private func collectSettings() -> WallpaperSettings {
        var settings = draftSettings
        for display in displays {
            guard let fields = displayFields[display.id] else { continue }
            settings.displayConfigurations[display.id] = DisplayConfiguration(
                name: display.name,
                width: display.width,
                height: display.height,
                rows: fields.rows.integerValue,
                columns: fields.columns.integerValue,
                enabled: displayEnabledSwitches[display.id]?.state != .off
            )
        }
        settings.transitionGapSeconds = transitionGapField.doubleValue
        settings.fadeDurationSeconds = fadeField.doubleValue
        return settings
    }

    private func save(_ settings: WallpaperSettings, immediately: Bool) {
        saveWorkItem?.cancel()
        draftSettings = settings
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.commit(settings, actionName: "Change Wallpaper Settings")
        }
        saveWorkItem = workItem
        if immediately {
            workItem.perform()
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    @objc private func resetDefaults() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all settings?"
        alert.informativeText = "This resets display grids, animation timing, transition selection, the random transition pool, transition parameters, app visibility, Dock icon cycling, and Launch at Login."
        alert.addButton(withTitle: "Reset All Settings")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performResetDefaults()
        }
    }

    @objc private func confirmQuitApplication() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Apple Logo Wallpaper?"
        alert.informativeText = "The live wallpapers and Dock icon animation will stop until you launch the application again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSApp.terminate(nil)
        }
    }

    private func performResetDefaults() {
        saveWorkItem?.cancel()
        let previous = store.settings
        let previousApplicationState = preferences.state
        store.reset(displays: displays)
        try? preferences.apply(.defaults)
        settingsUndoManager.registerUndo(withTarget: self) { target in
            target.restoreAll(
                previous,
                applicationState: previousApplicationState,
                actionName: "Reset All Settings"
            )
        }
        settingsUndoManager.setActionName("Reset All Settings")
        loadSettings()
    }

    @objc private func parameterBooleanChanged(_ sender: NSButton) {
        updateParameter(identifier: sender.identifier, number: nil, boolean: sender.state == .on, immediately: true)
    }

    @objc private func parameterSliderChanged(_ sender: NSSlider) {
        if let row = sender.superview as? NSStackView,
           let field = numericFieldDescendant(of: row) {
            field.doubleValue = sender.doubleValue
            syncNumericStepper(for: field)
        }
        updateParameter(identifier: sender.identifier, number: sender.doubleValue, boolean: nil, immediately: true)
    }

    private func updateParameter(from field: NSTextField, immediately: Bool) {
        if let row = enclosingParameterRow(for: field),
           let slider = row.arrangedSubviews.compactMap({ $0 as? NSSlider }).first {
            slider.doubleValue = clamp(field.doubleValue, slider.minValue, slider.maxValue)
        }
        updateParameter(identifier: field.identifier, number: field.doubleValue, boolean: nil, immediately: immediately)
    }

    private func updateParameter(
        identifier: NSUserInterfaceItemIdentifier?,
        number: Double?,
        boolean: Bool?,
        immediately: Bool
    ) {
        guard let parts = identifier?.rawValue.split(separator: "|", omittingEmptySubsequences: false),
              parts.count == 4 else { return }
        let transition = String(parts[1])
        let parameter = String(parts[2])
        let component = Int(parts[3])
        guard let metadata = store.transitionMetadata.first(where: { $0.name == transition }),
              let defaultValue = metadata.defaultParams[parameter] else { return }
        var settings = collectSettings()
        var values = settings.transitionParameters[transition] ?? [:]
        if let boolean {
            values[parameter] = .boolean(boolean)
        } else if let number {
            if let component {
                let current = values[parameter] ?? defaultValue
                guard case .vector(var vector) = current, vector.indices.contains(component) else { return }
                vector[component] = number
                values[parameter] = .vector(vector)
            } else {
                values[parameter] = .number(number)
            }
        }
        settings.transitionParameters[transition] = values
        save(settings, immediately: immediately)
    }

    @objc private func resetTransitionParameters(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue.split(separator: "|", maxSplits: 1).last.map(String.init) else {
            return
        }
        var settings = collectSettings()
        settings.transitionParameters.removeValue(forKey: name)
        save(settings, immediately: true)
        if let row = rowForTransition(name) {
            transitionTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        rebuildTransitionInspector()
    }

    private func commit(_ settings: WallpaperSettings, actionName: String) {
        let previous = store.settings
        guard previous != settings else { return }
        store.update(settings)
        draftSettings = store.settings
        settingsUndoManager.registerUndo(withTarget: self) { target in
            target.restore(previous, actionName: actionName)
        }
        settingsUndoManager.setActionName(actionName)
    }

    private func restore(_ settings: WallpaperSettings, actionName: String) {
        let inverse = store.settings
        store.update(settings)
        draftSettings = store.settings
        settingsUndoManager.registerUndo(withTarget: self) { target in
            target.restore(inverse, actionName: actionName)
        }
        settingsUndoManager.setActionName(actionName)
        loadSettings()
    }

    private func restoreAll(
        _ settings: WallpaperSettings,
        applicationState: ApplicationPreferences.State,
        actionName: String
    ) {
        let inverseSettings = store.settings
        let inverseApplicationState = preferences.state
        store.update(settings)
        try? preferences.apply(applicationState)
        draftSettings = store.settings
        settingsUndoManager.registerUndo(withTarget: self) { target in
            target.restoreAll(
                inverseSettings,
                applicationState: inverseApplicationState,
                actionName: actionName
            )
        }
        settingsUndoManager.setActionName(actionName)
        loadSettings()
    }
}

final class SettingsPresentation {
    private let store: SettingsStore
    private let preferences: ApplicationPreferences
    private var controller: SettingsWindowController?
    private var suppressActivationUntil = Date.distantPast
    private var isPresenting = false

    init(store: SettingsStore, preferences: ApplicationPreferences) {
        self.store = store
        self.preferences = preferences
    }

    func suppressActivation(for interval: TimeInterval) {
        suppressActivationUntil = Date(timeIntervalSinceNow: interval)
    }

    func applicationDidBecomeActive() {
        guard Date() >= suppressActivationUntil else { return }
        present()
    }

    func present() {
        guard !isPresenting else { return }
        isPresenting = true
        let controller = settingsController()
        controller.showWindow(nil)
        controller.window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak controller] in
            controller?.window?.orderFrontRegardless()
            controller?.window?.makeKeyAndOrderFront(nil)
            controller?.window?.makeFirstResponder(nil)
            self?.isPresenting = false
        }
    }

    func refresh(displays: [DisplayInfo]) {
        controller?.refresh(displays: displays)
    }

    private func settingsController() -> SettingsWindowController {
        if let controller { return controller }
        let controller = SettingsWindowController(
            store: store,
            preferences: preferences,
            displays: DisplayInfo.connected()
        )
        self.controller = controller
        return controller
    }
}

final class DockIconPresentation {
    private let imageView: NSImageView = {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }()

    private lazy var imageURLs: [URL] = {
        guard let directory = Bundle.main.resourceURL?
            .appendingPathComponent("Web/images", isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }
        let extensions = Set(["png", "jpg", "jpeg", "gif", "webp"])
        return urls.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }()

    func display(frameData: Data) {
        guard let source = NSImage(data: frameData) else { return }
        let image = formattedImage(from: source)
        DispatchQueue.main.async { [imageView] in
            if NSApp.dockTile.contentView !== imageView {
                NSApp.dockTile.contentView = imageView
            }
            imageView.image = image
            NSApp.dockTile.display()
        }
    }

    func restoreStaticIcon() {
        let preferredURL = imageURLs.first {
            $0.deletingPathExtension().lastPathComponent == "139 - T7OhIF7"
        }
        let fallbackURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        guard let url = preferredURL ?? fallbackURL,
              let image = NSImage(contentsOf: url) else { return }
        DispatchQueue.main.async {
            NSApp.dockTile.contentView = nil
            NSApp.applicationIconImage = self.formattedImage(from: image)
            NSApp.dockTile.display()
        }
    }

    private func formattedImage(from source: NSImage) -> NSImage {
        let outputSize = NSSize(width: 512, height: 512)
        let outputBounds = NSRect(origin: .zero, size: outputSize)
        // Dynamic Dock content bypasses the normal asset-catalog treatment.
        // Reproduce the macOS production grid's 824/1024 artwork footprint.
        let artworkScale = 824.0 / 1024.0
        let artworkSide = outputSize.width * artworkScale
        let artworkBounds = NSRect(
            x: (outputSize.width - artworkSide) / 2,
            y: (outputSize.height - artworkSide) / 2,
            width: artworkSide,
            height: artworkSide
        )
        let sourceSize = source.size
        let squareSide = min(sourceSize.width, sourceSize.height)
        let sourceRect = NSRect(
            x: (sourceSize.width - squareSide) / 2,
            y: (sourceSize.height - squareSide) / 2,
            width: squareSide,
            height: squareSide
        )
        let result = NSImage(size: outputSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.clear(outputBounds)
        let cornerRadius = artworkSide * 0.2237
        NSBezierPath(
            roundedRect: artworkBounds,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).addClip()
        source.draw(
            in: artworkBounds,
            from: sourceRect,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        result.unlockFocus()
        return result
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore.shared
    private let preferences = ApplicationPreferences.shared
    private var surfaces: [String: WallpaperSurface] = [:]
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var dockIconSurfaceID: String?
    private var connectedDisplays: [DisplayInfo] = []
    private var displayPollTimer: Timer?
    private let dockIconPresentation = DockIconPresentation()
    private lazy var settingsPresentation = SettingsPresentation(
        store: store,
        preferences: preferences
    )
    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsPresentation.suppressActivation(for: 1)
        applyDockVisibility()
        rebuildSurfaces()
        applyMenuBarVisibility()
        applyDockIconCycling()
        displayPollTimer = Timer.scheduledTimer(
            timeInterval: 3,
            target: self,
            selector: #selector(pollDisplays),
            userInfo: nil,
            repeats: true
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dockIconCyclingChanged),
            name: dockIconCyclingChangedNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: settingsChangedNotification,
            object: store
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(previewSelectedTransition),
            name: transitionPreviewRequestedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dockVisibilityChanged),
            name: dockVisibilityChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarVisibilityChanged),
            name: menuBarVisibilityChangedNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        settingsPresentation.applicationDidBecomeActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func rebuildSurfaces() {
        let displays = DisplayInfo.connected()
        store.reconcile(displays: displays)
        connectedDisplays = displays
        reconcileSurfaces(displays: displays)
        settingsPresentation.refresh(displays: displays)
    }

    private func reconcileSurfaces(displays: [DisplayInfo]) {
        let enabledDisplays = displays.filter {
            store.settings.displayConfigurations[$0.id]?.enabled ?? true
        }
        let enabledIDs = Set(enabledDisplays.map(\.id))
        dockIconSurfaceID = enabledDisplays.first?.id

        let removedIDs = surfaces.keys.filter { !enabledIDs.contains($0) }
        for id in removedIDs {
            surfaces[id]?.invalidate()
            surfaces.removeValue(forKey: id)
        }

        for display in enabledDisplays {
            if let surface = surfaces[display.id], surface.display == display {
                surface.apply(settings: store.settings)
                continue
            }
            surfaces[display.id]?.invalidate()
            surfaces.removeValue(forKey: display.id)
            if let surface = WallpaperSurface(
                display: display,
                settings: store.settings,
                dockIconCyclingEnabled: preferences.cycleDockIcon && display.id == dockIconSurfaceID,
                dockIconFrameReceiver: { [weak self] data in self?.receiveDockIconFrame(data) }
            ) {
                surfaces[display.id] = surface
            }
        }

        applyDockIconCycling()
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
        image?.accessibilityDescription = "Apple Logo Wallpaper"
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let reloadItem = NSMenuItem(title: "Reload Wallpapers", action: #selector(reloadWallpapers), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Apple Logo Wallpaper", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusMenu = menu
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let statusMenu {
            NSMenu.popUpContextMenu(statusMenu, with: event, for: sender)
        } else {
            openSettings()
        }
    }

    private func applyMenuBarVisibility() {
        if preferences.showInMenuBar {
            configureStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            statusMenu = nil
        }
    }

    @objc private func screenConfigurationChanged() {
        rebuildSurfaces()
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              application.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        settingsPresentation.applicationDidBecomeActive()
    }

    @objc private func pollDisplays() {
        let displays = DisplayInfo.connected()
        let sameDisplays = displays.count == connectedDisplays.count
            && zip(displays, connectedDisplays).allSatisfy { current, previous in
                current.id == previous.id
                    && current.name == previous.name
                    && current.width == previous.width
                    && current.height == previous.height
                    && current.frame == previous.frame
            }
        guard !sameDisplays else { return }
        rebuildSurfaces()
    }

    @objc private func settingsChanged() {
        reconcileSurfaces(displays: connectedDisplays)
    }

    @objc private func previewSelectedTransition() {
        surfaces.values.forEach { $0.previewSelectedTransition() }
    }

    @objc private func dockVisibilityChanged() {
        applyDockVisibility()
    }

    @objc private func menuBarVisibilityChanged() {
        applyMenuBarVisibility()
    }

    @objc private func dockIconCyclingChanged() {
        applyDockIconCycling()
    }

    private func applyDockIconCycling() {
        let enabled = preferences.cycleDockIcon
        surfaces.values.forEach { $0.setDockIconPublishing(false) }
        guard enabled, let dockIconSurfaceID else {
            restoreStaticDockIcon()
            return
        }
        surfaces[dockIconSurfaceID]?.setDockIconPublishing(true)
    }

    private func receiveDockIconFrame(_ data: Data) {
        guard preferences.cycleDockIcon,
              !data.isEmpty else { return }
        dockIconPresentation.display(frameData: data)
    }

    private func restoreStaticDockIcon() {
        dockIconPresentation.restoreStaticIcon()
    }

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(preferences.showInDock ? .regular : .accessory)
    }

    @objc private func openSettings() {
        settingsPresentation.present()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        openSettings()
        return true
    }

    @objc private func reloadWallpapers() {
        surfaces.values.forEach { $0.load() }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
