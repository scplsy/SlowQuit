// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import SwiftUI

@main
struct SlowQuitApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = Preferences()
    private lazy var service = QuitProtectionService(preferences: preferences)
    private let loginItem = LoginItemManager()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private let stateMenuItem = NSMenuItem()
    private let toggleMenuItem = NSMenuItem()
    private let countMenuItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupApplicationMenu()
        setupStatusItem()
        service.$status.combineLatest(service.$statusDetail).sink { [weak self] status, detail in
            self?.updateStatusItem(status: status, detail: detail)
        }.store(in: &subscriptions)
        preferences.$blockedShortPressCount.sink { [weak self] count in
            self?.countMenuItem.title = "已拦截短按 \(count.formatted()) 次"
        }.store(in: &subscriptions)
        service.onOwnQuitReady = { NSApp.reply(toApplicationShouldTerminate: true) }
        service.onOwnQuitCancelled = { NSApp.reply(toApplicationShouldTerminate: false) }
        service.start()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if firstLaunch || service.status == .needsPermission { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) { service.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = sender.currentEvent
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option, .function]
        let keyboardQuit = event?.type == .keyDown && event?.modifierFlags.intersection(shortcutModifiers) == .command
            && event?.charactersIgnoringModifiers?.lowercased() == "q"
        if (service.isRequestingOwnQuit || keyboardQuit), service.deferOwnQuitUntilRelease() {
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleMenuItem.title = service.isEnabled ? "暂停保护" : "恢复保护"
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: min(740, (NSScreen.main?.visibleFrame.height ?? 900) - 80)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "SlowQuit 设置"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 550, height: 540)
            window.contentMaxSize = NSSize(width: 550, height: 1000)
            window.contentView = NSHostingView(rootView: SettingsView(service: service, preferences: preferences, loginItem: loginItem))
            window.center()
            settingsWindow = window
        }
        loginItem.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleProtection() { service.isEnabled.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPermissionSettings() { service.openAccessibilitySettings() }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        countMenuItem.isEnabled = false
        menu.addItem(countMenuItem)
        menu.addItem(.separator())
        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleProtection)
        menu.addItem(toggleMenuItem)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let permission = NSMenuItem(title: "辅助功能权限…", action: #selector(openPermissionSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SlowQuit", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        // Use a persistent NSStatusItem so the protection's visible control
        // cannot be accidentally removed while the process continues running.
        statusItem = item
    }

    private func updateStatusItem(status: ProtectionStatus, detail: String) {
        statusItem?.button?.image = StatusIcon.image(for: status)
        statusItem?.button?.toolTip = "SlowQuit · \(status.rawValue)\n\(detail)"
        statusItem?.button?.setAccessibilityLabel("SlowQuit，\(status.rawValue)")
        stateMenuItem.title = "SlowQuit · \(status.rawValue)"
    }

    private func setupApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "SlowQuit")
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SlowQuit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
