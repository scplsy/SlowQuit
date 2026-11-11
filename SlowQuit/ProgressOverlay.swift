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
    private static let shadowPadding: CGFloat = 12
    private let presentation = ProgressPresentation()
    private var panel: NSPanel?
    private var materialView: NSView?
    private var displayedProcessID: pid_t?

    func show(application: NSRunningApplication, progress: Double, awaitingRelease: Bool = false) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240 + Self.shadowPadding * 2,
                                    height: 210 + Self.shadowPadding * 2),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
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
        if #available(macOS 26.0, *), let glass = materialView as? DesktopGlassEffectView {
            glass.updateBackdrop()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        displayedProcessID = nil
    }

    private func makeMaterialView(frame: NSRect) -> NSView {
        let container = NSView(frame: frame)
        container.wantsLayer = true
        let materialFrame = container.bounds.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
        let cornerRadius: CGFloat = 22
        let content = NSHostingView(rootView: HoldProgressView(presentation: presentation))
        content.frame = NSRect(origin: .zero, size: materialFrame.size)
        content.autoresizingMask = [.width, .height]

        // A small exterior shadow gives the glass depth without the heavy
        // system window shadow. Mask its center so it cannot darken the glass.
        let outline = CGPath(roundedRect: materialFrame, cornerWidth: cornerRadius,
                             cornerHeight: cornerRadius, transform: nil)
        let shadow = CALayer()
        shadow.frame = container.bounds
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.12
        shadow.shadowRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowPath = outline
        let exterior = CGMutablePath()
        exterior.addRect(container.bounds)
        exterior.addPath(outline)
        let mask = CAShapeLayer()
        mask.frame = container.bounds
        mask.path = exterior
        mask.fillRule = .evenOdd
        shadow.mask = mask
        container.layer?.addSublayer(shadow)

        let material: NSView
        if #available(macOS 26.0, *) {
            let glass = DesktopGlassEffectView(frame: materialFrame)
            glass.style = .clear
            glass.cornerRadius = cornerRadius
            // Leave tint and alpha at their system defaults. Native glass
            // follows the user's Liquid Glass and accessibility preferences.
            glass.contentView = content
            material = glass
        } else {
            let visualEffect = NSVisualEffectView(frame: materialFrame)
            visualEffect.material = .hudWindow
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.wantsLayer = true
            visualEffect.layer?.cornerRadius = cornerRadius
            visualEffect.layer?.masksToBounds = true
            visualEffect.addSubview(content)
            material = visualEffect
        }
        container.addSubview(material)
        materialView = material
        return container
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

@available(macOS 26.0, *)
@MainActor
private final class DesktopGlassEffectView: NSGlassEffectView {
    private var isUpdatingBackdrop = false
    private var hasAdjustedBackdrop = false

    override func layout() {
        super.layout()
        updateBackdrop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.updateBackdrop() }
    }

    func updateBackdrop() {
        guard !isUpdatingBackdrop else { return }
        isUpdatingBackdrop = true
        defer { isUpdatingBackdrop = false }

        let workspace = NSWorkspace.shared
        if workspace.accessibilityDisplayShouldReduceTransparency || workspace.accessibilityDisplayShouldIncreaseContrast {
            if hasAdjustedBackdrop {
                hasAdjustedBackdrop = false
                // Rebuild the system material so accessibility takes precedence.
                style = .regular
                style = .clear
            }
            return
        }

        // Standalone windows retain a blur even with clear glass. Limit only
        // that blur; macOS still renders the material, lensing and highlights.
        // These Core Animation filter inputs are private. Leave native clear
        // glass untouched when the filter or its numeric input is unavailable.
        var visited = Set<ObjectIdentifier>()
        func updateLayer(_ layer: CALayer) {
            guard visited.insert(ObjectIdentifier(layer)).inserted else { return }
            if let filters = layer.filters {
                var changed = false
                for filter in filters {
                    guard let object = filter as? NSObject,
                          object.responds(to: NSSelectorFromString("type")),
                          object.responds(to: NSSelectorFromString("inputKeys")),
                          object.value(forKey: "type") as? String == "glassBackground",
                          let keys = object.value(forKey: "inputKeys") as? [String],
                          keys.contains("inputBlurRadius"),
                          let radius = object.value(forKey: "inputBlurRadius") as? NSNumber,
                          radius.doubleValue > 2 else { continue }
                    object.setValue(2.0, forKey: "inputBlurRadius")
                    changed = true
                    hasAdjustedBackdrop = true
                }
                if changed { layer.filters = filters }
            }
            for child in layer.sublayers ?? [] { updateLayer(child) }
        }
        func updateView(_ view: NSView) {
            if let layer = view.layer { updateLayer(layer) }
            for child in view.subviews { updateView(child) }
        }
        updateView(self)
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
