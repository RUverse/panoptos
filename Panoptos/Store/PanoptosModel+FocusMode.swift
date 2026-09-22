import AppKit
import Foundation

/// An application Panoptos hid, identified the way every other pid record in
/// Panoptos is: macOS reuses pids, and unhiding the wrong process would undo a
/// user's own Command-H.
struct HiddenApplication: Hashable {
    let pid: pid_t
    let bundleIdentifier: String
}

struct HiddenApplicationWindowOrderRestoration {
    let generation: Int
    let sectionIDs: Set<UUID>
    var awaitingPIDs: Set<pid_t>
}

// Section focus mode: one section keeps the screen to itself while every other
// section's windows and bars are hidden, until focus leaves that section.
//
// Hiding is exactly what Command-H does — the windows disappear where they
// stand, instantly, and come back in place. It applies per application, so an
// application that also owns a window in the focused section is never hidden:
// taking it away would take the focused window with it.
//
// Leaving focus mode unhides exactly the applications Panoptos hid, so one the
// user had already hidden stays hidden.
@MainActor
extension PanoptosModel {
    /// Whether `sectionID` is the section focus mode is currently holding.
    func isFocusModeActive(for sectionID: UUID) -> Bool {
        focusedSectionID == sectionID
    }

    /// Whether a section's windows and bars belong on screen right now.
    func isSectionVisible(_ sectionID: UUID) -> Bool {
        focusedSectionID == nil || focusedSectionID == sectionID
    }

    /// The shortcut's entry point: focus mode follows the window the user is
    /// actually in, which is the only section the keyboard can mean.
    func toggleFocusModeForFocusedWindow() {
        guard hasWindowManagementAccess else { return }
        if focusedSectionID != nil {
            exitFocusModePreservingFocusedWindow()
            return
        }
        guard let location = focusedManagedWindowLocation() else { return }
        enterFocusMode(for: location.sectionID)
    }

    func toggleFocusMode(for sectionID: UUID) {
        guard hasWindowManagementAccess else { return }
        if focusedSectionID == sectionID {
            exitFocusModePreservingFocusedWindow()
        } else {
            enterFocusMode(for: sectionID)
        }
    }

    /// Restoring hidden applications can briefly disturb the workspace's
    /// frontmost-application bookkeeping even though the focused window did
    /// not change. Reassert the window that was actually focused before the
    /// restore so the switcher selection and the next navigation shortcut keep
    /// the same origin. Automatic exits deliberately do not use this path:
    /// foreign focus is what caused those exits and must be left alone.
    private func exitFocusModePreservingFocusedWindow() {
        guard let focusedSectionID else { return }
        let focusedWindow: (sectionID: UUID, windowID: UUID)? = focusedManagedWindowLocation().flatMap { location in
            guard location.sectionID == focusedSectionID,
                  let section = sections[location.sectionID],
                  section.windows.indices.contains(location.index) else { return nil }
            return (location.sectionID, section.windows[location.index].id)
        }
        exitFocusMode(preservingFocusedWindow: focusedWindow)
    }

    func enterFocusMode(for sectionID: UUID) {
        guard hasWindowManagementAccess,
              isAccessibilityTrusted,
              let section = sections[sectionID],
              !section.windows.isEmpty else { return }
        // Switching straight from another focused section restores its
        // neighbours first, so only one set of hidden applications is pending.
        if focusedSectionID != nil { exitFocusMode() }
        cancelPendingHiddenApplicationWindowOrderRestoration()
        // The section has to hold focus for the mode to mean anything: the
        // whole point is that the user works here, and every foreign focus ends
        // the mode. Focusing first also keeps the bar's own click from being
        // read as focus leaving the section.
        if let active = section.activeWindow { focus(windowID: active.id) }
        focusedSectionID = sectionID
        focusModeSettleDeadline = now().addingTimeInterval(Self.focusModeSettleInterval)
        hideApplicationsOutsideFocusedSection()
        reconcileApplicationSplitVisibilityForCurrentFocus(fallbackSectionID: sectionID)
        // The other sections' bars belong off screen the moment the applications
        // behind them go, not at whichever reconciliation happens to come next.
        onOverlayPresentationChanged?()
    }

