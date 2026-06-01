import Cocoa

// MARK: - Result

enum CaptureResult {
    case capture(CGRect)
    case window(CGRect, windowNumber: Int)
    case cancel
}

// MARK: - Annotation Types

enum AnnotationTool: Int, CaseIterable {
    case arrow, text, number, mosaic, rectangle, ellipse, highlight, select
}

struct AnnotationItem {
    let id = UUID()
    let tool: AnnotationTool
    let color: NSColor
    let lineWidth: CGFloat

    var startPoint: CGPoint = .zero
    var endPoint: CGPoint = .zero
    var text: String = ""
    var fontSize: CGFloat = 24
    var number: Int = 0
    var mosaicRect: CGRect = .zero
    var pixelSize: Int = 8

    static func arrow(start: CGPoint, end: CGPoint, color: NSColor) -> AnnotationItem {
        AnnotationItem(tool: .arrow, color: color, lineWidth: 3, startPoint: start, endPoint: end)
    }

    static func text(point: CGPoint, text: String, color: NSColor, fontSize: CGFloat = 24) -> AnnotationItem {
        AnnotationItem(tool: .text, color: color, lineWidth: 0, startPoint: point, text: text, fontSize: fontSize)
    }

    static func number(point: CGPoint, number: Int, color: NSColor) -> AnnotationItem {
        AnnotationItem(tool: .number, color: color, lineWidth: 0, startPoint: point, number: number)
    }

    static func mosaic(rect: CGRect, pixelSize: Int = 8) -> AnnotationItem {
        AnnotationItem(tool: .mosaic, color: .clear, lineWidth: 0, startPoint: rect.origin, mosaicRect: rect, pixelSize: pixelSize)
    }
}

enum AnnotationAction {
    case save, copy, pin
}

// MARK: - Overlay Window (needs to accept key for text input)

private class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay

final class CaptureOverlay: NSObject {

    var onComplete: ((CaptureResult) -> Void)?
    var onAnnotationResult: ((NSImage, AnnotationAction) -> Void)?
    var onAnnotationCancel: (() -> Void)?
    var onPinAction: ((NSImage, CGRect) -> Void)?
    /// Same as onPinAction but passes the raw CGImage to avoid NSImage
    /// representation size ambiguity on Retina displays.
    var onPinCGImage: ((CGImage, NSSize, CGRect) -> Void)?
    var onLongScreenshot: ((CGRect) -> Void)?

    private var overlayWindow: NSWindow?
    private var overlayView: OverlayView?

    var overlayWindowNumber: Int? { overlayWindow?.windowNumber }

    func beginSelection(frozenBackground: [(CGImage, CGRect)]? = nil) {
        guard overlayWindow == nil else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let totalFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        NSLog("[ScreenshotTool] overlay totalFrame=\(totalFrame) screens=\(screens.count)")

        overlayView = OverlayView(frame: CGRect(origin: .zero, size: totalFrame.size))
        overlayView?.screenOffset = totalFrame.origin
        if let frozen = frozenBackground {
            overlayView?.setFrozenBackground(frozen)
        }
        overlayView?.onSelectionComplete = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .capture, .window:
                // Keep overlay alive for annotation mode
                self.onComplete?(result)
            case .cancel:
                self.cleanup()
                self.onComplete?(result)
            }
        }
        overlayView?.onAnnotationAction = { [weak self] image, action in
            guard let self = self else { return }
            self.onAnnotationResult?(image, action)
        }
        overlayView?.onAnnotationCancel = { [weak self] in
            guard let self = self else { return }
            self.cleanup()
            self.onAnnotationCancel?()
        }
        overlayView?.onPinAction = { [weak self] image, rect in
            guard let self = self else { return }
            self.onPinAction?(image, rect)
        }
        overlayView?.onPinCGImage = { [weak self] cgImage, size, rect in
            guard let self = self else { return }
            self.onPinCGImage?(cgImage, size, rect)
        }
        overlayView?.onLongScreenshot = { [weak self] rect in
            guard let self = self else { return }
            self.onLongScreenshot?(rect)
        }

        let window = CaptureOverlayWindow(
            contentRect: totalFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.contentView = overlayView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        overlayWindow = window
    }

    func enterAnnotationMode(image: NSImage, selectionRect: CGRect, canMove: Bool = true) {
        overlayView?.enterAnnotationMode(image: image, globalRect: selectionRect, canMove: canMove)
    }

    func enterAnnotationMode(image: NSImage, cgImage: CGImage, selectionRect: CGRect, canMove: Bool = true) {
        overlayView?.enterAnnotationMode(image: image, cgImage: cgImage, globalRect: selectionRect, canMove: canMove)
    }

    func enterLongScreenshotMode(selectionRect: CGRect) {
        overlayWindow?.ignoresMouseEvents = true
        overlayView?.enterLongScreenshotMode(globalRect: selectionRect)
    }

    func exitLongScreenshotMode() {
        overlayWindow?.ignoresMouseEvents = false
        overlayView?.exitLongScreenshotMode()
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cleanupOverlay() {
        cleanup()
    }

    /// Restore overlay window level after a cancelled save panel
    func restoreWindowLevel() {
        overlayWindow?.level = .screenSaver
        overlayWindow?.makeKeyAndOrderFront(nil)
    }

    func clearFrozenBackground() {
        overlayView?.clearFrozenBackground()
    }

    private func cleanup() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
    }
}

// MARK: - Overlay View

private class OverlayView: NSView {

    // MARK: - Callbacks

    var onSelectionComplete: ((CaptureResult) -> Void)?
    var onAnnotationAction: ((NSImage, AnnotationAction) -> Void)?
    var onAnnotationCancel: (() -> Void)?
    var onPinAction: ((NSImage, CGRect) -> Void)?
    var onPinCGImage: ((CGImage, NSSize, CGRect) -> Void)?
    var onLongScreenshot: ((CGRect) -> Void)?
    var screenOffset = CGPoint.zero

    // Frozen background (pre-captured screenshot)
    private var frozenBackgrounds: [(CGImage, CGRect)] = []

    func setFrozenBackground(_ images: [(CGImage, CGRect)]) {
        frozenBackgrounds = images
        needsDisplay = true
    }

    func clearFrozenBackground() {
        frozenBackgrounds = []
    }

    private var trackingArea: NSTrackingArea?
    private var annotationGlobalRect: CGRect = .zero

    // MARK: - Mode

    private enum Mode { case selecting, adjusting, annotating, longScreenshotting }
    private var mode: Mode = .selecting

    // MARK: - Selection State

    private var isSelecting = false
    private var selectionStart = CGPoint.zero
    private var selectionRect = CGRect.null
    private var highlightedWindowRect: CGRect?

    // MARK: - Adjust State (after selection, before confirm)

    private enum AdjustDrag { case none, move, resizeLeft, resizeRight, resizeTop, resizeBottom, resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight }
    private var adjustDrag: AdjustDrag = .none
    private var adjustStartPoint = CGPoint.zero
    private var adjustStartRect = CGRect.zero

    // MARK: - Annotation State

    private var capturedImage: NSImage?
    private var capturedCGImage: CGImage? // original cropped CGImage for display
    private var captureRectLocal: CGRect = .null // in view coords
    private var annotations: [AnnotationItem] = []
    private var currentTool: AnnotationTool = .arrow
    private var currentColor: NSColor = .red
    private var inProgressItem: AnnotationItem?
    private var numberCounter = 0
    private var selectedAnnotationIndex: Int?
    private var mosaicCache: [String: NSImage] = [:]
    private let ciContext = CIContext()
    private var activeTextField: NSTextField?

    // MARK: - Long Screenshot Mode

    private var longScreenshotGlobalRect: CGRect = .null

    func enterLongScreenshotMode(globalRect: CGRect) {
        self.longScreenshotGlobalRect = globalRect
        mode = .longScreenshotting
        hideTooltip()
        tooltipTargetID = nil
        needsDisplay = true
    }

    func exitLongScreenshotMode() {
        mode = .selecting
        selectionStart = .zero
        selectionRect = .null
        highlightedWindowRect = nil
        isSelecting = false
        needsDisplay = true
    }

