// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from SlowQuitApps' SQAAppDelegate.m.
// SlowQuitApps Copyright (C) 2020 Douglas Teoh.
// 2026-09-28: rewritten in Swift with an independent timer, captured quit target,
// balanced event suppression, cancellation, and permission/tap recovery.
import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Combine
import OSLog

enum ProtectionStatus: String, Sendable {
    case protecting = "保护中"
    case paused = "已暂停"
    case needsPermission = "需要授权"
    case failed = "保护异常"

    var symbol: String {
        switch self {
        case .protecting: "hand.raised.fill"
        case .paused: "pause.circle"
        case .needsPermission: "lock.trianglebadge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

@MainActor
final class QuitProtectionService: ObservableObject {
    let preferences: Preferences
    @Published private(set) var status: ProtectionStatus = .needsPermission
    @Published private(set) var statusDetail = "开启辅助功能权限后，SlowQuit 才能保护 ⌘Q。"
    @Published private(set) var awaitingOwnQuit = false
    private(set) var isRequestingOwnQuit = false
    var onOwnQuitReady: (() -> Void)?
    var onOwnQuitCancelled: (() -> Void)?
    @Published var isEnabled = true {
        didSet {
            if !isEnabled { cancelHold() }
            checkHealth()
        }
    }

    private var machine = HoldStateMachine()
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var holdTimer: Timer?
    private var healthTimer: Timer?
    private var targetApplication: NSRunningApplication?
    private var capturedQCode: CGKeyCode?
    private var capturedQDown: CGEvent?
    private let menuInspector = QuitMenuInspector()
    private var pendingTrigger: UUID?
    private var observedPolicy: AnyCancellable?
    private enum Suspension: Hashable { case sleep, lock, inactiveSession }
    private var suspensions = Set<Suspension>()
    private var isSessionAvailable: Bool { suspensions.isEmpty }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let overlay = ProgressOverlayController()
    private var presentationScheduled = false
    private let logger = Logger(subsystem: "org.slowquit.SlowQuit", category: "Shortcut")

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { service, activatedPID in
            if service.machine.applicationActivated(processID: activatedPID) {
                service.logger.notice("Hold cancelled: application-changed.")
            }
            // Use the notification's target to catch a rapid switch away/back,
            // but don't cancel for duplicate activation of the same application.
            if let target = service.targetApplication, activatedPID == target.processIdentifier { return }
            service.cancelHold(reason: "application-changed")
        }
        observe(workspace, NSWorkspace.willSleepNotification) { service, _ in service.setSuspension(.sleep, active: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { service, _ in service.setSuspension(.sleep, active: false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { service, _ in service.setSuspension(.inactiveSession, active: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { service, _ in service.setSuspension(.inactiveSession, active: false) }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { service, _ in service.setSuspension(.lock, active: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { service, _ in service.setSuspension(.lock, active: false) }
        observe(distributed, Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)) { service, _ in
            service.cancelHold(reason: "input-source-changed")
        }
        observedPolicy = preferences.$protectionMode.combineLatest(preferences.$exclusions, preferences.$inclusions)
            .dropFirst().sink { [weak self] _ in
                // Every policy edit invalidates an in-flight decision, including
                // a switch away and back while the AX request is outstanding.
                self?.cancelHold()
            }
        checkHealth()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func stop() {
        awaitingOwnQuit = false
        cancelHold()
        overlay.hide()
        healthTimer?.invalidate()
        healthTimer = nil
        removeTap()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        observedPolicy = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        checkHealth()
    }

    func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func checkHealth() {
        guard AXIsProcessTrusted() else {
            cancelHold()
            removeTap()
            setStatus(.needsPermission, "系统尚未授予当前 SlowQuit 副本辅助功能权限。若开关已开启，请移除旧条目并重新添加当前应用。")
            return
        }
        guard isEnabled, isSessionAvailable else {
            cancelHold()
            setStatus(.paused, isEnabled ? "锁屏、睡眠或切换用户期间暂停保护。" : "本次运行已暂停保护；下次启动会自动恢复。")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            interruptInputStream(reason: "secure-input")
            setStatus(.failed, "安全键盘输入已开启，系统暂不允许保护快捷键；关闭后会自动恢复。")
            return
        }
        if let eventTap, !CFMachPortIsValid(eventTap) { removeTap() }
        if eventTap == nil, !installTap() {
            setStatus(.failed, "无法建立快捷键监听。请检查辅助功能授权，或退出后重新打开 SlowQuit。")
            return
        }
        if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
            interruptInputStream(reason: "tap-disabled")
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                removeTap()
                setStatus(.failed, "快捷键监听已中断，正在尝试恢复。")
                return
            }
        }
        setStatus(.protecting, awaitingOwnQuit ? "松开 Q 以退出 SlowQuit。" : "持续按住 ⌘Q 以确认，提前松手即可取消。")
    }

    private func installTap() -> Bool {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            // This tap is installed exclusively on the main run loop.
            let suppress = MainActor.assumeIsolated {
                let service = Unmanaged<QuitProtectionService>.fromOpaque(context).takeUnretainedValue()
                return service.handle(type: type, event: event) == nil
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // If monitoring began halfway through Command-Tab, bypass until Command
        // is released; there is no public API for the switcher's selected app.
        if NSEvent.modifierFlags.contains(.command) { machine.tabDown(modifiers: .command) }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func removeTap() {
        if let eventTap {
            interruptInputStream(reason: "tap-removed")
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        eventSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interruptInputStream(reason: "tap-interrupted")
            setStatus(.failed, "快捷键监听已中断，正在尝试恢复。")
            // Retry outside the callback, after cancellation has taken effect.
            DispatchQueue.main.async { [weak self] in self?.checkHealth() }
            return Unmanaged.passUnretained(event)
        }

        if ShortcutReplay.isOwnEvent(event) { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        let modifiers = Self.modifiers(from: event.flags)
        if type == .flagsChanged {
            let wasHolding = machine.hold != nil
            if !modifiers.subtracting(.command).isEmpty { cancelHold() }
            machine.modifiersChanged(modifiers, at: now)
            if wasHolding, machine.hold == nil { logger.notice("Hold cancelled by modifier change.") }
            recordShortPresses()
            schedulePresentation()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, capturedQCode == keyCode {
            logger.notice("Physical Q released.")
            let disposition = machine.qUp(at: now)
            recordShortPresses()
            releasePhysicalSequence()
            schedulePresentation()
            return disposition == .suppress ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if keyCode == CGKeyCode(kVK_Tab) {
            cancelHold()
            machine.tabDown(modifiers: modifiers)
            schedulePresentation()
            return Unmanaged.passUnretained(event)
        }

        let isQ = capturedQCode == keyCode || Self.isQuitKey(event, keyCode: keyCode)
        guard isQ else {
            // A different shortcut during a hold also abandons the pending quit.
            cancelHold()
            schedulePresentation()
            return Unmanaged.passUnretained(event)
        }

        let app = NSWorkspace.shared.frontmostApplication
        let guarding = status == .protecting && isEnabled && isSessionAvailable
        let canProtect = guarding && preferences.shouldProtect(app?.bundleIdentifier)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let recovering = machine.canRecoverOnFreshPress && !isRepeat
        let ownedSequence = machine.ownsQSequence && !recovering
        if recovering { releasePhysicalSequence() }
        if !ownedSequence { pendingTrigger = nil }
        let disposition = machine.qDown(
            at: now, modifiers: modifiers,
            isRepeat: isRepeat,
            protectedProcessID: canProtect ? app?.processIdentifier : nil,
            delay: preferences.delay, guardRepeats: guarding
        )
        if machine.ownsQSequence, !ownedSequence {
            capturedQCode = keyCode
            capturedQDown = event.copy()
            targetApplication = app
            if machine.hold != nil {
                logger.notice("Hold started; delay=\(self.preferences.delay, privacy: .public)s.")
                startHoldTimer()
            }
        }
        schedulePresentation()
        return disposition == .suppress ? nil : Unmanaged.passUnretained(event)
    }

    private func startHoldTimer() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func tick() {
        guard isEnabled, isSessionAvailable, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let eventTap, CGEvent.tapIsEnabled(tap: eventTap),
              let targetApplication, !targetApplication.isTerminated,
              preferences.shouldProtect(targetApplication.bundleIdentifier) else {
            cancelHold()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let completedTarget = machine.tick(
            at: now, frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
        recordShortPresses()
        updatePresentation()
        if completedTarget == targetApplication.processIdentifier, let capturedQDown {
            logger.notice("Hold confirmed.")
            resolveTrigger(for: targetApplication, event: capturedQDown)
        }
    }

    private func resolveTrigger(for application: NSRunningApplication, event: CGEvent) {
        let token = UUID()
        pendingTrigger = token
        var names = [application.localizedName].compactMap { $0 }
        if let url = application.bundleURL, let bundle = Bundle(url: url) {
            for key in ["CFBundleName", "CFBundleDisplayName"] {
                if let name = bundle.object(forInfoDictionaryKey: key) as? String { names.append(name) }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let action = await menuInspector.action(for: application.processIdentifier, applicationNames: names)
            guard pendingTrigger == token else { return }
            pendingTrigger = nil
            guard isEnabled, isSessionAvailable, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                  let eventTap, CGEvent.tapIsEnabled(tap: eventTap), !application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                  preferences.shouldProtect(application.bundleIdentifier) else { return }

            switch action {
            case .requestQuit:
                if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    isRequestingOwnQuit = true
                    NSApp.terminate(nil)
                    isRequestingOwnQuit = false
                } else {
                    // No replay retry: a refusal may be intentional, and posting
                    // another action could duplicate an asynchronously handled quit.
                    let accepted = application.terminate()
                    logger.notice("Normal quit requested; accepted=\(accepted, privacy: .public).")
                }
            case .sendShortcut:
                guard let events = ShortcutReplay.events(for: event) else {
                    setStatus(.failed, "无法发送确认后的 ⌘Q，请松开按键后重试。")
                    return
                }
                // Address the captured process, not whichever app next gets focus.
                events.down.postToPid(application.processIdentifier)
                events.up.postToPid(application.processIdentifier)
                logger.notice("Confirmed shortcut posted.")
            }
        }
    }

    /// Called by NSApplicationDelegate for a keyboard-originated self quit only.
    /// The event tap must stay alive until the real Q release, including when
    /// SlowQuit was excluded and its initial native key-down passed immediately.
    func deferOwnQuitUntilRelease() -> Bool {
        guard machine.ownsQSequence, capturedQCode != nil,
              targetApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        awaitingOwnQuit = true
        cancelHold()
        setStatus(status, "松开 Q 以退出 SlowQuit。")
        return true
    }

    private func recordShortPresses() {
        preferences.recordBlockedShortPresses(machine.takeBlockedShortPressCount())
    }

    private func releasePhysicalSequence() {
        capturedQCode = nil
        capturedQDown = nil
        targetApplication = nil
        if awaitingOwnQuit {
            awaitingOwnQuit = false
            overlay.hide()
            // Do not terminate inside the C event-tap callback.
            DispatchQueue.main.async { [weak self] in self?.onOwnQuitReady?() }
        }
    }

    private func cancelHold(reason: String = "state-changed") {
        if machine.hold != nil || pendingTrigger != nil {
            logger.notice("Hold cancelled: \(reason, privacy: .public).")
        }
        pendingTrigger = nil
        machine.cancel()
        updatePresentation()
    }

    private func schedulePresentation() {
        guard !presentationScheduled else { return }
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.updatePresentation()
        }
    }

    private func updatePresentation() {
        if awaitingOwnQuit, let targetApplication {
            if preferences.showOverlay {
                overlay.show(application: targetApplication, progress: 1, awaitingRelease: true)
            } else {
                overlay.hide()
            }
            return
        }
        guard let hold = machine.hold, let targetApplication else {
            holdTimer?.invalidate()
            holdTimer = nil
            overlay.hide()
            return
        }
        if preferences.showOverlay {
            overlay.show(application: targetApplication, progress: hold.progress(at: ProcessInfo.processInfo.systemUptime))
        } else {
            overlay.hide()
        }
    }

    private func interruptInputStream(reason: String) {
        // A lost key-up cannot be repaired by polling a suppressed key. Cancel
        // pending self-termination too, rather than guessing that Q was released.
        if awaitingOwnQuit {
            awaitingOwnQuit = false
            DispatchQueue.main.async { [weak self] in self?.onOwnQuitCancelled?() }
        }
        cancelHold(reason: reason)
        machine.inputStreamInterrupted()
    }

    private func setSuspension(_ reason: Suspension, active: Bool) {
        // Waking must not resume protection while the session is still locked.
        if active { suspensions.insert(reason) } else { suspensions.remove(reason) }
        interruptInputStream(reason: "session-changed")
        machine.resetSwitcher()
        checkHealth()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (QuitProtectionService, pid_t?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let self { action(self, activatedPID) }
            }
        }
        observers.append((center, token))
    }

    private func setStatus(_ status: ProtectionStatus, _ detail: String) {
        if self.status != status { self.status = status }
        if statusDetail != detail { statusDetail = detail }
    }

    private static func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        // Caps Lock, numeric-pad and device-specific flags do not change ⌘Q.
        return result
    }

    private static func isQuitKey(_ event: CGEvent, keyCode: CGKeyCode) -> Bool {
        if let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.lowercased() == "q"
        }
        var characters = [UniChar](repeating: 0, count: 8)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        if count > 0 {
            return String(utf16CodeUnits: characters, count: count).lowercased() == "q"
        }
        return keyCode == CGKeyCode(kVK_ANSI_Q)
    }
}
