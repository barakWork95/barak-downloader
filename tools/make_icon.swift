// מצייר את אייקון האפליקציה (1024x1024 PNG): ברק שמכה בקו, כלומר "הורדה".
// הברק מצויר כצורה מקורית, בלי אימוג'י ובלי SF Symbols (הרישיון שלהם אוסר שימוש באייקון של אפליקציה).
// שימוש: swiftc make_icon.swift -o make_icon && ./make_icon out.png [brand|electric]
import AppKit

let px: CGFloat = 1024
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "brand"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// נקודות בקואורדינטות "מלמעלה למטה" (כמו בעיצוב), מומרות למערכת של CoreGraphics
func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points.map { CGPoint(x: $0.0, y: px - $0.1) })
    path.closeSubpath()
    return path
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// הגריד של אפל: גוף האייקון 824x824 עם שוליים של 100
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
ctx.addPath(shape)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// רקע
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let background = variant == "electric"
    ? gradient([color(0x2B2F77), color(0x12142E)])
    : gradient([color(0xFF5F6D), color(0x7B2FF7)])
ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// הבהרה עדינה בחלק העליון
ctx.drawLinearGradient(gradient([color(0xFFFFFF, variant == "electric" ? 0.08 : 0.18), color(0xFFFFFF, 0)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
ctx.restoreGState()

// הברק והקו שהוא מכה בו
let bolt = polygon([(585, 170), (318, 585), (486, 585), (430, 805), (722, 430), (556, 430), (722, 170)])
let rounded = bolt.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10)
let bar = CGPath(roundedRect: CGRect(x: 318, y: px - 880, width: 404, height: 52),
                 cornerWidth: 26, cornerHeight: 26, transform: nil)

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()  // גם הזוהר נשאר בתוך האייקון
if variant == "electric" {
    ctx.setShadow(offset: .zero, blur: 60, color: color(0xFFC83D, 0.8))
} else {
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.22))
}
// שכבה אחת: מילוי נפרד לכל חלק (כדי שלא ייווצרו חורים במקום שקו המתאר חופף לצורה)
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(color(0xFFFFFF))
for path in [bolt, rounded, bar] {
    ctx.addPath(path)
    ctx.fillPath()
}
if variant == "electric" {
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(gradient([color(0xFFF27A), color(0xFFB23F), color(0xFF7A1A)]),
                           start: CGPoint(x: 512, y: px - 160), end: CGPoint(x: 512, y: px - 890),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
