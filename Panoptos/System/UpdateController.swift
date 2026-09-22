import Foundation
import Sparkle

/// Sparkle already persists the user's update preferences in its own defaults,
/// so Panoptos mirrors those values rather than keeping a second copy. This is
/// the same reasoning as `LoginItemController`: state the system owns has one
/// authoritative home, and duplicating it into `settings.json` would give the
/// two stores room to drift. It also means the preference survives a relaunch
/// without Panoptos persisting anything itself.
protocol UpdateControlling: AnyObject {
    /// Whether Sparkle checks on its own schedule. Panoptos never downloads or
    /// installs an update without asking, so this only governs the check.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Nil until the first check completes.
    var lastUpdateCheckDate: Date? { get }
    /// False while a check is already running, so the UI can disable the
    /// control instead of starting a second one.
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

final class SparkleUpdateController: NSObject, UpdateControlling, ObservableObject {
    /// Sparkle drives its own UI for the update sheet and release notes.
    /// `startingUpdater: true` begins the scheduled check cycle immediately;
    /// Sparkle honours the stored preference, so an automatic check does not
    /// happen when the user has switched it off.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Republished so SwiftUI redraws the control while a check is in flight.
    @Published private(set) var isCheckingForUpdates = false

    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        // canCheckForUpdates is false for the duration of a check. Observing it
        // is how the button learns to re-enable itself once Sparkle finishes,
        // including when the user dismisses the update sheet.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.isCheckingForUpdates = !updater.canCheckForUpdates
            }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Shows Sparkle's own progress and result UI, including the "you're up to
    /// date" case, so Panoptos does not report the outcome itself.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
