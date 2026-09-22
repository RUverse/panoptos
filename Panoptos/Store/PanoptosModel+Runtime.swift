import AppKit
import Foundation

@MainActor
extension PanoptosModel {
    /// Runtime callbacks use this as an operational guard after shutdown.
    /// Access is never conditioned on payment, credentials, or network state.
    var hasWindowManagementAccess: Bool { isWindowManagementRuntimeStarted }

    func startWindowManagementRuntime() {
        guard !isWindowManagementRuntimeStarted else { return }
        isWindowManagementRuntimeStarted = true
        let wasTrusted = isAccessibilityTrusted
        refreshPermissionState()
        if isAccessibilityTrusted, wasTrusted {
            restoreWindowAssignmentsIfNeeded()
            if showUnattachedWindowIcons { refreshUnattachedApplicationRoster() }
            refreshRuntime()
        }
        observeWorkspace()
        startPermissionPolling()
        if wasTrusted == isAccessibilityTrusted { refreshShortcutRegistration() }
        updateKeepAwakeActivity()
        onWindowManagementRuntimeChanged?(true)
    }

    func stopWindowManagementRuntime() {
        pendingWindowCreations.removeAll()
        exitFocusMode()
        revealApplicationsHiddenByApplicationSplits()
        guard isWindowManagementRuntimeStarted else {
            _ = shortcutRegistrar.update([:])
            keepAwakeController.stopPreventingIdleSystemSleep()
            keepAwakeController.stopPreventingIdleDisplaySleep()
            onWindowManagementRuntimeChanged?(false)
            return
        }
        isWindowManagementRuntimeStarted = false
        permissionPoller?.cancel()
        permissionPoller = nil
        removeWorkspaceObservers()
        _ = shortcutRegistrar.update([:])
        keepAwakeController.stopPreventingIdleSystemSleep()
        keepAwakeController.stopPreventingIdleDisplaySleep()
        loadingMenus.removeAll()
        menusByPID.removeAll()
        applicationIconsByPID.removeAll()
        clearUnattachedWindowState()
        focusedManagedWindowID = nil
        focusedUnattachedWindowHandle = nil
        onOverlayPresentationChanged?()
        onWindowManagementRuntimeChanged?(false)
    }

    func removeWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
            defaultCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }
}
