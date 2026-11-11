import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while something is actually playing.
final class SleepGuard {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func update(playing: Bool) {
        let want = playing && Prefs.preventSleep
        guard want != held else { return }
        if want {
            let reason = "Playing video in NFM" as CFString
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID)
            held = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }

    deinit {
        if held { IOPMAssertionRelease(assertionID) }
    }
}
