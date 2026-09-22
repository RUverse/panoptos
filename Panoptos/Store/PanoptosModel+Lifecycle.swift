import AppKit
import Foundation

import OSLog

// Keeping attached windows alive: runtime reconciliation, system
// transitions, and the narrow set of events that may detach a window.
@MainActor
extension PanoptosModel {
    /// The explicit "Refresh Windows and Menus" command.
    ///
    /// Most of what it reaches happens on its own: the overlay's idle pass and
    /// every application activation run `refreshRuntime()`, and a display
    /// change runs `refreshDisplays()`. Two things only happen when the user
    /// asks, and they are what the command is for.
    func refreshWindowsAndMenus(
        reportedFrontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) {
        guard hasWindowManagementAccess else { return }
        // A cached menu tree is otherwise only discarded when its application
        // quits or when Panoptos itself invokes a command, so an application
        // that rebuilt its menus on its own keeps serving the stale tree.
        // `refreshRuntime()` reloads each section's active window below.
        if isAccessibilityTrusted { menusByPID.removeAll() }
        // A deliberate refresh also retries records whose automatic recovery
        // window expired while their application or the system was unavailable.
        renewOrphanRecovery()
        nextOrphanRecoveryAttempt = nil
        // Also reflows every managed window back into its section, which the
        // idle pass only does when an AX notification asked for it.
        refreshDisplays()
        refreshUnattachedApplicationRoster()
        refreshRuntime(reportedFrontmostPID: reportedFrontmostPID)
    }

    /// Resolves which managed window holds focus, using a single Accessibility
    /// read, and publishes the result.
    ///
    /// `refreshRuntime()` reaches the same conclusion, but only after a blocking
    /// snapshot of every managed window, and an application switch runs it on
    /// every activation. The overlay's focused switcher selection is the
    /// visible result of clicking into another section, so it must not trail
    /// that click by the length of the sweep. This is the same resolution
    /// without the sweep.
    ///
    /// It only ever moves focus, never removes a window, so running it ahead of
    /// the authoritative pass cannot detach anything.
    @discardableResult
    func refreshFocusedWindow(
        reportedFrontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) -> Bool {
        guard hasWindowManagementAccess, isAccessibilityTrusted else { return false }
        let managedPIDs = Set(sections.values.flatMap { $0.windows.map(\.pid) })
        let selectablePIDs = managedPIDs.union(unattachedApplicationsByPID.keys)
        let frontmostPID = reportedFrontmostPID.flatMap { selectablePIDs.contains($0) ? $0 : nil }
        let focusedWindowID: UUID?
        let focusedUnattachedHandle: AXWindowHandle?
        if let frontmostPID {
            if let focusedWindow = try? accessibility.focusedWindow(pid: frontmostPID) {
                if managedWindow(matching: focusedWindow) == nil {
                    reconcileFinderTabs(pid: frontmostPID)
                }
                focusedWindowID = managedWindow(matching: focusedWindow)?.id
                focusedUnattachedHandle = unattachedWindowsByHandle[focusedWindow] == nil
                    ? nil
                    : focusedWindow
            } else if let previousID = focusedManagedWindowID,
                      managedWindow(id: previousID)?.pid == frontmostPID {
                // Same retention as `refreshRuntime()`: a read that timed out is
                // not evidence that focus moved.
                focusedWindowID = previousID
                focusedUnattachedHandle = nil
            } else if let previousHandle = focusedUnattachedWindowHandle,
                      unattachedWindowsByHandle[previousHandle]?.pid == frontmostPID {
                focusedWindowID = nil
                focusedUnattachedHandle = previousHandle
            } else {
                focusedWindowID = nil
                focusedUnattachedHandle = nil
            }
        } else {
            // The frontmost application owns no selectable window, so focus is
            // outside every section and external icon without asking AX.
            focusedWindowID = nil
            focusedUnattachedHandle = nil
        }

        var activeWindowChanged = false
        if let focusedWindowID {
            for key in Array(sections.keys) {
                guard var section = sections[key],
                      section.windows.contains(where: { $0.id == focusedWindowID }),
                      section.activeWindowID != focusedWindowID else { continue }
                section.activeWindowID = focusedWindowID
                sections[key] = section
                activeWindowChanged = true
            }
            rememberFocusedSection(windowID: focusedWindowID)
        }
        // A managed focus always wins, exactly as in `refreshRuntime()`: a
        // handle can appear in both collections for as long as it takes the
        // owning application's next free-window refresh to run.
        let resolvedUnattachedHandle = focusedWindowID == nil ? focusedUnattachedHandle : nil
        guard activeWindowChanged
                || self.focusedManagedWindowID != focusedWindowID
                || self.focusedUnattachedWindowHandle != resolvedUnattachedHandle else { return false }
        let previouslyFocusedWindowID = self.focusedManagedWindowID
        self.focusedManagedWindowID = focusedWindowID
        self.focusedUnattachedWindowHandle = resolvedUnattachedHandle
        if pendingUnattachedFocusReassertion?.handle != resolvedUnattachedHandle {
            pendingUnattachedFocusReassertion = nil
        }
        if let resolvedUnattachedHandle {
            updateUnattachedCycleCursor(for: resolvedUnattachedHandle)
        }
        if let focusedWindowID,
           let location = location(ofWindowID: focusedWindowID),
           let window = managedWindow(id: focusedWindowID) {
            // A switch made outside Panoptos — the Dock, the app switcher, a
            // click into a visible window — moves between layers just as the
            // switcher does.
            if focusedWindowID != previouslyFocusedWindowID { presentLayer(for: location.sectionID) }
            reconcileApplicationSplitVisibility(
                focusedWindow: window,
                inSection: location.sectionID
            )
            raiseApplicationSplitPartner(for: window, inSection: location.sectionID)
        } else {
            // A detached or unrelated frontmost window does not change which
            // group remains selected in each managed section. Keep active
            // split groups intact while clearing only global managed focus.
            reconcileApplicationSplitVisibilityForCurrentFocus()
        }
        onOverlayPresentationChanged?()
        // The following `refreshRuntime()` only persists an active-window change
        // it observes itself, and it will find this one already applied.
        if activeWindowChanged { persistWindowAssignments() }
        return true
    }

