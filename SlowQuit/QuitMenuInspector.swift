// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import ApplicationServices

/// AX can block while another application is busy. Keep all queries off the
/// event-tap/main thread, bound their work, and fall back to the original shortcut.
final class QuitMenuInspector: Sendable {
    private let queue = DispatchQueue(label: "org.slowquit.menu-inspection", qos: .userInitiated)

    func action(for processID: pid_t, applicationNames: [String]) async -> CommandQAction {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.inspect(processID: processID, names: applicationNames))
            }
        }
    }

    private static func inspect(processID: pid_t, names: [String]) -> CommandQAction {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        let application = AXUIElementCreateApplication(processID)

        func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.02)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &result) == .success else { return nil }
            return result
        }

        func children(_ element: AXUIElement) -> [AXUIElement]? {
            value(element, kAXChildrenAttribute as CFString) as? [AXUIElement]
        }

        guard let menuValue = value(application, kAXMenuBarAttribute as CFString),
              CFGetTypeID(menuValue) == AXUIElementGetTypeID(),
              let topItems = children(menuValue as! AXUIElement) else { return .sendShortcut }

        // Never assume an unchecked array index denotes the application's menu.
        // Match its title to the app's known display/bundle names instead.
        let normalizedNames = Set(names.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        var applicationMenu: AXUIElement?
        for item in topItems.prefix(12) {
            if let title = value(item, kAXTitleAttribute as CFString) as? String,
               normalizedNames.contains(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) {
                applicationMenu = children(item)?.first
                break
            }
        }
        guard let applicationMenu, let items = children(applicationMenu), items.count <= 64 else { return .sendShortcut }
        var candidates: [QuitMenuItem] = []
        for item in items {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .sendShortcut }
            guard let character = value(item, kAXMenuItemCmdCharAttribute as CFString) as? String,
                  character.lowercased() == "q" else { continue }
            guard let role = value(item, kAXRoleAttribute as CFString) as? String,
                  role == (kAXMenuItemRole as String),
                  let title = value(item, kAXTitleAttribute as CFString) as? String,
                  let enabled = value(item, kAXEnabledAttribute as CFString) as? Bool,
                  let modifiers = value(item, kAXMenuItemCmdModifiersAttribute as CFString) as? NSNumber else {
                return .sendShortcut
            }
            if modifiers.intValue == 0 {
                candidates.append(QuitMenuItem(title: title, commandCharacter: character,
                                               commandModifiers: modifiers.intValue, isEnabled: enabled))
            }
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, candidates.count == 1 else { return .sendShortcut }
        return candidates[0].action(applicationNames: names)
    }
}
