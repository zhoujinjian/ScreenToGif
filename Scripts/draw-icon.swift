import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// ScreenToGif macOS 图标绘制：深蓝黑 squircle + 白色取景框 + 红色录制球 + 底部胶片条
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

let inset: CGFloat = 100
let iconRect = CGRect(x: inset, y: inset, width: 824, height: 824)
let radius: CGFloat = iconRect.width * 0.2237
let squircle = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// 1. 底色渐变（上亮下暗，深蓝黑）
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0.20, 0.23, 0.30), rgb(0.085, 0.095, 0.135)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
                       end: CGPoint(x: iconRect.midX, y: iconRect.minY), options: [])
// 顶部微光
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY * 0.92), startRadius: 0,
                       endCenter: CGPoint(x: iconRect.midX, y: iconRect.maxY * 0.92),
                       endRadius: iconRect.width * 0.8, options: [])
ctx.restoreGState()

// 2. 内描边高光
ctx.addPath(squircle)
ctx.setStrokeColor(rgb(1, 1, 1, 0.15))
ctx.setLineWidth(2.5)
ctx.strokePath()

// 3. 取景框四角（白色 L 形，外发光）
let vi = iconRect.insetBy(dx: 96, dy: 96)
let arm: CGFloat = 132
let lw: CGFloat = 26
func cornerPath(_ sx: CGFloat, _ sy: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let ox = sx > 0 ? vi.maxX : vi.minX
    let oy = sy > 0 ? vi.maxY : vi.minY
    p.move(to: CGPoint(x: ox, y: oy - sy * arm))
    p.addLine(to: CGPoint(x: ox, y: oy))
    p.addLine(to: CGPoint(x: ox - sx * arm, y: oy))
    return p
}
let corners: [(CGFloat, CGFloat)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (sx, sy) in corners {                       // 发光层
    ctx.addPath(cornerPath(sx, sy))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.15))
    ctx.setLineWidth(lw + 20)
    ctx.strokePath()
}
for (sx, sy) in corners {                       // 主体层
    ctx.addPath(cornerPath(sx, sy))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.97))
    ctx.setLineWidth(lw)
    ctx.strokePath()
}

// 4. 红色录制球（径向渐变球体质感）
let dotCenter = CGPoint(x: iconRect.midX, y: iconRect.midY + 26)
let dotR: CGFloat = 118
let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
// 落影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: rgb(0, 0, 0, 0.45))
ctx.setFillColor(rgb(0.9, 0.2, 0.22))
ctx.fillEllipse(in: dotRect)
ctx.restoreGState()
// 球体渐变
ctx.saveGState()
ctx.addEllipse(in: dotRect); ctx.clip()
let dot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [rgb(1.0, 0.62, 0.55), rgb(0.92, 0.22, 0.23), rgb(0.60, 0.07, 0.12)] as CFArray,
                     locations: [0, 0.5, 1])!
ctx.drawRadialGradient(dot,
                       startCenter: CGPoint(x: dotCenter.x - dotR * 0.35, y: dotCenter.y + dotR * 0.42),
                       startRadius: dotR * 0.08,
                       endCenter: dotCenter, endRadius: dotR * 1.18, options: [])
// 高光点
let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(1, 1, 1, 0.85), rgb(1, 1, 1, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawRadialGradient(hl,
                       startCenter: CGPoint(x: dotCenter.x - dotR * 0.34, y: dotCenter.y + dotR * 0.44),
                       startRadius: 0,
                       endCenter: CGPoint(x: dotCenter.x - dotR * 0.34, y: dotCenter.y + dotR * 0.44),
                       endRadius: dotR * 0.55, options: [])
ctx.restoreGState()

// 5. 胶片条（底部，半透明 + 齿孔 + GIF 字样；左右让开底部取景框角标）
let filmH: CGFloat = 72
let filmInset: CGFloat = 96
let filmRect = CGRect(x: vi.minX + filmInset, y: iconRect.minY + 104, width: vi.width - filmInset * 2, height: filmH)
let filmPath = CGPath(roundedRect: filmRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
ctx.addPath(filmPath)
ctx.setFillColor(rgb(1, 1, 1, 0.16))
ctx.fillPath()
ctx.addPath(filmPath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.40))
ctx.setLineWidth(2)
ctx.strokePath()
// 齿孔（上下两排小圆）
ctx.setFillColor(rgb(1, 1, 1, 0.60))
let holeR: CGFloat = 6
let holeCount = 8
let holeMargin: CGFloat = 26
let holeStep = (filmRect.width - holeMargin * 2) / CGFloat(holeCount - 1)
for i in 0..<holeCount {
    let x = filmRect.minX + holeMargin + holeStep * CGFloat(i)
    for y in [filmRect.minY + 13, filmRect.maxY - 13] {
        ctx.fillEllipse(in: CGRect(x: x - holeR, y: y - holeR, width: holeR * 2, height: holeR * 2))
    }
}
// 中央 GIF 字样（用 ctx 填充色画，避免 CT 前景色属性对 CGColor 的兼容问题）
let gifAttr = NSAttributedString(string: "GIF", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
])
let gifLine = CTLineCreateWithAttributedString(gifAttr)
let gifWidth = CTLineGetTypographicBounds(gifLine, nil, nil, nil)
ctx.setFillColor(rgb(1, 1, 1, 0.95))
ctx.textPosition = CGPoint(x: filmRect.midX - gifWidth / 2, y: filmRect.midY - 12)
CTLineDraw(gifLine, ctx)

// 导出
guard let image = ctx.makeImage() else { fatalError("合成失败") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/appicon-drawn.png"
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("绘制完成 → \(out)")