    /// `publishesPresentationChanges` is false for callers that repaint the
    /// overlay themselves right afterwards. Publishing there would run the
    /// whole presentation pass twice in one runloop turn.
    func refreshRuntime(
        reportedFrontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        publishesPresentationChanges: Bool = true
    ) {
        guard hasWindowManagementAccess, isAccessibilityTrusted else { return }
        // The idle timer and activation events can otherwise repeatedly block
        // the main actor on every unavailable application during reconnect.
        // Retain the last presentation until the transition settles; click and
        // shortcut focus feedback still has its separate fast path. The
        // window server, unlike an application, answers instantly, so bars a
        // lock ordered out still return on the first pass after unlock.
        guard !isInSystemTransition else {
            if refreshManagedWindowSpaceVisibility(), publishesPresentationChanges {
                onOverlayPresentationChanged?()
            }
            return
        }
        reconcileFinderTabs()
        let previouslyFocusedWindowID = focusedManagedWindowID
        let previouslyFocusedUnattachedHandle = focusedUnattachedWindowHandle
        let activeSplitsBeforeRefresh = activeApplicationSplitPairs()
        retryDisplayTopologyReflowIfNeeded()
        let initialPIDs = Set(sections.values.flatMap { $0.windows.map(\.pid) })
        let terminatedPIDs = initialPIDs.filter { hasTerminated(pid: $0) }
        var assignmentsChanged = false
        for pid in terminatedPIDs where preserveAndRemoveWindows(forTerminatedPID: pid) {
            assignmentsChanged = true
        }
        let attachedPendingCreation = retryPendingWindowCreations(reportedFrontmostPID: reportedFrontmostPID)
        if attachedPendingCreation { assignmentsChanged = true }

        let managedPIDs = Set(sections.values.flatMap { $0.windows.map(\.pid) })
        let selectablePIDs = managedPIDs.union(unattachedApplicationsByPID.keys)
        let frontmostPID = reportedFrontmostPID.flatMap { selectablePIDs.contains($0) ? $0 : nil }
        let focusedWindow = frontmostPID.flatMap { try? accessibility.focusedWindow(pid: $0) }
        var focusedWindowID = focusedWindow.flatMap { managedWindow(matching: $0)?.id }
        var focusedUnattachedHandle = focusedWindow.flatMap {
            unattachedWindowsByHandle[$0] == nil ? nil : $0
        }
        if focusedWindow == nil,
           focusedWindowID == nil,
           let frontmostPID,
           let previousID = focusedManagedWindowID,
           managedWindow(id: previousID)?.pid == frontmostPID {
            // A focused-window read can time out independently of its window
            // snapshot. Retain the last confirmed focus for the same frontmost
            // application instead of flickering the overlay state.
            focusedWindowID = previousID
        } else if focusedWindow == nil,
                  focusedWindowID == nil,
                  let frontmostPID,
                  let previousHandle = focusedUnattachedWindowHandle,
                  unattachedWindowsByHandle[previousHandle]?.pid == frontmostPID {
            focusedUnattachedHandle = previousHandle
        }
        var confirmedInvalidHandles: [AXWindowHandle] = []
        // One raw window-list read per application per pass. Each is a blocking
        // IPC call, so an application with several invalid windows must not
        // multiply them.
        var listedHandlesByPID: [pid_t: [AXWindowHandle]?] = [:]

        for key in Array(sections.keys) {
            guard var section = sections[key] else { continue }
            var refreshed: [ManagedWindow] = []
            for var window in section.windows {
                let snapshot: AXWindowSnapshot
                do {
                    snapshot = try accessibility.snapshot(window: window.handle)
                } catch {
                    let isFirstFailure = snapshotFailures.insert(window.id).inserted
                    if Self.isInvalidWindowError(error), !isInSystemTransition {
                        let firstFailure = invalidSnapshotFirstFailure[window.id] ?? now()
                        invalidSnapshotFirstFailure[window.id] = firstFailure
                        // Only the owning application can distinguish a closed
                        // window from an element that a display or power change
                        // replaced underneath us.
                        if now().timeIntervalSince(firstFailure) >= Self.invalidWindowFailureDuration,
                           applicationHasStoppedListing(window, cache: &listedHandlesByPID) {
                            confirmedInvalidHandles.append(window.handle)
                        }
                    } else {
                        invalidSnapshotFirstFailure.removeValue(forKey: window.id)
                    }
                    if isFirstFailure {
                        lifecycleLogger.warning(
                            "Preserving window after transient AX snapshot failure for PID \(window.pid): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    // Preserve state for timeouts, permission interruptions,
                    // Space changes, and every other non-authoritative failure.
                    refreshed.append(window)
                    continue
                }
                snapshotFailures.remove(window.id)
                invalidSnapshotFirstFailure.removeValue(forKey: window.id)
                if window.title != snapshot.title { assignmentsChanged = true }
                window.title = snapshot.title
                window.isMinimized = snapshot.isMinimized
                window.finderTabGroup = snapshot.finderTabGroup ?? window.finderTabGroup
                window.lastKnownFrame = snapshot.frame
                refreshed.append(window)
                // Inactive applications still report their last focused
                // window. Only the frontmost application's value identifies
                // the window that is active in an overlapping section.
                if window.pid == frontmostPID, focusedWindow == window.handle {
                    if section.activeWindowID != window.id { assignmentsChanged = true }
                    section.activeWindowID = window.id
                    focusedWindowID = window.id
                    loadMenu(pid: window.pid)
                }
            }
            section.windows = refreshed
            if !refreshed.contains(where: { $0.id == section.activeWindowID }) {
                section.activeWindowID = refreshed.last?.id
            }
            // Each section's bar shows its active window's menus even while the
            // window is unfocused, so load them incrementally (once per pid).
            if let pid = section.activeWindow?.pid { loadMenu(pid: pid) }
            if refreshed.isEmpty { sections.removeValue(forKey: key) } else { sections[key] = section }
        }

        for handle in Set(confirmedInvalidHandles) {
            lifecycleLogger.warning(
                "Detaching window: its application stopped listing the element after sustained invalid AX errors"
            )
            // The record is kept as an orphan so the window can be reclaimed if
            // the application merely replaced the element.
            for window in managedWindows(matching: handle) { orphan(window) }
            if removeWindow(handle: handle) { assignmentsChanged = true }
        }
        // Frames are settled for this pass, so one window-server read now
        // answers for every managed window that stayed attached.
        let spaceVisibilityChanged = refreshManagedWindowSpaceVisibility()
        if let focusedWindowID, managedWindow(id: focusedWindowID) == nil {
            self.focusedManagedWindowID = nil
        } else {
            self.focusedManagedWindowID = focusedWindowID
            rememberFocusedSection(windowID: focusedWindowID)
        }
        self.focusedUnattachedWindowHandle = focusedWindowID == nil ? focusedUnattachedHandle : nil
        if pendingUnattachedFocusReassertion?.handle != self.focusedUnattachedWindowHandle {
            pendingUnattachedFocusReassertion = nil
        }
        if let focusedUnattachedHandle = self.focusedUnattachedWindowHandle {
            updateUnattachedCycleCursor(for: focusedUnattachedHandle)
        }
        if focusedWindowID != previouslyFocusedWindowID,
           let focusedWindowID,
           let location = location(ofWindowID: focusedWindowID),
           let window = managedWindow(id: focusedWindowID) {
            presentLayer(for: location.sectionID)
            reconcileApplicationSplitVisibility(
                focusedWindow: window,
                inSection: location.sectionID
            )
            raiseApplicationSplitPartner(for: window, inSection: location.sectionID)
        }
        if recoverOrphanedWindows() { assignmentsChanged = true }
        // Detachments and terminations run through the removal helpers above,
        // which know nothing about splits. This is the settled point where a
        // pair can be re-normalized, and where a surviving partner takes back
        // the section half its partner left behind. Sleep, lock, and display
        // changes invalidate elements without closing windows, so leave pairs
        // alone until the transition settles.
        if !isInSystemTransition {
            if pruneApplicationSplitPairs() { assignmentsChanged = true }
            if needsApplicationSplitReflow
                || activeApplicationSplitPairs() != activeSplitsBeforeRefresh {
                needsApplicationSplitReflow = false
                reflowManagedWindows()
            }
        }
        reconcileApplicationSplitVisibilityForCurrentFocus()
        if assignmentsChanged { persistWindowAssignments() }
        if publishesPresentationChanges,
           focusedWindowID != previouslyFocusedWindowID
            || self.focusedUnattachedWindowHandle != previouslyFocusedUnattachedHandle
            || attachedPendingCreation
            || spaceVisibilityChanged {
            onOverlayPresentationChanged?()
        }
        // Runs on every activation, so this is where a switch made outside
        // Panoptos — the app switcher, the Dock, a launcher — ends focus mode.
        reconcileFocusMode(frontmostPID: reportedFrontmostPID)
    }

    /// A destruction notification normally means the user closed this window,
    /// but applications also emit it while quitting. Keep the assignment for a
    /// short grace period so the workspace termination notification can claim
    /// it for application relaunch; otherwise retain it for a later window
    /// reopen in the same process.
    func confirmWindowDestroyed(
        _ handle: AXWindowHandle,
        reportedFrontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier
    ) {
        guard hasWindowManagementAccess else { return }
        pendingWindowCreations.removeAll { $0.handle == handle }
        // Closing the selected tab can destroy its AX window while the same
        // tab bar now belongs to a surviving tab.
        if let window = managedWindow(matching: handle), window.finderTabGroup != nil {
            reconcileFinderTabs(pid: window.pid)
        }
        let sectionNeedingFocus = sectionNeedingFocusAfterClosing(
            handle,
            frontmostPID: reportedFrontmostPID
        )
        removeUnattachedWindow(handle: handle)
        forgetUserDetachedWindow(handle)
        let activeSplitsBeforeDestruction = activeApplicationSplitPairs()
        let destroyedWindows = managedWindows(matching: handle)
        let destroyedIDs = Set(destroyedWindows.map(\.id))
        for window in destroyedWindows {
            // Persist the tentative reopen state immediately. If Panoptos
            // itself quits during the grace period, its next launch must still
            // know to observe this running application for a replacement.
            orphan(window, awaitsWindowReopen: true)
            windowReopenObservationIdentities[window.pid] = window.bundleIdentifier
            pendingDestroyedWindows[window.id] = (
                window.pid,
                window.bundleIdentifier,
                now().addingTimeInterval(Self.windowDestructionTerminationMaxWait)
            )
        }
        guard removeWindow(handle: handle) else { return }
        if activeApplicationSplitPairs() != activeSplitsBeforeDestruction {
            // The durable pair stays in the orphaned assignment for a later
            // reopen, but its live half no longer exists. Return every
            // surviving window to the whole section once AX is safe to read.
            if isInSystemTransition {
                needsApplicationSplitReflow = true
            } else {
                reflowManagedWindows()
            }
        }
        reconcileApplicationSplitVisibilityForCurrentFocus()
        onOverlayPresentationChanged?()
        persistWindowAssignments()
        exitFocusModeIfSectionIsEmpty()
        if let sectionNeedingFocus,
           let replacement = sections[sectionNeedingFocus]?.activeWindow {
            // Updating activeWindowID only changes the overlay. Keyboard
            // navigation resolves real AX focus, so give the survivor the same
            // focus handoff as an explicit switcher click.
            focus(windowID: replacement.id)
        }
        scheduleWindowDestructionFinalization(destroyedIDs)
    }

    private func sectionNeedingFocusAfterClosing(
        _ handle: AXWindowHandle,
        frontmostPID: pid_t?
    ) -> UUID? {
        guard isAccessibilityTrusted, !isInSystemTransition,
              let window = managedWindow(matching: handle),
              window.pid == frontmostPID,
              let location = location(ofWindowID: window.id),
              sections[location.sectionID]?.activeWindowID == window.id else { return nil }

        // AX can announce the loss of focus before announcing destruction.
        // Retain the last confirmed section through that gap, but never take
        // focus back from another managed or unattached window.
        guard focusedManagedWindowID == window.id
                || (focusedManagedWindowID == nil
                    && focusedUnattachedWindowHandle == nil
                    && lastFocusedSectionByPID[window.pid] == location.sectionID) else { return nil }
        if let focused = try? accessibility.focusedWindow(pid: window.pid),
           focused != handle { return nil }
        return location.sectionID
    }

    private func scheduleWindowDestructionFinalization(_ destroyedIDs: Set<UUID>) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.windowDestructionTerminationGraceInterval
        ) { [weak self] in
            Task { @MainActor in self?.finalizeWindowDestructions(destroyedIDs) }
        }
    }

    /// Completes destruction records whose applications remained alive through
    /// the grace period. Internal so lifecycle tests can drive it without
    /// sleeping; production reaches it through the delayed callback above.
    func finalizeWindowDestructions(_ candidateIDs: Set<UUID>) {
        guard hasWindowManagementAccess else { return }
        let pendingIDs = candidateIDs.intersection(pendingDestroyedWindows.keys)
        guard !pendingIDs.isEmpty else { return }
        var preservedForWindowReopen = false
        var retryIDs: Set<UUID> = []
        var preservedForRelaunch = false
        for id in pendingIDs {
            guard let pending = pendingDestroyedWindows.removeValue(forKey: id) else { continue }
            let application = runningApplication(pid: pending.pid)
            let identity = application.map {
                $0.bundleIdentifier ?? "pid.\($0.processIdentifier)"
            }
            if identity == pending.bundleIdentifier {
                let listedHandles = try? accessibility.windowHandles(pid: pending.pid)
                if (listedHandles == nil || listedHandles?.isEmpty == true),
                   now() < pending.finalizationDeadline {
                    pendingDestroyedWindows[id] = pending
                    retryIDs.insert(id)
                    continue
                }
                for index in orphanedAssignments.indices
                where orphanedAssignments[index].id == id {
                    orphanedAssignments[index].orphanedAt = now()
                    orphanedAssignments[index].awaitsWindowReopen = true
                    preservedForWindowReopen = true
                }
            } else {
                // The process exited before the workspace notification reached
                // us. Preserve the record here as the same termination result.
                for index in orphanedAssignments.indices
                where orphanedAssignments[index].id == id {
                    orphanedAssignments[index].orphanedAt = now()
                    orphanedAssignments[index].awaitsWindowReopen = nil
                    orphanedAssignments[index].awaitsApplicationRelaunch = true
                    preservedForRelaunch = true
                }
            }
        }
        if !retryIDs.isEmpty { scheduleWindowDestructionFinalization(retryIDs) }
        if preservedForWindowReopen || preservedForRelaunch { persistWindowAssignments() }
    }
    func managedWindow(matching handle: AXWindowHandle) -> ManagedWindow? {
        sections.values.flatMap(\.windows).first { $0.handle == handle }
    }

