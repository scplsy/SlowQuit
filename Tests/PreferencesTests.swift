import XCTest
@testable import SlowQuitCore

final class PreferencesTests: XCTestCase {
    func testValuesAndApplicationIdentitySurviveRelaunch() {
        let suite = "SlowQuitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.delay, 1)
        XCTAssertTrue(preferences.showOverlay)
        XCTAssertTrue(preferences.isExcluded("com.apple.finder"))

        preferences.delay = 2.34
        preferences.showOverlay = false
        preferences.addExclusion(.init(bundleIdentifier: "test.editor", name: "Editor"))
        preferences.addExclusion(.init(bundleIdentifier: "test.editor", name: "Renamed Editor"))
        preferences.removeExclusion(id: "com.apple.finder")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.delay, 2.3)
        XCTAssertFalse(reloaded.showOverlay)
        XCTAssertEqual(reloaded.exclusions, [.init(bundleIdentifier: "test.editor", name: "Renamed Editor")])
        reloaded.removeExclusion(id: "test.editor")
        XCTAssertTrue(Preferences(defaults: defaults).exclusions.isEmpty)
    }

    func testInvalidDurationsCannotProduceInstantOrInfiniteHold() {
        XCTAssertEqual(DelaySettings.normalize(-1), 0.3)
        XCTAssertEqual(DelaySettings.normalize(99), 5)
        XCTAssertEqual(DelaySettings.normalize(.nan), 1)
        XCTAssertEqual(DelaySettings.normalize(.infinity), 1)
        XCTAssertEqual(DelaySettings.normalize(1.26), 1.3)
    }

    func testCorruptStoredPreferencesHaveUsableDefaults() {
        let suite = "SlowQuitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-2, forKey: "quitDelay")
        defaults.set(Data([0, 1, 2]), forKey: "excludedApplications")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.delay, 0.3)
        XCTAssertTrue(preferences.isExcluded("com.apple.finder"))
    }

    func testExistingExclusionsMigrateWithoutReinterpretingOrRestoringFinder() {
        let suite = "SlowQuitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("[{\"bundleIdentifier\":\"test.editor\",\"name\":\"Editor\"}]".utf8), forKey: "excludedApplications")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.protectionMode, .allExceptListed)
        XCTAssertFalse(preferences.shouldProtect("test.editor"))
        XCTAssertTrue(preferences.shouldProtect("com.apple.finder"))
        XCTAssertTrue(preferences.inclusions.isEmpty)
        XCTAssertEqual(preferences.blockedShortPressCount, 0)
    }

    func testTwoModesRememberIndependentListsIncludingEmptyInclusionList() {
        let suite = "SlowQuitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.addRule(.init(bundleIdentifier: "test.excluded", name: "Excluded"))
        preferences.protectionMode = .onlyListed
        XCTAssertFalse(preferences.shouldProtect("test.excluded"))
        XCTAssertFalse(preferences.shouldProtect("test.editor"))
        XCTAssertFalse(preferences.shouldProtect(nil))
        preferences.addRule(.init(bundleIdentifier: "test.editor", name: "Editor"))
        XCTAssertTrue(preferences.shouldProtect("test.editor"))

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.protectionMode, .onlyListed)
        XCTAssertTrue(reloaded.shouldProtect("test.editor"))
        reloaded.protectionMode = .allExceptListed
        XCTAssertFalse(reloaded.shouldProtect("test.excluded"))
        XCTAssertTrue(reloaded.shouldProtect("test.editor"))
        reloaded.removeRule(id: "test.excluded")
        reloaded.protectionMode = .onlyListed
        XCTAssertEqual(reloaded.activeRules.map(\.id), ["test.editor"])
    }

    func testCountPersistsResetsAndDoesNotOverflow() {
        let suite = "SlowQuitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.recordBlockedShortPresses(2)
        preferences.recordBlockedShortPresses(0)
        XCTAssertEqual(Preferences(defaults: defaults).blockedShortPressCount, 2)
        preferences.recordBlockedShortPresses(Int.max)
        XCTAssertEqual(preferences.blockedShortPressCount, Int.max)
        preferences.resetBlockedShortPressCount()
        XCTAssertEqual(Preferences(defaults: defaults).blockedShortPressCount, 0)
    }
}
