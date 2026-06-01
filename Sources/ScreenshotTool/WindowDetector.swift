import Cocoa

struct WindowInfo {
    let rect: CGRect
    let windowNumber: Int
    let pid: pid_t
    let displayID: CGDirectDisplayID
}

final class WindowDetector {

    /// Returns true if the given rect matches any screen's full frame (desktop background).
    private static func isFullScreenDesktop(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.equalTo(rect) }
    }

    static func windowUnderCursor(excluding excludedWindowNumber: Int? = nil) -> CGRect? {
        let mouseLocation = NSEvent.mouseLocation
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        guard let windows = windowList as? [[String: Any]] else { return nil }

        let sortedWindows = windows.sorted { a, b in
            let layerA = a[kCGWindowLayer as String] as? Int ?? 0
            let layerB = b[kCGWindowLayer as String] as? Int ?? 0
            if layerA != layerB { return layerA < layerB }
            let idxA = a[kCGWindowNumber as String] as? Int ?? 0
            let idxB = b[kCGWindowNumber as String] as? Int ?? 0
            return idxA < idxB
        }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: mouseLocation.x, y: screenHeight - mouseLocation.y)

        for info in sortedWindows {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int
            else { continue }

            if windowNumber == excludedWindowNumber { continue }
            if layer < 0 || layer > 20 { continue }

            let rect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: max(bounds["Width"] ?? 0, 0),
                height: max(bounds["Height"] ?? 0, 0)
            )
            if rect.width < 50 || rect.height < 50 { continue }
            if isFullScreenDesktop(rect) { continue }

            if rect.contains(cgPoint) {
                if info[kCGWindowOwnerName as String] as? String != nil {
                    return rect
                }
            }
        }
        return nil
    }

    static func windowAtPoint(_ point: CGPoint, excluding excludedWindowNumber: Int? = nil) -> CGRect? {
        return windowInfoAtPoint(point, excluding: excludedWindowNumber)?.rect
    }

    static func windowInfoAtPoint(_ point: CGPoint, excluding excludedWindowNumber: Int? = nil) -> WindowInfo? {
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        guard let windows = windowList as? [[String: Any]] else { return nil }

        let sortedWindows = windows.sorted { a, b in
            let layerA = a[kCGWindowLayer as String] as? Int ?? 0
            let layerB = b[kCGWindowLayer as String] as? Int ?? 0
            if layerA != layerB { return layerA < layerB }
            let idxA = a[kCGWindowNumber as String] as? Int ?? 0
            let idxB = b[kCGWindowNumber as String] as? Int ?? 0
            return idxA < idxB
        }

        // Flip point to CGWindow's top-left coordinate space.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: screenHeight - point.y)

        for info in sortedWindows {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  info[kCGWindowOwnerName as String] as? String != nil,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t
            else { continue }

            if windowNumber == excludedWindowNumber { continue }
            if layer < 0 || layer > 20 { continue }

            let rect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: max(bounds["Width"] ?? 0, 0),
                height: max(bounds["Height"] ?? 0, 0)
            )
            if rect.width < 50 || rect.height < 50 { continue }
            if isFullScreenDesktop(rect) { continue }

            if rect.contains(cgPoint) {
                let displayID = screenForRect(rect)?.displayID ?? 0
                return WindowInfo(rect: rect, windowNumber: windowNumber, pid: pid, displayID: displayID)
            }
        }
        return nil
    }

    private static func screenForRect(_ rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // rect is in Quartz coords (top-left), NSScreen uses bottom-left
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let blPoint = CGPoint(x: center.x, y: screenHeight - center.y)
        return NSScreen.screens.first { $0.frame.contains(blPoint) }
            ?? NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }
}
