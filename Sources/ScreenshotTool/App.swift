import Cocoa
import Carbon
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App Entry Point

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var captureMenuItem: NSMenuItem!
    private var savePathMenuItem: NSMenuItem!
    private var currentOverlay: CaptureOverlay?
    private var pinManager: PinManager?
    private var activeHotkeyConfig: HotkeyConfigWindow?
    private var longScreenshotManager: LongScreenshotManager?

    // MARK: - Lifecycle

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--test") {
            TestCapture.run()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Load saved hotkey first so menu displays the correct value
        setupHotkey()
        setupMenuBar()
        pinManager = PinManager()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.fill",
                                           accessibilityDescription: "截图工具")

        let menu = NSMenu()
        captureMenuItem = NSMenuItem(title: "", action: #selector(startCapture), keyEquivalent: "")
        updateCaptureMenuItemTitle()
        menu.addItem(captureMenuItem)
        let hotkeyItem = NSMenuItem(title: "设置快捷键...", action: #selector(showHotkeyConfig), keyEquivalent: "")
        hotkeyItem.target = self
        menu.addItem(hotkeyItem)
        menu.addItem(NSMenuItem.separator())
        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        savePathMenuItem = NSMenuItem(title: "保存路径...", action: #selector(chooseSavePath), keyEquivalent: "")
        updateSavePathMenuItemTitle()
        menu.addItem(savePathMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateCaptureMenuItemTitle() {
        captureMenuItem.title = "截图 (\(HotkeyManager.shared.currentHotkeyString()))"
    }

    // MARK: - Save Path

    private func updateSavePathMenuItemTitle() {
        if let path = defaultSavePath() {
            savePathMenuItem.title = "保存到: \(path.lastPathComponent)"
        } else {
            savePathMenuItem.title = "保存路径..."
        }
    }

    private func defaultSavePath() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "savePath"),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    @objc private func chooseSavePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择默认截图保存目录"
        panel.directoryURL = defaultSavePath()

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: "savePath")
            self?.updateSavePathMenuItemTitle()
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let ok = HotkeyManager.shared.register { [weak self] in
            self?.startCapture()
        }
        if !ok {
            NSLog("[ScreenshotTool] hotkey registration failed")
        }
    }

    // MARK: - Capture Flow

    @objc private func startCapture() {
        if let overlay = currentOverlay {
            NSLog("[ScreenshotTool] cleaning up stale overlay")
            overlay.cleanupOverlay()
            currentOverlay = nil
        }

        NSLog("[ScreenshotTool] starting capture")
        // Capture all screens immediately before showing the overlay
        Task { await self.captureAllScreensAndStart() }
    }

    /// Pre-capture all screens to freeze the frame, then show overlay with frozen background.
    private func captureAllScreensAndStart() async {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            await MainActor.run { self.showError("无法获取屏幕内容") }
            return
        }

        let frozen = await { () -> [(CGImage, CGRect)] in
            var result: [(CGImage, CGRect)] = []
            for screen in screens {
                let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

                let scale = screen.backingScaleFactor
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
                config.width = Int(round(screen.frame.width * scale))
                config.height = Int(round(screen.frame.height * scale))
                config.showsCursor = false

                let filter = SCContentFilter(display: display, excludingWindows: [])
                if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    result.append((cgImage, screen.frame))
                }
            }
            return result
        }()

        guard !frozen.isEmpty else {
            await MainActor.run { self.showError("截图失败") }
            return
        }

        await MainActor.run { self.showOverlayWithFrozenBackground(frozen) }
    }

    private func showOverlayWithFrozenBackground(_ frozen: [(CGImage, CGRect)]) {
        let overlay = CaptureOverlay()
        currentOverlay = overlay

        overlay.onComplete = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .capture:
                // Frozen background handles area capture internally — no action needed
                break
            case .cancel:
                self.currentOverlay = nil
            case .window(let windowRect, let windowNumber):
                self.captureWindow(windowRect: windowRect, windowNumber: windowNumber)
            }
        }

        overlay.onAnnotationResult = { [weak self] image, cgImage, action in
            guard let self = self else { return }
            switch action {
            case .save:
                self.saveImage(image, cgImage: cgImage)
            case .copy:
                NSPasteboard.general.clearContents()
                if let cg = cgImage {
                    NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: image.size)])
                } else {
                    NSPasteboard.general.writeObjects([image])
                }
            case .pin:
                break
            }
        }

        overlay.onPinCGImage = { [weak self] cgImage, imageSize, rect in
            self?.pinManager?.pin(cgImage: cgImage, imageSize: imageSize, at: rect.origin)
        }
        overlay.onPinAction = { [weak self] image, rect in
            self?.pinManager?.pin(image: image, at: rect.origin)
        }

        overlay.onLongScreenshot = { [weak self] rect in
            guard let self = self else { return }
            self.startLongScreenshot(selectionRect: rect)
        }

        overlay.onAnnotationCancel = { [weak self] in
            self?.currentOverlay = nil
        }

        overlay.beginSelection(frozenBackground: frozen)
    }

    // MARK: - Long Screenshot

    private func startLongScreenshot(selectionRect: CGRect) {
        // Transition overlay to long screenshot mode (don't close)
        currentOverlay?.enterLongScreenshotMode(selectionRect: selectionRect)

        let center = CGPoint(x: selectionRect.midX, y: selectionRect.midY)

        // Find the window under the selection
        guard let winInfo = WindowDetector.windowInfoAtPoint(center) else {
            currentOverlay?.exitLongScreenshotMode()
            showError("未找到目标窗口")
            return
        }

        let manager = LongScreenshotManager()
        manager.overlayWindowNumber = currentOverlay?.overlayWindowNumber
        longScreenshotManager = manager

        manager.onProgress = { msg in
            NSLog("[ScreenshotTool] long screenshot: \(msg)")
        }

        manager.onComplete = { [weak self] image, region in
            guard let self = self else { return }
            self.longScreenshotManager = nil

            DispatchQueue.main.async {
                // Exit long screenshot mode
                self.currentOverlay?.exitLongScreenshotMode()
                // Show result in annotation mode
                self.showLongScreenshotResult(image: image, region: region)
            }
        }

        manager.onError = { [weak self] msg in
            guard let self = self else { return }
            self.longScreenshotManager = nil
            DispatchQueue.main.async {
                self.currentOverlay?.exitLongScreenshotMode()
                self.showError("长截图失败: \(msg)")
            }
        }

        manager.onCancel = { [weak self] in
            guard let self = self else { return }
            self.longScreenshotManager = nil
            DispatchQueue.main.async {
                self.currentOverlay?.exitLongScreenshotMode()
            }
        }

        manager.startManualCapture(region: selectionRect, windowInfo: winInfo)
    }

    private func showLongScreenshotResult(image: NSImage, region: CGRect) {
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)

        // Scale image to fit within 85% of screen height to avoid extending beyond bounds
        let imgSize = image.size
        let maxH = screenFrame.height * 0.85
        let maxW = screenFrame.width * 0.9
        let scale = min(1.0, min(maxW / imgSize.width, maxH / imgSize.height))
        let displaySize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)

        let displayRect = CGRect(
            x: screenFrame.midX - displaySize.width / 2,
            y: screenFrame.midY - displaySize.height / 2,
            width: displaySize.width,
            height: displaySize.height
        )

        // Prevent recapture from frozen background on move — the image is the stitched result
        currentOverlay?.clearFrozenBackground()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        currentOverlay?.enterAnnotationMode(image: image, cgImage: cgImage, selectionRect: displayRect, canMove: false)
    }

    // MARK: - ScreenCaptureKit Capture

    private func captureWithSCK(rect: CGRect) {
        NSLog("[ScreenshotTool] capture rect=\(rect)")

        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.main else {
            showError("未找到显示器")
            return
        }

        let scale = screen.backingScaleFactor
        let dispFrame = screen.frame
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        NSLog("[ScreenshotTool] screen frame=\(dispFrame) scale=\(scale) id=\(screenID)")

        // NSScreen uses bottom-left, SCK uses top-left.
        // sourceRect is in the display's point coordinate system (top-left origin).
        // The selected region relative to the display's bottom-left corner.
        let relX = rect.origin.x - dispFrame.origin.x
        let relY = rect.origin.y - dispFrame.origin.y
        let sourceRect = CGRect(
            x: relX,
            y: dispFrame.size.height - relY - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )

        let pixelW = Int(round(rect.size.width * scale))
        let pixelH = Int(round(rect.size.height * scale))

        NSLog("[ScreenshotTool] SCK sourceRect=\(sourceRect) outSize=\(pixelW)x\(pixelH)")

        // Small delay to ensure overlay is removed before capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Task { await self.performSCKCapture(
                screenID: screenID,
                sourceRect: sourceRect,
                pixelW: pixelW,
                pixelH: pixelH,
                selectionRect: rect,
                excludeWindowNumber: self.currentOverlay?.overlayWindowNumber
            ) }
        }
    }

    private func performSCKCapture(screenID: CGDirectDisplayID, sourceRect: CGRect, pixelW: Int, pixelH: Int, selectionRect: CGRect, excludeWindowNumber: Int? = nil) async {
        do {
            let content = try await SCShareableContent.current

            // Match the display by ID so we capture the correct screen
            guard let display = content.displays.first(where: { $0.displayID == screenID })
                    ?? content.displays.first else {
                await MainActor.run { self.showError("未找到可用的显示器") }
                return
            }

            // Exclude our overlay window so the dim overlay isn't captured
            let excluded: [SCWindow]
            if let winNum = excludeWindowNumber {
                excluded = content.windows.filter { $0.windowID == winNum }
            } else {
                excluded = []
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()

            // Set capture region in display's point coordinate system
            if sourceRect.width > 0 && sourceRect.height > 0 {
                config.sourceRect = sourceRect
            }
            // Output image dimensions in pixels
            config.width = pixelW
            config.height = pixelH
            config.showsCursor = false

            NSLog("[ScreenshotTool] capturing SCK filter=\(display.width)x\(display.height)")

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            NSLog("[ScreenshotTool] SCK result size=\(cgImage.width)x\(cgImage.height)")

            let imageSize = CGSize(
                width: sourceRect.width > 0 ? sourceRect.width : CGFloat(display.width),
                height: sourceRect.height > 0 ? sourceRect.height : CGFloat(display.height)
            )

            await MainActor.run {
                let image = NSImage(cgImage: cgImage, size: imageSize)
                self.currentOverlay?.enterAnnotationMode(image: image, cgImage: cgImage, selectionRect: selectionRect)
            }

        } catch {
            NSLog("[ScreenshotTool] SCK error: \(error)")
            await MainActor.run {
                self.currentOverlay?.cleanupOverlay()
                self.currentOverlay = nil
                self.showError("截屏失败: \(error.localizedDescription)\n\n请检查「系统设置 → 隐私与安全性 → 屏幕录制」中是否已添加本应用")
            }
        }
    }

    // MARK: - Window-based capture (bypasses coordinate math)

    private func captureWindow(windowRect: CGRect, windowNumber: Int) {
        // Convert CGWindow Y (top-left origin) to bottom-left for overlay positioning
        let primaryH = NSScreen.main?.frame.height ?? 0
        let blY = primaryH - windowRect.origin.y - windowRect.height
        let adjustedRect = CGRect(
            x: windowRect.origin.x,
            y: blY,
            width: windowRect.width,
            height: windowRect.height
        )

        let center = CGPoint(x: adjustedRect.midX, y: adjustedRect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.main else {
            showError("未找到显示器")
            return
        }

        let scale = screen.backingScaleFactor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Task { await self.performSCKWindowCapture(
                windowNumber: windowNumber,
                scale: scale,
                selectionRect: adjustedRect
            ) }
        }
    }

    private func performSCKWindowCapture(windowNumber: Int, scale: CGFloat, selectionRect: CGRect) async {
        do {
            let content = try await SCShareableContent.current

            guard let scWindow = content.windows.first(where: { $0.windowID == windowNumber }) else {
                await MainActor.run { self.showError("未找到窗口") }
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.showsCursor = false
            // Capture at full window resolution
            config.width = Int(scWindow.frame.width * scale)
            config.height = Int(scWindow.frame.height * scale)

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let imageSize = CGSize(width: scWindow.frame.width, height: scWindow.frame.height)

            await MainActor.run {
                let image = NSImage(cgImage: cgImage, size: imageSize)
                self.currentOverlay?.enterAnnotationMode(image: image, cgImage: cgImage, selectionRect: selectionRect)
            }

        } catch {
            NSLog("[ScreenshotTool] window capture error: \(error)")
            await MainActor.run {
                self.currentOverlay?.cleanupOverlay()
                self.currentOverlay = nil
                self.showError("窗口截屏失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Save

    private func saveImage(_ image: NSImage, cgImage: CGImage?) {
        // Use the passed CGImage directly to preserve original color space;
        // fall back to extracting from NSImage only when CGImage is unavailable.
        let cgImageToSave: CGImage
        if let cg = cgImage {
            cgImageToSave = cg
        } else if let rep = image.representations.first as? NSBitmapImageRep, let cg = rep.cgImage {
            cgImageToSave = cg
        } else if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImageToSave = cg
        } else {
            return
        }

        let writePNG: (CGImage, URL) -> Void = { srcImage, url in
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: 72,
                kCGImagePropertyDPIHeight: 72,
            ]
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, srcImage, properties as CFDictionary)
            CGImageDestinationFinalize(destination)
        }

        // If default save path is set, save directly without asking
        if let dir = defaultSavePath() {
            let filename = "截图_\(formattedDate()).png"
            let url = dir.appendingPathComponent(filename)
            writePNG(cgImageToSave, url)
            self.currentOverlay?.cleanupOverlay()
            self.currentOverlay = nil
            return
        }

        // No default path — show save panel
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "截图_\(formattedDate()).png"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                self?.currentOverlay?.restoreWindowLevel()
                return
            }
            writePNG(cgImageToSave, url)
            self?.currentOverlay?.cleanupOverlay()
            self?.currentOverlay = nil
        }
    }

    private func formattedDate() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
    }

    @objc private func toggleLoginItem() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[ScreenshotTool] login item error: \(error)")
        }
        // Refresh menu state
        if let item = statusItem.menu?.item(withTitle: "开机自启") {
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func showHotkeyConfig() {
        let config = HotkeyConfigWindow(
            currentShortcut: HotkeyManager.shared.currentHotkeyString(),
            onConfirm: { [weak self] keyCode, modifiers in
                let ok = HotkeyManager.shared.reregister(keyCode: keyCode, modifiers: modifiers)
                if ok {
                    self?.updateCaptureMenuItemTitle()
                } else {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "快捷键注册失败"
                        alert.informativeText = "该快捷键组合可能被系统或其他应用占用，请尝试其他组合。"
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        )
        activeHotkeyConfig = config
        config.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Hotkey Configuration Window

private class HotkeyConfigWindow: NSObject {
    private let panel: NSPanel
    private var capturedKeyCode: UInt32 = 0
    private var capturedModifiers: UInt32 = 0
    private let keyLabel: NSTextField
    private let confirmBtn: NSButton
    private var monitor: Any?
    private let onConfirm: (UInt32, UInt32) -> Void

    init(currentShortcut: String, onConfirm: @escaping (UInt32, UInt32) -> Void) {
        self.onConfirm = onConfirm

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "快捷键设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        let view = panel.contentView!

        let currentLabel = NSTextField(labelWithString: "当前: \(currentShortcut)")
        currentLabel.font = .systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.alignment = .center
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(currentLabel)

        let recordBox = NSBox()
        recordBox.boxType = .custom
        recordBox.borderWidth = 1
        recordBox.borderColor = .separatorColor
        recordBox.cornerRadius = 8
        recordBox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordBox)

        keyLabel = NSTextField(labelWithString: "按下快捷键组合...")
        keyLabel.font = .systemFont(ofSize: 15)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        recordBox.addSubview(keyLabel)

        let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
        confirmBtn = NSButton(title: "确认", target: nil, action: nil)
        confirmBtn.isEnabled = false

        let btnStack = NSStackView(views: [cancelBtn, confirmBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 12
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btnStack)

        NSLayoutConstraint.activate([
            currentLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            currentLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            recordBox.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 12),
            recordBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            recordBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            recordBox.heightAnchor.constraint(equalToConstant: 80),

            keyLabel.centerXAnchor.constraint(equalTo: recordBox.centerXAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: recordBox.centerYAnchor),

            btnStack.topAnchor.constraint(equalTo: recordBox.bottomAnchor, constant: 16),
            btnStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        super.init()

        cancelBtn.target = self
        cancelBtn.action = #selector(cancel)
        confirmBtn.target = self
        confirmBtn.action = #selector(confirm)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyEvent(event)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let m = self.monitor else { return }
            NSEvent.removeMonitor(m)
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 0x24, 0x4C: // Return / Enter
            if capturedKeyCode != 0 {
                confirm()
            }
            return nil
        case 0x35: // Escape
            cancel()
            return nil
        default:
            capturedKeyCode = UInt32(event.keyCode)
            capturedModifiers = HotkeyManager.carbonFlags(from: event.modifierFlags)
            updateDisplay()
            return nil
        }
    }

    private func updateDisplay() {
        guard capturedKeyCode != 0 else {
            keyLabel.stringValue = "按下快捷键组合..."
            keyLabel.textColor = .secondaryLabelColor
            return
        }
        var parts: [String] = []
        let mod = capturedModifiers
        if mod & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if mod & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mod & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mod & UInt32(controlKey) != 0 { parts.append("⌃") }
        if let chars = keyCodeToString(capturedKeyCode) {
            parts.append(chars)
        } else {
            parts.append("?")
        }
        keyLabel.stringValue = parts.joined()
        keyLabel.textColor = .labelColor
        confirmBtn.isEnabled = true
    }

    @objc private func confirm() {
        onConfirm(capturedKeyCode, capturedModifiers)
        panel.close()
    }

    @objc private func cancel() {
        panel.close()
    }
}

// MARK: - Test Capture (--test CLI flag)

struct TestCapture {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first,
                      let screen = NSScreen.screens.first else {
                    print("TEST FAIL: No display")
                    semaphore.signal()
                    return
                }

                let scale = screen.backingScaleFactor
                print("Screen frame: \(screen.frame), scale: \(scale)")

                // Step 1: Capture full screen (same as captureAllScreensAndStart)
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
                config.width = Int(round(screen.frame.width * scale))
                config.height = Int(round(screen.frame.height * scale))
                config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let fullCGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                print("Step1 full capture: \(fullCGImage.width)x\(fullCGImage.height) colorspace=\(fullCGImage.colorSpace?.name ?? "nil" as CFString)")

                // Step 2: Crop a test region (same as croppedImage)
                let testRegion = CGRect(x: 200, y: 200, width: 500, height: 400)
                let inter = screen.frame.intersection(testRegion)
                let cropScale = CGFloat(fullCGImage.width) / screen.frame.width
                let originX = round((inter.origin.x - screen.frame.origin.x) * cropScale)
                let originY = round(CGFloat(fullCGImage.height) - (inter.origin.y - screen.frame.origin.y + inter.height) * cropScale)
                let cropW = round(inter.width * cropScale)
                let cropH = round(inter.height * cropScale)
                let cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)
                guard let cropped = fullCGImage.cropping(to: cropRect) else {
                    print("TEST FAIL: Crop failed")
                    semaphore.signal()
                    return
                }
                let capturedNSImage = NSImage(cgImage: cropped, size: NSSize(width: cropW / cropScale, height: cropH / cropScale))
                print("Step2 cropped: \(cropped.width)x\(cropped.height) nsImage.size=\(capturedNSImage.size)")

                // Step 3: Render using the screen's actual color space (not DeviceRGB)
                let pixelW = cropped.width
                let pixelH = cropped.height
                let screenColorSpace = screen.colorSpace?.cgColorSpace ?? cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                guard let ctx = CGContext(
                    data: nil, width: pixelW, height: pixelH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: screenColorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    print("TEST FAIL: CGContext")
                    semaphore.signal()
                    return
                }
                ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
                guard let resultCGImage = ctx.makeImage() else {
                    print("TEST FAIL: makeImage")
                    semaphore.signal()
                    return
                }
                print("Step3 rendered: \(resultCGImage.width)x\(resultCGImage.height) colorspace=\(resultCGImage.colorSpace?.name ?? "nil" as CFString)")

                // Step 4: Save using CGImageDestination to embed the correct color profile
                let finalCGImage = resultCGImage
                guard let destination = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: "/tmp/tool_output.png") as CFURL,
                    UTType.png.identifier as CFString, 1, nil
                ) else {
                    print("TEST FAIL: destination")
                    semaphore.signal()
                    return
                }
                CGImageDestinationAddImage(destination, finalCGImage, [
                    kCGImagePropertyDPIWidth: 72,
                    kCGImagePropertyDPIHeight: 72,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    print("TEST FAIL: finalize")
                    semaphore.signal()
                    return
                }
                print("Step4 saved: done")

                // Compare with system screenshot
                let task = Process()
                task.launchPath = "/usr/sbin/screencapture"
                task.arguments = ["-x", "-R", "200,200,500,400", "/tmp/sys_output.png"]
                task.launch()
                task.waitUntilExit()

                // Analyze both
                let t1 = Process(); t1.launchPath = "/usr/bin/sips"; t1.arguments = ["-g", "all", "/tmp/tool_output.png"]
                let t2 = Process(); t2.launchPath = "/usr/bin/sips"; t2.arguments = ["-g", "all", "/tmp/sys_output.png"]

                print("\n=== TOOL OUTPUT ===")
                t1.launch(); t1.waitUntilExit()
                print("\n=== SYSTEM OUTPUT ===")
                t2.launch(); t2.waitUntilExit()

                print("\n=== COMPARISON ===")
                print("Expected pixel: \(Int(inter.width * scale))x\(Int(inter.height * scale))")
                print("Tool actual:    \(finalCGImage.width)x\(finalCGImage.height)")
                print("Match: \(finalCGImage.width == Int(inter.width * scale) && finalCGImage.height == Int(inter.height * scale))")
            } catch {
                print("TEST ERROR: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
