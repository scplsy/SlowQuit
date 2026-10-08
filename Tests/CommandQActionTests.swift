import CoreGraphics
import XCTest
@testable import SlowQuitCore

final class CommandQActionTests: XCTestCase {
    func testRecognizedEnabledQuitUsesNormalTermination() {
        for title in ["Quit Editor", "QUIT EDITOR", "退出 Editor", "退出Editor", "結束 Editor", "Quit", "退出"] {
            let item = QuitMenuItem(title: title, commandCharacter: "Q", commandModifiers: 0, isEnabled: true)
            XCTAssertEqual(item.action(applicationNames: ["Editor"]), .requestQuit, title)
        }
    }

    func testDisabledRemappedAndCustomCommandsAlwaysReplay() {
        let items = [
            QuitMenuItem(title: "Quit Editor", commandCharacter: "Q", commandModifiers: 0, isEnabled: false),
            QuitMenuItem(title: "Quit Editor", commandCharacter: "W", commandModifiers: 0, isEnabled: true),
            QuitMenuItem(title: "Quit Editor", commandCharacter: "Q", commandModifiers: 1, isEnabled: true),
            QuitMenuItem(title: "Quit Editor", commandCharacter: "Q", commandModifiers: 8, isEnabled: true),
            QuitMenuItem(title: "Quick Open", commandCharacter: "Q", commandModifiers: 0, isEnabled: true),
            QuitMenuItem(title: "Quit Session", commandCharacter: "Q", commandModifiers: 0, isEnabled: true),
            QuitMenuItem(title: "Quit Editor", commandCharacter: nil, commandModifiers: nil, isEnabled: true),
            QuitMenuItem(title: "Unrecognized localized title", commandCharacter: "Q", commandModifiers: 0, isEnabled: true)
        ]
        for item in items { XCTAssertEqual(item.action(applicationNames: ["Editor"]), .sendShortcut, item.title) }
    }

    func testReplayHasBalancedTaggedKeyPairAndPreservesCapturedKeyIdentity() throws {
        // No events are posted: this test cannot activate or quit real apps.
        let original = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        original.flags = [.maskCommand, .maskAlphaShift]
        original.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let characters: [UniChar] = [81]
        original.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        let events = try XCTUnwrap(ShortcutReplay.events(for: original))
        XCTAssertEqual(events.down.type, .keyDown)
        XCTAssertEqual(events.up.type, .keyUp)
        XCTAssertFalse(ShortcutReplay.isOwnEvent(original))
        for event in [events.down, events.up] {
            XCTAssertTrue(ShortcutReplay.isOwnEvent(event))
            XCTAssertEqual(event.flags, original.flags)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 6)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertEqual(Array(buffer.prefix(length)), characters)
        }
    }
}
