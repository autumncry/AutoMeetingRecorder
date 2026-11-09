import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else { fatalError("usage: verify_icon.swift APP_PATH OUTPUT_DIR") }
let path = CommandLine.arguments[1]
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let bundle = Bundle(path: path), let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
      let resource = bundle.resourceURL?.appendingPathComponent(iconName), let packaged = NSImage(contentsOf: resource) else {
    fatalError("Missing packaged icon reference")
}
func save(_ image: NSImage, name: String) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Image context failed") }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try data.write(to: output.appendingPathComponent(name))
}
try save(packaged, name: "packaged-icon.png")
try save(NSWorkspace.shared.icon(forFile: path), name: "system-resolved-icon.png")
print("Verified icon reference: \(iconName)")
print("App: \(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? "")")