    // MARK: - Selection Move / Resize in Annotation Mode

    private var canMoveSelection = true

    private enum AnnDrag { case none, move, resizeLeft, resizeRight, resizeTop, resizeBottom, resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight }
    private var annDrag: AnnDrag = .none
    private var annDragStart = CGPoint.zero
    private var annDragStartRect = CGRect.zero

    /// Snap a point to the pixel grid of the current display to avoid sub-pixel
    /// interpolation (drawn image jitter / blur).
    private func alignToPixelGrid(_ point: CGPoint) -> CGPoint {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let unit = 1.0 / scale
        return CGPoint(
            x: round(point.x / unit) * unit,
            y: round(point.y / unit) * unit
        )
    }

    // MARK: - Toolbar Layout

    private struct ToolbarLayout {
        static let height: CGFloat = 36
        static let pad: CGFloat = 4
        static let toolSize = CGSize(width: 30, height: 26)
        static let swatchSize = CGSize(width: 16, height: 16)
        static let actionWidth: CGFloat = 36
        static let sepW: CGFloat = 12 // space around separator

        static let toolIDs: [(AnnotationTool, String)] = [
            (.rectangle, "rectangle"),
            (.ellipse, "circle"),
            (.highlight, "sun.max"),
            (.arrow, "arrow.up.right"),
            (.mosaic, "square.grid.3x3.fill"),
            (.text, "textformat"),
            (.number, "textformat.123"),
        ]

        static let swatchColors: [NSColor] = [
            .red, .systemOrange, .systemYellow, .systemGreen,
            .systemCyan, .systemBlue, .systemPurple, .white, .black,
        ]

        static let actionIDs: [(String, String)] = [
            ("undo", "arrow.uturn.backward"),
            ("save", "arrow.down.to.line"),
            ("copy", "doc.on.doc"),
            ("pin", "pin"),
            ("cancel", "xmark"),
        ]

        static func totalWidth() -> CGFloat {
            let toolsW = CGFloat(toolIDs.count) * toolSize.width + CGFloat(toolIDs.count - 1) * pad
            let swatchesW = CGFloat(swatchColors.count) * swatchSize.width + CGFloat(swatchColors.count - 1) * 4
            let actionsW = CGFloat(actionIDs.count) * actionWidth + CGFloat(actionIDs.count - 1) * pad
            return toolsW + sepW + swatchesW + sepW + actionsW + pad * 2
        }
    }

    private var toolbarGlobalRect: CGRect = .null
    private var toolbarHitRects: [String: CGRect] = [:]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        layer?.contentsScale = maxScale
        layer?.backgroundColor = NSColor.clear.cgColor
        updateTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateTrackingArea() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    // MARK: - Enter Annotation Mode

