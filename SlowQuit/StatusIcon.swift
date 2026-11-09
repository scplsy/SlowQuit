// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Original vector artwork: an open confirmation ring with the tail of a Q.
/// A template image lets macOS choose the color for light/dark/selected menus.
enum StatusIcon {
    static func image(for status: ProtectionStatus) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath()
            ring.lineWidth = 1.8
            ring.lineCapStyle = .round
            ring.appendArc(withCenter: NSPoint(x: 8.5, y: 9.5), radius: 6.25,
                           startAngle: 35, endAngle: 340, clockwise: false)
            ring.stroke()

            let tail = NSBezierPath()
            tail.lineWidth = 1.8
            tail.lineCapStyle = .round
            tail.move(to: NSPoint(x: 11.2, y: 6.2))
            tail.line(to: NSPoint(x: 15.5, y: 2))
            tail.stroke()

            switch status {
            case .protecting:
                break
            case .paused:
                for x in [CGFloat(6.8), 10.2] {
                    NSBezierPath(roundedRect: NSRect(x: x - 0.7, y: 7, width: 1.4, height: 5),
                                 xRadius: 0.7, yRadius: 0.7).fill()
                }
            case .needsPermission:
                let shackle = NSBezierPath()
                shackle.lineWidth = 1.1
                shackle.appendArc(withCenter: NSPoint(x: 8.5, y: 10.1), radius: 1.8,
                                  startAngle: 0, endAngle: 180)
                shackle.stroke()
                NSBezierPath(roundedRect: NSRect(x: 5.8, y: 6.4, width: 5.4, height: 4),
                             xRadius: 0.9, yRadius: 0.9).fill()
            case .failed:
                NSBezierPath(roundedRect: NSRect(x: 7.7, y: 9, width: 1.6, height: 4),
                             xRadius: 0.8, yRadius: 0.8).fill()
                NSBezierPath(ovalIn: NSRect(x: 7.7, y: 6.2, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SlowQuit，\(status.rawValue)"
        return image
    }
}
