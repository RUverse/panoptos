import AppKit
import Foundation

// Durable preferences, the keep-awake assertions, and the login item.
@MainActor
extension PanoptosModel {
    func persistSettings() {
        let settings = PanoptosSettings(
            attachAllApplicationWindowsWithControlShift:
                windowDragShortcuts.attachApplicationWindows != nil,
            sectionBarsFillAvailableWidth: sectionBarsFillAvailableWidth,
            sectionBarsCentered: sectionBarsCentered,
            showWindowMenuBars: showWindowMenuBars,
            showUnattachedWindowIcons: showUnattachedWindowIcons,
            windowSwitcherUIScale: windowSwitcherUIScale,
            windowSwitcherTitleMode: windowSwitcherTitleMode,
            limitWindowSwitcherTitleCharacters: limitWindowSwitcherTitleCharacters,
            invokeWithoutActivation: invokeWithoutActivation,
            keepMacAwake: keepMacAwake,
            keepScreenOn: keepScreenOn,
            hasCompletedOnboarding: hasCompletedOnboarding,
            windowDragShortcuts: windowDragShortcuts
        )
        do {
            try settingsPersistence.save(settings)
        } catch {
            compatibilityError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Records that the welcome tour was dismissed, whether it was skipped or
    /// read to the end. Replaying the tour later does not undo this.
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func setWindowSwitcherUIScale(_ scale: Double) {
        let normalized = WindowSwitcherSize.normalized(scale)
        guard normalized != windowSwitcherUIScale else { return }
        windowSwitcherUIScale = normalized
        persistSettings()
        reflowManagedWindows()
        onOverlayPresentationChanged?()
    }

    func updateKeepAwakeActivity() {
        if hasWindowManagementAccess && keepMacAwake {
            keepAwakeController.startPreventingIdleSystemSleep()
        } else {
            keepAwakeController.stopPreventingIdleSystemSleep()
        }
        if hasWindowManagementAccess && keepScreenOn {
            keepAwakeController.startPreventingIdleDisplaySleep()
        } else {
            keepAwakeController.stopPreventingIdleDisplaySleep()
        }
    }

    /// Re-reads the system login-item state, which the user can change in
    /// System Settings while Panoptos is running.
    func refreshLaunchAtLoginState() {
        adopt(loginItemState: loginItemController.state)
    }

    /// Sparkle persists this itself, which is why it is not part of
    /// `PanoptosSettings` and why nothing here writes `settings.json`. Reading
    /// through to the controller keeps one authoritative value, the same way
    /// the login item defers to macOS.
    var automaticallyChecksForUpdates: Bool {
        get { updateController.automaticallyChecksForUpdates }
        set {
            guard newValue != updateController.automaticallyChecksForUpdates else { return }
            objectWillChange.send()
            updateController.automaticallyChecksForUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updateController.lastUpdateCheckDate }

    var canCheckForUpdates: Bool { updateController.canCheckForUpdates }

    /// Sparkle presents the progress, the release notes, and the up-to-date
    /// result, so Panoptos reports none of them itself.
    func checkForUpdatesNow() {
        objectWillChange.send()
        updateController.checkForUpdates()
    }

    func applyLaunchAtLogin() {
        let state = loginItemController.state
        // Pending approval already means "registered, switched off by the user".
        // Registering again cannot clear it and would replace the actionable
        // notice with a generic failure, so send the user to System Settings.
        guard !(launchAtLogin && state == .requiresApproval) else {
            adopt(loginItemState: state)
            return
        }
        do {
            try loginItemController.setEnabled(launchAtLogin)
            adopt(loginItemState: loginItemController.state)
        } catch {
            let attempt = launchAtLogin ? "add Panoptos to" : "remove Panoptos from"
            // The system value did not change, so put the toggle back first,
            // then report why.
            adopt(loginItemState: loginItemController.state)
            launchAtLoginNotice = "Could not \(attempt) your login items: \(error.localizedDescription)"
        }
    }

    /// Takes the system state as the truth for the toggle and its notice,
    /// without re-entering `applyLaunchAtLogin()`.
    private func adopt(loginItemState state: LoginItemState) {
        isSyncingLaunchAtLogin = true
        launchAtLogin = state == .enabled
        isSyncingLaunchAtLogin = false
        launchAtLoginNeedsSystemSettings = state == .requiresApproval
        launchAtLoginNotice = Self.launchAtLoginNotice(for: state)
    }

    static func launchAtLoginNotice(for state: LoginItemState) -> String? {
        switch state {
        case .enabled, .disabled:
            nil
        case .requiresApproval:
            "Panoptos is already a login item but macOS has it switched off. Turn it back on in Login Items."
        case .unavailable:
            "macOS cannot manage this Panoptos build as a login item. Move it to Applications and try again."
        }
    }
}
