// Normalises a new pose so it matches the existing sprite set:
//   swift scripts/add-sprite.swift <image> <state> [--colour-only]
//
// With --bounds-from <image> the size and position are computed from that other picture
// instead: every frame of one animation must share one transform, or the character
// jitters by a pixel from frame to frame.
//
// With --colour-only the picture keeps its size and position and only step 3 runs:
// for poses that already fit the set but were drawn in a slightly different tone.
//
// 1. If the picture has an opaque white background, removes it by flood-filling from the
//    borders (so the whites of the eyes, enclosed by the outline, are untouched) and
//    un-blends the anti-aliased edge from white, which avoids a pale halo.
// 2. Scales the character to the height of `idle.png` and stands it on the same baseline,
//    horizontally centred like the rest, on a 1024×1024 canvas in Assets/sprites/.
// 3. Matches the fur colour to `idle.png`: poses drawn in separate sessions drift in hue, and a
//    bear that changes colour when the sprite swaps looks broken. Only saturated pixels are
//    shifted, so the whites of the eyes and the black outline stay as drawn.
import AppKit

var arguments = CommandLine.arguments
let colourOnly = arguments.contains("--colour-only")
arguments.removeAll { $0 == "--colour-only" }
var boundsSource: String?
if let flag = arguments.firstIndex(of: "--bounds-from"), flag + 1 < arguments.count {
    boundsSource = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 3 else { print("usage: add-sprite.swift <image> <state> [--colour-only]"); exit(1) }
let state = arguments[2]

func rgba(_ url: URL) -> (pixels: [UInt8], width: Int, height: Int)? {
    guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width, height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

func bounds(_ p: [UInt8], _ w: Int, _ h: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 12 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return (minX, maxX, minY, maxY)
}

guard var (pixels, width, height) = rgba(URL(fileURLWithPath: arguments[1])) else { print("cannot read image"); exit(1) }

// --- 1. background removal, only if the corners are opaque and white
func isWhite(_ i: Int, _ level: UInt8) -> Bool { pixels[i] >= level && pixels[i + 1] >= level && pixels[i + 2] >= level && pixels[i + 3] > 250 }
let corners = [0, (width - 1) * 4, (height - 1) * width * 4, (height * width - 1) * 4]
if corners.allSatisfy({ isWhite($0, 245) }) {
    var removed = [Bool](repeating: false, count: width * height)
    var stack: [Int] = []
    for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
    for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
    while let index = stack.popLast() {
        guard !removed[index], isWhite(index * 4, 238) else { continue }
        removed[index] = true
        let x = index % width, y = index / width
        if x > 0 { stack.append(index - 1) }; if x < width - 1 { stack.append(index + 1) }
        if y > 0 { stack.append(index - width) }; if y < height - 1 { stack.append(index + width) }
    }
    var edge = 0
    for index in 0..<(width * height) {
        let i = index * 4
        if removed[index] { pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0; continue }
        let x = index % width, y = index / width
        let touchesBackground = (x > 0 && removed[index - 1]) || (x < width - 1 && removed[index + 1])
            || (y > 0 && removed[index - width]) || (y < height - 1 && removed[index + width])
        guard touchesBackground else { continue }
        // A blend of outline and white: recover how much outline there is, and its colour.
        let lightest = Double(max(pixels[i], pixels[i + 1], pixels[i + 2]))
        let alpha = min(1, max(0.05, (255 - lightest) / 215))
        for c in 0..<3 {
            let original = (Double(pixels[i + c]) - (1 - alpha) * 255) / alpha
            pixels[i + c] = UInt8(max(0, min(255, original * alpha)))   // premultiplied
        }
        pixels[i + 3] = UInt8(alpha * 255)
        edge += 1
    }
    print("removed white background (\(removed.filter { $0 }.count) px, softened \(edge) edge px)")
} else {
    print("background already transparent")
}

// --- 2. match the reference pose
guard let reference = rgba(URL(fileURLWithPath: "Assets/sprites/idle.png")) else { print("Assets/sprites/idle.png missing"); exit(1) }
let ref = bounds(reference.pixels, reference.width, reference.height)
var own = bounds(pixels, width, height)
if let boundsSource, let other = rgba(URL(fileURLWithPath: boundsSource)) { own = bounds(other.pixels, other.width, other.height) }
let scale = colourOnly ? 1 : Double(ref.maxY - ref.minY) / Double(own.maxY - own.minY)
let canvas = colourOnly ? width : 1024
let source = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: canvas * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let drawnWidth = Double(width) * scale, drawnHeight = Double(height) * scale
// Feet on the reference baseline; character centred where the reference is centred.
let refCentreX = Double(ref.minX + ref.maxX) / 2, ownCentreX = Double(own.minX + own.maxX) / 2 * scale
let left = colourOnly ? 0 : refCentreX - ownCentreX
let topOfImage = colourOnly ? 0 : Double(ref.maxY) - Double(own.maxY) * scale   // in top-left coordinates
out.draw(source, in: CGRect(x: left, y: Double(canvas) - topOfImage - drawnHeight, width: drawnWidth, height: drawnHeight))

// --- 3. colour match
/// Median colour of the orange fur: saturated, mid-bright, clearly more red than blue.
func furColour(_ p: UnsafePointer<UInt8>, count: Int) -> [Double]? {
    var r: [Double] = [], g: [Double] = [], b: [Double] = []
    for index in stride(from: 0, to: count, by: 7) {
        let i = index * 4
        let a = Double(p[i + 3]); guard a > 250 else { continue }
        let red = Double(p[i]), green = Double(p[i + 1]), blue = Double(p[i + 2])
        guard red > 150, green > 60, green < 190, blue < 100, red - blue > 90 else { continue }
        r.append(red); g.append(green); b.append(blue)
    }
    guard r.count > 500 else { return nil }
    return [r, g, b].map { $0.sorted()[$0.count / 2] }
}

let drawn = out.data!.bindMemory(to: UInt8.self, capacity: canvas * canvas * 4)
if let target = reference.pixels.withUnsafeBufferPointer({ furColour($0.baseAddress!, count: reference.width * reference.height) }),
   let current = furColour(drawn, count: canvas * canvas) {
    let gain = zip(target, current).map { $0 / $1 }
    for index in 0..<(canvas * canvas) {
        let i = index * 4
        let alpha = Double(drawn[i + 3]) / 255
        guard alpha > 0 else { continue }
        let colour = (0..<3).map { Double(drawn[i + $0]) / alpha }
        let high = colour.max()!, low = colour.min()!
        // Weight by saturation: greys, whites and blacks keep their colour.
        let weight = high > 0 ? min(1, (high - low) / high * 2) : 0
        for c in 0..<3 {
            let adjusted = colour[c] * (1 + (gain[c] - 1) * weight)
            drawn[i + c] = UInt8(max(0, min(255, adjusted * alpha)))
        }
    }
    print(String(format: "fur matched to idle: gain r %.2f g %.2f b %.2f", gain[0], gain[1], gain[2]))
}

let destination = URL(fileURLWithPath: "Assets/sprites/\(state).png")
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: destination)
print(String(format: "scale %.3f → %@ (character %d px tall, baseline y=%d)", scale, destination.path, ref.maxY - ref.minY, ref.maxY))