    func isUserDetached(_ handle: AXWindowHandle, pid: pid_t) -> Bool {
        userDetachedWindowHandles[pid]?.contains(handle) == true
    }

    var allUserDetachedWindowHandles: Set<AXWindowHandle> {
        userDetachedWindowHandles.values.reduce(into: []) { $0.formUnion($1) }
    }

    func forgetUserDetachedWindow(_ handle: AXWindowHandle, pid: pid_t) {
        guard var handles = userDetachedWindowHandles[pid] else { return }
        handles.remove(handle)
        if handles.isEmpty {
            userDetachedWindowHandles.removeValue(forKey: pid)
        } else {
            userDetachedWindowHandles[pid] = handles
        }
    }

    private func forgetUserDetachedWindow(_ handle: AXWindowHandle) {
        for pid in Array(userDetachedWindowHandles.keys) {
            forgetUserDetachedWindow(handle, pid: pid)
        }
    }

    /// Finder keeps inactive tabs readable as AX windows after removing them
    /// from AXWindows. Its tab bar moves to the selected tab's window, so use
    /// that public relationship to transfer the existing assignment in place.
    /// Equal titles, identifiers and frames alone do not establish a tab group.
    @discardableResult
    func reconcileFinderTabs(pid: pid_t? = nil) -> Bool {
        guard hasWindowManagementAccess, isAccessibilityTrusted, !isInSystemTransition else { return false }
        let candidates = sections.values.flatMap(\.windows).filter {
            $0.finderTabGroup != nil && (pid == nil || $0.pid == pid)
        }
        var listedByPID: [pid_t: Set<AXWindowHandle>] = [:]
        var changed = false
        for candidate in candidates {
            guard let group = candidate.finderTabGroup,
                  let selected = try? accessibility.selectedWindow(inFinderTabGroup: group),
                  selected != candidate.handle,
                  let snapshot = try? accessibility.snapshot(window: selected),
                  snapshot.pid == candidate.pid,
                  snapshot.finderTabGroup == group || snapshot.finderTabGroup == nil else { continue }
            if listedByPID[candidate.pid] == nil {
                guard let handles = try? accessibility.windowHandles(pid: candidate.pid) else { continue }
                listedByPID[candidate.pid] = Set(handles)
            }
            guard let listed = listedByPID[candidate.pid], listed.contains(selected) else { continue }
            if listed.contains(candidate.handle) {
                // Dragging the selected tab out leaves two real windows. Keep
                // the original window; it no longer owns the remaining tabs.
                if let old = try? accessibility.snapshot(window: candidate.handle),
                   old.finderTabGroup != group,
                   let location = location(ofWindowID: candidate.id) {
                    sections[location.sectionID]?.windows[location.order].finderTabGroup = old.finderTabGroup
                }
                continue
            }
            guard let location = location(ofWindowID: candidate.id) else { continue }
            // A creation callback may already have attached the new tab before
            // this pass ran. The confirmed tab-bar identity coalesces that
            // duplicate; all unrelated Finder windows keep their own entries.
            if let duplicate = managedWindow(matching: selected), duplicate.id != candidate.id {
                removeWindow(id: duplicate.id)
                forgetSavedWindowAssignments { $0.id == duplicate.id }
            }
            guard let updatedLocation = self.location(ofWindowID: candidate.id) else { continue }
            var window = sections[updatedLocation.sectionID]!.windows[updatedLocation.order]
            window.handle = selected
            window.title = snapshot.title
            window.isMinimized = snapshot.isMinimized
            window.finderTabGroup = snapshot.finderTabGroup
            window.lastKnownFrame = snapshot.frame
            sections[updatedLocation.sectionID]?.windows[updatedLocation.order] = window
            snapshotFailures.remove(candidate.id)
            invalidSnapshotFirstFailure.removeValue(forKey: candidate.id)
            removeUnattachedWindow(handle: selected)
            if focusedManagedWindowID == candidate.id { lastFocusedSectionByPID[candidate.pid] = location.sectionID }
            changed = true
        }
        if changed {
            persistWindowAssignments()
            onOverlayPresentationChanged?()
            exitFocusModeIfSectionIsEmpty()
        }
        return changed
    }

    /// The switcher groups by bundle identifier, so its "when needed" title
    /// rule must make the same application-wide decision even when that
    /// application's windows are distributed across several sections.
    func managedWindowCount(bundleIdentifier: String) -> Int {
        sections.values
            .flatMap(\.windows)
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .count
    }

    private func rememberFocusedSection(windowID: UUID?) {
        guard let windowID,
              let window = managedWindow(id: windowID),
              let location = location(ofWindowID: windowID) else { return }
        lastFocusedSectionByPID[window.pid] = location.sectionID
    }

    /// Display reconfiguration can replace a window's AX element without
    /// replacing the window. Reattachment therefore uses public identity
    /// descriptors after trying the exact live handle.
    func managedWindow(
        matching snapshot: AXWindowSnapshot,
        windowOrdinal: Int,
        listedHandles: Set<AXWindowHandle>?
    ) -> ManagedWindow? {
        if let exact = managedWindow(matching: snapshot.handle) { return exact }
        if let group = snapshot.finderTabGroup,
           let existing = sections.values.flatMap(\.windows).first(where: {
               $0.pid == snapshot.pid && $0.finderTabGroup == group
                   && listedHandles?.contains($0.handle) == false
           }) { return existing }
        // Descriptor matching exists only for elements replaced during a
        // display transition. A candidate the application still lists is a
        // different live window, even if its title or identifier is identical.
        guard let listedHandles else { return nil }
        let candidates = sections.values.flatMap(\.windows).filter {
            $0.pid == snapshot.pid && !listedHandles.contains($0.handle)
        }
        if let identifier = snapshot.accessibilityIdentifier,
           !identifier.isEmpty {
            let identifierMatches = candidates.filter {
                $0.accessibilityIdentifier == identifier
            }
            if identifierMatches.count == 1 { return identifierMatches[0] }
        }
        let titleMatches = candidates.filter { $0.title == snapshot.title }
        if titleMatches.count == 1 { return titleMatches[0] }
        return candidates.first { $0.windowOrdinal == windowOrdinal && $0.title == snapshot.title }
    }

    private func managedWindows(matching handle: AXWindowHandle) -> [ManagedWindow] {
        sections.values.flatMap(\.windows).filter { $0.handle == handle }
    }

    func managedWindow(id: UUID) -> ManagedWindow? {
        sections.values.flatMap(\.windows).first { $0.id == id }
    }

    /// Whether the owning application no longer lists this window at all.
    /// Unreadable applications answer `false`: an unanswered question is not
    /// evidence that a window closed.
    private func applicationHasStoppedListing(
        _ window: ManagedWindow,
        cache: inout [pid_t: [AXWindowHandle]?]
    ) -> Bool {
        let handles: [AXWindowHandle]?
        if let cached = cache[window.pid] {
            handles = cached
        } else {
            handles = try? accessibility.windowHandles(pid: window.pid)
            cache[window.pid] = handles
        }
        guard let handles else { return false }
        return !handles.contains(window.handle)
    }

    @discardableResult
    func removeWindow(handle: AXWindowHandle) -> Bool {
        var removedAny = false
        for key in Array(sections.keys) {
            guard var section = sections[key] else { continue }
            let removedIDs = section.windows.filter { $0.handle == handle }.map(\.id)
            guard !removedIDs.isEmpty else { continue }
            removedAny = true
            for id in removedIDs {
                snapshotFailures.remove(id)
                invalidSnapshotFirstFailure.removeValue(forKey: id)
            }
            if let focusedManagedWindowID, removedIDs.contains(focusedManagedWindowID) {
                self.focusedManagedWindowID = nil
            }
            section.windows.removeAll { $0.handle == handle }
            if let active = section.activeWindowID, removedIDs.contains(active) {
                section.activeWindowID = section.windows.last?.id
            }
            if section.windows.isEmpty { sections.removeValue(forKey: key) } else { sections[key] = section }
        }
        return removedAny
    }

    @discardableResult
    func removeWindow(id: UUID) -> Bool {
        var removedAny = false
        for key in Array(sections.keys) {
            guard var section = sections[key],
                  section.windows.contains(where: { $0.id == id }) else { continue }
            removedAny = true
            snapshotFailures.remove(id)
            invalidSnapshotFirstFailure.removeValue(forKey: id)
            if focusedManagedWindowID == id { focusedManagedWindowID = nil }
            section.windows.removeAll { $0.id == id }
            if section.activeWindowID == id {
                section.activeWindowID = section.windows.last?.id
            }
            if section.windows.isEmpty {
                sections.removeValue(forKey: key)
            } else {
                sections[key] = section
            }
        }
        return removedAny
    }

    @discardableResult
    private func removeAllWindows(forTerminatedPID pid: pid_t) -> Bool {
        pendingWindowCreations.removeAll { $0.pid == pid }
        let handles = Set(sections.values.flatMap(\.windows).filter { $0.pid == pid }.map(\.handle))
        guard !handles.isEmpty else { return false }
        for handle in handles { removeWindow(handle: handle) }
        menusByPID.removeValue(forKey: pid)
        lastFocusedSectionByPID.removeValue(forKey: pid)
        userDetachedWindowHandles.removeValue(forKey: pid)
        return true
    }