    func exitFocusMode(preservingFocusedWindow: (sectionID: UUID, windowID: UUID)? = nil) {
        guard focusedSectionID != nil else { return }
        focusedSectionID = nil
        focusModeSettleDeadline = nil
        let revealedPIDs = revealApplicationsHiddenByFocusMode()
        if let preservingFocusedWindow {
            reassertFocusAfterLeavingFocusMode(
                sectionID: preservingFocusedWindow.sectionID,
                windowID: preservingFocusedWindow.windowID
            )
        }
        beginRestoringActiveWindowOrder(for: revealedPIDs)
        // Other sections became visible again. A split may have hidden an
        // application only because all of its other windows were in sections
        // focus mode had ordered out; give that application back immediately.
        reconcileApplicationSplitVisibilityForCurrentFocus()
        // Every section is on screen again, and this is the one place that sees
        // it: the mode is left from the bar control, the shortcut, the runtime
        // pass, and `focus(windowID:)` alike. Manual exits also finish their
        // focus restoration above, so this single repaint sees the final state.
        onOverlayPresentationChanged?()
    }

    /// Reasserts the already-focused window without going through
    /// `focus(windowID:)`: its menu is already current, and publishing from the
    /// generic path would add a second overlay repaint to the manual exit.
    private func reassertFocusAfterLeavingFocusMode(sectionID: UUID, windowID: UUID) {
        guard var section = sections[sectionID],
              let window = section.windows.first(where: { $0.id == windowID }) else { return }
        do {
            try accessibility.focus(window: window.handle, pid: window.pid)
            let activeWindowChanged = section.activeWindowID != window.id
            section.activeWindowID = window.id
            sections[sectionID] = section
            focusedManagedWindowID = window.id
            lastFocusedSectionByPID[window.pid] = sectionID
            compatibilityError = nil
            if activeWindowChanged { persistWindowAssignments() }
        } catch {
            compatibilityError = error.localizedDescription
        }
    }

