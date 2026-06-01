import Cocoa
import ScreenCaptureKit

/// Borderless panel that can become key (needed for the control panel to work correctly)
private class ControlPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Creates a plain NSButton with a symbol image, no border, no bezel
private func makeSymbolButton(symbol: String, color: NSColor, action: Selector, target: AnyObject) -> NSButton {
    let btn = NSButton(frame: .zero)
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    btn.contentTintColor = color
    btn.action = action
    btn.target = target
    return btn
}

final class LongScreenshotManager {

    var onProgress: ((String) -> Void)?
    var onComplete: ((NSImage, CGRect) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Thread-safe cancellation flag
    private let cancellationLock = NSLock()
    private var _isCancelled = false

    private var isCancelled: Bool {
        cancellationLock.lock()
        let v = _isCancelled
        cancellationLock.unlock()
        return v
    }

    private func setCancelled(_ v: Bool) {
        cancellationLock.lock()
        _isCancelled = v
        cancellationLock.unlock()
    }

    private let operationQueue = DispatchQueue(label: "com.screenshottool.longscreenshot", qos: .userInitiated)

    private var controlPanel: NSPanel?

    /// Window number of the overlay to exclude from captures
    var overlayWindowNumber: Int?

    // MARK: - Cached Capture Context

    /// Cached SCContentFilter — rebuilt only when displayID/overlay changes, not per frame.
    private var cachedFilter: SCContentFilter?
    /// Cached SCStreamConfiguration — rebuilt only when region changes.
    private var cachedConfig: SCStreamConfiguration?
    /// Screen scale cached at setup time.
    private var cachedCaptureScale: CGFloat = 1.0
    /// Cached region used for config validity check.
    private var cachedRegionRect: CGRect = .zero
    private var cachedDisplayID: CGDirectDisplayID = 0

    // MARK: - Scroll Direction

    private enum ScrollDirection {
        case down
        case up
    }

    private struct OverlapResult {
        let direction: ScrollDirection
        let overlap: Int
        let confidence: Double
    }

    func cancel() {
        setCancelled(true)
        DispatchQueue.main.async { self.controlPanel?.orderOut(nil) }
    }

    // MARK: - Capture Context Setup

    /// Build cached SCContentFilter and SCStreamConfiguration once before the capture loop.
    /// This avoids calling expensive SCShareableContent.current on every frame.
    private func setupCaptureContext(region: CGRect, displayID: CGDirectDisplayID, overlayWindowNumber: Int?) {
        cachedRegionRect = region
        cachedDisplayID = displayID

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let scale = screen.backingScaleFactor
        cachedCaptureScale = scale

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

                let excluded: [SCWindow]
                if let winNum = overlayWindowNumber, winNum != 0 {
                    excluded = content.windows.filter { $0.windowID == winNum }
                } else {
                    excluded = []
                }
                self.cachedFilter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.showsCursor = false

                let relX = region.origin.x - screen.frame.origin.x
                let relY = region.origin.y - screen.frame.origin.y
                let sourceRect = CGRect(
                    x: relX,
                    y: screen.frame.height - relY - region.height,
                    width: region.width,
                    height: region.height
                )
                config.sourceRect = sourceRect
                config.width = Int(round(region.width * scale))
                config.height = Int(round(region.height * scale))
                self.cachedConfig = config
            } catch {
                NSLog("[ScreenshotTool] setupCaptureContext error: \(error)")
            }
        }
        semaphore.wait()
    }

    /// Invalidate the cached capture context so it is rebuilt on next capture.
    private func invalidateCaptureContext() {
        cachedFilter = nil
        cachedConfig = nil
        cachedRegionRect = .zero
        cachedDisplayID = 0
    }

    func startManualCapture(region: CGRect, windowInfo: WindowInfo) {
        setCancelled(false)

        // Pre-setup capture context (one expensive call, then cached for the loop)
        setupCaptureContext(region: region, displayID: windowInfo.displayID, overlayWindowNumber: overlayWindowNumber)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showControlPanel(region: region)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.operationQueue.async {
                    self.autoScrollCaptureLoop(region: region, windowInfo: windowInfo)
                    // Clean up cache when loop finishes
                    self.invalidateCaptureContext()
                }
            }
        }
    }

    // MARK: - Control Panel

    private func showControlPanel(region: CGRect) {
        let btnSize: CGFloat = 48
        let padding: CGFloat = 8
        let panelW = btnSize * 2 + padding * 3
        let panelH = btnSize + padding * 2

        let panel = ControlPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position at the right edge of the selection, below it
        let margin: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.contains(region) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero
        let panelX = max(screenFrame.minX + margin, min(region.maxX - panelW, screenFrame.maxX - panelW - margin))
        let panelY = max(screenFrame.minY + margin, region.minY - panelH - margin)
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        let view = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        view.layer?.cornerRadius = 8

        // Cancel on left, Done on right
        let cancelBtn = makeSymbolButton(symbol: "xmark", color: .red, action: #selector(cancelCapture), target: self)
        cancelBtn.frame = NSRect(x: padding, y: padding, width: btnSize, height: btnSize)
        view.addSubview(cancelBtn)

        let doneBtn = makeSymbolButton(symbol: "checkmark", color: .green, action: #selector(finishCapture), target: self)
        doneBtn.frame = NSRect(x: padding * 2 + btnSize, y: padding, width: btnSize, height: btnSize)
        view.addSubview(doneBtn)

        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKey()
        controlPanel = panel
    }

    @objc private func finishCapture() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        captureFinished = true
    }

    @objc private func cancelCapture() {
        setCancelled(true)
        controlPanel?.orderOut(nil)
        controlPanel = nil
        DispatchQueue.main.async { self.onCancel?() }
    }

    private let blendBorder = 8
    private var captureFinished = false
    /// Chunks in page order: index 0 = top, last = bottom.
    private var capturedChunks: [CGImage] = []
    /// Overlap pixel count between adjacent chunks. overlaps[i] = overlap between chunk[i] and chunk[i+1].
    /// Each overlap value includes `blendBorder` extra pixels kept for seam cross-fade.
    private var overlaps: [Int] = []
    /// The last full frame used for overlap detection.
    private var lastCapturedFrame: CGImage?
    /// Cached row signatures of lastCapturedFrame to avoid recomputation on every frame.
    private var lastFrameSignatures: [[(Int, Int, Int)]]?
    /// Throttle full-frame captures to every N polls to avoid duplicates
    private var fullFrameCooldown = 0
    /// Last known scroll direction; used by the full-frame fallback to decide insert position.
    private var lastDirection: ScrollDirection?
    private var directionLocked = false
    /// AX scroll area found during setup — used for scroll position tracking.
    private var axScrollArea: AXUIElement?

    // MARK: - Auto-Scroll Capture Loop (using CGEvent scroll + pixel overlap)

    /// Automatically scroll the target app via simulated mouse wheel, capture and stitch.
    /// Uses pixel-based overlap detection so it works on any app.
    private func autoScrollCaptureLoop(region: CGRect, windowInfo: WindowInfo) {
        guard let firstFrame = captureRegion(cachedRegionRect, displayID: cachedDisplayID) else {
            DispatchQueue.main.async { self.onError?("截取画面失败") }
            return
        }

        let pw = firstFrame.width
        let ph = firstFrame.height
        let scale = CGFloat(ph) / CGFloat(region.height)
        let overlapSearch = Int(CGFloat(Int(region.height * 0.8)) * scale)

        capturedChunks = [firstFrame]
        overlaps = []
        lastCapturedFrame = firstFrame
        lastFrameSignatures = nil

        // Find AX scroll area
        axScrollArea = findScrollArea(pid: windowInfo.pid)
        if axScrollArea != nil {
            DispatchQueue.main.async { self.onProgress?("已识别滚动区域，将自动滚动") }
        }

        activateApp(pid: windowInfo.pid)
        Thread.sleep(forTimeInterval: 0.3)

        // Move cursor to center of selection for CGEvent scroll targeting
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let cursorPoint = CGPoint(x: region.midX, y: screenHeight - region.midY)
        CGWarpMouseCursorPosition(cursorPoint)
        Thread.sleep(forTimeInterval: 0.05)

        var consecutiveNoChange = 0
        var consecutiveSmallOverlap = 0
        var staleFrameCount = 0

        let hasAXTracking = axScrollArea != nil
        let maxEndRetries = hasAXTracking ? 1 : 3

        while !isCancelled && !captureFinished {
            // Smart scroll with AX verification and retry.
            // Returns false only when AX confirms end of scrollable content.
            if !performSmartScroll(pid: windowInfo.pid, direction: .down) {
                NSLog("[ScreenshotTool] end of content reached (AX confirmed)")
                break
            }

            guard let frame = captureRegion(cachedRegionRect, displayID: cachedDisplayID) else {
                staleFrameCount += 1
                if staleFrameCount > 5 { break }
                continue
            }
            staleFrameCount = 0

            guard let prev = lastCapturedFrame else { lastCapturedFrame = frame; continue }

            // Compute row signatures for the new frame; reuse cached for prev
            guard let currSigs = rowSignatures(cgImage: frame) else { continue }
            let prevSigs: [[(Int, Int, Int)]]
            if let cached = lastFrameSignatures {
                prevSigs = cached
            } else {
                guard let sigs = rowSignatures(cgImage: prev) else { continue }
                prevSigs = sigs
            }
            // Cache current frame's signatures for next iteration (avoids recomputation)
            lastFrameSignatures = currSigs

            // Pixel-based overlap detection using cached signatures
            let result = findOverlapBothDirections(prevSigs: prevSigs, currSigs: currSigs,
                                                    width: pw, height: ph,
                                                    searchHeight: overlapSearch)
            guard let overlapResult = result else {
                // No overlap found — content may have scrolled completely.
                let dir = lastDirection ?? .down
                capturedChunks.append(frame)
                overlaps.append(0)
                lastCapturedFrame = frame
                if !directionLocked { lastDirection = dir; directionLocked = true }
                NSLog("[ScreenshotTool] no overlap found, full frame appended")
                continue
            }

            let overlapRatio = Double(overlapResult.overlap) / Double(ph)
            if overlapRatio > 0.95 {
                consecutiveNoChange += 1
                if consecutiveNoChange >= maxEndRetries { break }
                // Try one more aggressive scroll to confirm end
                performCGScroll(pid: windowInfo.pid, lines: 40)
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            consecutiveNoChange = 0

            // Overscroll recovery: if overlap is tiny, content changed too much
            if overlapRatio < 0.03 {
                NSLog("[ScreenshotTool] overscroll (overlap=\(overlapResult.overlap)), skipping frame")
                // Don't stitch this frame — we'll wait for content to stabilize
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }

            if overlapRatio < 0.15 {
                consecutiveSmallOverlap += 1
            } else {
                consecutiveSmallOverlap = 0
            }

            let newHeight = ph - overlapResult.overlap
            guard newHeight > 0 else { continue }
            let keep = min(blendBorder, overlapResult.overlap / 2)

            switch overlapResult.direction {
            case .down:
                lastDirection = .down; directionLocked = true
                let cropY = max(0, overlapResult.overlap - keep)
                let cropH = ph - cropY
                guard cropH > keep, cropH <= ph else { continue }
                guard let cropped = frame.cropping(to: CGRect(x: 0, y: cropY, width: pw, height: cropH)) else { continue }
                if isDuplicate(cropped, lastChunk: capturedChunks.last!, threshold: 0.98) { break }
                capturedChunks.append(cropped)
                overlaps.append(overlapResult.overlap)
                lastCapturedFrame = frame

            case .up:
                lastDirection = .up; directionLocked = true
                let cropH = min(ph, newHeight + keep)
                guard cropH > keep, cropH <= ph else { continue }
                guard let cropped = frame.cropping(to: CGRect(x: 0, y: 0, width: pw, height: cropH)) else { continue }
                if isDuplicate(cropped, lastChunk: capturedChunks.first!, threshold: 0.98) { break }
                capturedChunks.insert(cropped, at: 0)
                overlaps.insert(overlapResult.overlap, at: 0)
                lastCapturedFrame = frame
            }

            DispatchQueue.main.async {
                self.onProgress?("已截取 \(self.capturedChunks.count) 屏")
            }
        }

        DispatchQueue.main.async {
            self.controlPanel?.orderOut(nil)
            self.controlPanel = nil
            self.onProgress?("正在合成最终图片...")
        }

        guard !capturedChunks.isEmpty else { return }

        let finalImage = stitchChunks(capturedChunks, overlaps: overlaps, regionWidth: region.width, scale: scale)
        guard !isCancelled else { return }

        DispatchQueue.main.async {
            self.onComplete?(finalImage, region)
        }
    }

    /// Simulate a scroll wheel event via CGEvent, posted to the target PID.
    private func performCGScroll(pid: pid_t, lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        // Re-position cursor to the center of the region for reliable targeting
        // (the app may have moved the mouse since the initial warp)
        let mouse = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        event.location = CGPoint(x: mouse.x, y: screenHeight - mouse.y)
        event.postToPid(pid)
    }

    /// Scroll the target app with AX position verification and retry.
    /// Uses AXContentOffset/scrollbar position to confirm the scroll actually moved content.
    /// Returns false only when AX confirms we've reached the end of scrollable content.
    private func performSmartScroll(pid: pid_t, direction: ScrollDirection) -> Bool {
        // Read position before scrolling (AX may not be available)
        let posBefore = axScrollArea != nil ? readScrollOffset(scrollArea: axScrollArea!) : nil

        let amounts: [Int32] = direction == .down ? [12, 28] : [-12, -28]
        let canVerify = posBefore != nil && axScrollArea != nil

        for (index, lines) in amounts.enumerated() {
            performCGScroll(pid: pid, lines: lines)
            Thread.sleep(forTimeInterval: 0.25 + Double(index) * 0.1)

            if canVerify {
                if let posAfter = readScrollOffset(scrollArea: axScrollArea!) {
                    let delta = abs(posAfter - posBefore!)
                    if delta > 3.0 {
                        return true // Content scrolled — success
                    }
                    // delta <= 3: no significant movement, try larger scroll
                    continue
                }
                // readScrollOffset failed mid-way — assume scroll worked
                return true
            }

            // No AX tracking — assume scroll worked
            return true
        }

        // All scroll attempts failed — likely at end of content
        if canVerify {
            NSLog("[ScreenshotTool] AX end of content (no movement after \(amounts.last ?? 0) lines)")
        }
        return false
    }

    /// Quick perceptual hash comparison to detect duplicate frames.
    private func isDuplicate(_ new: CGImage, lastChunk: CGImage, threshold: Double) -> Bool {
        let w = min(new.width, lastChunk.width)
        let h = min(new.height, lastChunk.height, 40)

        guard let newData = pixelData(cgImage: new),
              let lastData = pixelData(cgImage: lastChunk) else { return false }

        let bytesPerRow = w * 4
        var diff: Double = 0
        var count = 0

        for row in 0..<h {
            for x in 0..<min(w, 100) {
                let idx = row * bytesPerRow + x * 4
                guard idx + 3 < newData.count, idx + 3 < lastData.count else { continue }
                let dr = abs(Int(newData[idx]) - Int(lastData[idx]))
                let dg = abs(Int(newData[idx + 1]) - Int(lastData[idx + 1]))
                let db = abs(Int(newData[idx + 2]) - Int(lastData[idx + 2]))
                diff += Double(dr + dg + db)
                count += 1
            }
        }

        return count > 0 && (diff / Double(count)) < threshold
    }

    // MARK: - Screen Capture

    /// Capture the given region using the cached SCContentFilter and config.
    /// Falls back to uncached capture if the cache is invalid (should not happen in normal flow).
    private func captureRegion(_ region: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        if let filter = cachedFilter, let config = cachedConfig {
            let semaphore = DispatchSemaphore(value: 0)
            var result: CGImage?
            Task {
                defer { semaphore.signal() }
                do {
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    result = cgImage
                } catch {
                    NSLog("[ScreenshotTool] SCK capture error: \(error)")
                }
            }
            semaphore.wait()
            return result
        }

        // Fallback: uncached capture (should not be hit after setupCaptureContext)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        let excludeWindowNumber = overlayWindowNumber ?? 0

        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?

        Task {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

                let excluded: [SCWindow]
                if excludeWindowNumber != 0 {
                    excluded = content.windows.filter { $0.windowID == excludeWindowNumber }
                } else {
                    excluded = []
                }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.showsCursor = false

                let relX = region.origin.x - screen.frame.origin.x
                let relY = region.origin.y - screen.frame.origin.y
                let sourceRect = CGRect(
                    x: relX,
                    y: screen.frame.height - relY - region.height,
                    width: region.width,
                    height: region.height
                )
                config.sourceRect = sourceRect
                config.width = Int(round(region.width * screen.backingScaleFactor))
                config.height = Int(round(region.height * screen.backingScaleFactor))

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result = cgImage
            } catch {
                NSLog("[ScreenshotTool] SCK capture error: \(error)")
            }
        }

        semaphore.wait()
        return result
    }

    private func activateApp(pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Accessibility Scroll Tracking

    /// Find the AXScrollArea within the target application's front window.
    private func findScrollArea(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &focused) == .success,
           let win = focused as! AXUIElement? {
            NSLog("[ScreenshotTool] AX checking focused window")
            if let found = findScrollAreaInElement(win, depth: 30) {
                NSLog("[ScreenshotTool] AX found scroll area in focused window")
                return found
            }
            NSLog("[ScreenshotTool] AX no scroll area in focused window")
        } else {
            NSLog("[ScreenshotTool] AX no focused window")
        }

        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &windows) == .success,
              let wins = windows as? [AXUIElement] else {
            NSLog("[ScreenshotTool] AX no windows found")
            return nil
        }
        NSLog("[ScreenshotTool] AX checking \(wins.count) windows")

        for win in wins {
            if let found = findScrollAreaInElement(win, depth: 30) {
                NSLog("[ScreenshotTool] AX found scroll area in window")
                return found
            }
        }
        NSLog("[ScreenshotTool] AX no scroll area found in any window")
        return nil
    }

    /// Recursively search an AX element tree for a scroll area.
    /// Increased depth from 20 to 30 for complex view hierarchies.
    private func findScrollAreaInElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role) == .success,
           let r = role as? String {
            if r == "AXScrollArea" || r == "AXScrollView" {
                return element
            }
            if r == "AXWebArea" {
                var parent: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &parent) == .success,
                   let p = parent as! AXUIElement? {
                    var parentRole: CFTypeRef?
                    if AXUIElementCopyAttributeValue(p, "AXRole" as CFString, &parentRole) == .success,
                       let pr = parentRole as? String,
                       (pr == "AXScrollArea" || pr == "AXScrollView") {
                        return p
                    }
                }
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &children) == .success,
              let childArray = children as? [AXUIElement] else { return nil }

        for child in childArray {
            if let found = findScrollAreaInElement(child, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Read the current vertical scroll offset in document points.
    /// Returns nil if the scroll position cannot be read.
    private func readScrollOffset(scrollArea: AXUIElement) -> CGFloat? {
        var offsetVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(scrollArea, "AXContentOffset" as CFString, &offsetVal) == .success,
           let axVal = offsetVal as! AXValue?,
           AXValueGetType(axVal) == .cgPoint {
            var point = CGPoint.zero
            AXValueGetValue(axVal, .cgPoint, &point)
            NSLog("[ScreenshotTool] AX Method1 contentOffset point=\(point) returning \(-point.y)")
            return -point.y
        }

        var scrollBarVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, "AXVerticalScrollBar" as CFString, &scrollBarVal) == .success else {
            NSLog("[ScreenshotTool] AX no vertical scroll bar found")
            return nil
        }
        let scrollBar = scrollBarVal as! AXUIElement

        var valRef: CFTypeRef?, minRef: CFTypeRef?, maxRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollBar, "AXValue" as CFString, &valRef) == .success else {
            NSLog("[ScreenshotTool] AX scroll bar has no value")
            return nil
        }
        AXUIElementCopyAttributeValue(scrollBar, "AXMinValue" as CFString, &minRef)
        AXUIElementCopyAttributeValue(scrollBar, "AXMaxValue" as CFString, &maxRef)

        guard let numVal = valRef as! NSNumber? else { return nil }
        let rawValue = numVal.doubleValue
        let rawMin = (minRef as! NSNumber?)?.doubleValue ?? 0
        let rawMax = (maxRef as! NSNumber?)?.doubleValue ?? 100
        let range = rawMax - rawMin
        guard range > 0 else { return nil }
        let proportion = (rawValue - rawMin) / range

        var contentHeight: CGFloat = 0
        var visibleHeight: CGFloat = 0

        if let chRef: CFTypeRef? = {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(scrollArea, "AXContentHeight" as CFString, &v)
            return v
        }(), let ch = chRef as! NSNumber? {
            contentHeight = CGFloat(ch.doubleValue)
        }

        var frameRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(scrollArea, "AXFrame" as CFString, &frameRef) == .success,
           let axFrame = frameRef as! AXValue?,
           AXValueGetType(axFrame) == .cgRect {
            var rect = CGRect.zero
            AXValueGetValue(axFrame, .cgRect, &rect)
            visibleHeight = rect.height
        }

        if contentHeight > 0, visibleHeight > 0 {
            let scrollable = contentHeight - visibleHeight
            if scrollable > 0 {
                let result = proportion * scrollable
                NSLog("[ScreenshotTool] AX Method2 bar=\(rawValue) min=\(rawMin) max=\(rawMax) prop=\(proportion) ch=\(contentHeight) vh=\(visibleHeight) result=\(result)")
                return result
            }
        }

        let fallback = proportion * 2000
        NSLog("[ScreenshotTool] AX Method2 fallback bar=\(rawValue) prop=\(proportion) result=\(fallback)")
        return fallback
    }

    // MARK: - Overlap Detection

    private static let signatureBlockCount: Int = 32
    private static let signatureSampleStep: Int = 2

    /// Search both scroll directions and return the best overlap result.
    /// Uses pre-computed signatures to avoid redundant pixel data extraction.
    /// Once the direction is locked, only searches the locked direction.
    private func findOverlapBothDirections(prevSigs: [[(Int, Int, Int)]], currSigs: [[(Int, Int, Int)]],
                                            width: Int, height: Int,
                                            searchHeight: Int) -> OverlapResult? {
        guard prevSigs.count == height, currSigs.count == height else { return nil }

        let maxSearch = min(searchHeight, height * 3 / 4)

        var bestDown = (scroll: 0, diff: Double.infinity)
        if !directionLocked || lastDirection == .down {
            for scroll in 1..<maxSearch {
                let compareRows = height - scroll
                if compareRows < 20 { break }
                let diff = compareRowSignatures(prevSigs: prevSigs, currSigs: currSigs,
                                                prevStart: scroll, currStart: 0, count: compareRows)
                let regularized = diff + Double(scroll) * 0.002
                if regularized < bestDown.diff {
                    bestDown = (scroll, regularized)
                }
            }
        }

        var bestUp = (scroll: 0, diff: Double.infinity)
        if !directionLocked || lastDirection == .up {
            for scroll in 1..<maxSearch {
                let compareRows = height - scroll
                if compareRows < 20 { break }
                let diff = compareRowSignatures(prevSigs: prevSigs, currSigs: currSigs,
                                                prevStart: 0, currStart: scroll, count: compareRows)
                let regularized = diff + Double(scroll) * 0.002
                if regularized < bestUp.diff {
                    bestUp = (scroll, regularized)
                }
            }
        }

        let useDown: Bool
        if directionLocked {
            useDown = lastDirection == .down
        } else if let lastDir = lastDirection {
            let bias: Double = 5.0
            if lastDir == .down {
                useDown = bestDown.diff <= bestUp.diff + bias
            } else {
                useDown = bestDown.diff + bias < bestUp.diff
            }
        } else {
            useDown = bestDown.diff < bestUp.diff
        }

        if useDown, bestDown.scroll > 0 {
            let refined = refineOverlapPixelLevel(prev: nil, curr: nil,
                                                  width: width, height: height,
                                                  bestScroll: bestDown.scroll, searchRange: 12,
                                                  reverse: false,
                                                  prevSigs: prevSigs, currSigs: currSigs)
            let overlap = height - refined
            if overlap > 0 && overlap < height {
                return OverlapResult(direction: .down, overlap: overlap, confidence: bestDown.diff)
            }
        } else if !useDown, bestUp.scroll > 0 {
            let refined = refineOverlapPixelLevel(prev: nil, curr: nil,
                                                  width: width, height: height,
                                                  bestScroll: bestUp.scroll, searchRange: 12,
                                                  reverse: true,
                                                  prevSigs: prevSigs, currSigs: currSigs)
            let overlap = height - refined
            if overlap > 0 && overlap < height {
                return OverlapResult(direction: .up, overlap: overlap, confidence: bestUp.diff)
            }
        }

        return nil
    }

    /// Compare row signatures between two image regions.
    private func compareRowSignatures(prevSigs: [[(Int, Int, Int)]],
                                      currSigs: [[(Int, Int, Int)]],
                                      prevStart: Int, currStart: Int, count: Int) -> Double {
        var diff: Int64 = 0
        var countPixels = 0
        for row in 0..<count {
            let prevBlocks = prevSigs[prevStart + row]
            let currBlocks = currSigs[currStart + row]
            for b in 0..<Self.signatureBlockCount {
                diff += Int64(abs(prevBlocks[b].0 - currBlocks[b].0)
                            + abs(prevBlocks[b].1 - currBlocks[b].1)
                            + abs(prevBlocks[b].2 - currBlocks[b].2))
                countPixels += 1
            }
        }
        return countPixels > 0 ? Double(diff) / Double(countPixels) : Double.infinity
    }

    /// Refine the overlap using signature-based comparison (much faster than pixelData extraction).
    /// Falls back to pixelData if signatures are not provided.
    private func refineOverlapPixelLevel(prev: CGImage?, curr: CGImage?,
                                         width: Int, height: Int,
                                         bestScroll: Int, searchRange: Int,
                                         reverse: Bool = false,
                                         prevSigs: [[(Int, Int, Int)]]? = nil,
                                         currSigs: [[(Int, Int, Int)]]? = nil) -> Int {
        // Fast path: use signatures when available (no pixelData extraction needed)
        if let prevSigs = prevSigs, let currSigs = currSigs {
            var best = bestScroll
            var bestDiff = Double.infinity

            for scroll in max(1, bestScroll - searchRange)...min(height - 20, bestScroll + searchRange) {
                let compareRows = height - scroll
                if compareRows < 20 { continue }
                let diff = compareRowSignatures(prevSigs: prevSigs, currSigs: currSigs,
                                                prevStart: reverse ? 0 : scroll,
                                                currStart: reverse ? scroll : 0,
                                                count: compareRows)
                if diff < bestDiff {
                    bestDiff = diff
                    best = scroll
                }
            }
            return best
        }

        // Fallback: pixel-level comparison with CGImage data
        guard let prev = prev, let curr = curr,
              let prevData = pixelData(cgImage: prev),
              let currData = pixelData(cgImage: curr) else { return bestScroll }

        let bytesPerRow = width * 4
        var best = bestScroll
        var bestDiff = Double.infinity
        let sampleStep = max(1, width / 100)

        for scroll in max(1, bestScroll - searchRange)...min(height - 20, bestScroll + searchRange) {
            let compareRows = height - scroll
            if compareRows < 20 { continue }
            var diff: Int64 = 0
            var count = 0

            if reverse {
                for row in 0..<compareRows {
                    let prevRow = row * bytesPerRow
                    let currRow = (scroll + row) * bytesPerRow
                    for x in stride(from: 0, to: width, by: sampleStep) {
                        let pi = prevRow + x * 4
                        let ci = currRow + x * 4
                        guard pi + 3 < prevData.count, ci + 3 < currData.count else { break }
                        diff += Int64(abs(Int(prevData[pi]) - Int(currData[ci]))
                                    + abs(Int(prevData[pi+1]) - Int(currData[ci+1]))
                                    + abs(Int(prevData[pi+2]) - Int(currData[ci+2])))
                        count += 1
                    }
                }
            } else {
                for row in 0..<compareRows {
                    let prevRow = (scroll + row) * bytesPerRow
                    let currRow = row * bytesPerRow
                    for x in stride(from: 0, to: width, by: sampleStep) {
                        let pi = prevRow + x * 4
                        let ci = currRow + x * 4
                        guard pi + 3 < prevData.count, ci + 3 < currData.count else { break }
                        diff += Int64(abs(Int(prevData[pi]) - Int(currData[ci]))
                                    + abs(Int(prevData[pi+1]) - Int(currData[ci+1]))
                                    + abs(Int(prevData[pi+2]) - Int(currData[ci+2])))
                        count += 1
                    }
                }
            }

            if count > 0 {
                let avg = Double(diff) / Double(count)
                if avg < bestDiff {
                    bestDiff = avg
                    best = scroll
                }
            }
        }

        return best
    }

    /// Build a row signature for each row of the image.
    private func rowSignatures(cgImage: CGImage) -> [[(Int, Int, Int)]]? {
        guard let data = pixelData(cgImage: cgImage) else { return nil }
        let h = cgImage.height
        let w = cgImage.width
        let bytesPerRow = w * 4
        let blockW = max(1, w / Self.signatureBlockCount)

        var sigs: [[(Int, Int, Int)]] = []
        sigs.reserveCapacity(h)

        for row in 0..<h {
            let rowStart = row * bytesPerRow
            var blockSigs: [(Int, Int, Int)] = []
            blockSigs.reserveCapacity(Self.signatureBlockCount)

            for b in 0..<Self.signatureBlockCount {
                let startX = b * blockW
                let endX = min(startX + blockW, w)
                var rSum = 0, gSum = 0, bSum = 0, n = 0

                for col in stride(from: startX, to: endX, by: Self.signatureSampleStep) {
                    let idx = rowStart + col * 4
                    guard idx + 3 < data.count else { break }
                    rSum += Int(data[idx])
                    gSum += Int(data[idx + 1])
                    bSum += Int(data[idx + 2])
                    n += 1
                }
                blockSigs.append(n > 0 ? (rSum / n, gSum / n, bSum / n) : (0, 0, 0))
            }
            sigs.append(blockSigs)
        }
        return sigs
    }

    // MARK: - Pixel Data

    private func pixelData(cgImage: CGImage) -> Data? {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    // MARK: - Stitching

    private func stitchChunks(_ chunks: [CGImage], overlaps: [Int], regionWidth: CGFloat, scale: CGFloat) -> NSImage {
        guard !chunks.isEmpty else { return NSImage(size: .zero) }

        // Compute unique content heights and blend strip heights.
        var uniqueHeights: [CGFloat] = []
        var totalH: CGFloat = 0

        for i in 0..<chunks.count {
            let ptH = CGFloat(chunks[i].height) / scale
            let keepTop = (i > 0) ? CGFloat(min(blendBorder, overlaps[i - 1] / 2)) / scale : 0
            let keepBottom = (i < overlaps.count) ? CGFloat(min(blendBorder, overlaps[i] / 2)) / scale : 0
            let uniqueH = ptH - keepTop - keepBottom
            uniqueHeights.append(uniqueH)
            totalH += uniqueH
            if i > 0 {
                totalH += CGFloat(min(blendBorder, overlaps[i - 1] / 2)) / scale
            }
        }
        totalH = max(totalH, 1)

        let result = NSImage(size: NSSize(width: regionWidth, height: totalH))
        result.lockFocus()
        defer { result.unlockFocus() }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return result }

        // Draw from bottom to top (NSImage bottom-left origin)
        var y: CGFloat = 0

        for i in (0..<chunks.count).reversed() {
            let ch = chunks[i]
            let keepTop = (i > 0) ? min(blendBorder, overlaps[i - 1] / 2) : 0
            let keepBottom = (i < overlaps.count) ? min(blendBorder, overlaps[i] / 2) : 0
            let uniqueH = uniqueHeights[i]

            // Draw unique content (exclude any overlap borders)
            if keepTop > 0 || keepBottom > 0 {
                let cropY = keepTop
                let cropH = ch.height - keepTop - keepBottom
                if cropH > 0, let cropped = ch.cropping(to: CGRect(x: 0, y: cropY, width: ch.width, height: cropH)) {
                    ctx.draw(cropped, in: CGRect(x: 0, y: y, width: regionWidth, height: uniqueH))
                }
            } else {
                ctx.draw(ch, in: CGRect(x: 0, y: y, width: regionWidth, height: uniqueH))
            }
            y += uniqueH

            // Blend strip between chunk[i-1] (above) and chunk[i] (below)
            if i > 0 {
                let keep = min(blendBorder, overlaps[i - 1] / 2)
                guard keep > 0 else { continue }

                let keepPt = CGFloat(keep) / scale

                let aboveChunk = chunks[i - 1]
                let belowChunk = chunks[i]

                guard let aboveCrop = aboveChunk.cropping(to: CGRect(
                    x: 0, y: aboveChunk.height - keep, width: aboveChunk.width, height: keep
                )), let belowCrop = belowChunk.cropping(to: CGRect(
                    x: 0, y: 0, width: belowChunk.width, height: keep
                )) else { y += keepPt; continue }

                guard let aboveData = pixelData(cgImage: aboveCrop),
                      let belowData = pixelData(cgImage: belowCrop) else { y += keepPt; continue }

                let w = aboveCrop.width
                let bpr = w * 4
                var blendData = Data(count: bpr * keep)
                blendData.withUnsafeMutableBytes { ptr in
                    let dest = ptr.bindMemory(to: UInt8.self)
                    for row in 0..<keep {
                        let t = CGFloat(row) / CGFloat(keep)
                        let alphaA = 1.0 - Double(t)
                        let alphaB = Double(t)
                        let aRow = row * bpr
                        let bRow = row * bpr
                        let dRow = row * bpr
                        for x in 0..<w {
                            let di = dRow + x * 4
                            let ai = aRow + x * 4
                            let bi = bRow + x * 4
                            guard ai + 3 < aboveData.count, bi + 3 < belowData.count else { break }
                            dest[di]     = UInt8(Double(aboveData[ai])     * alphaA + Double(belowData[bi])     * alphaB)
                            dest[di + 1] = UInt8(Double(aboveData[ai + 1]) * alphaA + Double(belowData[bi + 1]) * alphaB)
                            dest[di + 2] = UInt8(Double(aboveData[ai + 2]) * alphaA + Double(belowData[bi + 2]) * alphaB)
                            dest[di + 3] = 255
                        }
                    }
                }

                let provider = CGDataProvider(data: blendData as NSData)
                if let blendedImage = CGImage(
                    width: w, height: keep,
                    bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: bpr,
                    space: aboveCrop.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    provider: provider!,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent
                ) {
                    ctx.draw(blendedImage, in: CGRect(x: 0, y: y, width: regionWidth, height: keepPt))
                }
                y += keepPt
            }
        }

        return result
    }
}
