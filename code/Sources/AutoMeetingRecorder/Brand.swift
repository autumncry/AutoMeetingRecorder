import SwiftUI
import AppKit

enum Brand {
    static let name = "AutoMeetingRecorder"
    static let shortName = "AMR"
    static let blue = Color(red: 0, green: 117.0 / 255, blue: 1)
    static let accent = adaptive(light: 0x005FD2, dark: 0x82B8FF)
    static let text = adaptive(light: 0x16233A, dark: 0xF4F7FB)
    static let secondary = adaptive(light: 0x4D6587, dark: 0xB8C9E4)
    static let canvas = adaptive(light: 0xF4F7FB, dark: 0x0E1828)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x16233A)
    static let sidebar = adaptive(light: 0xFFFFFF, dark: 0x0E2241)
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static var icon: NSImage? {
        guard let path = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: path)
    }
    /// Native monochrome adaptation of the note/waveform mark for the menu bar.
    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let page = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 1.5, width: 11, height: 15), xRadius: 2, yRadius: 2)
            page.lineWidth = 1.4; page.stroke()
            for (x, h) in [(6.5, 3.0), (9.0, 6.0), (11.5, 4.0)] {
                let line = NSBezierPath(); line.lineCapStyle = .round; line.lineWidth = 1.5
                line.move(to: NSPoint(x: x, y: 10 - h / 2)); line.line(to: NSPoint(x: x, y: 10 + h / 2)); line.stroke()
            }
            let text = NSBezierPath(); text.lineWidth = 1.4; text.lineCapStyle = .round
            text.move(to: NSPoint(x: 6, y: 4.8)); text.line(to: NSPoint(x: 12, y: 4.8)); text.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