    func enterAnnotationMode(image: NSImage, globalRect: CGRect, canMove: Bool = true) {
        enterAnnotationMode(image: image, cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil), globalRect: globalRect, canMove: canMove)
    }

    func enterAnnotationMode(image: NSImage, cgImage: CGImage?, globalRect: CGRect, canMove: Bool = true) {
        hideTooltip()
        tooltipTargetID = nil
        capturedImage = image
        capturedCGImage = cgImage
        annotationGlobalRect = globalRect
        captureRectLocal = CGRect(
            x: globalRect.origin.x - screenOffset.x,
            y: globalRect.origin.y - screenOffset.y,
            width: globalRect.width,
            height: globalRect.height
        )
        // Snap to pixel grid to avoid sub-pixel rendering jitter
        captureRectLocal.origin = alignToPixelGrid(captureRectLocal.origin)
        annotations = []
        currentTool = .arrow
        currentColor = .red
        numberCounter = 0
        selectedAnnotationIndex = nil
        inProgressItem = nil
        canMoveSelection = canMove
        annDrag = .none
        annDragStart = .zero
        annDragStartRect = .zero
        highlightedWindowRect = nil
        isSelecting = false
        selectionRect = .null
        mode = .annotating
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch mode {
        case .selecting:
            drawSelecting(ctx)
        case .adjusting:
            drawAdjusting(ctx)
        case .annotating:
            drawAnnotating(ctx)
        case .longScreenshotting:
            drawLongScreenshot(ctx)
        }
    }

    // MARK: - Selection Drawing

    private func drawSelecting(_ ctx: CGContext) {
        // Draw frozen background (full brightness) — pre-captured screenshot
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.draw(cgImage, in: localFrame)
        }

        if !selectionRect.isNull && isSelecting {
            let r = selectionRect
            let outsideRects = [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: r.minY - bounds.minY),
                CGRect(x: bounds.minX, y: r.minY, width: r.minX - bounds.minX, height: r.height),
                CGRect(x: r.maxX, y: r.minY, width: bounds.maxX - r.maxX, height: r.height),
                CGRect(x: bounds.minX, y: r.maxY, width: bounds.width, height: bounds.maxY - r.maxY),
            ]
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            for rect in outsideRects where rect.width > 0 && rect.height > 0 {
                ctx.fill(rect)
            }

            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)

            let w = Int(r.width)
            let h = Int(r.height)
            let dimText = "\(w) × \(h)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let textSize = (dimText as NSString).size(withAttributes: [.font: font])

            let labelPadding: CGFloat = 8
            var labelRect = CGRect(
                x: r.midX - (textSize.width + labelPadding * 2) / 2,
                y: r.maxY + 8,
                width: textSize.width + labelPadding * 2,
                height: textSize.height + 6
            )
            if labelRect.maxY > bounds.maxY - 4 {
                labelRect.origin.y = r.minY - labelRect.height - 4
            }

            let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
            NSColor.black.withAlphaComponent(0.65).setFill()
            bg.fill()

            let textPt = CGPoint(
                x: labelRect.midX - textSize.width / 2,
                y: labelRect.midY - textSize.height / 2
            )
            (dimText as NSString).draw(at: textPt, withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ])
        } else {
            // No selection yet — dim the entire screen
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fill(bounds)
        }

        // Highlighted window border
        if let hwRect = highlightedWindowRect {
            // CGWindow bounds Y is from top of primary display (top-left origin).
            // Convert to bottom-left: primaryHeight - cgY - cgH
            let primaryH = NSScreen.main?.frame.height ?? bounds.height
            let blY = primaryH - hwRect.origin.y - hwRect.height
            let localRect = CGRect(
                x: hwRect.origin.x - screenOffset.x,
                y: blY - screenOffset.y,
                width: hwRect.width,
                height: hwRect.height
            )
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
            ctx.setShadow(offset: .zero, blur: 8, color: NSColor.systemYellow.withAlphaComponent(0.5).cgColor)
            ctx.stroke(localRect)
        }

        // Crosshair
        if !isSelecting {
            let mouseGlobal = NSEvent.mouseLocation
            let localPt = CGPoint(
                x: mouseGlobal.x - screenOffset.x,
                y: mouseGlobal.y - screenOffset.y
            )
            if bounds.contains(localPt) {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: localPt.x - 12, y: localPt.y))
                ctx.addLine(to: CGPoint(x: localPt.x + 12, y: localPt.y))
                ctx.move(to: CGPoint(x: localPt.x, y: localPt.y - 12))
                ctx.addLine(to: CGPoint(x: localPt.x, y: localPt.y + 12))
                ctx.strokePath()
            }
        }
    }

    // MARK: - Adjusting Drawing

    private func drawAdjusting(_ ctx: CGContext) {
        // Draw frozen background (full brightness)
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.draw(cgImage, in: localFrame)
        }

        let r = selectionRect

        // Dim outside the selected region
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: r.minY - bounds.minY),
            CGRect(x: bounds.minX, y: r.minY, width: r.minX - bounds.minX, height: r.height),
            CGRect(x: r.maxX, y: r.minY, width: bounds.maxX - r.maxX, height: r.height),
            CGRect(x: bounds.minX, y: r.maxY, width: bounds.width, height: bounds.maxY - r.maxY),
        ]
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect)
        }

        // Selection border
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)

        // Dimension label
        drawSelectionLabel(ctx, rect: r)

        // Resize handles
        let hs: CGFloat = 8
        let half = hs / 2
        let handlePts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for pt in handlePts {
            let hr = CGRect(x: pt.x - half, y: pt.y - half, width: hs, height: hs)
            ctx.fill(hr)
            ctx.stroke(hr)
        }
    }

    private func drawSelectionLabel(_ ctx: CGContext, rect r: CGRect) {
        let w = Int(r.width)
        let h = Int(r.height)
        let dimText = "\(w) × \(h)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textSize = (dimText as NSString).size(withAttributes: [.font: font])
        let labelPadding: CGFloat = 8
        var labelRect = CGRect(
            x: r.midX - (textSize.width + labelPadding * 2) / 2,
            y: r.maxY + 8,
            width: textSize.width + labelPadding * 2,
            height: textSize.height + 6
        )
        if labelRect.maxY > bounds.maxY - 4 {
            labelRect.origin.y = r.minY - labelRect.height - 4
        }
        let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bg.fill()
        let textPt = CGPoint(
            x: labelRect.midX - textSize.width / 2,
            y: labelRect.midY - textSize.height / 2
        )
        (dimText as NSString).draw(at: textPt, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
    }

    private func drawAnnotationHandles(_ ctx: CGContext, rect r: CGRect) {
        let hs: CGFloat = 8
        let half = hs / 2
        let handlePts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for pt in handlePts {
            let hr = CGRect(x: pt.x - half, y: pt.y - half, width: hs, height: hs)
            ctx.fill(hr)
            ctx.stroke(hr)
        }
    }

    // MARK: - Long Screenshot Drawing

    private func drawLongScreenshot(_ ctx: CGContext) {
        let r = longScreenshotGlobalRect

        // Dim outside the selection area (lighter dim so user can see context)
        let localRect = CGRect(
            x: r.origin.x - screenOffset.x,
            y: r.origin.y - screenOffset.y,
            width: r.width, height: r.height
        )
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: localRect.minY - bounds.minY),
            CGRect(x: bounds.minX, y: localRect.minY, width: localRect.minX - bounds.minX, height: localRect.height),
            CGRect(x: localRect.maxX, y: localRect.minY, width: bounds.maxX - localRect.maxX, height: localRect.height),
            CGRect(x: bounds.minX, y: localRect.maxY, width: bounds.width, height: bounds.maxY - localRect.maxY),
        ]
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect)
        }

        // Selection border
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(localRect)

        // Dimension label
        drawSelectionLabel(ctx, rect: localRect)
    }

    // MARK: - Annotation Drawing

    private func drawAnnotating(_ ctx: CGContext) {
        let cr = captureRectLocal

        // Draw frozen background with the selection rect clipped out,
        // so the captured image draws on a clean area with no sub-pixel ghosting
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.saveGState()
            ctx.addRect(localFrame)
            ctx.addRect(cr)
            ctx.clip(using: .evenOdd)
            ctx.draw(cgImage, in: localFrame)
            ctx.restoreGState()
        }

        // Dim everything outside the capture rect
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)

        // Draw dim around the capture rect (not over it)
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: cr.minY - bounds.minY), // bottom
            CGRect(x: bounds.minX, y: cr.minY, width: cr.minX - bounds.minX, height: cr.height), // left
            CGRect(x: cr.maxX, y: cr.minY, width: bounds.maxX - cr.maxX, height: cr.height), // right
            CGRect(x: bounds.minX, y: cr.maxY, width: bounds.width, height: bounds.maxY - cr.maxY), // top
        ]
        for r in outsideRects where r.width > 0 && r.height > 0 {
            ctx.fill(r)
        }

        // Draw captured image on the clean (clipped-out) area
        if let cgImg = capturedCGImage {
            ctx.draw(cgImg, in: cr)
        }

        // Draw highlight dimming (single pass for all highlight rects)
        drawHighlightDimming(ctx)

        // Show selection border, dimensions and resize handles when movable
        if canMoveSelection {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(cr)
            drawSelectionLabel(ctx, rect: cr)
            drawAnnotationHandles(ctx, rect: cr)
        }

        // Draw annotations
        for annotation in annotations {
            drawAnnotation(annotation, in: ctx)
        }
        if let inProgress = inProgressItem {
            drawAnnotation(inProgress, in: ctx)
        }

        // Draw selected annotation highlight
        if let selIdx = selectedAnnotationIndex, selIdx < annotations.count {
            let sel = annotations[selIdx]
            var highlightRect: CGRect?
            switch sel.tool {
            case .arrow:
                let start = imageToView(sel.startPoint)
                let end = imageToView(sel.endPoint)
                highlightRect = rectFromPoints(start, end).insetBy(dx: -6, dy: -6)
            case .mosaic:
                let origin = imageToView(sel.mosaicRect.origin)
                let size = CGSize(width: sel.mosaicRect.width, height: sel.mosaicRect.height)
                highlightRect = CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4)
            case .rectangle, .ellipse, .highlight:
                let start = imageToView(sel.startPoint)
                let end = imageToView(sel.endPoint)
                highlightRect = rectFromPoints(start, end).insetBy(dx: -6, dy: -6)
            case .text, .number, .select:
                break
            }
            if let hr = highlightRect {
                ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(hr)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // Draw toolbar
        drawToolbar(ctx)
    }

    private func drawAnnotation(_ annotation: AnnotationItem, in ctx: CGContext) {
        switch annotation.tool {
        case .arrow: drawArrow(annotation, in: ctx)
        case .text: drawText(annotation, in: ctx)
        case .number: drawNumber(annotation, in: ctx)
        case .mosaic: drawMosaic(annotation, in: ctx)
        case .rectangle: drawRectShape(annotation, in: ctx)
        case .ellipse: drawEllipseShape(annotation, in: ctx)
        case .highlight: drawHighlightShape(annotation, in: ctx)
        case .select: break
        }
    }

    // MARK: - Coordinate Helpers

    private func globalPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenOffset.x, y: local.y + screenOffset.y)
    }

    private func globalRect(_ local: CGRect) -> CGRect {
        CGRect(
            x: local.origin.x + screenOffset.x,
            y: local.origin.y + screenOffset.y,
            width: local.width,
            height: local.height
        )
    }

    /// Convert from view coordinates to image-relative coordinates (bottom-left).
    private func viewToImage(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: viewPoint.x - captureRectLocal.origin.x,
            y: viewPoint.y - captureRectLocal.origin.y
        )
    }

    /// Convert from image-relative coordinates to view coordinates.
    private func imageToView(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: imagePoint.x + captureRectLocal.origin.x,
            y: imagePoint.y + captureRectLocal.origin.y
        )
    }

    // MARK: - Arrow Drawing

    private func drawArrow(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        let color = annotation.color

        let angle = atan2(end.y - start.y, end.x - start.x)
        let len: CGFloat = 16
        let spread: CGFloat = .pi / 8

        // Arrowhead points (base midpoint is len*cos(spread) before end)
        let p1 = CGPoint(x: end.x - len * cos(angle - spread),
                         y: end.y - len * sin(angle - spread))
        let p2 = CGPoint(x: end.x - len * cos(angle + spread),
                         y: end.y - len * sin(angle + spread))

        // Line stops at arrowhead base
        let inset = len * cos(spread)
        let lineEnd = CGPoint(x: end.x - inset * cos(angle),
                              y: end.y - inset * sin(angle))

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: start)
        ctx.addLine(to: lineEnd)
        ctx.strokePath()

        // Filled arrowhead
        let path = CGMutablePath()
        path.move(to: end)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()

        ctx.restoreGState()
    }

    // MARK: - Text Drawing

    private func drawText(_ annotation: AnnotationItem, in ctx: CGContext) {
        let point = imageToView(annotation.startPoint)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.fontSize),
            .foregroundColor: annotation.color,
        ]
        (annotation.text as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: - Number Drawing

    private func drawNumber(_ annotation: AnnotationItem, in ctx: CGContext) {
        let point = imageToView(annotation.startPoint)
        let radius: CGFloat = 14
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setFillColor(annotation.color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)

        let text = "\(annotation.number)"
        let font = NSFont.boldSystemFont(ofSize: 14)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let attrStr = NSAttributedString(string: text, attributes: textAttrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .excludeTypographicLeading)
        let textPoint = CGPoint(
            x: point.x - bounds.width / 2 - bounds.origin.x,
            y: point.y - bounds.midY
        )
        ctx.textPosition = textPoint
        CTLineDraw(line, ctx)
    }

    // MARK: - Mosaic Drawing

    private func drawRectShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        let rect = rectFromPoints(start, end)
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(rect)
    }

    private func drawEllipseShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        let rect = rectFromPoints(start, end)
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: rect)
    }

    private func drawHighlightDimming(_ ctx: CGContext) {
        let cr = captureRectLocal
        var rects: [CGRect] = annotations.filter { $0.tool == .highlight }.map {
            rectFromPoints(imageToView($0.startPoint), imageToView($0.endPoint)).intersection(cr)
        }.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }

        if let inProgress = inProgressItem, inProgress.tool == .highlight {
            let rect = rectFromPoints(imageToView(inProgress.startPoint), imageToView(inProgress.endPoint)).intersection(cr)
            if !rect.isNull && rect.width > 1 && rect.height > 1 {
                rects.append(rect)
            }
        }

        guard !rects.isEmpty else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        let path = CGMutablePath()
        path.addRect(cr)
        for rect in rects {
            path.addRect(rect)
        }
        ctx.addPath(path)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
    }

    private func drawHighlightShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        // Highlight dimming is handled globally in drawHighlightDimming
    }

    private func drawMosaic(_ annotation: AnnotationItem, in ctx: CGContext) {
        let rect = annotation.mosaicRect // bottom-left image coords
        let viewOrigin = imageToView(rect.origin)
        let viewRect = CGRect(origin: viewOrigin, size: rect.size)

        if viewRect.width < 2 || viewRect.height < 2 { return }

        // Flip Y to top-left for CGImage cropping
        let imageH = capturedImage?.size.height ?? rect.height
        let flippedRect = CGRect(
            x: rect.origin.x,
            y: imageH - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        guard let pixelated = pixelateRegion(flippedRect, pixelSize: annotation.pixelSize) else {
            ctx.setFillColor(NSColor.gray.cgColor)
            ctx.fill(viewRect)
            return
        }

        pixelated.draw(in: viewRect)
    }

    private func pixelateRegion(_ region: CGRect, pixelSize: Int) -> NSImage? {
        guard let image = capturedImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let scale = image.recommendedLayerContentsScale(0)
        let scaledRect = CGRect(
            x: region.origin.x * scale,
            y: region.origin.y * scale,
            width: region.width * scale,
            height: region.height * scale
        )

        guard let cropped = cgImage.cropping(to: scaledRect) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(Float(pixelSize), 1), forKey: kCIInputScaleKey)

        guard let output = filter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: region.size)
        result.addRepresentation(rep)
        return result
    }

    /// Render pixelated region directly to CGImage (avoids NSImage/NSGraphicsContext in export).
    private func pixelatedCGImage(region: CGRect, pixelSize: Int) -> CGImage? {
        guard let baseCG = capturedCGImage else { return nil }
        let imgW = capturedImage?.size.width ?? CGFloat(baseCG.width)
        let imgH = capturedImage?.size.height ?? CGFloat(baseCG.height)
        let scaleX = CGFloat(baseCG.width) / max(imgW, 1)
        let scaleY = CGFloat(baseCG.height) / max(imgH, 1)
        let scaledRect = CGRect(
            x: region.origin.x * scaleX,
            y: region.origin.y * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        )
        guard let cropped = baseCG.cropping(to: scaledRect) else { return nil }
        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(Float(pixelSize), 1), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: - Toolbar Drawing

    private func drawToolbar(_ ctx: CGContext) {
        let cr = captureRectLocal
        let tH = ToolbarLayout.height
        let tW = ToolbarLayout.totalWidth()

        // Position below capture rect, centered
        var tX = cr.midX - tW / 2
        var tY = cr.minY - tH - 8
        if tY < bounds.minY + 4 { tY = cr.maxY + 8 }
        if tY + tH > bounds.maxY - 4 { tY = bounds.maxY - tH - 8 }
        tX = max(bounds.minX + 4, min(tX, bounds.maxX - tW - 4))

        toolbarGlobalRect = CGRect(x: tX, y: tY, width: tW, height: tH)
        toolbarHitRects = [:]

        // Background
        let bg = NSBezierPath(roundedRect: toolbarGlobalRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        bg.fill()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(0.5)
        bg.stroke()

        let pad = ToolbarLayout.pad
        var curX = tX + pad

        // --- Tool buttons ---
        let whiteConfig = NSImage.SymbolConfiguration(paletteColors: [NSColor.white])

        // Pre-render custom tool icons
        let textImg: NSImage? = {
            let s = ToolbarLayout.toolSize
            let i = NSImage(size: NSSize(width: s.width - 8, height: s.height - 6), flipped: true) { _ in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: round(s.height * 0.65)),
                    .foregroundColor: NSColor.white,
                ]
                let str = "A" as NSString
                let strSize = str.size(withAttributes: attrs)
                str.draw(at: CGPoint(x: ((s.width - 8) - strSize.width) / 2, y: ((s.height - 6) - strSize.height) / 2), withAttributes: attrs)
                return true
            }
            return i
        }()
        let mosaicImg: NSImage? = {
            let s = ToolbarLayout.toolSize
            let i = NSImage(size: NSSize(width: s.width - 8, height: s.height - 8), flipped: true) { _ in
                guard let c = NSGraphicsContext.current?.cgContext else { return false }
                let cw = (s.width - 14) / 4
                let ch = (s.height - 14) / 4
                for row in 0..<4 {
                    for col in 0..<4 {
                        let rr = CGRect(x: 3 + CGFloat(col) * cw, y: 3 + CGFloat(row) * ch, width: cw, height: ch)
                        let fill: CGFloat = ((row + col) % 3 == 0) ? 0.7 : ((row + col) % 3 == 1) ? 0.4 : 0.2
                        c.setFillColor(NSColor.white.withAlphaComponent(fill).cgColor)
                        c.fill(rr)
                        c.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
                        c.setLineWidth(0.5)
                        c.stroke(rr)
                    }
                }
                return true
            }
            return i
        }()
        let numberImg: NSImage? = {
            let s = ToolbarLayout.toolSize
            let side = min(s.width, s.height) - 8
            let imgSize = NSSize(width: side, height: side)
            let i = NSImage(size: imgSize, flipped: true) { _ in
                guard let c = NSGraphicsContext.current?.cgContext else { return false }
                let r = CGRect(origin: .zero, size: imgSize).insetBy(dx: 2, dy: 2)
                c.setStrokeColor(NSColor.white.cgColor)
                c.setLineWidth(1.5)
                c.strokeEllipse(in: r)

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: round(side * 0.55)),
                    .foregroundColor: NSColor.white,
                ]
                let num = "1" as NSString
                let numSize = num.size(withAttributes: attrs)
                num.draw(at: CGPoint(
                    x: (imgSize.width - numSize.width) / 2,
                    y: (imgSize.height - numSize.height) / 2
                ), withAttributes: attrs)
                return true
            }
            return i
        }()

        for (tool, symbol) in ToolbarLayout.toolIDs {
            let rect = CGRect(
                x: curX, y: tY + (tH - ToolbarLayout.toolSize.height) / 2,
                width: ToolbarLayout.toolSize.width, height: ToolbarLayout.toolSize.height
            )
            toolbarHitRects["tool_\(tool.rawValue)"] = rect

            if tool == currentTool && !canMoveSelection {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
                let sel = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                sel.fill()
            }

            if tool == .text {
                textImg?.draw(in: rect.insetBy(dx: 4, dy: 3))
            } else if tool == .mosaic {
                mosaicImg?.draw(in: rect.insetBy(dx: 4, dy: 3))
            } else if tool == .number {
                let drawRect = rect.insetBy(dx: 4, dy: 3)
                let side = min(drawRect.width, drawRect.height)
                let centered = CGRect(
                    x: drawRect.midX - side / 2,
                    y: drawRect.midY - side / 2,
                    width: side,
                    height: side
                )
                numberImg?.draw(in: centered)
            } else {
                let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(whiteConfig)
                img?.draw(in: rect.insetBy(dx: 4, dy: 3))
            }

            curX = rect.maxX + pad
        }

        // Separator
        curX += ToolbarLayout.sepW / 2
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        ctx.fill(CGRect(x: curX, y: tY + 7, width: 1, height: tH - 14))
        curX += ToolbarLayout.sepW / 2

        // --- Color swatches ---
        for (i, color) in ToolbarLayout.swatchColors.enumerated() {
            let rect = CGRect(
                x: curX, y: tY + (tH - ToolbarLayout.swatchSize.height) / 2,
                width: ToolbarLayout.swatchSize.width, height: ToolbarLayout.swatchSize.height
            )
            toolbarHitRects["color_\(i)"] = rect

            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: rect)

            if color == currentColor {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            } else {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
                ctx.setLineWidth(0.5)
                ctx.strokeEllipse(in: rect)
            }

            curX = rect.maxX + 4
        }

        // Separator
        curX += ToolbarLayout.sepW / 2
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
        ctx.fill(CGRect(x: curX, y: tY + 7, width: 1, height: tH - 14))
        curX += ToolbarLayout.sepW / 2

        // --- Action buttons ---
        for (id, symbol) in ToolbarLayout.actionIDs {
            let rect = CGRect(
                x: curX, y: tY + (tH - ToolbarLayout.toolSize.height) / 2,
                width: ToolbarLayout.actionWidth, height: ToolbarLayout.toolSize.height
            )
            toolbarHitRects[id] = rect

            let tint = NSColor.white
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            let iconSize = min(rect.width, rect.height) - 8
            let iconRect = CGRect(
                x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2,
                width: iconSize, height: iconSize
            )
            img?.draw(in: iconRect)

            curX = rect.maxX + pad
        }
    }

    private var tooltipLabel: NSTextField?
    private var tooltipTargetID: String?

    private func showTooltip(for id: String, buttonRect: CGRect) {
        let tips: [String: String] = [
            "tool_0": "箭头", "tool_1": "文字", "tool_2": "编号",
            "tool_3": "马赛克", "tool_4": "矩形", "tool_5": "椭圆", "tool_6": "高亮",
            "undo": "撤销", "save": "保存", "copy": "复制",
            "pin": "固定", "cancel": "取消",
        ]
        guard let text = tips[id] else { hideTooltip(); return }

        let label: NSTextField
        if let existing = tooltipLabel {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 14)
            label.textColor = NSColor.white
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            label.layer?.cornerRadius = 4
            label.alignment = .center
            addSubview(label)
            tooltipLabel = label
        }

        label.stringValue = text
        label.sizeToFit()

        let padding: CGFloat = 8
        let labelW = label.frame.width + padding * 2
        let labelH = label.frame.height + padding
        let x = buttonRect.midX - labelW / 2
        let y = buttonRect.minY - labelH - 6
        label.frame = CGRect(x: x, y: y, width: labelW, height: labelH)

        label.isHidden = false
    }

    private func hideTooltip() {
        tooltipLabel?.isHidden = true
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseDownSelecting(event)
        case .adjusting:
            mouseDownAdjusting(event)
        case .annotating:
            mouseDownAnnotating(event)
        case .longScreenshotting:
            break // ignored — overlay window has ignoresMouseEvents = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseDraggedSelecting(event)
        case .adjusting:
            mouseDraggedAdjusting(event)
        case .annotating:
            mouseDraggedAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseUpSelecting(event)
        case .adjusting:
            mouseUpAdjusting(event)
        case .annotating:
            mouseUpAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseMovedSelecting(event)
        case .adjusting:
            mouseMovedAdjusting(event)
        case .annotating:
            mouseMovedAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    // MARK: - Frozen Background Cropping

    private func croppedImage(from globalRect: CGRect) -> (NSImage, CGSize, CGImage)? {
        for (cgImage, screenFrame) in frozenBackgrounds {
            let inter = screenFrame.intersection(globalRect)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }

            let scale = CGFloat(cgImage.width) / screenFrame.width
            let originX = round((inter.origin.x - screenFrame.origin.x) * scale)
            let originY = round(CGFloat(cgImage.height) - (inter.origin.y - screenFrame.origin.y + inter.height) * scale)
            let cropW = round(inter.width * scale)
            let cropH = round(inter.height * scale)
            let cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)

            guard let cropped = cgImage.cropping(to: cropRect) else { continue }
            capturedCGImage = cropped
            let adjustedSize = NSSize(width: cropW / scale, height: cropH / scale)
            return (NSImage(cgImage: cropped, size: adjustedSize), adjustedSize, cropped)
        }
        capturedCGImage = nil
        return nil
    }

    // MARK: - Selection Mouse Events

    private func mouseDownSelecting(_ event: NSEvent) {
        let pt = event.locationInWindow
        NSLog("[ScreenshotTool] mouseDown pt=\(pt) isSelecting=\(isSelecting)")

        if isSelecting { return }
        isSelecting = true
        selectionStart = pt
        selectionRect = CGRect(origin: pt, size: .zero)
        highlightedWindowRect = nil
    }

    private func mouseDraggedSelecting(_ event: NSEvent) {
        guard isSelecting else { return }
        let pt = event.locationInWindow
        selectionRect = CGRect(
            x: min(selectionStart.x, pt.x),
            y: min(selectionStart.y, pt.y),
            width: abs(pt.x - selectionStart.x),
            height: abs(pt.y - selectionStart.y)
        )
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseUpSelecting(_ event: NSEvent) {
        guard isSelecting else { return }
        isSelecting = false

        if selectionRect.width >= 10 && selectionRect.height >= 10 {
            confirmSelection()
        } else {
            let globalPt = globalPoint(event.locationInWindow)
            if let winInfo = WindowDetector.windowInfoAtPoint(globalPt, excluding: window?.windowNumber) {
                onSelectionComplete?(.window(winInfo.rect, windowNumber: winInfo.windowNumber))
            } else {
                onSelectionComplete?(.cancel)
            }
            selectionRect = .null
            needsDisplay = true
        }
    }

    private func mouseMovedSelecting(_ event: NSEvent) {
        guard !isSelecting else { return }
        NSCursor.crosshair.set()

        let globalPt = globalPoint(event.locationInWindow)
        if let winRect = WindowDetector.windowAtPoint(globalPt, excluding: window?.windowNumber) {
            if highlightedWindowRect != winRect {
                highlightedWindowRect = winRect
                needsDisplay = true
            }
        } else {
            if highlightedWindowRect != nil {
                highlightedWindowRect = nil
                needsDisplay = true
            }
        }
    }

    // MARK: - Adjusting Mouse Events

    private func mouseDownAdjusting(_ event: NSEvent) {
        let pt = event.locationInWindow
        if event.clickCount >= 2 { confirmSelection(); return }

        // Check handle hit
        let action = hitTestAdjustHandle(at: pt)
        if action != .none {
            adjustDrag = action
            adjustStartPoint = pt
            adjustStartRect = selectionRect
            return
        }

        // Inside selection → move
        if selectionRect.contains(pt) {
            adjustDrag = .move
            adjustStartPoint = pt
            adjustStartRect = selectionRect
            return
        }

        // Clicked outside → start new selection
        cancelAdjusting()
        mode = .selecting
        isSelecting = true
        selectionStart = pt
        selectionRect = CGRect(origin: pt, size: .zero)
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseDraggedAdjusting(_ event: NSEvent) {
        switch adjustDrag {
        case .none:
            return
        case .move:
            let pt = event.locationInWindow
            let delta = CGPoint(x: pt.x - adjustStartPoint.x, y: pt.y - adjustStartPoint.y)
            var r = adjustStartRect
            r.origin.x = max(bounds.minX, min(adjustStartRect.origin.x + delta.x, bounds.maxX - adjustStartRect.width))
            r.origin.y = max(bounds.minY, min(adjustStartRect.origin.y + delta.y, bounds.maxY - adjustStartRect.height))
            selectionRect = r
        default:
            resizeSelection(with: event.locationInWindow)
        }
        needsDisplay = true
    }

    private func mouseUpAdjusting(_ event: NSEvent) {
        adjustDrag = .none
        adjustStartPoint = .zero
        adjustStartRect = .zero
    }

    private func mouseMovedAdjusting(_ event: NSEvent) {
        let pt = event.locationInWindow

        // Over a handle
        let action = hitTestAdjustHandle(at: pt)
        if action != .none {
            switch action {
            case .resizeLeft, .resizeRight: NSCursor.resizeLeftRight.set()
            case .resizeTop, .resizeBottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
            return
        }

        // Over the selection
        if selectionRect.contains(pt) {
            NSCursor.openHand.set()
            return
        }

        NSCursor.crosshair.set()
    }

    private func hitTestAdjustHandle(at point: CGPoint) -> AdjustDrag {
        let hs: CGFloat = 12 // wider hit area
        let half = hs / 2
        let r = selectionRect
        let handles: [(CGRect, AdjustDrag)] = [
            (CGRect(x: r.minX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomLeft),
            (CGRect(x: r.midX - half, y: r.minY - half, width: hs, height: hs), .resizeBottom),
            (CGRect(x: r.maxX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomRight),
            (CGRect(x: r.maxX - half, y: r.midY - half, width: hs, height: hs), .resizeRight),
            (CGRect(x: r.maxX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopRight),
            (CGRect(x: r.midX - half, y: r.maxY - half, width: hs, height: hs), .resizeTop),
            (CGRect(x: r.minX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopLeft),
            (CGRect(x: r.minX - half, y: r.midY - half, width: hs, height: hs), .resizeLeft),
        ]
        for (rect, action) in handles where rect.contains(point) {
            return action
        }
        return .none
    }

    private func resizeSelection(with point: CGPoint) {
        let minSize: CGFloat = 10
        let start = adjustStartRect
        let clamped = CGPoint(x: max(bounds.minX, min(point.x, bounds.maxX)),
                              y: max(bounds.minY, min(point.y, bounds.maxY)))

        var newMinX = start.minX, newMinY = start.minY
        var newMaxX = start.maxX, newMaxY = start.maxY

        switch adjustDrag {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            newMinX = min(start.maxX - minSize, clamped.x)
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            newMaxX = max(start.minX + minSize, clamped.x)
        default:
            break
        }
        switch adjustDrag {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            newMinY = min(start.maxY - minSize, clamped.y)
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            newMaxY = max(start.minY + minSize, clamped.y)
        default:
            break
        }

        selectionRect = CGRect(x: newMinX, y: newMinY,
                               width: newMaxX - newMinX,
                               height: newMaxY - newMinY)
    }

    private func confirmSelection() {
        guard selectionRect.width >= 10 && selectionRect.height >= 10 else { return }
        let globalSel = globalRect(selectionRect)
        adjustDrag = .none
        selectionRect = .null
        needsDisplay = true

        if !frozenBackgrounds.isEmpty, let (image, adjustedSize, originalCG) = croppedImage(from: globalSel) {
            let adjustedGlobalRect = CGRect(
                x: globalSel.midX - adjustedSize.width / 2,
                y: globalSel.midY - adjustedSize.height / 2,
                width: adjustedSize.width,
                height: adjustedSize.height
            )
            // Pass the original cropped CGImage directly to avoid NSImage → CGImage round-trip
            // which can lose Retina scale info and cause blurry text.
            enterAnnotationMode(image: image, cgImage: originalCG, globalRect: adjustedGlobalRect)
        } else {
            onSelectionComplete?(.capture(globalSel))
        }
    }

    private func cancelAdjusting() {
        adjustDrag = .none
        adjustStartPoint = .zero
        adjustStartRect = .zero
        mode = .selecting
        isSelecting = false
        selectionRect = .null
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseMovedAnnotating(_ event: NSEvent) {
        let pt = event.locationInWindow

        if let hitID = hitTestToolbar(pt) {
            NSCursor.pointingHand.set()
            if hitID != tooltipTargetID {
                tooltipTargetID = hitID
                if let rect = toolbarHitRects[hitID] {
                    showTooltip(for: hitID, buttonRect: rect)
                }
            }
        } else {
            if tooltipTargetID != nil {
                tooltipTargetID = nil
                hideTooltip()
            }
            if canMoveSelection {
                // Check handle cursor first
                let handleHit = hitTestAnnHandle(at: pt, rect: captureRectLocal)
                switch handleHit {
                case .resizeLeft, .resizeRight: NSCursor.resizeLeftRight.set()
                case .resizeTop, .resizeBottom: NSCursor.resizeUpDown.set()
                case .resizeTopLeft, .resizeBottomRight, .resizeTopRight, .resizeBottomLeft: NSCursor.crosshair.set()
                default:
                    if captureRectLocal.contains(pt) {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            } else if captureRectLocal.contains(pt) {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - Annotation Mouse Events

    private var imageBounds: CGRect {
        CGRect(origin: .zero, size: captureRectLocal.size)
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(point.x, imageBounds.width)),
            y: max(0, min(point.y, imageBounds.height))
        )
    }

    private func mouseDownAnnotating(_ event: NSEvent) {
        let viewPt = event.locationInWindow

        // Check toolbar hit first
        if let hitID = hitTestToolbar(viewPt) {
            handleToolbarAction(hitID)
            return
        }

        if canMoveSelection {
            // Check resize handle hit first (handles may be outside captureRectLocal)
            let handleHit = hitTestAnnHandle(at: viewPt, rect: captureRectLocal)
            if handleHit != .none {
                annDrag = handleHit
                annDragStart = viewPt
                annDragStartRect = captureRectLocal
                return
            }
            // Inside selection → move
            if captureRectLocal.contains(viewPt) {
                annDrag = .move
                annDragStart = viewPt
                annDragStartRect = captureRectLocal
                return
            }
            // Clicked outside → ignore
            return
        }

        guard captureRectLocal.contains(viewPt) else { return }

        let imagePt = viewToImage(viewPt)

        switch currentTool {
        case .arrow:
            let pt = clampToImage(imagePt)
            inProgressItem = AnnotationItem.arrow(start: pt, end: pt, color: currentColor)

        case .mosaic:
            inProgressItem = AnnotationItem.mosaic(rect: CGRect(origin: clampToImage(imagePt), size: .zero))

        case .text:
            showTextField(at: imagePt)

        case .number:
            numberCounter += 1
            let item = AnnotationItem.number(point: imagePt, number: numberCounter, color: currentColor)
            addAnnotation(item)

        case .rectangle, .ellipse, .highlight:
            let pt = clampToImage(imagePt)
            inProgressItem = AnnotationItem(tool: currentTool, color: currentColor, lineWidth: 3, startPoint: pt, endPoint: pt)

        case .select:
            selectedAnnotationIndex = nil
            for (i, ann) in annotations.enumerated().reversed() {
                if hitTestAnnotation(ann, at: imagePt) {
                    selectedAnnotationIndex = i
                    break
                }
            }
            needsDisplay = true
        }
    }

    private func mouseDraggedAnnotating(_ event: NSEvent) {
        // Handle selection resize / move when canMoveSelection
        if annDrag != .none {
            let pt = event.locationInWindow
            switch annDrag {
            case .move:
                let delta = CGPoint(x: pt.x - annDragStart.x, y: pt.y - annDragStart.y)
                var newOrigin = CGPoint(
                    x: annDragStartRect.origin.x + delta.x,
                    y: annDragStartRect.origin.y + delta.y
                )
                newOrigin = alignToPixelGrid(newOrigin)
                newOrigin.x = max(bounds.minX, min(newOrigin.x, bounds.maxX - captureRectLocal.width))
                newOrigin.y = max(bounds.minY, min(newOrigin.y, bounds.maxY - captureRectLocal.height))
                captureRectLocal.origin = newOrigin
                annotationGlobalRect = CGRect(
                    origin: CGPoint(x: newOrigin.x + screenOffset.x, y: newOrigin.y + screenOffset.y),
                    size: annotationGlobalRect.size
                )
                recaptureAnnotationImage()
            default:
                resizeAnnotationRect(to: pt)
            }
            needsDisplay = true
            return
        }
        guard var inProgress = inProgressItem else { return }
        let viewPt = event.locationInWindow
        let imagePt = viewToImage(viewPt)

        switch currentTool {
        case .arrow:
            inProgress.endPoint = clampToImage(imagePt)
            inProgressItem = inProgress
            needsDisplay = true

        case .mosaic:
            let clamped = clampToImage(imagePt)
            let origin = CGPoint(x: min(inProgress.startPoint.x, clamped.x),
                                 y: min(inProgress.startPoint.y, clamped.y))
            let size = CGSize(width: abs(clamped.x - inProgress.startPoint.x),
                              height: abs(clamped.y - inProgress.startPoint.y))
            inProgress.mosaicRect = CGRect(origin: origin, size: size)
            inProgressItem = inProgress
            needsDisplay = true

        case .rectangle, .ellipse, .highlight:
            inProgress.endPoint = clampToImage(imagePt)
            inProgressItem = inProgress
            needsDisplay = true

        default:
            break
        }
    }

    private func mouseUpAnnotating(_ event: NSEvent) {
        if annDrag != .none {
            annDrag = .none
            annDragStart = .zero
            annDragStartRect = .zero
            return
        }
        guard let inProgress = inProgressItem else { return }

        switch currentTool {
        case .arrow:
            let dist = hypot(inProgress.endPoint.x - inProgress.startPoint.x,
                             inProgress.endPoint.y - inProgress.startPoint.y)
            if dist > 5 { addAnnotation(inProgress) }

        case .mosaic:
            if inProgress.mosaicRect.width >= 5 && inProgress.mosaicRect.height >= 5 {
                addAnnotation(inProgress)
            }

        case .rectangle, .ellipse, .highlight:
            let dist = hypot(inProgress.endPoint.x - inProgress.startPoint.x,
                             inProgress.endPoint.y - inProgress.startPoint.y)
            if dist > 5 { addAnnotation(inProgress) }

        default:
            break
        }

        inProgressItem = nil
        needsDisplay = true
    }

    // MARK: - Annotation Resize Helpers

    private func hitTestAnnHandle(at point: CGPoint, rect r: CGRect) -> AnnDrag {
        let hs: CGFloat = 12
        let half = hs / 2
        let handles: [(CGRect, AnnDrag)] = [
            (CGRect(x: r.minX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomLeft),
            (CGRect(x: r.midX - half, y: r.minY - half, width: hs, height: hs), .resizeBottom),
            (CGRect(x: r.maxX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomRight),
            (CGRect(x: r.maxX - half, y: r.midY - half, width: hs, height: hs), .resizeRight),
            (CGRect(x: r.maxX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopRight),
            (CGRect(x: r.midX - half, y: r.maxY - half, width: hs, height: hs), .resizeTop),
            (CGRect(x: r.minX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopLeft),
            (CGRect(x: r.minX - half, y: r.midY - half, width: hs, height: hs), .resizeLeft),
        ]
        for (rect, action) in handles where rect.contains(point) {
            return action
        }
        return .none
    }

    private func resizeAnnotationRect(to point: CGPoint) {
        let minSize: CGFloat = 20
        let start = annDragStartRect
        let clamped = CGPoint(x: max(bounds.minX, min(point.x, bounds.maxX)),
                              y: max(bounds.minY, min(point.y, bounds.maxY)))

        var newMinX = start.minX, newMinY = start.minY
        var newMaxX = start.maxX, newMaxY = start.maxY

        switch annDrag {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            newMinX = min(start.maxX - minSize, clamped.x)
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            newMaxX = max(start.minX + minSize, clamped.x)
        default:
            break
        }
        switch annDrag {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            newMinY = min(start.maxY - minSize, clamped.y)
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            newMaxY = max(start.minY + minSize, clamped.y)
        default:
            break
        }

        let newRect = CGRect(x: newMinX, y: newMinY,
                            width: newMaxX - newMinX,
                            height: newMaxY - newMinY)
        let alignedOrigin = alignToPixelGrid(newRect.origin)
        let alignedRect = CGRect(origin: alignedOrigin, size: newRect.size)
        captureRectLocal = alignedRect
        annotationGlobalRect = CGRect(
            origin: CGPoint(x: alignedRect.origin.x + screenOffset.x, y: alignedRect.origin.y + screenOffset.y),
            size: CGSize(width: alignedRect.width, height: alignedRect.height)
        )

        // Recapture image from frozen background at the new rect
        recaptureAnnotationImage()
    }

    private func recaptureAnnotationImage() {
        guard !frozenBackgrounds.isEmpty else { return }
        let globalSel = annotationGlobalRect
        guard globalSel.width >= 10 && globalSel.height >= 10 else { return }
        if let (image, adjustedSize, originalCG) = croppedImage(from: globalSel) {
            capturedImage = image
            capturedCGImage = originalCG
            let adjustedOrigin = alignToPixelGrid(CGPoint(
                x: globalSel.midX - adjustedSize.width / 2,
                y: globalSel.midY - adjustedSize.height / 2
            ))
            captureRectLocal = CGRect(
                x: adjustedOrigin.x - screenOffset.x,
                y: adjustedOrigin.y - screenOffset.y,
                width: adjustedSize.width,
                height: adjustedSize.height
            )
            annotationGlobalRect = CGRect(
                origin: adjustedOrigin,
                size: adjustedSize
            )
        }
    }

    // MARK: - Toolbar Hit Testing

    private func hitTestToolbar(_ point: CGPoint) -> String? {
        for (id, rect) in toolbarHitRects where rect.contains(point) {
            return id
        }
        return nil
    }

    private func handleToolbarAction(_ id: String) {
        if id == "cancel" {
            onAnnotationCancel?()
            return
        }

        if id == "undo" {
            undoLast()
            return
        }

        if id == "longscreenshot" {
            onLongScreenshot?(annotationGlobalRect)
            return
        }

        if id == "save" {
            guard let image = renderedImage() else { return }
            // Lower level so save panel isn't blocked by overlay
            self.window?.level = .floating
            onAnnotationAction?(image, .save)
            // Don't close — App.swift will close on successful save
            return
        }

        if id == "copy" {
            guard let image = renderedImage() else { return }
            onAnnotationAction?(image, .copy)
            onAnnotationCancel?()
            return
        }

        if id == "pin" {
            guard let (cgImage, _, imageSize) = renderCGImage() else { return }
            onPinCGImage?(cgImage, imageSize, annotationGlobalRect)
            onAnnotationCancel?()
            return
        }

        // Tool selection
        if id.hasPrefix("tool_"), let raw = Int(id.replacingOccurrences(of: "tool_", with: "")),
           let tool = AnnotationTool(rawValue: raw) {
            currentTool = tool
            canMoveSelection = false
            needsDisplay = true
            return
        }

        // Color selection
        if id.hasPrefix("color_"), let idx = Int(id.replacingOccurrences(of: "color_", with: "")) {
            let colors: [NSColor] = [
                .red, .systemOrange, .systemYellow, .systemGreen,
                .systemCyan, .systemBlue, .systemPurple, .white, .black,
            ]
            if idx < colors.count {
                currentColor = colors[idx]
                needsDisplay = true
            }
        }
    }

    // MARK: - Hit Testing (for select tool)

    private func hitTestAnnotation(_ annotation: AnnotationItem, at point: CGPoint) -> Bool {
        let tolerance: CGFloat = 15
        switch annotation.tool {
        case .arrow:
            return distanceToLine(point, annotation.startPoint, annotation.endPoint) < tolerance
        case .text:
            let size = (annotation.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)])
            let rect = CGRect(origin: annotation.startPoint, size: size).insetBy(dx: -4, dy: -4)
            return rect.contains(point)
        case .number:
            return hypot(point.x - annotation.startPoint.x, point.y - annotation.startPoint.y) < 16
        case .mosaic:
            return annotation.mosaicRect.insetBy(dx: -4, dy: -4).contains(point)
        case .rectangle, .ellipse, .highlight:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint).insetBy(dx: -6, dy: -6)
            return rect.contains(point)
        case .select:
            return false
        }
    }

    private func distanceToLine(_ point: CGPoint, _ lineStart: CGPoint, _ lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - lineStart.x, point.y - lineStart.y) }
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / (length * length)))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    // MARK: - Annotation Management

    private func addAnnotation(_ annotation: AnnotationItem) {
        annotations.append(annotation)
        canMoveSelection = false
        needsDisplay = true
    }

    private func undoLast() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if removed.tool == .number {
            numberCounter = max(0, numberCounter - 1)
        }
        needsDisplay = true
    }

    // MARK: - Text Field

    private func showTextField(at imagePoint: CGPoint) {
        activeTextField?.removeFromSuperview()
        let viewPoint = imageToView(imagePoint)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 200, height: 32))
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: 24)
        field.textColor = currentColor
        field.placeholderString = "输入文字..."
        field.target = self
        field.action = #selector(textFieldDoneEditing(_:))
        addSubview(field)
        field.becomeFirstResponder()
        activeTextField = field
    }

    @objc private func textFieldDoneEditing(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let imagePt = viewToImage(sender.frame.origin)
            let item = AnnotationItem.text(point: imagePt, text: text, color: currentColor)
            addAnnotation(item)
        }
        sender.removeFromSuperview()
        activeTextField = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if mode == .longScreenshotting { return }

        if mode == .adjusting {
            if event.keyCode == 53 { // Escape
                cancelAdjusting()
                return
            }
            if event.keyCode == 0x24 || event.keyCode == 0x4C { // Return / Enter
                confirmSelection()
                return
            }
        }

        if event.keyCode == 53 { // Escape
            if mode == .annotating {
                if activeTextField != nil {
                    activeTextField?.removeFromSuperview()
                    activeTextField = nil
                    window?.makeFirstResponder(self)
                    return
                }
                if inProgressItem != nil || selectedAnnotationIndex != nil {
                    inProgressItem = nil
                    selectedAnnotationIndex = nil
                    needsDisplay = true
                    return
                }
                // Nothing active — dismiss overlay
                onAnnotationCancel?()
                return
            } else {
                // Selection mode
                onSelectionComplete?(.cancel)
                return
            }
        }
        if mode == .annotating && (event.keyCode == 51 || event.keyCode == 117) {
            if let selIdx = selectedAnnotationIndex, selIdx < annotations.count {
                annotations.remove(at: selIdx)
                selectedAnnotationIndex = nil
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Render Final Image

    /// Render the base image + annotations into a new CGImage at pixel resolution.
    /// Returns `(cgImage, pixelSize, pointSize)`.
    private func renderCGImage() -> (CGImage, NSSize, NSSize)? {
        guard let image = capturedImage else { return nil }
        let imageSize = image.size

        let baseCGImage: CGImage
        if let cap = capturedCGImage {
            baseCGImage = cap
        } else {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            baseCGImage = cg
        }

        let pixelW = baseCGImage.width
        let pixelH = baseCGImage.height

        let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? baseCGImage.colorSpace!
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: displayColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        let sx = CGFloat(pixelW) / imageSize.width
        let sy = CGFloat(pixelH) / imageSize.height
        ctx.saveGState()
        ctx.scaleBy(x: sx, y: sy)

        // Draw highlight dimming (single pass for all highlight rects, in image coords)
        let highlightRects = annotations.filter { $0.tool == .highlight }.map {
            rectFromPoints($0.startPoint, $0.endPoint)
        }.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
        if !highlightRects.isEmpty {
            let imageBounds = CGRect(origin: .zero, size: imageSize)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            let path = CGMutablePath()
            path.addRect(imageBounds)
            for rect in highlightRects {
                path.addRect(rect.intersection(imageBounds))
            }
            ctx.addPath(path)
            ctx.drawPath(using: .eoFill)
        }

        for annotation in annotations {
            switch annotation.tool {
            case .arrow, .text, .number, .mosaic, .rectangle, .ellipse:
                drawAnnotationFixed(annotation, in: ctx, imageSize: imageSize)
            case .highlight:
                break
            case .select:
                break
            }
        }
        ctx.restoreGState()

        guard let resultCGImage = ctx.makeImage() else { return nil }
        return (resultCGImage, NSSize(width: pixelW, height: pixelH), imageSize)
    }

    func renderedImage() -> NSImage? {
        guard let (resultCGImage, _, imageSize) = renderCGImage() else { return nil }

        // Use NSBitmapImageRep with explicit point-size so the
        // pixel-to-point ratio is correct for Retina displays.
        // NSImage(cgImage:size:) can create a mismatch between
        // the rep's size (pixelsWide ÷ 72dpi) and the image size,
        // causing NSView to apply extra interpolation on draw.
        let rep = NSBitmapImageRep(cgImage: resultCGImage)
        rep.size = imageSize
        let outputImage = NSImage(size: imageSize)
        outputImage.addRepresentation(rep)
        return outputImage
    }

    /// Draw an annotation in the export context (no transform, already flipped).
    private func drawAnnotationFixed(_ annotation: AnnotationItem, in ctx: CGContext, imageSize: CGSize) {
        switch annotation.tool {
        case .arrow:
            let start = annotation.startPoint
            let end = annotation.endPoint
            let color = annotation.color

            let angle = atan2(end.y - start.y, end.x - start.x)
            let len: CGFloat = 16
            let spread: CGFloat = .pi / 8

            let p1 = CGPoint(x: end.x - len * cos(angle - spread),
                             y: end.y - len * sin(angle - spread))
            let p2 = CGPoint(x: end.x - len * cos(angle + spread),
                             y: end.y - len * sin(angle + spread))
            let inset = len * cos(spread)
            let lineEnd = CGPoint(x: end.x - inset * cos(angle),
                                  y: end.y - inset * sin(angle))

            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: start)
            ctx.addLine(to: lineEnd)
            ctx.strokePath()

            let path = CGMutablePath()
            path.move(to: end)
            path.addLine(to: p1)
            path.addLine(to: p2)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.fontSize),
                .foregroundColor: annotation.color,
            ]
            let attrStr = NSAttributedString(string: annotation.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = annotation.startPoint
            CTLineDraw(line, ctx)

        case .number:
            let point = annotation.startPoint
            let radius: CGFloat = 14
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(annotation.color.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)

            let text = "\(annotation.number)"
            let font = NSFont.boldSystemFont(ofSize: 14)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let attrStr = NSAttributedString(string: text, attributes: textAttrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .excludeTypographicLeading)
            let textPoint = CGPoint(
                x: point.x - bounds.width / 2 - bounds.origin.x,
                y: point.y - bounds.midY
            )
            ctx.textPosition = textPoint
            CTLineDraw(line, ctx)

        case .mosaic:
            let viewRect = annotation.mosaicRect // bottom-left
            if viewRect.width < 2 || viewRect.height < 2 { return }
            // Flip Y for CGImage cropping (top-left origin)
            let cropRect = CGRect(x: viewRect.origin.x,
                                  y: imageSize.height - viewRect.origin.y - viewRect.height,
                                  width: viewRect.width, height: viewRect.height)
            guard let pixelatedCG = pixelatedCGImage(region: cropRect, pixelSize: annotation.pixelSize) else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(viewRect)
                return
            }
            ctx.draw(pixelatedCG, in: viewRect)

        case .rectangle:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint)
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(rect)

        case .ellipse:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint)
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)

        case .highlight:
            break

        case .select:
            break
        }
    }
}

// MARK: - Helper

private func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
           width: abs(a.x - b.x), height: abs(a.y - b.y))
}
