//
//  SleepPreventer.swift
//  QuickRecorder
//
//  Created by apple on 2024/12/9.
//

import Foundation
import IOKit.pwr_mgt

class SleepPreventer {
    static let shared = SleepPreventer()
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?
    
    @discardableResult
    func preventSleep(reason: String) -> Bool {
        lock.withLock {
            if assertionID != nil { return true }
            let type = "PreventUserIdleDisplaySleep" as CFString
            let reason = reason as CFString
            var newAssertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &newAssertionID
            )
            guard result == kIOReturnSuccess else {
                print("Failure to prevent sleep, error: \(result)")
                return false
            }
            assertionID = newAssertionID
            return true
        }
    }
    
    func allowSleep() {
        let ownedAssertionID = lock.withLock { () -> IOPMAssertionID? in
            defer { assertionID = nil }
            return assertionID
        }
        guard let ownedAssertionID else { return }
        let result = IOPMAssertionRelease(ownedAssertionID)
        if result != kIOReturnSuccess { print("Failed to release assertion, error: \(result)") }
    }
}