    /// Removes dead live handles without discarding where their windows were
    /// attached. The persisted descriptors are resolved against the next
    /// process that launches with the same bundle identifier.
    @discardableResult
    private func preserveAndRemoveWindows(forTerminatedPID pid: pid_t) -> Bool {
        let windows = sections.values.flatMap(\.windows).filter { $0.pid == pid }
        guard !windows.isEmpty else { return false }
        for window in windows {
            orphan(window, awaitsApplicationRelaunch: true)
            pendingDestroyedWindows.removeValue(forKey: window.id)
        }
        return removeAllWindows(forTerminatedPID: pid)
    }

    /// The workspace notification names a process that just quit in this
    /// session. Its live windows and destruction records still inside the quit
    /// grace period become durable relaunch records. Windows conclusively
    /// closed earlier are discarded instead of being resurrected by a later
    /// application launch.
    func confirmApplicationTerminated(pid: pid_t, bundleIdentifier: String?) {
        guard hasWindowManagementAccess else { return }
        pendingWindowCreations.removeAll { $0.pid == pid }
        let removedUnattachedApplication = unattachedApplicationsByPID.removeValue(forKey: pid) != nil
        unattachedApplicationPIDsAwaitingSeed.remove(pid)
        unattachedApplicationPIDsWithEmptySeedRead.remove(pid)
        applicationIconsByPID.removeValue(forKey: pid)
        removeUnattachedWindows(pid: pid)
        let activeSplitsBeforeTermination = activeApplicationSplitPairs()
        lastFocusedSectionByPID.removeValue(forKey: pid)
        userDetachedWindowHandles.removeValue(forKey: pid)
        let identity = bundleIdentifier ?? "pid.\(pid)"
        windowReopenObservationIdentities.removeValue(forKey: pid)
        let wasRelaunchRecoveryProcess = applicationRelaunchRecoveryPIDs[identity] == pid
        applicationRelaunchRecoveryPIDs.removeValue(forKey: identity)
        // A relaunch record gets one relaunch. This process was the instance
        // allowed to claim the bundle's earlier-generation records, and it has
        // now run its whole life without that window coming back. Carrying the
        // record into yet another generation only lets it capture an unrelated
        // window by position later, so it is retired here.
        let discardedStaleRelaunchAssignments = wasRelaunchRecoveryProcess && forgetSavedWindowAssignments {
            $0.bundleIdentifier == identity
                && $0.awaitsApplicationRelaunch == true
                && $0.processIdentifier != pid
        }
        let pendingDestructionIDs = Set(pendingDestroyedWindows.keys)
        let closedWindowIDs = Set(
            (orphanedAssignments + savedWindowAssignments)
                .filter {
                    $0.processIdentifier == pid
                        && $0.bundleIdentifier == identity
                        && $0.awaitsWindowReopen == true
                        && !pendingDestructionIDs.contains($0.id)
                }
                .map(\.id)
        )
        let discardedClosedAssignments = forgetSavedWindowAssignments {
            closedWindowIDs.contains($0.id)
        }
        let hasAnotherRunningInstance = bundleIdentifier.map { bundleIdentifier in
            NSWorkspace.shared.runningApplications.contains {
                $0.processIdentifier != pid && $0.bundleIdentifier == bundleIdentifier
            }
        } ?? true
        let liveWindows = sections.values.flatMap(\.windows).filter {
            $0.pid == pid && $0.bundleIdentifier == identity
        }
        let knownWindowIDs = Set(liveWindows.map(\.id)).union(
            orphanedAssignments
                .filter { $0.processIdentifier == pid && $0.bundleIdentifier == identity }
                .map(\.id)
        )
        let matchesTerminatedApplication: (PersistedWindowAssignment) -> Bool = { assignment in
            knownWindowIDs.contains(assignment.id)
                || (assignment.processIdentifier == pid && assignment.bundleIdentifier == identity)
                || (!hasAnotherRunningInstance && assignment.bundleIdentifier == bundleIdentifier)
        }
        for window in liveWindows {
            orphan(window, awaitsApplicationRelaunch: true)
        }

        for index in orphanedAssignments.indices
        where matchesTerminatedApplication(orphanedAssignments[index]) {
            orphanedAssignments[index].orphanedAt = now()
            orphanedAssignments[index].awaitsWindowReopen = nil
            orphanedAssignments[index].awaitsApplicationRelaunch = true
        }
        // A destruction notification may already have removed the live handle.
        // Requeue its current profile before persistence filters that profile.
        for saved in savedWindowAssignments
        where matchesTerminatedApplication(saved)
            && saved.displayTopology == currentDisplayTopology
            && !orphanedAssignments.contains(where: { $0.id == saved.id }) {
            var pending = saved
            pending.orphanedAt = now()
            pending.awaitsWindowReopen = nil
            pending.awaitsApplicationRelaunch = true
            orphanedAssignments.append(pending)
        }
        var changedSavedAssignment = false
        for index in savedWindowAssignments.indices
        where matchesTerminatedApplication(savedWindowAssignments[index]) {
            savedWindowAssignments[index].awaitsWindowReopen = nil
            savedWindowAssignments[index].awaitsApplicationRelaunch = true
            changedSavedAssignment = true
        }

        let affectedIDs = Set(
            orphanedAssignments.filter(matchesTerminatedApplication).map(\.id)
        )
        for id in affectedIDs { pendingDestroyedWindows.removeValue(forKey: id) }
        let removed = removeAllWindows(forTerminatedPID: pid)
        if removedUnattachedApplication { onUnattachedApplicationRosterChanged?() }
        guard removed
            || !affectedIDs.isEmpty
            || changedSavedAssignment
            || discardedClosedAssignments
            || discardedStaleRelaunchAssignments else { return }
        if activeApplicationSplitPairs() != activeSplitsBeforeTermination {
            if isInSystemTransition {
                needsApplicationSplitReflow = true
            } else {
                reflowManagedWindows()
            }
            reconcileApplicationSplitVisibilityForCurrentFocus()
            onOverlayPresentationChanged?()
        }
        persistWindowAssignments()
        exitFocusModeIfSectionIsEmpty()
    }

    // MARK: - Orphaned assignments

    /// The retry limit bounds idle AX traffic, not the lifetime of a saved
    /// attachment. A wake, display/permission refresh, or application event is
    /// new evidence that a previously unavailable window may be readable now.
    /// Application events renew only expired records to preserve pacing. System
    /// recovery gives every pending window a full budget, including records
    /// that would otherwise expire during the wake-settling period.
    func renewOrphanRecovery(bundleIdentifier: String? = nil, onlyExpired: Bool = false) {
        guard hasWindowManagementAccess else { return }
        let retryStart = now()
        let expiry = retryStart.addingTimeInterval(-Self.orphanRetentionInterval)
        var renewed = false
        for index in orphanedAssignments.indices {
            let assignment = orphanedAssignments[index]
            guard assignment.awaitsWindowReopen != true,
                  pendingDestroyedWindows[assignment.id] == nil,
                  bundleIdentifier == nil || assignment.bundleIdentifier == bundleIdentifier,
                  !onlyExpired || (assignment.orphanedAt ?? retryStart) <= expiry else { continue }
            orphanedAssignments[index].orphanedAt = retryStart
            renewed = true
        }
        if renewed { nextOrphanRecoveryAttempt = nil }
    }

    /// Files a temporarily absent window so a later refresh can reclaim it.
    /// Explicit user detachment removes its record. A confirmed ordinary close
    /// retains one only while the same application process remains alive;
    /// application termination marks only its live/pending windows for relaunch.
    private func orphan(
        _ window: ManagedWindow,
        awaitsWindowReopen: Bool? = nil,
        awaitsApplicationRelaunch: Bool? = nil
    ) {
        guard let location = location(ofWindowID: window.id) else { return }
        var pending = assignment(
            for: window,
            in: location,
            orphanedAt: now(),
            awaitsWindowReopen: awaitsWindowReopen,
            awaitsApplicationRelaunch: awaitsApplicationRelaunch
        )
        // A previous write may already include dormant windows ahead of this
        // live one, so its durable order is more complete than the compacted
        // index in the live-only section array.
        if let saved = savedWindowAssignments.first(where: {
            $0.id == window.id
                && $0.sectionID == location.sectionID
                && ($0.displayTopology == nil || $0.displayTopology == currentDisplayTopology)
        }) {
            pending.order = saved.order
        }
        forgetOrphans { $0.id == window.id }
        orphanedAssignments.append(pending)
    }

    @discardableResult
    func forgetOrphans(where matches: (PersistedWindowAssignment) -> Bool) -> Bool {
        let before = orphanedAssignments.count
        orphanedAssignments.removeAll(where: matches)
        return orphanedAssignments.count != before
    }

    /// Retries every filed orphan against its application's current windows.
    /// Returns true when the managed set changed.
    @discardableResult
    private func recoverOrphanedWindows() -> Bool {
        guard !orphanedAssignments.isEmpty else { return false }
        // Elements are still being replaced mid-transition; retrying now would
        // only burn AX round trips against an application that cannot answer.
        guard !isInSystemTransition else { return false }
        // refreshRuntime() also runs on every application activation, so pace
        // the window-list reads instead of following its cadence.
        if let nextOrphanRecoveryAttempt, now() < nextOrphanRecoveryAttempt { return false }
        nextOrphanRecoveryAttempt = now().addingTimeInterval(Self.orphanRecoveryInterval)

        // Idle retries stop after the recovery window. The record remains,
        // and a lifecycle/application event or explicit refresh can renew it.
        let expiry = now().addingTimeInterval(-Self.orphanRetentionInterval)
        let pendingDestructionIDs = Set(pendingDestroyedWindows.keys)
        let retryable = orphanedAssignments.filter {
            !pendingDestructionIDs.contains($0.id)
                && $0.awaitsWindowReopen != true
                && ($0.orphanedAt ?? now()) > expiry
        }
        guard !retryable.isEmpty else { return false }

        // Ordinal matching is deliberately unavailable here. At launch it is a
        // reasonable last resort, but mid-session it would let a stale record
        // drag an unrelated window into a section.
        let recovered = restore(
            assignments: retryable,
            excluding: Set(sections.values.flatMap(\.windows).map(\.handle)),
            allowingOrdinalFallback: false,
            reflowExistingWindows: false
        )
        guard !recovered.isEmpty else { return false }
        lifecycleLogger.info("Reclaimed \(recovered.count) window(s) after their AX elements were replaced")
        forgetOrphans { recovered.contains($0.id) }
        return true
    }

