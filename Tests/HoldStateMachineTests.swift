import XCTest
@testable import SlowQuitCore

final class HoldStateMachineTests: XCTestCase {
    private func begin(_ machine: inout HoldStateMachine, delay: Double = 1) {
        XCTAssertEqual(machine.qDown(at: 10, modifiers: .command, isRepeat: false,
                                     protectedProcessID: 42, delay: delay), .suppress)
    }

    func testShortPressIsSwallowedAndCancelled() {
        var machine = HoldStateMachine()
        begin(&machine)
        XCTAssertNil(machine.tick(at: 10.9, frontmostProcessID: 42))
        XCTAssertEqual(machine.qUp(at: 10.9), .suppress)
        XCTAssertNil(machine.tick(at: 11, frontmostProcessID: 42))
        XCTAssertEqual(machine.phase, .idle)
    }

    func testTimerCompletesWithoutKeyRepeatAndOnlyOnce() {
        var machine = HoldStateMachine()
        begin(&machine)
        XCTAssertEqual(machine.tick(at: 11, frontmostProcessID: 42), 42)
        XCTAssertNil(machine.tick(at: 12, frontmostProcessID: 42))
        XCTAssertEqual(machine.qDown(at: 12, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 99, delay: 1), .suppress)
        XCTAssertNil(machine.hold)
        XCTAssertEqual(machine.qUp(at: 12), .suppress)
    }

    func testChangingFocusNeverQuitsEitherApplication() {
        var machine = HoldStateMachine()
        begin(&machine)
        XCTAssertNil(machine.tick(at: 11, frontmostProcessID: 99))
        XCTAssertNil(machine.tick(at: 12, frontmostProcessID: 42))
        XCTAssertEqual(machine.phase, .awaitingRelease)
    }

