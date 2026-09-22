import Foundation

protocol KeepAwakeControlling: AnyObject {
    func startPreventingIdleSystemSleep()
    func stopPreventingIdleSystemSleep()
    func startPreventingIdleDisplaySleep()
    func stopPreventingIdleDisplaySleep()
}

final class ProcessInfoKeepAwakeController: KeepAwakeControlling {
    private var systemSleepActivity: NSObjectProtocol?
    private var displaySleepActivity: NSObjectProtocol?

    func startPreventingIdleSystemSleep() {
        guard systemSleepActivity == nil else { return }
        systemSleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Panoptos Keep Mac Awake is enabled"
        )
    }

    func stopPreventingIdleSystemSleep() {
        guard let systemSleepActivity else { return }
        ProcessInfo.processInfo.endActivity(systemSleepActivity)
        self.systemSleepActivity = nil
    }

    func startPreventingIdleDisplaySleep() {
        guard displaySleepActivity == nil else { return }
        displaySleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleDisplaySleepDisabled,
            reason: "Panoptos Keep Screen On is enabled"
        )
    }

    func stopPreventingIdleDisplaySleep() {
        guard let displaySleepActivity else { return }
        ProcessInfo.processInfo.endActivity(displaySleepActivity)
        self.displaySleepActivity = nil
    }

    deinit {
        if let systemSleepActivity { ProcessInfo.processInfo.endActivity(systemSleepActivity) }
        if let displaySleepActivity { ProcessInfo.processInfo.endActivity(displaySleepActivity) }
    }
}
