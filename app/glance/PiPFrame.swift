import AppKit
import CoreGraphics
import CoreVideo

enum PiPFrame {
    /// 画中画锁定的宽高比。第一帧用这个比例，之后只等比缩放。
    static let contentAspect: CGFloat = 16.0 / 10.0

    static func aspectPixelSize(renderSize: CGSize?) -> CGSize {
        let base = CGSize(width: 1280, height: 1280 / contentAspect)
        guard let renderSize, renderSize.width >= 32, renderSize.height >= 32 else { return base }
        let scale = max(renderSize.width / base.width, renderSize.height / base.height)
        let width = evenPixel(base.width * scale)
        let height = evenPixel(CGFloat(width) / contentAspect)
        return CGSize(width: width, height: height)
    }

    static func defaultPixelSize(lineCount _: Int) -> CGSize {
        aspectPixelSize(renderSize: nil)
    }

    static func image(lines: [PiPLine], pointSize: CGSize) -> NSImage {
        let size = NSSize(width: max(pointSize.width, 1), height: max(pointSize.height, 1))
        return NSImage(size: size, flipped: true) { rect in
            draw(lines: lines, in: rect)
            return true
        }
    }

    static func pixelBuffer(lines: [PiPLine], pixelSize: CGSize) -> CVPixelBuffer? {
        let width = evenPixel(pixelSize.width)
        let height = evenPixel(pixelSize.height)
        guard width > 0, height > 0 else { return nil }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        )
        guard created == kCVReturnSuccess, let buffer else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = graphics
        draw(lines: lines, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return buffer
    }

    static func draw(lines: [PiPLine], in rect: CGRect) {
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1).setFill()
        rect.fill()

        if lines.isEmpty {
            drawCentered("未选择要展示的信息", in: rect, alpha: 0.55)
            return
        }

        let marginX = rect.width * 0.05
        let marginY = rect.height * 0.045
        let content = rect.insetBy(dx: marginX, dy: marginY)
        guard content.width > 1, content.height > 1 else { return }

        let rowHeight = content.height / CGFloat(lines.count)
        let fontSize = sharedFontSize(lines: lines, rowHeight: rowHeight, width: content.width)
        let thickness = max(1, min(rect.width, rect.height) * 0.0015)

        for (index, line) in lines.enumerated() {
            let row = CGRect(
                x: content.minX,
                y: content.minY + CGFloat(index) * rowHeight,
                width: content.width,
                height: rowHeight
            )
            if index > 0 {
                NSColor.white.withAlphaComponent(0.10).setFill()
                NSRect(x: row.minX, y: row.minY, width: row.width, height: thickness).fill()
            }
            drawRow(line, in: row, fontSize: fontSize)
        }
    }

    private static func sharedFontSize(lines: [PiPLine], rowHeight: CGFloat, width: CGFloat) -> CGFloat {
        let upper = max(8, rowHeight * 0.5)
        var low: CGFloat = 8
        var high = upper
        var best: CGFloat = 8
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if lines.allSatisfy({ rowFits($0, fontSize: mid, width: width) }) {
                best = mid
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    private static func rowFits(_ line: PiPLine, fontSize: CGFloat, width: CGFloat) -> Bool {
        let nameFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let nameWidth = (line.leading as NSString).size(withAttributes: [.font: nameFont]).width
        let gap = columnGap(value: line.trailing, width: width)
        let valueWidth = line.trailing.isEmpty
            ? 0
            : (line.trailing as NSString).size(withAttributes: [.font: valueFont]).width
        return nameWidth + gap + valueWidth <= width
    }

    private static func columnGap(value: String, width: CGFloat) -> CGFloat {
        value.isEmpty ? 0 : max(12, width * 0.03)
    }

    private static func drawRow(_ line: PiPLine, in rect: CGRect, fontSize: CGFloat) {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        let nameFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let value = line.trailing
        let gap = columnGap(value: value, width: rect.width)
        let valueWidth: CGFloat
        if value.isEmpty {
            valueWidth = 0
        } else {
            let measured = (value as NSString).size(withAttributes: [.font: valueFont]).width
            valueWidth = min(measured, max(0, rect.width - gap))
        }
        let nameWidth = max(0, rect.width - valueWidth - gap)

        let nameStyle = NSMutableParagraphStyle()
        nameStyle.lineBreakMode = .byTruncatingTail
        nameStyle.alignment = .left
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: nameStyle,
        ]
        let name = fitted(line.leading, width: nameWidth, attributes: nameAttrs)
        let nameRect = verticallyCentered(text: name, attributes: nameAttrs, in: CGRect(x: rect.minX, y: rect.minY, width: nameWidth, height: rect.height))
        (name as NSString).draw(in: nameRect, withAttributes: nameAttrs)

        guard !value.isEmpty else { return }
        let valueStyle = NSMutableParagraphStyle()
        valueStyle.lineBreakMode = .byTruncatingTail
        valueStyle.alignment = .right
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: valueStyle,
        ]
        let valueRect = verticallyCentered(
            text: value,
            attributes: valueAttrs,
            in: CGRect(x: rect.maxX - valueWidth, y: rect.minY, width: valueWidth, height: rect.height)
        )
        (value as NSString).draw(in: valueRect, withAttributes: valueAttrs)
    }

    private static func drawCentered(_ text: String, in rect: CGRect, alpha: CGFloat) {
        let font = NSFont.systemFont(ofSize: max(12, min(rect.width, rect.height) * 0.08), weight: .medium)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: style,
        ]
        let textRect = verticallyCentered(text: text, attributes: attrs, in: rect)
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private static func verticallyCentered(text: String, attributes: [NSAttributedString.Key: Any], in rect: CGRect) -> CGRect {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: rect.width, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let height = min(ceil(bounds.height), rect.height)
        let y = rect.minY + (rect.height - height) / 2
        return CGRect(x: rect.minX, y: y, width: rect.width, height: height)
    }

    private static func fitted(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        if width <= 0 { return "" }
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters.prefix(mid)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low == 0 ? "…" : String(characters.prefix(low)) + "…"
    }

    private static func evenPixel(_ value: CGFloat) -> Int {
        let rounded = max(Int(value.rounded()), 2)
        return rounded - (rounded % 2)
    }
}