    /// Unhiding an application does not promise which of its windows returns
    /// above its siblings. Restore each affected section's recorded active
    /// window only after manual focus has been reasserted: activating the
    /// focused application can itself raise that application's windows in
    /// other sections.
    func beginRestoringActiveWindowOrder(for pids: Set<pid_t>) {
        guard !pids.isEmpty else { return }
        let managedPIDs = Set(sections.values.flatMap(\.windows).map(\.pid))
        let revealsUnattachedWindows = !pids.isSubset(of: managedPIDs)
            || unattachedWindowsByHandle.values.contains { pids.contains($0.pid) }
        // Free windows are not confined to a section and their discovery
        // cache may have been cleared while hidden. Restore occupied sections
        // after these reveals too, including the section that kept focus.
        // This remains one bounded nonactivating pass per unhide transition.
        let sectionIDs = Set(sections.compactMap { sectionID, section in
            !section.windows.isEmpty
                && (revealsUnattachedWindows || section.windows.contains(where: { pids.contains($0.pid) }))
                ? sectionID : nil
        })
        guard !sectionIDs.isEmpty else { return }

        hiddenApplicationWindowOrderRestorationGeneration += 1
        let generation = hiddenApplicationWindowOrderRestorationGeneration
        let pending = pendingHiddenApplicationWindowOrderRestoration
        let mergedSectionIDs = sectionIDs.union(pending?.sectionIDs ?? [])
        let mergedPIDs = pids.union(pending?.awaitingPIDs ?? [])
        pendingHiddenApplicationWindowOrderRestoration = HiddenApplicationWindowOrderRestoration(
            generation: generation,
            sectionIDs: mergedSectionIDs,
            awaitingPIDs: mergedPIDs
        )
        restoreActiveWindowOrder(in: mergedSectionIDs)

        // Some applications do not reliably produce a workspace unhide
        // notification when AXHidden is changed. The fallback is intentionally
        // one-shot and generation-guarded so it cannot affect a later focus-mode
        // session.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hiddenApplicationWindowOrderSettleInterval) { [weak self] in
            Task { @MainActor in
                self?.finishPendingHiddenApplicationWindowOrderRestoration(generation: generation)
            }
        }
    }

    /// Called from the workspace's did-unhide notification. Each application
    /// may finish independently, and a later unhide can disturb an earlier
    /// correction, so reassert all affected sections after every expected one.
    func applicationDidUnhide(pid: pid_t) {
        guard var pending = pendingHiddenApplicationWindowOrderRestoration,
              pending.awaitingPIDs.remove(pid) != nil else { return }
        pendingHiddenApplicationWindowOrderRestoration = pending
        restoreActiveWindowOrder(in: pending.sectionIDs)
        reassertPendingUnattachedFocusIfNeeded()
    }

    /// `focus(windowID:)` may reveal applications hidden by focus mode or an
    /// application split before AX activates its destination. That activation
    /// can disturb sibling windows again, so finish the successful operation
    /// with the same nonactivating ordering correction used by a manual exit.
    func restorePendingHiddenApplicationWindowOrderAfterFocusChange() {
        guard let pending = pendingHiddenApplicationWindowOrderRestoration else { return }
        restoreActiveWindowOrder(in: pending.sectionIDs)
        reassertPendingUnattachedFocusIfNeeded()
    }

    /// A span and the sections it covers share one area, so restoring any of
    /// them restores that whole stack, lowest layer first: an application
    /// coming back from hidden does not promise where its windows land, and
    /// the layer that was on top has to end up on top again. A split's other
    /// half is a window of its own in the same layer and is raised with it.
    private func restoreActiveWindowOrder(in sectionIDs: Set<UUID>) {
        var stack = sectionIDs
        for sectionID in sectionIDs {
            guard let section = sections[sectionID] else { continue }
            if section.isSpanned {
                stack.formUnion(section.coveredSectionIDs)
            } else {
                stack.formUnion(sections.filter { $0.value.coveredSectionIDs.contains(sectionID) }.keys)
            }
        }
        let ordered = stack.sorted { $0.uuidString < $1.uuidString }
        for sectionID in ordered.filter({ !isSectionOnTop($0) }) + ordered.filter({ isSectionOnTop($0) }) {
            guard let active = sections[sectionID]?.activeWindow else { continue }
            do {
                try accessibility.raise(window: active.handle)
            } catch {
                lifecycleLogger.warning(
                    "Could not restore active window order for PID \(active.pid): \(error.localizedDescription, privacy: .public)"
                )
            }
            raiseApplicationSplitPartner(for: active, inSection: sectionID)
        }
    }

    private func finishPendingHiddenApplicationWindowOrderRestoration(generation: Int) {
        guard let pending = pendingHiddenApplicationWindowOrderRestoration,
              pending.generation == generation else { return }
        pendingHiddenApplicationWindowOrderRestoration = nil
        restoreActiveWindowOrder(in: pending.sectionIDs)
        reassertPendingUnattachedFocusIfNeeded()
        pendingUnattachedFocusReassertion = nil
    }

    private func cancelPendingHiddenApplicationWindowOrderRestoration() {
        hiddenApplicationWindowOrderRestorationGeneration += 1
        pendingHiddenApplicationWindowOrderRestoration = nil
        pendingUnattachedFocusReassertion = nil
    }

    private func reassertPendingUnattachedFocusIfNeeded() {
        guard let target = pendingUnattachedFocusReassertion else { return }
        guard focusedUnattachedWindowHandle == target.handle,
              unattachedWindowsByHandle[target.handle]?.pid == target.pid else {
            pendingUnattachedFocusReassertion = nil
            return
        }
        do {
            try accessibility.focus(window: target.handle, pid: target.pid)
        } catch {
            lifecycleLogger.warning(
                "Could not reassert unattached window focus for PID \(target.pid): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Ends focus mode when the section it holds can no longer justify it:
    /// focus moved somewhere else, or the section itself is gone.
    ///
    /// Called from `refreshRuntime()`, which every application activation and
    /// the overlay's idle pass already run, so a switch made through the Dock,
    /// the app switcher, or any other route outside Panoptos lands here.
    func reconcileFocusMode(frontmostPID: pid_t?) {
        guard hasWindowManagementAccess else { return }
        guard let focusedSectionID else { return }
        guard let section = sections[focusedSectionID], !section.windows.isEmpty,
              sectionFrames()[focusedSectionID] != nil else {
            exitFocusMode()
            return
        }
        if shouldEndFocusMode(in: section, frontmostPID: frontmostPID) {
            exitFocusMode()
            return
        }
        // Keep the other sections hidden as the managed set changes: an
        // application whose window was attached elsewhere, or recovered, while
        // the mode was running would otherwise show over the focused section.
        hideApplicationsOutsideFocusedSection()
    }

    private func shouldEndFocusMode(in section: LayoutSectionState, frontmostPID: pid_t?) -> Bool {
        // Sleep, locking, and display changes make focus reads meaningless for
        // a while, and none of them are the user switching windows.
        guard !isInSystemTransition else { return false }
        if let focusModeSettleDeadline, now() < focusModeSettleDeadline { return false }
        // Panoptos' own settings window and its overlay menus are not "another
        // window" — browsing the section's menus must not close the mode.
        guard frontmostPID != ownProcessIdentifier else { return false }
        guard let focusedManagedWindowID else { return true }
        return !section.windows.contains { $0.id == focusedManagedWindowID }
    }

    /// Ends focus mode once its section has nothing left to show. The runtime
    /// pass reaches this too, but a window that goes away between passes would
    /// otherwise leave the desktop empty for as long as a second.
    func exitFocusModeIfSectionIsEmpty() {
        guard let focusedSectionID else { return }
        if sections[focusedSectionID]?.windows.isEmpty ?? true { exitFocusMode() }
    }

    func hideApplicationsOutsideFocusedSection() {
        guard let focusedSectionID, let focused = sections[focusedSectionID] else { return }
        // Hiding is per application: an application with a window in the
        // focused section keeps every window it owns, attached or not.
        let retained = Set(focused.windows.map(\.pid)).union([ownProcessIdentifier])
        var candidates: [HiddenApplication] = []
        for (sectionID, section) in sections where sectionID != focusedSectionID {
            for window in section.windows where !retained.contains(window.pid) {
                let candidate = HiddenApplication(pid: window.pid, bundleIdentifier: window.bundleIdentifier)
                guard !focusModeHiddenApplications.contains(candidate),
                      !candidates.contains(candidate) else { continue }
                candidates.append(candidate)
            }
        }
        for window in selectableUnattachedWindows() where !retained.contains(window.pid) {
            let candidate = HiddenApplication(pid: window.pid, bundleIdentifier: window.bundleIdentifier)
            guard !focusModeHiddenApplications.contains(candidate),
                  !candidates.contains(candidate) else { continue }
            candidates.append(candidate)
        }
        for candidate in candidates {
            // An application the user had already hidden is not focus mode's to
            // give back later.
            guard !accessibility.isApplicationHidden(pid: candidate.pid) else { continue }
            do {
                try accessibility.setApplicationHidden(true, pid: candidate.pid)
                focusModeHiddenApplications.insert(candidate)
            } catch {
                lifecycleLogger.warning(
                    "Could not hide PID \(candidate.pid) for focus mode: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func revealApplicationsHiddenByFocusMode() -> Set<pid_t> {
        let hidden = focusModeHiddenApplications
        focusModeHiddenApplications = []
        var revealedPIDs: Set<pid_t> = []
        for application in hidden {
            // A pid that now belongs to a different application is not the one
            // that was hidden, and unhiding it would surprise the user.
            let identity = runningApplication(pid: application.pid)
                .map { $0.bundleIdentifier ?? "pid.\(application.pid)" }
            guard identity == application.bundleIdentifier else { continue }
            do {
                try accessibility.setApplicationHidden(false, pid: application.pid)
                revealedPIDs.insert(application.pid)
            } catch {
                lifecycleLogger.warning(
                    "Could not show PID \(application.pid) after focus mode: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return revealedPIDs
    }
}
