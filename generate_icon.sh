#!/bin/bash
# Generate app icon for 截图工具
set -e

OUTPUT_DIR="/tmp/screenshot_icon.iconset"
mkdir -p "$OUTPUT_DIR"

# Generate a Swift script that creates the icon using CoreGraphics
cat > /tmp/gen_icon.swift << 'SWIFT'
import Cocoa

let size = 1024.0
let inset = size * 0.09
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// ---- Background: rounded rect with gradient ----
let path = NSBezierPath(roundedRect: rect, xRadius: 140, yRadius: 140)
path.addClip()

let colors = [
    CGColor(red: 37/255.0, green: 99/255.0, blue: 235/255.0, alpha: 1),
    CGColor(red: 124/255.0, green: 58/255.0, blue: 237/255.0, alpha: 1),
]
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

let cx = size / 2
let cy = size / 2 + size * 0.02

// ---- Camera body (white rounded rect) ----
let bodyW = size * 0.36
let bodyH = size * 0.25
let bodyRect = CGRect(x: cx - bodyW/2, y: cy - bodyH/2, width: bodyW, height: bodyH)
NSColor.white.setFill()
NSBezierPath(roundedRect: bodyRect, xRadius: 26, yRadius: 26).fill()

// ---- Top deck ----
let deckW = bodyW * 0.44
let deckH = bodyH * 0.16
let deckRect = CGRect(x: cx + bodyW * 0.06, y: cy + bodyH/2 - deckH + 4, width: deckW, height: deckH)
NSColor.white.setFill()
NSBezierPath(roundedRect: deckRect, xRadius: 8, yRadius: 8).fill()

// ---- Flash ----
ctx.setFillColor(CGColor(red: 251/255.0, green: 191/255.0, blue: 36/255.0, alpha: 1))
NSBezierPath(roundedRect: CGRect(
    x: deckRect.midX - deckW * 0.05, y: deckRect.midY - deckH * 0.15,
    width: deckW * 0.18, height: deckH * 0.4
), xRadius: 3, yRadius: 3).fill()

// ---- Main lens (dark outer) ----
let lensR = bodyH * 0.30
ctx.setFillColor(CGColor(red: 20/255.0, green: 45/255.0, blue: 120/255.0, alpha: 1))
ctx.fillEllipse(in: CGRect(x: cx - lensR, y: cy - lensR, width: lensR*2, height: lensR*2))

// ---- Inner lens (darker) ----
let lensR2 = lensR * 0.80
ctx.setFillColor(CGColor(red: 10/255.0, green: 25/255.0, blue: 70/255.0, alpha: 1))
ctx.fillEllipse(in: CGRect(x: cx - lensR2, y: cy - lensR2, width: lensR2*2, height: lensR2*2))

// ---- Lens glass (gradient ring) ----
let lensR3 = lensR * 0.50
let lensGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 99/255.0, green: 102/255.0, blue: 241/255.0, alpha: 1),
        CGColor(red: 30/255.0, green: 58/255.0, blue: 138/255.0, alpha: 1),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: cx - lensR3, y: cy - lensR3, width: lensR3*2, height: lensR3*2))
ctx.clip()
ctx.drawRadialGradient(
    lensGrad,
    startCenter: CGPoint(x: cx - lensR3*0.3, y: cy + lensR3*0.3),
    startRadius: 0,
    endCenter: CGPoint(x: cx, y: cy),
    endRadius: lensR3,
    options: []
)
ctx.restoreGState()

// ---- Lens glare highlight ----
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.2))
ctx.fillEllipse(in: CGRect(
    x: cx - lensR3*0.5, y: cy + lensR3*0.35,
    width: lensR3*0.85, height: lensR3*0.35
))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
ctx.fillEllipse(in: CGRect(
    x: cx - lensR3*0.3, y: cy + lensR3*0.5,
    width: lensR3*0.12, height: lensR3*0.12
))

// ---- Shutter button area on body top ----
ctx.setFillColor(CGColor(red: 20/255.0, green: 45/255.0, blue: 120/255.0, alpha: 0.08))
NSBezierPath(roundedRect: CGRect(
    x: cx + bodyW*0.06, y: cy - bodyH*0.18,
    width: bodyW*0.42, height: bodyH*0.035
), xRadius: 2, yRadius: 2).fill()

// ---- Green indicator LED ----
ctx.setFillColor(CGColor(red: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1))
ctx.fillEllipse(in: CGRect(
    x: deckRect.minX + deckW*0.12, y: deckRect.midY - deckH*0.2,
    width: deckH*0.3, height: deckH*0.3
))

image.unlockFocus()

let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
let pngData = bitmapRep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: "/tmp/screenshot_icon_1024.png"))
print("Icon generated: /tmp/screenshot_icon_1024.png")
SWIFT

swift /tmp/gen_icon.swift

# Convert 16-bit CGImage PNG to 8-bit for iconutil
python3 -c "
from PIL import Image
img = Image.open('/tmp/screenshot_icon_1024.png').convert('RGBA')
img.save('/tmp/screenshot_icon_8bit.png', 'PNG')
print('Converted to 8-bit')
"

# Create iconset from 8-bit source (clear first)
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
ICON8="/tmp/screenshot_icon_8bit.png"
sips -z 16 16 "$ICON8" --out "$OUTPUT_DIR/icon_16x16.png" &>/dev/null
sips -z 32 32 "$ICON8" --out "$OUTPUT_DIR/icon_16x16@2x.png" &>/dev/null
sips -z 32 32 "$ICON8" --out "$OUTPUT_DIR/icon_32x32.png" &>/dev/null
sips -z 64 64 "$ICON8" --out "$OUTPUT_DIR/icon_32x32@2x.png" &>/dev/null
sips -z 128 128 "$ICON8" --out "$OUTPUT_DIR/icon_128x128.png" &>/dev/null
sips -z 256 256 "$ICON8" --out "$OUTPUT_DIR/icon_128x128@2x.png" &>/dev/null
sips -z 256 256 "$ICON8" --out "$OUTPUT_DIR/icon_256x256.png" &>/dev/null
sips -z 512 512 "$ICON8" --out "$OUTPUT_DIR/icon_256x256@2x.png" &>/dev/null
sips -z 512 512 "$ICON8" --out "$OUTPUT_DIR/icon_512x512.png" &>/dev/null
cp "$ICON8" "$OUTPUT_DIR/icon_512x512@2x.png"

# Create ICNS
ICON_DEST="/Users/xuhang/work/截图工具/截图工具.app/Contents/Resources/AppIcon.icns"
mkdir -p "$(dirname "$ICON_DEST")"
iconutil -c icns "$OUTPUT_DIR" -o "$ICON_DEST"

echo "✅ Icon created: $ICON_DEST"

# Also copy to source directory for version control
cp "$ICON_DEST" "/Users/xuhang/work/截图工具/Sources/ScreenshotTool/AppIcon.icns"
echo "✅ Copied to source directory"
