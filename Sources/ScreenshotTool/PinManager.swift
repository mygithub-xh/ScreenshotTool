import Cocoa

private class PinWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Draggable container for pinned image

private class PinContainerView: NSView {
    private let cgImage: CGImage?
    /// Logical point size of the image.
    private let imageSize: NSSize
    var closeButton: NSView?

    init(cgImage: CGImage?, imageSize: NSSize, frame: NSRect) {
        self.cgImage = cgImage
        self.imageSize = imageSize
        super.init(frame: frame)
        // Use the layer for rendering so we can set contentsScale
        // to match the window's backing scale factor.
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure the layer renders at the display's full resolution
        // (e.g. 2× for Retina) so the CGImage pixels map 1:1.
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgImage = cgImage,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let scale = layer?.contentsScale ?? window?.backingScaleFactor ?? 2.0
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let ptW = pixelW / scale
        let ptH = pixelH / scale

        // Center the image within the view bounds, maintaining aspect ratio
        let sc = min(bounds.width / max(ptW, 1), bounds.height / max(ptH, 1))
        let drawW = ptW * sc
        let drawH = ptH * sc
        let drawX = (bounds.width - drawW) / 2
        let drawY = (bounds.height - drawH) / 2
        let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

        // Disable interpolation so no blur is introduced when the
        // source pixel grid maps 1:1 to destination pixels.
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: drawRect)
    }

    override func layout() {
        super.layout()
        guard let btn = closeButton else { return }
        let sc = min(bounds.width / max(imageSize.width, 1),
                     bounds.height / max(imageSize.height, 1))
        let drawW = imageSize.width * sc
        let drawH = imageSize.height * sc
        let drawX = (bounds.width - drawW) / 2
        let drawY = (bounds.height - drawH) / 2
        let btnSize: CGFloat = 22
        btn.frame = NSRect(
            x: drawX + drawW - btnSize - 4,
            y: drawY + drawH - btnSize - 4,
            width: btnSize, height: btnSize
        )
    }
}

// MARK: - Custom close button

private class CloseButtonView: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillEllipse(in: bounds)

        let text = "✕" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 11),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                               y: bounds.midY - size.height / 2),
                  withAttributes: attrs)
    }
}

final class PinManager: NSObject {

    private var pinnedWindows: [NSWindow] = []

    func pin(cgImage: CGImage, imageSize: NSSize, at origin: CGPoint) {
        guard imageSize.width > 0 && imageSize.height > 0 else {
            NSLog("[ScreenshotTool] PinManager: skipping pin with zero-size image")
            return
        }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        var pos = origin
        let maxX = screenFrame.maxX - imageSize.width - 10
        let maxY = screenFrame.maxY - imageSize.height - 10
        if pos.x < screenFrame.minX { pos.x = screenFrame.minX + 10 }
        if pos.y < screenFrame.minY { pos.y = screenFrame.minY + 10 }
        if pos.x > maxX { pos.x = maxX }
        if pos.y > maxY { pos.y = maxY }

        let windowRect = NSRect(origin: pos, size: imageSize)

        let window = PinWindow(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 100, height: 100)

        let container = PinContainerView(
            cgImage: cgImage,
            imageSize: imageSize,
            frame: NSRect(origin: .zero, size: imageSize)
        )
        container.autoresizingMask = [.width, .height]

        let btnSize: CGFloat = 22
        let closeBtn = CloseButtonView(frame: NSRect(
            x: imageSize.width - btnSize - 4,
            y: imageSize.height - btnSize - 4,
            width: btnSize, height: btnSize
        ))
        closeBtn.autoresizingMask = [.minXMargin, .minYMargin]
        closeBtn.onClick = { [weak self] in
            guard let window = closeBtn.window else { return }
            self?.closeWindow(window)
        }
        container.closeButton = closeBtn
        container.addSubview(closeBtn)

        window.contentView = container
        window.orderFront(nil)
        pinnedWindows.append(window)

        NSLog("[ScreenshotTool] PinManager: pinned image at \(pos) size=\(imageSize)")
    }

    func pin(image: NSImage, at origin: CGPoint) {
        let imgSize = image.size
        guard imgSize.width > 0 && imgSize.height > 0 else {
            NSLog("[ScreenshotTool] PinManager: skipping pin with zero-size image")
            return
        }

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        var pos = origin
        let maxX = screenFrame.maxX - imgSize.width - 10
        let maxY = screenFrame.maxY - imgSize.height - 10
        if pos.x < screenFrame.minX { pos.x = screenFrame.minX + 10 }
        if pos.y < screenFrame.minY { pos.y = screenFrame.minY + 10 }
        if pos.x > maxX { pos.x = maxX }
        if pos.y > maxY { pos.y = maxY }

        let windowRect = NSRect(origin: pos, size: imgSize)

        let window = PinWindow(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 100, height: 100)

        let container = PinContainerView(
            cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            imageSize: imgSize,
            frame: NSRect(origin: .zero, size: imgSize)
        )
        container.autoresizingMask = [.width, .height]

        let btnSize: CGFloat = 22
        let closeBtn = CloseButtonView(frame: NSRect(
            x: imgSize.width - btnSize - 4,
            y: imgSize.height - btnSize - 4,
            width: btnSize, height: btnSize
        ))
        closeBtn.autoresizingMask = [.minXMargin, .minYMargin]
        closeBtn.onClick = { [weak self] in
            guard let window = closeBtn.window else { return }
            self?.closeWindow(window)
        }
        container.closeButton = closeBtn
        container.addSubview(closeBtn)

        window.contentView = container
        window.orderFront(nil)
        pinnedWindows.append(window)

        NSLog("[ScreenshotTool] PinManager: pinned image at \(pos) size=\(imgSize)")
    }

    private func closeWindow(_ window: NSWindow) {
        window.orderOut(nil)
        pinnedWindows.removeAll { $0 == window }
    }

    func closeAll() {
        for win in pinnedWindows {
            win.orderOut(nil)
        }
        pinnedWindows.removeAll()
    }

    var pinnedCount: Int { pinnedWindows.count }
}
