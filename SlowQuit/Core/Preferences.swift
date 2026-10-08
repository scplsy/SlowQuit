// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation

enum DelaySettings {
    static let range = 0.3...5.0
    static let defaultValue = 1.0

    static func normalize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return (min(range.upperBound, max(range.lowerBound, value)) * 10).rounded() / 10
    }
}

enum ProtectionMode: String, CaseIterable, Identifiable {
    case allExceptListed
    case onlyListed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .allExceptListed: "保护全部，排除指定应用"
        case .onlyListed: "仅保护指定应用"
        }
    }
}

struct ApplicationRule: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var name: String
    var id: String { bundleIdentifier }
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults

    @Published private var storedDelay: Double
    var delay: Double {
        get { storedDelay }
        set {
            storedDelay = DelaySettings.normalize(newValue)
            defaults.set(storedDelay, forKey: "quitDelay")
        }
    }

    @Published var showOverlay: Bool {
        didSet { defaults.set(showOverlay, forKey: "showOverlay") }
    }

    @Published var protectionMode: ProtectionMode {
        didSet { defaults.set(protectionMode.rawValue, forKey: "protectionMode") }
    }

    @Published private(set) var exclusions: [ApplicationRule] {
        didSet {
            if let data = try? JSONEncoder().encode(exclusions) {
                defaults.set(data, forKey: "excludedApplications")
            }
        }
    }

    @Published private(set) var inclusions: [ApplicationRule] {
        didSet {
            if let data = try? JSONEncoder().encode(inclusions) {
                defaults.set(data, forKey: "includedApplications")
            }
        }
    }

    @Published private(set) var blockedShortPressCount: Int {
        didSet { defaults.set(blockedShortPressCount, forKey: "blockedShortPressCount") }
    }

    var activeRules: [ApplicationRule] {
        protectionMode == .allExceptListed ? exclusions : inclusions
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["quitDelay": 1.0, "showOverlay": true])
        storedDelay = DelaySettings.normalize(defaults.double(forKey: "quitDelay"))
        showOverlay = defaults.bool(forKey: "showOverlay")
        protectionMode = ProtectionMode(rawValue: defaults.string(forKey: "protectionMode") ?? "") ?? .allExceptListed
        blockedShortPressCount = max(0, defaults.integer(forKey: "blockedShortPressCount"))
        if let data = defaults.data(forKey: "excludedApplications"),
           let saved = try? JSONDecoder().decode([ApplicationRule].self, from: data) {
            exclusions = saved
        } else {
            exclusions = [ApplicationRule(bundleIdentifier: "com.apple.finder", name: "访达")]
        }
        if let data = defaults.data(forKey: "includedApplications"),
           let saved = try? JSONDecoder().decode([ApplicationRule].self, from: data) {
            inclusions = saved
        } else {
            inclusions = []
        }
    }

    func isExcluded(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return exclusions.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func shouldProtect(_ bundleIdentifier: String?) -> Bool {
        switch protectionMode {
        case .allExceptListed: return !isExcluded(bundleIdentifier)
        case .onlyListed:
            guard let bundleIdentifier else { return false }
            return inclusions.contains { $0.id == bundleIdentifier }
        }
    }

    func addRule(_ application: ApplicationRule) {
        if protectionMode == .allExceptListed {
            addExclusion(application)
        } else {
            inclusions = replacing(application, in: inclusions)
        }
    }

    func removeRule(id: String) {
        if protectionMode == .allExceptListed {
            removeExclusion(id: id)
        } else {
            inclusions.removeAll { $0.id == id }
        }
    }

    func addExclusion(_ application: ApplicationRule) {
        exclusions = replacing(application, in: exclusions)
    }

    func removeExclusion(id: String) {
        exclusions.removeAll { $0.id == id }
    }

    func recordBlockedShortPresses(_ count: Int) {
        guard count > 0 else { return }
        blockedShortPressCount += min(count, Int.max - blockedShortPressCount)
    }

    func resetBlockedShortPressCount() { blockedShortPressCount = 0 }

    private func replacing(_ application: ApplicationRule, in list: [ApplicationRule]) -> [ApplicationRule] {
        (list.filter { $0.id != application.id } + [application])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
