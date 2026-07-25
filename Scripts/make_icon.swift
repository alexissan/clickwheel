import AppKit
import CoreGraphics
import Foundation

// Turns the supplied artwork into a macOS app icon.
//
// The source is a white square with a black frame around it, so this trims the
// frame, then lays the artwork out on Apple's icon grid: a 1024pt canvas with
// the visible shape occupying the middle 824pt, corners rounded to the
// standard 22.5% of that shape, and a soft contact shadow beneath. Shipping
// the raw square would give a hard-edged tile that looks nothing like every
// other icon in the Dock.
//
//   swift Scripts/make_icon.swift <source.png> <output.png>

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make_icon <source> <output>\n".utf8))
    exit(1)
}

guard
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("could not read source image\n".utf8))
    exit(1)
}

// MARK: - Trim the black frame

/// Reads the image into sRGB so the border can be detected by luminance.
func pixels(of image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height)
}

let (bytes, width, height) = pixels(of: image)

func isDark(x: Int, y: Int) -> Bool {
    let offset = (y * width + x) * 4
    let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
    return luma < 40
}

// Walk in from each edge along the centre line until the dark frame ends.
var left = 0
while left < width / 2, isDark(x: left, y: height / 2) { left += 1 }
var right = width - 1
while right > width / 2, isDark(x: right, y: height / 2) { right -= 1 }
var top = 0
while top < height / 2, isDark(x: width / 2, y: top) { top += 1 }
var bottom = height - 1
while bottom > height / 2, isDark(x: width / 2, y: bottom) { bottom -= 1 }

let cropRect = CGRect(
    x: left,
    y: top,
    width: max(1, right - left + 1),
    height: max(1, bottom - top + 1)
)
let artwork = image.cropping(to: cropRect) ?? image
print("trimmed frame: \(width)x\(height) -> \(artwork.width)x\(artwork.height)")

// MARK: - Compose on the icon grid

let canvas: CGFloat = 1024
let shape: CGFloat = 824
let inset = (canvas - shape) / 2
let cornerRadius = shape * 0.225

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

context.interpolationQuality = .high
context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// Icon shapes sit slightly above centre on Apple's grid.
let shapeRect = CGRect(x: inset, y: inset - canvas * 0.012, width: shape, height: shape)
let rounded = CGPath(
    roundedRect: shapeRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// Contact shadow.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -canvas * 0.012),
    blur: canvas * 0.022,
    color: NSColor.black.withAlphaComponent(0.28).cgColor
)
context.addPath(rounded)
context.setFillColor(NSColor.white.cgColor)
context.fillPath()
context.restoreGState()

// Artwork, clipped to the rounded shape.
context.saveGState()
context.addPath(rounded)
context.clip()
context.draw(artwork, in: shapeRect)
context.restoreGState()

guard
    let output = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[2]) as CFURL,
        "public.png" as CFString,
        1,
        nil
    )
else { exit(1) }

CGImageDestinationAddImage(destination, output, nil)
CGImageDestinationFinalize(destination)
print("wrote \(arguments[2]) (\(output.width)x\(output.height))")
