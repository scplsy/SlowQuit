// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics

enum ShortcutReplay {
    // Per-process marker. Own events must bypass ALL gesture processing,
    // especially Q-up handling, which belongs to the physical keyboard only.
    static let marker = Int64.random(in: 1...Int64.max)

    static func isOwnEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Creates a brief, non-repeating key pair. Does not post events or synthesize
    /// Command key transitions; the physical modifier remains owned by the user.
    static func events(for original: CGEvent) -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = marker
        let keyCode = CGKeyCode(original.getIntegerValueField(.keyboardEventKeycode))
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        var characters = [UniChar](repeating: 0, count: 16)
        var count = 0
        original.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        for event in [down, up] {
            event.flags = original.flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if count > 0 { event.keyboardSetUnicodeString(stringLength: count, unicodeString: characters) }
        }
        return (down, up)
    }
}
