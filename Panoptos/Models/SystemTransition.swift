import AppKit
import Foundation

/// System states that invalidate live Accessibility elements without closing
/// anything. Each case pairs the notification that starts the state with the
/// one that ends it, so the two can never drift apart.
enum SystemTransition: CaseIterable {
    case systemSleep
    case screenSleep
    case sessionInactive

    var beginNotification: Notification.Name {
        switch self {
        case .systemSleep: NSWorkspace.willSleepNotification
        case .screenSleep: NSWorkspace.screensDidSleepNotification
        case .sessionInactive: NSWorkspace.sessionDidResignActiveNotification
        }
    }

    var endNotification: Notification.Name {
        switch self {
        case .systemSleep: NSWorkspace.didWakeNotification
        case .screenSleep: NSWorkspace.screensDidWakeNotification
        case .sessionInactive: NSWorkspace.sessionDidBecomeActiveNotification
        }
    }
}