    /// An application may be reopened long after heuristic orphan retries have
    /// stopped. Activation is the precise signal to make its relaunch records
    /// immediately eligible again.
    func prepareApplicationRelaunchRecovery(pid: pid_t, bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        // Activation and window creation also let the same still-running
        // application recover after a long Accessibility interruption.
        renewOrphanRecovery(bundleIdentifier: bundleIdentifier, onlyExpired: true)
        guard applicationRelaunchRecoveryPIDs[bundleIdentifier] != pid else { return }
        var foundNewProcessRecord = false
        for index in orphanedAssignments.indices
        where orphanedAssignments[index].bundleIdentifier == bundleIdentifier
            && orphanedAssignments[index].awaitsApplicationRelaunch == true
            && orphanedAssignments[index].processIdentifier != pid {
            orphanedAssignments[index].orphanedAt = now()
            foundNewProcessRecord = true
        }
        if foundNewProcessRecord {
            applicationRelaunchRecoveryPIDs[bundleIdentifier] = pid
            nextOrphanRecoveryAttempt = nil
        }
    }

    func hasAwaitingApplicationRelaunch(pid: pid_t) -> Bool {
        guard let bundleIdentifier = runningApplication(pid: pid)?.bundleIdentifier,
              applicationRelaunchRecoveryPIDs[bundleIdentifier] == pid else { return false }
        let expiry = now().addingTimeInterval(-Self.orphanRetentionInterval)
        return orphanedAssignments.contains {
            $0.bundleIdentifier == bundleIdentifier
                && $0.awaitsApplicationRelaunch == true
                && ($0.orphanedAt ?? now()) > expiry
        }
    }

    /// PIDs whose application-level window-created notification must remain
    /// observed even when they currently have no attached live window.
    var windowObservationPIDs: Set<pid_t> {
        var pids = Set(sections.values.flatMap { $0.windows.map(\.pid) })
        pids.formUnion(pendingDestroyedWindows.values.map(\.pid))
        for assignment in orphanedAssignments where assignment.awaitsWindowReopen == true {
            guard windowReopenObservationIdentities[assignment.processIdentifier]
                    == assignment.bundleIdentifier else { continue }
            pids.insert(assignment.processIdentifier)
        }
        if showUnattachedWindowIcons {
            pids.formUnion(visibleUnattachedApplications().map(\.pid))
        }
        return pids
    }

    /// Whether this process still owns a window in some section. Free-window
    /// observation puts an observer on every running application, so an
    /// application-level notification needs this before it is allowed to cost
    /// a full reconciliation.
    func hasManagedWindows(pid: pid_t) -> Bool {
        sections.values.contains { section in
            section.windows.contains { $0.pid == pid }
        }
    }

    /// The applications free-window discovery may enumerate right now. Every
    /// caller that picks an application to read goes through this, so a new
    /// exclusion is added in exactly one place.
    func visibleUnattachedApplications() -> [RunningApplicationSnapshot] {
        unattachedApplicationsByPID.values.filter(isUnattachedApplicationVisible)
    }