    func testCommandReleaseCannotRestartUntilQReleased() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.modifiersChanged([], at: 10.2)
        machine.modifiersChanged(.command, at: 10.3)
        XCTAssertEqual(machine.qDown(at: 12, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertNil(machine.tick(at: 13, frontmostProcessID: 42))
        _ = machine.qUp(at: 13)
        begin(&machine)
        XCTAssertNotNil(machine.hold)
    }

    func testPhysicalReleaseAtThresholdCancelsBeforeCompletion() {
        var machine = HoldStateMachine()
        begin(&machine)
        _ = machine.qUp(at: 11)
        XCTAssertNil(machine.tick(at: 11, frontmostProcessID: 42))
    }

    func testAdditionalModifiersCancelAndSystemShortcutsPass() {
        for extra in [ShortcutModifiers.control, .shift, .option, .function] {
            var machine = HoldStateMachine()
            XCTAssertEqual(machine.qDown(at: 0, modifiers: [.command, extra], isRepeat: false,
                                         protectedProcessID: 42, delay: 1), .pass)
            begin(&machine)
            machine.modifiersChanged([.command, extra], at: 10.2)
            XCTAssertNil(machine.tick(at: 12, frontmostProcessID: 42))
            XCTAssertEqual(machine.qUp(at: 12), .suppress)
        }
    }

    func testAppSwitcherQuitPassesUntilCommandReleased() {
        var machine = HoldStateMachine()
        machine.tabDown(modifiers: .command)
        XCTAssertEqual(machine.qDown(at: 0, modifiers: .command, isRepeat: false,
                                     protectedProcessID: 42, delay: 1), .pass)
        _ = machine.qUp(at: 0.2)
        XCTAssertTrue(machine.appSwitcherActive)
        machine.modifiersChanged([], at: 1)
        begin(&machine)
        XCTAssertNotNil(machine.hold)
    }

    func testTabDuringHoldCancelsAndKeepsSwallowingOriginalSequence() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.tabDown(modifiers: .command)
        XCTAssertEqual(machine.qDown(at: 12, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertNil(machine.hold)
    }

    func testExcludedFirstPressPassesButRepeatsCannotQuitTheNextApp() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.qDown(at: 0, modifiers: .command, isRepeat: false,
                                     protectedProcessID: nil, delay: 1), .pass)
        XCTAssertEqual(machine.qDown(at: 2, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertEqual(machine.qUp(at: 2.1), .pass)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testExternalCancellationNeedsFreshQPress() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.cancel() // Pause, sleep, permission loss, or another shortcut.
        XCTAssertEqual(machine.phase, .awaitingRelease)
        XCTAssertNil(machine.tick(at: 20, frontmostProcessID: 42))
        XCTAssertEqual(machine.qUp(at: 20), .suppress)
        begin(&machine)
        XCTAssertNotNil(machine.hold)
    }

    func testMissedReleaseAfterInterruptionRecoversOnlyOnFreshPress() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.inputStreamInterrupted()
        XCTAssertTrue(machine.canRecoverOnFreshPress)
        XCTAssertEqual(machine.qDown(at: 11, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertEqual(machine.phase, .awaitingRelease)
        XCTAssertNil(machine.tick(at: 12, frontmostProcessID: 42))
        XCTAssertEqual(machine.qDown(at: 13, modifiers: .command, isRepeat: false,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertEqual(machine.tick(at: 14, frontmostProcessID: 42), 42)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testChangingDelayDuringRepeatDoesNotChangeCurrentDeadline() {
        var machine = HoldStateMachine()
        begin(&machine, delay: 2)
        _ = machine.qDown(at: 10.5, modifiers: .command, isRepeat: true, protectedProcessID: 42, delay: 0.3)
        XCTAssertNil(machine.tick(at: 11, frontmostProcessID: 42))
        XCTAssertEqual(machine.tick(at: 12, frontmostProcessID: 42), 42)
    }

    func testPauseLeavesNewSequencesNativeIncludingRepeats() {
        var machine = HoldStateMachine()
        for repeated in [false, true, true] {
            XCTAssertEqual(machine.qDown(at: 0, modifiers: .command, isRepeat: repeated,
                                         protectedProcessID: nil, delay: 1, guardRepeats: false), .pass)
        }
        XCTAssertEqual(machine.qUp(at: 1), .pass)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testUnownedRepeatRequiresFreshPressRatherThanQuitting() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.qDown(at: 0, modifiers: .command, isRepeat: true,
                                     protectedProcessID: 42, delay: 1), .suppress)
        XCTAssertNil(machine.hold)
        _ = machine.qUp(at: 0.1)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        begin(&machine)
    }

    func testQReleaseCountsOnceAndCountCanBeDrained() {
        var machine = HoldStateMachine()
        begin(&machine)
        _ = machine.qDown(at: 10.1, modifiers: .command, isRepeat: true, protectedProcessID: 42, delay: 1)
        _ = machine.qUp(at: 10.2)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 1)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        _ = machine.qUp(at: 10.3)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testCommandThenQReleaseCountsOnlyOnce() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.modifiersChanged([], at: 10.2)
        _ = machine.qUp(at: 10.3)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 1)
    }

    func testObservedKeyUpCancelsBeforeNextTimerAndCountsOnlyOnce() {
        var machine = HoldStateMachine()
        begin(&machine)
        _ = machine.qUp(at: 10.31)
        XCTAssertNil(machine.tick(at: 10.4, frontmostProcessID: 42))
        XCTAssertNil(machine.tick(at: 12, frontmostProcessID: 42))
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 1)
    }

    func testCompletedHoldsAndReleaseAtDeadlineDoNotCount() {
        var machine = HoldStateMachine()
        begin(&machine)
        XCTAssertEqual(machine.tick(at: 11, frontmostProcessID: 42), 42)
        _ = machine.qUp(at: 11.1)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        begin(&machine)
        _ = machine.qUp(at: 11)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testExternalAndModifierCancellationsDoNotCount() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.cancel()
        _ = machine.qUp(at: 10.2)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        begin(&machine)
        machine.modifiersChanged([.command, .control], at: 10.1)
        machine.modifiersChanged([], at: 10.2)
        _ = machine.qUp(at: 10.3)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testFocusChangeTakesPrecedenceOverSimultaneousReleaseForCounting() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.applicationActivated(processID: 99)
        XCTAssertNil(machine.tick(at: 10.2, frontmostProcessID: 99))
        _ = machine.qUp(at: 10.3)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testPassthroughSequenceSurvivesFocusChangeAndAllowsNewQAfterRelease() {
        var machine = HoldStateMachine()
        XCTAssertEqual(machine.qDown(at: 0, modifiers: .command, isRepeat: false,
                                     protectedProcessID: nil, delay: 1), .pass)
        machine.cancel() // The excluded app quit and another application activated.
        XCTAssertEqual(machine.qDown(at: 2, modifiers: .command, isRepeat: true,
                                     protectedProcessID: nil, delay: 1), .suppress)
        XCTAssertEqual(machine.qUp(at: 2.1), .pass)
        begin(&machine) // Command may remain held between deliberate Q presses.
    }

    func testSuppressedDownStaysHeldAcrossProgressTicksWithoutPollingOrRepeats() {
        var machine = HoldStateMachine()
        begin(&machine)
        // No key-up arrives. Suppressing the key-down must not erase it from
        // our state, even when the OS polling table never observed the down.
        for frame in 1..<60 {
            XCTAssertNil(machine.tick(at: 10 + Double(frame) / 60, frontmostProcessID: 42))
            XCTAssertNotNil(machine.hold)
        }
        XCTAssertEqual(machine.tick(at: 11, frontmostProcessID: 42), 42)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        XCTAssertTrue(machine.ownsQSequence)
    }

    func testDuplicateActivationOfTargetKeepsHoldButAwayAndBackCancels() {
        var machine = HoldStateMachine()
        begin(&machine)
        XCTAssertFalse(machine.applicationActivated(processID: 42))
        XCTAssertNotNil(machine.hold)
        XCTAssertTrue(machine.applicationActivated(processID: 99))
        machine.applicationActivated(processID: 42)
        XCTAssertNil(machine.tick(at: 11, frontmostProcessID: 42))
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testInterruptedPassthroughStillSwallowsRepeatsUntilNewPress() {
        var machine = HoldStateMachine()
        _ = machine.qDown(at: 0, modifiers: .command, isRepeat: false, protectedProcessID: nil, delay: 1)
        machine.inputStreamInterrupted()
        XCTAssertEqual(machine.qDown(at: 1, modifiers: .command, isRepeat: true,
                                     protectedProcessID: nil, delay: 1), .suppress)
        XCTAssertEqual(machine.qDown(at: 2, modifiers: .command, isRepeat: false,
                                     protectedProcessID: nil, delay: 1), .pass)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
    }

    func testInterruptionFollowedByActualKeyUpRearmsNormally() {
        var machine = HoldStateMachine()
        begin(&machine)
        machine.inputStreamInterrupted()
        XCTAssertEqual(machine.qUp(at: 10.2), .suppress)
        XCTAssertFalse(machine.canRecoverOnFreshPress)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.takeBlockedShortPressCount(), 0)
        begin(&machine)
    }
}
