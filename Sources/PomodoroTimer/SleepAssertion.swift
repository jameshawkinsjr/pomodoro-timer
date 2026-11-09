import Foundation
import IOKit.pwr_mgt

/// Wraps an IOKit power-management assertion that keeps the Mac (and optionally the display) awake.
@MainActor
final class SleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    /// Acquires the assertion, replacing any existing one. Returns false if macOS refused it.
    @discardableResult
    func acquire(keepDisplayAwake: Bool) -> Bool {
        release()

        // "PreventUserIdleDisplaySleep" keeps the screen on (and implies the system stays awake);
        // "PreventUserIdleSystemSleep" lets the display sleep but keeps the Mac running.
        let type = keepDisplayAwake ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Pomodoro Timer session" as CFString,
            &assertionID
        )
        isHeld = result == kIOReturnSuccess
        return isHeld
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }
}
