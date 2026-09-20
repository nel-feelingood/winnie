// Prepares artist sprites for the app:  swift scripts/import-sprites.swift [source-dir]
//
// Every frame is cropped to ONE shared rectangle (the union of all opaque areas)
// so the character fills the pet window without shifting between poses, then
// scaled down: the pet is ~150 pt on screen, so 1024 px frames only cost memory.
import AppKit

let states = ["idle", "hover", "thinking", "talking", "drag", "error", "sleep"]
let outputSide = 512
let padding = 12

let source = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/sprites")
let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Winnie/Sprites")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func bitmap(_ name: String) -> NSBitmapImageRep? {
    guard let data = try? Data(contentsOf: source.appendingPathComponent("\(name).png")) else { return nil }
    return NSBitmapImageRep(data: data)
}

var frames: [(String, NSBitmapImageRep)] = []
var union = CGRect.null
for state in states {
    guard let rep = bitmap(state) else { print("missing \(state).png — skipped"); continue }
    var minX = rep.pixelsWide, maxX = 0, minY = rep.pixelsHigh, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    union = union.union(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    frames.append((state, rep))
}
guard let canvas = frames.first?.1 else { fatalError("no sprites found in \(source.path)") }

// Square crop, horizontally centred on the union, sitting on its bottom edge so feet keep one baseline.
let side = min(CGFloat(canvas.pixelsWide), max(union.width, union.height) + CGFloat(padding * 2))
var crop = CGRect(x: union.midX - side / 2, y: union.maxY + CGFloat(padding) - side, width: side, height: side)
crop.origin.x = min(max(crop.origin.x, 0), CGFloat(canvas.pixelsWide) - side)
crop.origin.y = min(max(crop.origin.y, 0), CGFloat(canvas.pixelsHigh) - side)

for (state, rep) in frames {
    guard let cropped = rep.cgImage?.cropping(to: crop) else { continue }
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outputSide, pixelsHigh: outputSide,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSide, height: outputSide))
    NSGraphicsContext.restoreGraphicsState()
    try out.representation(using: .png, properties: [:])!
        .write(to: destination.appendingPathComponent("\(state).png"))
}
print("crop \(Int(crop.minX)),\(Int(crop.minY)) \(Int(side))px → \(frames.count) sprites in \(destination.path)")
