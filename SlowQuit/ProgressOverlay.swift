// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ApplicationServices
import Combine
import SwiftUI

@MainActor
private final class ProgressPresentation: ObservableObject {
    @Published var name = ""
    @Published var icon: NSImage?
    @Published var progress = 0.0
    @Published var awaitingRelease = false
}

@MainActor
final class ProgressOverlayController {
    private let presentation = ProgressPresentation()
    private var panel: NSPanel?
    private var displayedProcessID: pid_t?

    func show(application: NSRunningApplication, progress: Double, awaitingRelease: Bool = false) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 210),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = makeMaterialView(frame: panel.contentLayoutRect)
            self.panel = panel
        }
        guard let panel else { return }
        if displayedProcessID != application.processIdentifier || !panel.isVisible {
            displayedProcessID = application.processIdentifier
            presentation.name = application.localizedName ?? "当前应用"
            presentation.icon = application.icon
            if let screen = screen(for: application) {
                let frame = screen.frame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            panel.orderFrontRegardless()
        }
        presentation.progress = progress
        presentation.awaitingRelease = awaitingRelease
    }

    func hide() {
        panel?.orderOut(nil)
        displayedProcessID = nil
    }

    private func makeMaterialView(frame: NSRect) -> NSView {
        let content = NSHostingView(rootView: HoldProgressView(presentation: presentation))
        content.frame = NSRect(origin: .zero, size: frame.size)
        content.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = 22
            // Leave tint and alpha at their system defaults. Native glass
            // follows the user's Liquid Glass and accessibility preferences.
            glass.contentView = content
            return glass
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 22
            material.layer?.masksToBounds = true
            material.addSubview(content)
            return material
        }
    }

    private func screen(for application: NSRunningApplication) -> NSScreen? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return NSScreen.main }
        let window = windowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return NSScreen.main }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              let primary = NSScreen.screens.first else { return NSScreen.main }
        // Accessibility uses a top-left origin on the primary display; AppKit
        // uses a bottom-left origin. Other displays may have negative coordinates.
        let windowFrame = NSRect(x: position.x, y: primary.frame.maxY - position.y - size.height,
                                 width: size.width, height: size.height)
        return NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, windowFrame) < intersectionArea(rhs.frame, windowFrame)
        } ?? NSScreen.main
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

private struct HoldProgressView: View {
    @ObservedObject var presentation: ProgressPresentation

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: presentation.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let icon = presentation.icon {
                    Image(nsImage: icon).resizable().frame(width: 42, height: 42)
                } else {
                    Image(systemName: "app").font(.largeTitle)
                }
            }
            .frame(width: 76, height: 76)
            .accessibilityLabel("快捷键确认进度")
            .accessibilityValue("\(Int(presentation.progress * 100))%")

            Text(presentation.name).font(.headline).lineLimit(1)
            Text(presentation.awaitingRelease ? "松开 Q 以退出 SlowQuit" : "继续按住 ⌘Q 以确认").font(.subheadline)
            Text(presentation.awaitingRelease ? "正在保护后面的应用" : "松手即可取消").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 240, height: 210)
    }
}