    /// Rebuilds the cheap NSWorkspace side of unattached-window discovery.
    /// Actual AX window enumeration is paced separately, one application per
    /// idle pass, and targeted events refresh only their owning process.
    func refreshUnattachedApplicationRoster() {
        guard hasWindowManagementAccess else { return }
        guard showUnattachedWindowIcons else { return }
        let applications = runningApplicationSnapshotsProvider().filter {
            $0.pid != ownProcessIdentifier && $0.activationPolicy != .prohibited
        }
        let next = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { _, latest in latest })
        let terminatedPIDs = Set(unattachedApplicationsByPID.keys).subtracting(next.keys)
        let replacedPIDs: Set<pid_t> = Set(next.compactMap { pid, application in
            guard let previous = unattachedApplicationsByPID[pid],
                  previous.bundleIdentifier != application.bundleIdentifier else { return nil }
            return pid
        })
        let newlyObservedPIDs = Set(next.keys)
            .subtracting(unattachedApplicationsByPID.keys)
            .union(replacedPIDs)
        let rosterChanged = next != unattachedApplicationsByPID
        unattachedApplicationsByPID = next
        unattachedApplicationPIDsAwaitingSeed.formIntersection(next.keys)
        unattachedApplicationPIDsAwaitingSeed.formUnion(newlyObservedPIDs)
        unattachedApplicationPIDsWithEmptySeedRead.formIntersection(next.keys)
        unattachedApplicationPIDsWithEmptySeedRead.subtract(newlyObservedPIDs)
        for pid in terminatedPIDs.union(replacedPIDs) {
            removeUnattachedWindows(pid: pid)
            applicationIconsByPID.removeValue(forKey: pid)
        }
        // Install an application-level AX observer before the launch handler's
        // immediate window enumeration. NSWorkspace commonly reports a process
        // before its first window enters AXWindows; observing only in the next
        // full reconciliation leaves a gap in which AXWindowCreated is lost.
        if rosterChanged { onUnattachedApplicationRosterChanged?() }
        // Activating an already-running application rebuilds an identical
        // roster; publishing that would repaint every bar for nothing. The
        // pending-seed term keeps this the trigger that starts the paced seed
        // pass, which is what the publish is really for.
        if rosterChanged || hasVisibleUnattachedApplicationAwaitingSeed {
            onOverlayPresentationChanged?()
        }
    }

    var hasVisibleUnattachedApplicationAwaitingSeed: Bool {
        showUnattachedWindowIcons && isAccessibilityTrusted
            && nextUnattachedApplicationAwaitingSeed() != nil
    }

    /// Regular applications before background agents, then by pid, so the
    /// applications the user actually looks at get their icons first.
    private func nextUnattachedApplicationAwaitingSeed() -> RunningApplicationSnapshot? {
        visibleUnattachedApplications()
            .filter {
                unattachedApplicationPIDsAwaitingSeed.contains($0.pid)
                    && !unattachedApplicationPIDsWithEmptySeedRead.contains($0.pid)
            }
            .min {
                if $0.activationPolicy != $1.activationPolicy {
                    return $0.activationPolicy == .regular
                }
                return $0.pid < $1.pid
            }
    }

    /// A bounded compatibility fallback. AX observers carry normal changes;
    /// this refreshes only one GUI application per idle turn so a slow process
    /// cannot turn every reconciliation into a system-wide window sweep.
    func refreshNextUnattachedApplication() {
        guard hasWindowManagementAccess, showUnattachedWindowIcons, isAccessibilityTrusted else { return }
        let pids = visibleUnattachedApplications().map(\.pid).sorted()
        guard !pids.isEmpty else {
            lastUnattachedDiscoveryPID = nil
            return
        }
        let pid = lastUnattachedDiscoveryPID.flatMap { previous in
            pids.first(where: { $0 > previous })
        } ?? pids[0]
        lastUnattachedDiscoveryPID = pid
        refreshUnattachedWindows(pid: pid)
    }

    /// Seeds each newly observed visible application once. The overlay calls
    /// this repeatedly on separate main-runloop turns, which makes every
    /// already-open free window discoverable without an activation while
    /// avoiding one blocking system-wide AX sweep.
    @discardableResult
    func refreshNextUnattachedApplicationAwaitingSeed() -> Bool {
        guard hasWindowManagementAccess,
              showUnattachedWindowIcons,
              isAccessibilityTrusted,
              let pid = nextUnattachedApplicationAwaitingSeed()?.pid else { return false }
        refreshUnattachedWindows(pid: pid)
        // Only a read that listed a window consumes the seed, so an
        // application whose first window has not entered the AX tree yet
        // keeps its one-time enumeration for a later targeted refresh.
        // Recording the empty read is what stops this paced pass from
        // choosing the same application forever.
        if unattachedApplicationPIDsAwaitingSeed.contains(pid) {
            unattachedApplicationPIDsWithEmptySeedRead.insert(pid)
        }
        return true
    }

    /// Refreshes selectable-but-unmanaged windows for one application. A raw
    /// handle-list failure preserves every prior icon, and individual snapshot
    /// failures preserve that handle's last readable presentation.
    func refreshUnattachedWindows(pid: pid_t) {
        guard hasWindowManagementAccess else { return }
        reconcileFinderTabs(pid: pid)
        guard showUnattachedWindowIcons,
              isAccessibilityTrusted,
              let application = unattachedApplicationsByPID[pid],
              !application.isHidden else { return }
        let listedHandles: [AXWindowHandle]
        do {
            listedHandles = try accessibility.windowHandles(pid: pid)
        } catch {
            return
        }
        // A targeted activation/launch refresh that already sees a real
        // window makes the queued seed redundant. An empty launch-era list is
        // deliberately left pending because the first window may not have
        // entered the AX tree yet.
        if !listedHandles.isEmpty {
            unattachedApplicationPIDsAwaitingSeed.remove(pid)
            unattachedApplicationPIDsWithEmptySeedRead.remove(pid)
        }

        let attachedHandles = Set(sections.values.flatMap(\.windows).map(\.handle))
        let previousForPID = unattachedWindowsByHandle.filter { $0.value.pid == pid }
        var resolvedIcon = applicationIconsByPID[pid].flatMap {
            $0.bundleIdentifier == application.bundleIdentifier ? $0.icon : nil
        }
        var refreshed: [AXWindowHandle: UnattachedWindow] = [:]
        for handle in listedHandles where !attachedHandles.contains(handle) {
            do {
                let snapshot = try accessibility.snapshot(window: handle)
                guard snapshot.pid == pid else { continue }
                let discoveryOrder: Int
                if let previous = previousForPID[handle] {
                    discoveryOrder = previous.discoveryOrder
                } else {
                    discoveryOrder = nextUnattachedWindowDiscoveryOrder
                    nextUnattachedWindowDiscoveryOrder += 1
                }
                let icon = resolvedIcon ?? unattachedIcon(for: application)
                resolvedIcon = icon
                refreshed[handle] = UnattachedWindow(
                    handle: handle,
                    pid: pid,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    icon: icon,
                    title: snapshot.title,
                    frame: Self.appKitFrame(fromAccessibilityFrame: snapshot.frame),
                    isMinimized: snapshot.isMinimized,
                    // Corrected by the window-server sweep below, which
                    // answers for every application in one query.
                    isOnActiveSpace: previousForPID[handle]?.isOnActiveSpace ?? true,
                    discoveryOrder: discoveryOrder
                )
            } catch {
                if let previous = previousForPID[handle] { refreshed[handle] = previous }
            }
        }
        // During sleep, locking, wake settling, and display reconfiguration,
        // even the owning application's raw list is not trustworthy enough to
        // make a visible icon disappear.
        if isInSystemTransition {
            for (handle, previous) in previousForPID where refreshed[handle] == nil {
                refreshed[handle] = previous
            }
        }

        let changed = previousForPID != refreshed
        unattachedWindowsByHandle = unattachedWindowsByHandle.filter { $0.value.pid != pid }
        unattachedWindowsByHandle.merge(refreshed) { _, replacement in replacement }
        if let focusedUnattachedWindowHandle,
           previousForPID[focusedUnattachedWindowHandle] != nil,
           refreshed[focusedUnattachedWindowHandle] == nil {
            self.focusedUnattachedWindowHandle = nil
            if pendingUnattachedFocusReassertion?.handle == focusedUnattachedWindowHandle {
                pendingUnattachedFocusReassertion = nil
            }
        }
        pruneUnattachedCycleCursors()
        let spaceVisibilityChanged = refreshUnattachedWindowSpaceVisibility()
        if changed || spaceVisibilityChanged { onOverlayPresentationChanged?() }
    }

    /// Refreshes one already-known free window. A title, move, or resize
    /// notification names its own element, so re-enumerating the owning
    /// application for it would spend a blocking read per sibling window —
    /// and applications that rewrite their titles continuously would keep
    /// that cost running while the desktop is idle. Space membership is
    /// deliberately carried over: none of these events can change it.
    func refreshUnattachedWindow(handle: AXWindowHandle, pid: pid_t) {
        guard hasWindowManagementAccess else { return }
        guard showUnattachedWindowIcons,
              isAccessibilityTrusted,
              let previous = unattachedWindowsByHandle[handle],
              previous.pid == pid,
              let application = unattachedApplicationsByPID[pid],
              !application.isHidden,
              let snapshot = try? accessibility.snapshot(window: handle),
              snapshot.pid == pid else { return }
        var updated = previous
        updated.title = snapshot.title
        updated.frame = Self.appKitFrame(fromAccessibilityFrame: snapshot.frame)
        updated.isMinimized = snapshot.isMinimized
        guard updated != previous else { return }
        unattachedWindowsByHandle[handle] = updated
        onOverlayPresentationChanged?()
    }

    /// Re-reads which cached free windows sit on the active Space. The window
    /// server answers for every application at once, so this is never done
    /// per process, and a nil answer leaves every window visible rather than
    /// making icons disappear on an unavailable read.
    @discardableResult
    func refreshUnattachedWindowSpaceVisibility() -> Bool {
        guard hasWindowManagementAccess else { return false }
        guard showUnattachedWindowIcons, !unattachedWindowsByHandle.isEmpty else { return false }
        let onScreenFrames = onScreenWindowFramesProvider()
        var changed = false
        for (handle, window) in unattachedWindowsByHandle {
            let isOnActiveSpace = Self.isOnScreen(
                accessibilityFrame: Self.accessibilityFrame(fromAppKitFrame: window.frame),
                pid: window.pid,
                onScreenFrames: onScreenFrames
            )
            guard window.isOnActiveSpace != isOnActiveSpace else { continue }
            unattachedWindowsByHandle[handle]?.isOnActiveSpace = isOnActiveSpace
            changed = true
        }
        return changed
    }

    /// Re-reads which managed windows the window server shows on the active
    /// Space, from the frames the last snapshots recorded, so no Accessibility
    /// call is made. A window that fails this check stays attached: closing a
    /// window is never inferred from it. Only the switcher stops drawing it,
    /// and the icon returns as soon as the window is on screen again. That
    /// covers windows parked on another Space and windows an application
    /// ordered out instead of closing, which menu bar applications do; the
    /// Accessibility API reports both as ordinary open windows.
    ///
    /// Minimized windows sit in the Dock and a hidden application's windows
    /// return with it, so both keep their icons even though the window server
    /// lists neither as on screen. A nil answer keeps every window visible.
    @discardableResult
    func refreshManagedWindowSpaceVisibility() -> Bool {
        guard hasWindowManagementAccess,
              sections.values.contains(where: { !$0.windows.isEmpty }) else { return false }
        // A display or power transition can empty the window server's list
        // for a moment; judging windows from it would blank every switcher.
        // A window the list does show is on screen regardless, so bars a lock
        // ordered out return with the desktop instead of waiting out the
        // settle period.
        let canHide = !isInSystemTransition
        let onScreenFrames = onScreenWindowFramesProvider()
        var hiddenApplications: [pid_t: Bool] = [:]
        var changed = false
        for key in Array(sections.keys) {
            guard var section = sections[key] else { continue }
            var sectionChanged = false
            for index in section.windows.indices {
                let window = section.windows[index]
                let isOnActiveSpace: Bool
                if let onScreenFrames, !window.isMinimized, window.lastKnownFrame != .zero {
                    let isApplicationHidden = hiddenApplications[window.pid] ?? {
                        let value = runningApplication(pid: window.pid)?.isHidden ?? false
                        hiddenApplications[window.pid] = value
                        return value
                    }()
                    isOnActiveSpace = isApplicationHidden || Self.isOnScreen(
                        accessibilityFrame: window.lastKnownFrame,
                        pid: window.pid,
                        onScreenFrames: onScreenFrames
                    )
                } else {
                    isOnActiveSpace = true
                }
                guard isOnActiveSpace || canHide,
                      section.windows[index].isOnActiveSpace != isOnActiveSpace else { continue }
                section.windows[index].isOnActiveSpace = isOnActiveSpace
                sectionChanged = true
            }
            if sectionChanged {
                sections[key] = section
                changed = true
            }
        }
        return changed
    }

    /// Windows parked on another Space — a native full-screen Space included —
    /// still report frames inside a display, so nothing in the Accessibility
    /// API separates them from windows the user can see. This public window
    /// server list does, and it needs no permission beyond Accessibility: only
    /// window titles and images are gated behind Screen Recording.
    static func currentOnScreenWindowFrames() -> [pid_t: [CGRect]]? {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var result: [pid_t: [CGRect]] = [:]
        for entry in entries {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            result[pid, default: []].append(frame)
        }
        return result
    }

    /// The window server reports the same flipped global coordinates the
    /// Accessibility API uses, but a point of rounding drift between the two
    /// is normal, so the frames are matched with a tolerance.
    private static func isOnScreen(
        accessibilityFrame frame: CGRect,
        pid: pid_t,
        onScreenFrames: [pid_t: [CGRect]]?
    ) -> Bool {
        guard let onScreenFrames else { return true }
        return (onScreenFrames[pid] ?? []).contains { candidate in
            abs(candidate.minX - frame.minX) <= onScreenFrameTolerance
                && abs(candidate.minY - frame.minY) <= onScreenFrameTolerance
                && abs(candidate.width - frame.width) <= onScreenFrameTolerance
                && abs(candidate.height - frame.height) <= onScreenFrameTolerance
        }
    }

    private static let onScreenFrameTolerance: CGFloat = 2

    func removeUnattachedWindow(handle: AXWindowHandle) {
        guard unattachedWindowsByHandle.removeValue(forKey: handle) != nil else { return }
        if focusedUnattachedWindowHandle == handle { focusedUnattachedWindowHandle = nil }
        if pendingUnattachedFocusReassertion?.handle == handle {
            pendingUnattachedFocusReassertion = nil
        }
        pruneUnattachedCycleCursors()
        onOverlayPresentationChanged?()
    }

    func removeUnattachedWindows(pid: pid_t) {
        let handles = Set(unattachedWindowsByHandle.values.filter { $0.pid == pid }.map(\.handle))
        guard !handles.isEmpty else { return }
        unattachedWindowsByHandle = unattachedWindowsByHandle.filter { $0.value.pid != pid }
        if let focusedUnattachedWindowHandle, handles.contains(focusedUnattachedWindowHandle) {
            self.focusedUnattachedWindowHandle = nil
        }
        if let handle = pendingUnattachedFocusReassertion?.handle, handles.contains(handle) {
            pendingUnattachedFocusReassertion = nil
        }
        pruneUnattachedCycleCursors()
        onOverlayPresentationChanged?()
    }

    /// Disabling the feature also stops observing applications that Panoptos
    /// knows only through their external icons. None of this state is durable,
    /// and clearing it never changes an attachment or its persistence record.
    func clearUnattachedWindowState() {
        let hadApplications = !unattachedApplicationsByPID.isEmpty
        unattachedApplicationsByPID.removeAll()
        unattachedApplicationPIDsAwaitingSeed.removeAll()
        unattachedApplicationPIDsWithEmptySeedRead.removeAll()
        unattachedWindowsByHandle.removeAll()
        unattachedCycleCursors.removeAll()
        focusedUnattachedWindowHandle = nil
        pendingUnattachedFocusReassertion = nil
        lastUnattachedDiscoveryPID = nil
        if hadApplications { onUnattachedApplicationRosterChanged?() }
    }

    /// The sections an unattached icon may be shown beside. Both the grouping
    /// and the cycle cursor resolve a window to a section, and they have to
    /// agree on what counts as a destination.
    private func occupiedVisibleSectionIDs(frames: [UUID: CGRect]) -> [UUID] {
        let occupied = sections.keys.filter {
            sections[$0]?.windows.isEmpty == false && frames[$0] != nil && isSectionVisible($0)
        }
        // A free window inside one section is inside the span over it as
        // well, and ties go to whichever comes first here. Layout sections
        // come first, so an icon joins the span only for a window that
        // straddles several of the sections it covers.
        return LayoutGeometry.readingOrder(
            leafIDs: occupied.filter { sections[$0]?.isSpanned == false },
            frames: frames
        ) + LayoutGeometry.readingOrder(
            leafIDs: occupied.filter { sections[$0]?.isSpanned == true },
            frames: frames
        )
    }

    /// Whether this cached free window may be presented at all. Shared with
    /// the cursor path so a window can never be selectable for one and not
    /// the other.
    private func isUnattachedWindowSelectable(
        _ window: UnattachedWindow,
        attachedHandles: Set<AXWindowHandle>
    ) -> Bool {
        guard !attachedHandles.contains(window.handle),
              !window.isMinimized,
              window.isOnActiveSpace,
              window.frame.width > 0,
              window.frame.height > 0,
              let application = unattachedApplicationsByPID[window.pid],
              isUnattachedApplicationVisible(application) else { return false }
        return currentDisplays.contains { $0.frame.intersects(window.frame) }
    }

    /// The cached free windows that are visible and actionable right now.
    /// Focus mode shares this query with icon presentation so hiding an
    /// unattached application never reaches minimized or other-Space windows.
    func selectableUnattachedWindows() -> [UnattachedWindow] {
        guard showUnattachedWindowIcons else { return [] }
        let attachedHandles = Set(sections.values.flatMap(\.windows).map(\.handle))
        return unattachedWindowsByHandle.values.filter {
            isUnattachedWindowSelectable($0, attachedHandles: attachedHandles)
        }
    }

    /// The window a click on this group's icon selects: one past whichever of
    /// its windows is focused or was last chosen. Both the tooltip's "Next"
    /// title and the click itself read this, so they cannot disagree.
    private func nextUnattachedWindowIndex(
        in windows: [UnattachedWindow],
        for key: UnattachedWindowGroupKey
    ) -> Int {
        guard !windows.isEmpty else { return 0 }
        let cursor = focusedUnattachedWindowHandle.flatMap { focused in
            windows.contains(where: { $0.handle == focused }) ? focused : nil
        } ?? unattachedCycleCursors[key]
        return cursor.flatMap { cursor in
            windows.firstIndex(where: { $0.handle == cursor }).map { ($0 + 1) % windows.count }
        } ?? 0
    }

    /// Pure presentation grouping: no AX calls occur while panels repaint.
    func unattachedWindowGroupsBySection() -> [UUID: [UnattachedWindowApplicationGroup]] {
        guard showUnattachedWindowIcons else { return [:] }
        let frames = sectionFrames()
        let orderedSectionIDs = occupiedVisibleSectionIDs(frames: frames)
        guard !orderedSectionIDs.isEmpty else { return [:] }

        let visibleWindows = selectableUnattachedWindows()

        var windowsByGroup: [UnattachedWindowGroupKey: [UnattachedWindow]] = [:]
        for window in visibleWindows {
            guard let sectionID = nearestOccupiedSection(
                to: window.frame,
                orderedSectionIDs: orderedSectionIDs,
                frames: frames
            ) else { continue }
            let key = UnattachedWindowGroupKey(
                sectionID: sectionID,
                bundleIdentifier: window.bundleIdentifier
            )
            windowsByGroup[key, default: []].append(window)
        }

        var result: [UUID: [UnattachedWindowApplicationGroup]] = [:]
        for (key, unorderedWindows) in windowsByGroup {
            let windows = unorderedWindows.sorted { $0.discoveryOrder < $1.discoveryOrder }
            guard let first = windows.first else { continue }
            let nextIndex = nextUnattachedWindowIndex(in: windows, for: key)
            result[key.sectionID, default: []].append(
                UnattachedWindowApplicationGroup(
                    id: key,
                    applicationName: first.applicationName,
                    icon: first.icon,
                    windows: windows,
                    nextWindowTitle: windows[nextIndex].title
                )
            )
        }
        for sectionID in result.keys {
            result[sectionID]?.sort {
                let left = $0.windows.first?.discoveryOrder ?? .max
                let right = $1.windows.first?.discoveryOrder ?? .max
                if left != right { return left < right }
                return $0.id.bundleIdentifier < $1.id.bundleIdentifier
            }
        }
        return result
    }

    func cycleUnattachedWindows(in key: UnattachedWindowGroupKey) {
        guard hasWindowManagementAccess,
              let group = unattachedWindowGroupsBySection()[key.sectionID]?.first(where: { $0.id == key }),
              !group.windows.isEmpty else { return }
        let target = group.windows[nextUnattachedWindowIndex(in: group.windows, for: key)]
        let exitedFocusMode = focusedSectionID != nil
        if exitedFocusMode { exitFocusMode() }
        do {
            try accessibility.focus(window: target.handle, pid: target.pid)
            unattachedCycleCursors[key] = target.handle
            focusedUnattachedWindowHandle = target.handle
            focusedManagedWindowID = nil
            compatibilityError = nil
            if exitedFocusMode, pendingHiddenApplicationWindowOrderRestoration != nil {
                pendingUnattachedFocusReassertion = (target.handle, target.pid)
                restorePendingHiddenApplicationWindowOrderAfterFocusChange()
            }
            onOverlayPresentationChanged?()
        } catch {
            compatibilityError = "Could not focus \(target.applicationName): \(error.localizedDescription)"
        }
    }

    /// Attaches the window selected by this icon's single-click cycling to the
    /// exact section beside which the icon is displayed. A fresh snapshot is
    /// resolved immediately before attachment because AX window attributes are
    /// volatile and the cached record is presentation-only.
    func attachUnattachedWindow(in key: UnattachedWindowGroupKey) {
        guard hasWindowManagementAccess,
              let group = unattachedWindowGroupsBySection()[key.sectionID]?.first(where: { $0.id == key }),
              !group.windows.isEmpty else { return }
        let target = focusedUnattachedWindowHandle.flatMap { focused in
            group.windows.first(where: { $0.handle == focused })
        } ?? unattachedCycleCursors[key].flatMap { cursor in
            group.windows.first(where: { $0.handle == cursor })
        } ?? group.windows[0]
        do {
            let snapshot = try accessibility.snapshot(window: target.handle)
            guard snapshot.pid == target.pid else { return }
            attach(window: snapshot, to: key.sectionID)
        } catch {
            compatibilityError = "Could not attach \(target.applicationName): \(error.localizedDescription)"
        }
    }

    private func nearestOccupiedSection(
        to windowFrame: CGRect,
        orderedSectionIDs: [UUID],
        frames: [UUID: CGRect]
    ) -> UUID? {
        var best: (sectionID: UUID, intersectionArea: CGFloat, distanceSquared: CGFloat)?
        for sectionID in orderedSectionIDs {
            guard let sectionFrame = frames[sectionID] else { continue }
            let intersection = windowFrame.intersection(sectionFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            let distance = Self.rectangleDistanceSquared(windowFrame, sectionFrame)
            guard let current = best else {
                best = (sectionID, area, distance)
                continue
            }
            if area > current.intersectionArea
                || (area == current.intersectionArea && distance < current.distanceSquared) {
                best = (sectionID, area, distance)
            }
        }
        return best?.sectionID
    }

    static func rectangleDistanceSquared(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let dx = max(0, max(first.minX - second.maxX, second.minX - first.maxX))
        let dy = max(0, max(first.minY - second.maxY, second.minY - first.maxY))
        return dx * dx + dy * dy
    }

    private func pruneUnattachedCycleCursors() {
        let handles = Set(unattachedWindowsByHandle.keys)
        unattachedCycleCursors = unattachedCycleCursors.filter { handles.contains($0.value) }
    }

    private func unattachedIcon(for application: RunningApplicationSnapshot) -> NSImage {
        if let cached = applicationIconsByPID[application.pid],
           cached.bundleIdentifier == application.bundleIdentifier {
            return cached.icon
        }

        let icon: NSImage
        if let suppliedIcon = application.icon {
            icon = suppliedIcon
        } else if let running = runningApplication(pid: application.pid),
                  (running.bundleIdentifier ?? "pid.\(application.pid)") == application.bundleIdentifier {
            icon = ApplicationIconResolver.icon(for: running)
        } else {
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        applicationIconsByPID[application.pid] = CachedApplicationIcon(
            bundleIdentifier: application.bundleIdentifier,
            icon: icon
        )
        return icon
    }

    func applicationIcon(for application: NSRunningApplication) -> NSImage {
        let pid = application.processIdentifier
        let bundleIdentifier = application.bundleIdentifier ?? "pid.\(pid)"
        if let cached = applicationIconsByPID[pid],
           cached.bundleIdentifier == bundleIdentifier {
            return cached.icon
        }

        let icon = ApplicationIconResolver.icon(for: application)
        applicationIconsByPID[pid] = CachedApplicationIcon(
            bundleIdentifier: bundleIdentifier,
            icon: icon
        )
        return icon
    }

    private func updateUnattachedCycleCursor(for handle: AXWindowHandle) {
        guard let window = unattachedWindowsByHandle[handle] else { return }
        let frames = sectionFrames()
        let orderedSectionIDs = occupiedVisibleSectionIDs(frames: frames)
        let attachedHandles = Set(sections.values.flatMap(\.windows).map(\.handle))
        guard !orderedSectionIDs.isEmpty,
              isUnattachedWindowSelectable(window, attachedHandles: attachedHandles),
              let sectionID = nearestOccupiedSection(
                  to: window.frame,
                  orderedSectionIDs: orderedSectionIDs,
                  frames: frames
              ) else { return }
        unattachedCycleCursors[
            UnattachedWindowGroupKey(
                sectionID: sectionID,
                bundleIdentifier: window.bundleIdentifier
            )
        ] = handle
    }

    private func isUnattachedApplicationVisible(_ application: RunningApplicationSnapshot) -> Bool {
        guard !application.isHidden, application.activationPolicy != .prohibited else { return false }
        let identity = HiddenApplication(
            pid: application.pid,
            bundleIdentifier: application.bundleIdentifier
        )
        return !focusModeHiddenApplications.contains(identity)
            && !applicationSplitHiddenApplications.contains(identity)
    }

    /// Corroborates persisted pid/bundle pairs once when launch restoration is
    /// prepared. Newly closed live windows are registered directly at the
    /// authoritative destruction notification instead.
    func rebuildWindowReopenObservationIdentities() {
        let expected = Dictionary(grouping: orphanedAssignments.filter {
            $0.awaitsWindowReopen == true
        }, by: \.processIdentifier).mapValues { Set($0.map(\.bundleIdentifier)) }
        guard !expected.isEmpty else {
            windowReopenObservationIdentities.removeAll()
            return
        }
        var validated: [pid_t: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            let identity = application.bundleIdentifier ?? "pid.\(pid)"
            if expected[pid]?.contains(identity) == true { validated[pid] = identity }
        }
        windowReopenObservationIdentities = validated
    }

    /// A newly created element is a strong, narrowly scoped replacement signal.
    /// Match it only against closed-window records (including ones still in the
    /// short quit-detection grace period) from this exact process, and scope
    /// restoration to that exact handle so an unrelated existing window cannot
    /// be pulled into the vacated section.
    func recoverReopenedWindow(_ handle: AXWindowHandle, pid: pid_t) -> AutomaticWindowAttachmentResult? {
        let assignments = orphanedAssignments.filter {
            $0.processIdentifier == pid && $0.awaitsWindowReopen == true
        }
        guard !assignments.isEmpty else { return nil }

        let snapshot: AXWindowSnapshot
        do {
            snapshot = try accessibility.snapshot(window: handle)
        } catch {
            return .retry
        }
        guard snapshot.pid == pid, !snapshot.isFullScreen else { return .ignored }
        guard snapshot.isResizable else { return .retry }

        let identifierMatches = snapshot.accessibilityIdentifier.flatMap { identifier in
            identifier.isEmpty ? nil : assignments.filter { $0.accessibilityIdentifier == identifier }
        } ?? []
        let titleMatches = assignments.filter { $0.title == snapshot.title }
        let candidate: PersistedWindowAssignment?
        if identifierMatches.count == 1 {
            candidate = identifierMatches[0]
        } else if titleMatches.count == 1 {
            candidate = titleMatches[0]
        } else if assignments.count == 1 {
            candidate = assignments[0]
        } else {
            let windows = (try? accessibility.windows(pid: pid)) ?? []
            let ordinal = windows.firstIndex { $0.handle == handle }
            let ordinalMatches = assignments.filter { $0.windowOrdinal == ordinal }
            candidate = ordinalMatches.count == 1 ? ordinalMatches[0] : nil
        }
        // This creation may be a genuinely new window rather than a reopening.
        // Let normal automatic placement handle it when several dormant records
        // cannot identify which section it belongs to.
        guard let candidate else { return nil }

        let recovered = restore(
            assignments: [candidate],
            excluding: Set(sections.values.flatMap(\.windows).map(\.handle)),
            allowingOrdinalFallback: false,
            reopenedWindowHandle: handle
        )
        guard recovered.contains(candidate.id) else { return .retry }
        pendingDestroyedWindows.removeValue(forKey: candidate.id)
        forgetOrphans { $0.id == candidate.id }
        if !orphanedAssignments.contains(where: {
            $0.processIdentifier == pid && $0.awaitsWindowReopen == true
        }) {
            windowReopenObservationIdentities.removeValue(forKey: pid)
        }
        persistWindowAssignments()
        return .attached
    }

    /// Window-created notifications are stronger than the idle recovery timer.
    /// Resolve every outstanding record for this newly launched process before
    /// generic automatic placement gets a chance to collapse its windows into
    /// the first restored section.
    @discardableResult
    func recoverApplicationRelaunchWindows(pid: pid_t) -> Bool {
        guard let bundleIdentifier = runningApplication(pid: pid)?.bundleIdentifier else { return false }
        prepareApplicationRelaunchRecovery(pid: pid, bundleIdentifier: bundleIdentifier)
        let pendingDestructionIDs = Set(pendingDestroyedWindows.keys)
        let expiry = now().addingTimeInterval(-Self.orphanRetentionInterval)
        let assignments = orphanedAssignments.filter {
            $0.bundleIdentifier == bundleIdentifier
                && $0.awaitsApplicationRelaunch == true
                && ($0.orphanedAt ?? now()) > expiry
                && !pendingDestructionIDs.contains($0.id)
        }
        guard !assignments.isEmpty else { return false }
        let recovered = restore(
            assignments: assignments,
            excluding: Set(sections.values.flatMap(\.windows).map(\.handle)),
            allowingOrdinalFallback: false
        )
        guard !recovered.isEmpty else { return false }
        forgetOrphans { recovered.contains($0.id) }
        persistWindowAssignments()
        return true
    }

    private static func isInvalidWindowError(_ error: Error) -> Bool {
        guard case AccessibilityClientError.attribute(_, .invalidUIElement) = error else { return false }
        return true
    }
    func observeWorkspace() {
        guard hasWindowManagementAccess, workspaceObservers.isEmpty else { return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let launchedApplication = application.map(RunningApplicationSnapshot.init(application:))
            Task { @MainActor in
                guard let self, self.hasWindowManagementAccess else { return }
                self.refreshUnattachedApplicationRoster()
                if let launchedApplication {
                    // A launch commonly precedes the application's first AX
                    // window. The observer installed by the roster callback
                    // normally catches it; one targeted retry also covers an AX
                    // server that was not ready to accept observation yet.
                    self.refreshUnattachedWindows(pid: launchedApplication.pid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        Task { @MainActor in
                            guard let self,
                                  self.hasWindowManagementAccess,
                                  self.unattachedApplicationsByPID[launchedApplication.pid]?
                                      .bundleIdentifier == launchedApplication.bundleIdentifier else { return }
                            self.refreshUnattachedWindows(pid: launchedApplication.pid)
                        }
                    }
                }
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            let bundleIdentifier = application.bundleIdentifier
            Task { @MainActor in
                guard self?.hasWindowManagementAccess == true else { return }
                self?.confirmApplicationTerminated(pid: pid, bundleIdentifier: bundleIdentifier)
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor in
                guard let self, self.hasWindowManagementAccess else { return }
                self.refreshUnattachedApplicationRoster()
                if let pid = application?.processIdentifier {
                    self.refreshUnattachedWindows(pid: pid)
                }
                self.prepareApplicationRelaunchRecovery(
                    pid: application?.processIdentifier ?? -1,
                    bundleIdentifier: application?.bundleIdentifier
                )
                // Repaint the bars from one Accessibility read before the full
                // pass, which spends a blocking read per managed window before
                // it reaches the same answer.
                self.refreshFocusedWindow()
                self.refreshRuntime()
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshUnattachedApplicationRoster() }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            Task { @MainActor in
                guard let self, self.hasWindowManagementAccess else { return }
                self.refreshUnattachedApplicationRoster()
                self.refreshUnattachedWindows(pid: pid)
                self.applicationDidUnhide(pid: pid)
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasWindowManagementAccess else { return }
                self.refreshUnattachedApplicationRoster()
                let unattachedChanged = self.refreshUnattachedWindowSpaceVisibility()
                let managedChanged = self.refreshManagedWindowSpaceVisibility()
                if unattachedChanged || managedChanged {
                    self.onOverlayPresentationChanged?()
                }
            }
        })
        // Quitting while Panoptos hides applications would leave them hidden
        // with nothing left to restore them. The handler has to run inline:
        // a hop to the next main-queue turn never happens during termination.
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.exitFocusMode()
                self?.revealApplicationsHiddenByApplicationSplits()
            }
        })
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasWindowManagementAccess else { return }
                // Windows are still being moved between displays here, and AX
                // reads for them can report invalid elements meanwhile.
                self.extendTransitionSettlePeriod()
                self.refreshDisplays()
                self.onOverlayPresentationChanged?()
            }
        })

        // Sleep, screen sleep, and session locking all tear AX elements down
        // temporarily. Removing a window during one of those is never correct.
        for reason in SystemTransition.allCases {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: reason.beginNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.beginSystemTransition(reason) }
            })
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: reason.endNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.endSystemTransition(reason) }
            })
        }
    }

    /// True while the system is mid-sleep, locked, or still settling after a
    /// wake or display change, when Accessibility results are not trustworthy
    /// enough to drop a window over.
    var isInSystemTransition: Bool {
        if !activeSystemTransitions.isEmpty { return true }
        guard let transitionSettleDeadline else { return false }
        return now() < transitionSettleDeadline
    }

    func beginSystemTransition(_ reason: SystemTransition) {
        guard hasWindowManagementAccess else { return }
        activeSystemTransitions.insert(reason)
        // Failures observed before the transition say nothing about what
        // survives it, so no window carries a head start into the wake.
        invalidSnapshotFirstFailure.removeAll()
    }

    func endSystemTransition(_ reason: SystemTransition) {
        guard hasWindowManagementAccess else { return }
        activeSystemTransitions.remove(reason)
        invalidSnapshotFirstFailure.removeAll()
        extendTransitionSettlePeriod()
        renewOrphanRecovery()
        scheduleDisplayTopologyReflow()
        // Windows the window server already lists again need not wait for the
        // settle period; only hiding waits.
        if refreshManagedWindowSpaceVisibility() { onOverlayPresentationChanged?() }
    }

    private func extendTransitionSettlePeriod() {
        transitionSettleDeadline = now().addingTimeInterval(Self.transitionSettleInterval)
    }

    /// `NSRunningApplication(processIdentifier:)` momentarily fails to resolve
    /// a live pid, so every lookup corroborates with the workspace's own list
    /// before concluding the process is not there.
    func runningApplication(pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
            ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
    }

    /// A false positive here detaches every window of an application and
    /// persists the loss, so a single unresolved lookup is not enough, and the
    /// question is not asked at all while the system is mid-transition. The
    /// authoritative answer arrives as a workspace termination notification.
    private func hasTerminated(pid: pid_t) -> Bool {
        guard !isInSystemTransition else { return false }
        return runningApplication(pid: pid) == nil
    }
}
