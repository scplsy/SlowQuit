// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum CommandQAction: Sendable, Equatable {
    case requestQuit
    case sendShortcut
}

/// A snapshot of a direct child of the application's own menu, never the Apple
/// menu or an arbitrary command in a different menu. AX provides no portable
/// "this is Quit" action identifier, so ambiguous/localized titles fall back
/// to replay rather than guessing that an arbitrary Q command means Quit.
struct QuitMenuItem: Sendable {
    let title: String
    let commandCharacter: String?
    let commandModifiers: Int?
    let isEnabled: Bool

    func action(applicationNames: [String]) -> CommandQAction {
        // AX modifiers use implicit Command: 0 means Command only, 8 means
        // no Command. These are not CGEventFlags values.
        guard isEnabled, commandCharacter?.lowercased() == "q", commandModifiers == 0 else {
            return .sendShortcut
        }
        let title = normalized(title)
        var quitTitles: Set<String> = ["quit", "退出", "結束", "结束"]
        for name in applicationNames where !name.isEmpty {
            let name = normalized(name)
            quitTitles.formUnion(["quit \(name)", "退出\(name)", "退出 \(name)",
                                  "結束\(name)", "結束 \(name)", "结束\(name)", "结束 \(name)"])
        }
        return quitTitles.contains(title) ? .requestQuit : .sendShortcut
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
