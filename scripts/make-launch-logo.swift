// Regenerates Assets.xcassets/LaunchLogo.imageset from SpineLogo.png (alpha mask tinted ink/paper at 240/480/720px).
// Usage: swiftc -O -o /tmp/tint Scripts/make-launch-logo.swift && /tmp/tint SPINE/Assets.xcassets/SpineLogo.imageset/SpineLogo.png SPINE/Assets.xcassets/LaunchLogo.imageset
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = args[1], outDir = args[2]
let url = URL(fileURLWithPath: src)
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(source, 0, nil)!

func render(size: Int, color: (CGFloat, CGFloat, CGFloat), name: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.clip(to: rect, mask: img)
    ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
    ctx.fill(rect)
    let out = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
}
let ink: (CGFloat, CGFloat, CGFloat) = (20/255, 16/255, 24/255)
let paper: (CGFloat, CGFloat, CGFloat) = (237/255, 238/255, 227/255)
for (scale, px) in [(1, 240), (2, 480), (3, 720)] {
    render(size: px, color: ink, name: "LaunchLogo-light@\(scale)x")
    render(size: px, color: paper, name: "LaunchLogo-dark@\(scale)x")
}
print("ok")
