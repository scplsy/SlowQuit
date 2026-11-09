// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct ShortcutModifiers: OptionSet, Sendable {
    let rawValue: Int
    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let option = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)
}

/// Pure transitions: timing is independent of key repeat; no application side effects.
struct HoldStateMachine {
    struct Hold: Equatable {
        let processID: Int32
        let startedAt: TimeInterval
        let duration: TimeInterval

        func progress(at time: TimeInterval) -> Double {
            min(1, max(0, (time - startedAt) / duration))
        }
    }

    enum Phase: Equatable {
        case idle
        case holding(Hold)
        // The initial native key-down passed, but repeats must not reach another app.
        // Its physical key-up must pass as well, to balance that native down.
        case passingThrough
        // Swallow repeats until Q is released, including after cancellation.
        case awaitingRelease
    }

    enum Disposition { case pass, suppress }

    private(set) var phase: Phase = .idle
    private(set) var appSwitcherActive = false
    private(set) var canRecoverOnFreshPress = false
    private var pendingShortPressCount = 0

    var hold: Hold? {
        if case .holding(let hold) = phase { return hold }
        return nil
    }

    var ownsQSequence: Bool { phase != .idle }

    mutating func qDown(
        at time: TimeInterval, modifiers: ShortcutModifiers, isRepeat: Bool,
        protectedProcessID: Int32?, delay: TimeInterval, guardRepeats: Bool = true
    ) -> Disposition {
        if canRecoverOnFreshPress, !isRepeat {
            // A fresh physical down proves a new press after a stream gap. A
            // repeat never proves that the missing key-up actually happened.
            phase = .idle
            canRecoverOnFreshPress = false
        }
        if ownsQSequence {
            if modifiers != .command { cancel() }
            return .suppress
        }
        guard guardRepeats, modifiers == .command, !appSwitcherActive else { return .pass }
        guard !isRepeat else {
            // The original press happened before monitoring, or before Command.
            // Require a fresh press instead of treating a repeat as confirmation.
            phase = .awaitingRelease
            return .suppress
        }
        guard let processID = protectedProcessID else {
            phase = .passingThrough
            return .pass
        }
        phase = .holding(Hold(processID: processID, startedAt: time, duration: DelaySettings.normalize(delay)))
        return .suppress
    }

    mutating func qUp(at time: TimeInterval) -> Disposition {
        let disposition: Disposition = ownsQSequence && phase != .passingThrough ? .suppress : .pass
        recordEarlyRelease(at: time)
        phase = .idle
        canRecoverOnFreshPress = false
        return disposition
    }

    mutating func modifiersChanged(_ modifiers: ShortcutModifiers, at time: TimeInterval) {
        if !modifiers.contains(.command) { appSwitcherActive = false }
        if modifiers.isEmpty { recordEarlyRelease(at: time) }
        if modifiers != .command { cancel() }
    }

    mutating func tabDown(modifiers: ShortcutModifiers) {
        if modifiers.contains(.command) { appSwitcherActive = true }
        cancel()
    }

    mutating func cancel() {
        if hold != nil { phase = .awaitingRelease }
    }

    /// Do not poll system key-state tables for a key whose down we suppressed.
    /// On a known input-stream gap, cancel and accept the next fresh press,
    /// while still swallowing repeats from the interrupted physical sequence.
    mutating func inputStreamInterrupted() {
        cancel()
        canRecoverOnFreshPress = ownsQSequence
    }

    @discardableResult
    mutating func applicationActivated(processID: Int32?) -> Bool {
        guard let hold, hold.processID != processID else { return false }
        cancel()
        return true
    }

    mutating func resetSwitcher() { appSwitcherActive = false }

    mutating func takeBlockedShortPressCount() -> Int {
        let count = pendingShortPressCount
        pendingShortPressCount = 0
        return count
    }

    private mutating func recordEarlyRelease(at time: TimeInterval) {
        guard let hold, time >= hold.startedAt, time - hold.startedAt < hold.duration else { return }
        pendingShortPressCount += 1
        phase = .awaitingRelease
    }

    /// Returns the captured target exactly once; the caller resolves its ⌘Q action.
    mutating func tick(at time: TimeInterval, frontmostProcessID: Int32?) -> Int32? {
        guard let hold else { return nil }
        guard frontmostProcessID == hold.processID else {
            cancel()
            return nil
        }
        // .holding means Q-down was observed and neither a Q-up nor a
        // cancelling modifier event has arrived. This is the authoritative
        // state, even if Quartz's separate polling table reports Q as up.
        guard time - hold.startedAt >= hold.duration else { return nil }
        phase = .awaitingRelease
        return hold.processID
    }
}
