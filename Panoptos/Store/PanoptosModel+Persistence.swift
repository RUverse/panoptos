import AppKit
import Foundation

private struct WindowRestorationPlan {
    let assignment: PersistedWindowAssignment
    let application: NSRunningApplication
    let snapshot: AXWindowSnapshot
    let additionalSectionIDs: Set<UUID>
}

// Window assignments: writing them, restoring them at launch, and
// re-resolving a record against an application's live windows.
@MainActor
extension PanoptosModel {
    /// Rewrites legacy display aliases to the public stable identity exposed by
    /// the currently connected display, then coalesces duplicate layouts and
    /// assignment profiles without dropping records unique to an alias.
    func canonicalizeDisplayPersistence(using displays: [CurrentDisplay]) {
        let current = displays.map(\.fingerprint)
        let layoutResult = DisplayPersistenceMigration.layouts(layouts, current: current)
        if layoutResult.changed {
            layouts = layoutResult.layouts
            do {
                try persistence.save(layouts)
            } catch {
                compatibilityError = "Could not save layouts: \(error.localizedDescription)"
            }
        }

        let migratedAssignments = DisplayPersistenceMigration.assignments(
            savedWindowAssignments,
            current: current
        )
        if !DisplayPersistenceMigration.assignmentsAreStorageEquivalent(
            savedWindowAssignments,
            migratedAssignments
        ) {
            savedWindowAssignments = migratedAssignments
            do {
                try windowAssignmentPersistence.save(migratedAssignments)
            } catch {
                compatibilityError = "Could not save window assignments: \(error.localizedDescription)"
            }
        }
        let migratedOrphans = DisplayPersistenceMigration.orphanedAssignments(
            orphanedAssignments,
            current: current
        )
        if orphanedAssignments != migratedOrphans {
            orphanedAssignments = migratedOrphans
        }
    }

    func location(ofWindowID id: UUID) -> (sectionID: UUID, order: Int, isActive: Bool)? {
        for (sectionID, section) in sections {
            guard let order = section.windows.firstIndex(where: { $0.id == id }) else { continue }
            return (sectionID, order, section.activeWindowID == id)
        }
        return nil
    }

    func assignment(
        for window: ManagedWindow,
        in location: (sectionID: UUID, order: Int, isActive: Bool),
        orphanedAt: Date? = nil,
        awaitsWindowReopen: Bool? = nil,
        awaitsApplicationRelaunch: Bool? = nil,
        displayTopology: [DisplayFingerprint]? = nil
    ) -> PersistedWindowAssignment {
        let persisted = persistedSectionIDs(for: location.sectionID)
        return PersistedWindowAssignment(
            id: window.id,
            sectionID: persisted.sectionID,
            additionalSectionIDs: persisted.additionalSectionIDs,
            bundleIdentifier: window.bundleIdentifier,
            processIdentifier: window.pid,
            accessibilityIdentifier: window.accessibilityIdentifier,
            title: window.title,
            windowOrdinal: window.windowOrdinal,
            order: location.order,
            isActive: location.isActive,
            splitPartnerBundleIdentifier: applicationSplitPartner(
                for: window.bundleIdentifier,
                inSection: location.sectionID
            ),
            orphanedAt: orphanedAt,
            awaitsWindowReopen: awaitsWindowReopen,
            awaitsApplicationRelaunch: awaitsApplicationRelaunch,
            displayTopology: displayTopology ?? currentDisplayTopology
        )
    }

    /// A spanned section is written as the covered layout section that comes
    /// first in reading order plus the others it covers, so the file keeps
    /// naming layout sections only, exactly as before spanned sections
    /// existed. Its live identity is derived from the whole set again on load.
    func persistedSectionIDs(for sectionID: UUID) -> (sectionID: UUID, additionalSectionIDs: Set<UUID>) {
        let covered = layoutSectionIDs(for: sectionID)
        guard covered.count > 1 else { return (sectionID, []) }
        let home = LayoutGeometry.readingOrder(leafIDs: Array(covered), frames: layoutSectionFrames()).first
            ?? covered.sorted { $0.uuidString < $1.uuidString }[0]
        return (home, covered.subtracting([home]))
    }

    func persistWindowAssignments() {
        guard previewSectionsBackup == nil else { return }
        let topology = currentDisplayTopology
        // With no confirmed display set there is no safe profile to replace.
        // Keep the last durable state until refreshDisplays observes one.
        guard !topology.isEmpty else { return }
        let attached = liveWindowAssignments(displayTopology: topology)
        let attachedIDs = Set(attached.map(\.id))
        let activeOrphans = orphanedAssignments
            .filter {
                !attachedIDs.contains($0.id)
                    && ($0.displayTopology == nil || $0.displayTopology == topology)
            }
            .map { assignment in
                var assignment = assignment
                assignment.displayTopology = topology
                assignment.splitPartnerBundleIdentifier = applicationSplitPartner(
                    for: assignment.bundleIdentifier,
                    inSection: assignment.sectionID
                )
                return assignment
            }
        let currentProfile = assignmentsByReservingOrphanOrder(
            attached: attached,
            orphans: activeOrphans
        )
        let currentByID = Dictionary(currentProfile.map { ($0.id, $0) }) { _, latest in latest }
        // Preserve each disconnected setup's organization, but keep the same
        // window's descriptors and lifecycle state current in every profile.
        // Otherwise reconnecting can resurrect an old title/pid or forget a
        // close that happened while using only the laptop display.
        let inactiveProfiles = savedWindowAssignments.filter {
            $0.displayTopology == nil || $0.displayTopology != topology
        }.map { saved in
            currentByID[saved.id].map { saved.updatingWindowState(from: $0) } ?? saved
        }
        let assignments = inactiveProfiles + currentProfile
        saveWindowAssignments(assignments)
    }

    /// AXWindowCreated can describe a replacement for an existing window
    /// after display reconfiguration. Recover its own assignment before the
    /// generic new-window path follows another window's last focused section.
    /// Only unique descriptors in this process qualify; position alone does not.
    func recoverReplacedWindow(_ handle: AXWindowHandle, pid: pid_t) -> AutomaticWindowAttachmentResult? {
        let live = sections.values.flatMap(\.windows).filter { $0.pid == pid }
        let liveIDs = Set(live.map(\.id))
        let pending = orphanedAssignments.filter {
            $0.processIdentifier == pid && !liveIDs.contains($0.id)
                && $0.awaitsWindowReopen != true && $0.awaitsApplicationRelaunch != true
        }
        guard !live.isEmpty || !pending.isEmpty else { return nil }
        // The settled topology reflow/idle recovery will retry replacements
        // after wake. Do not infer their identity from an incomplete AX list.
        guard !isInSystemTransition else { return .retry }
        guard let listed = try? accessibility.windowHandles(pid: pid) else { return .retry }
        let listedHandles = Set(listed)
        let durableOrders = durableWindowOrders(for: [])
        let candidates = pending + live.filter { !listedHandles.contains($0.handle) }.compactMap { window in
            location(ofWindowID: window.id).map { location in
                var record = assignment(for: window, in: location)
                // Live indices omit dormant slots. Restoration compares against
                // durable positions, including for a spanned section's own order.
                record.order = durableOrders[record.liveSectionID]?[record.id] ?? record.order
                return record
            }
        }
        guard !candidates.isEmpty else { return nil }
        guard let snapshot = try? accessibility.snapshot(window: handle) else { return .retry }
        guard snapshot.pid == pid, !snapshot.isFullScreen else { return .ignored }
        guard snapshot.isResizable else { return .retry }
        let identifierMatches = snapshot.accessibilityIdentifier.flatMap { identifier in
            identifier.isEmpty ? nil : candidates.filter { $0.accessibilityIdentifier == identifier }
        } ?? []
        let titleMatches = candidates.filter { !$0.title.isEmpty && $0.title == snapshot.title }
        let candidate: PersistedWindowAssignment
        if identifierMatches.count == 1 {
            candidate = identifierMatches[0]
        } else if titleMatches.count == 1 {
            candidate = titleMatches[0]
        } else {
            return nil
        }
        let preservedCompatibilityError = compatibilityError
        defer { compatibilityError = preservedCompatibilityError }
        let recovered = restore(
            assignments: [candidate],
            excluding: listedHandles.subtracting([handle]),
            allowingOrdinalFallback: false
        )
        guard recovered.contains(candidate.id) else { return .retry }
        forgetOrphans { $0.id == candidate.id }
        persistWindowAssignments()
        lifecycleLogger.info("Recovered a replacement window in its saved section before automatic placement")
        return .attached
    }

    /// A closed window keeps its original switcher slot, but it cannot become
    /// the ordering authority for an application that still has live windows.
    /// The live switcher is the user's latest ordering decision. Inserting a
    /// dormant record at its old global slot and later grouping by application
    /// would let that stale slot move the whole live application on the next
    /// display refresh.
    private func assignmentsByReservingOrphanOrder(
        attached: [PersistedWindowAssignment],
        orphans: [PersistedWindowAssignment]
    ) -> [PersistedWindowAssignment] {
        let topology = currentDisplayTopology
        let previousOrders = savedWindowAssignments.reduce(
            into: [UUID: Int](),
            { orders, assignment in
                guard assignment.displayTopology == topology else { return }
                orders[assignment.id] = assignment.order
            }
        )
        // Spanned windows are ordered within their own spanned section, not
        // within the home section their record names.
        let sectionIDs = Set(attached.map(\.liveSectionID)).union(orphans.map(\.liveSectionID))
        return sectionIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { sectionID in
            let live = attached.filter { $0.liveSectionID == sectionID }
                .sorted { $0.order < $1.order }
            let dormant = orphans.filter { $0.liveSectionID == sectionID }.sorted(by: {
                if $0.order == $1.order { return $0.id.uuidString < $1.id.uuidString }
                return $0.order < $1.order
            })

            let liveGroups = SwitcherOrder.groups(
                live,
                bundleIdentifier: \PersistedWindowAssignment.bundleIdentifier
            )
            let liveBundleIdentifiers = Set(liveGroups.map(\.bundleIdentifier))
            let dormantGroups = SwitcherOrder.groups(
                dormant,
                bundleIdentifier: \PersistedWindowAssignment.bundleIdentifier
            )
            let dormantRecordsByBundle = Dictionary(uniqueKeysWithValues: dormantGroups.map {
                ($0.bundleIdentifier, $0.elements)
            })
            var groups = liveGroups.map { liveGroup in
                var records = liveGroup.elements
                let liveIDs = Set(liveGroup.elements.map(\.id))
                for orphan in dormantRecordsByBundle[liveGroup.bundleIdentifier, default: []] {
                    // The old profile tells us where a closed window sat
                    // inside its application. Compare against those durable
                    // slots while leaving the latest live-window sequence
                    // untouched if the user reordered it as well.
                    let insertionIndex = records.firstIndex { existing in
                        guard liveIDs.contains(existing.id) else { return false }
                        let existingOrder = previousOrders[existing.id] ?? existing.order
                        if existingOrder != orphan.order { return existingOrder > orphan.order }
                        return existing.id.uuidString > orphan.id.uuidString
                    } ?? records.count
                    records.insert(orphan, at: insertionIndex)
                }
                return records
            }

            // An application with no live window has no new user-selected
            // position. Keep its dormant group near the old numeric slot,
            // choosing only boundaries between live groups so it can never
            // disturb their relative order.
            for orphanOnlyGroup in dormantGroups
            where !liveBundleIdentifiers.contains(orphanOnlyGroup.bundleIdentifier) {
                let targetSlot = orphanOnlyGroup.elements.map(\.order).min() ?? 0
                var insertionIndex = 0
                var boundary = 0
                var closestDistance = abs(targetSlot)
                for candidate in groups.indices {
                    boundary += groups[candidate].count
                    let distance = abs(targetSlot - boundary)
                    if distance < closestDistance {
                        closestDistance = distance
                        insertionIndex = candidate + 1
                    }
                }
                groups.insert(orphanOnlyGroup.elements, at: insertionIndex)
            }

            return groups.flatMap { $0 }.enumerated().map { order, assignment in
                var assignment = assignment
                assignment.order = order
                return assignment
            }
        }
    }

    private func liveWindowAssignments(
        displayTopology: [DisplayFingerprint]
    ) -> [PersistedWindowAssignment] {
        sections
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .flatMap { sectionID, section in
                section.windows.enumerated().map { order, window in
                    assignment(
                        for: window,
                        in: (sectionID, order, section.activeWindowID == window.id),
                        displayTopology: displayTopology
                    )
                }
            }
    }

    private func saveWindowAssignments(_ assignments: [PersistedWindowAssignment]) {
        do {
            try windowAssignmentPersistence.save(assignments)
            savedWindowAssignments = assignments
        } catch {
            compatibilityError = "Could not save window assignments: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func forgetSavedWindowAssignments(
        where matches: (PersistedWindowAssignment) -> Bool
    ) -> Bool {
        let savedBefore = savedWindowAssignments.count
        let orphansBefore = orphanedAssignments.count
        savedWindowAssignments.removeAll(where: matches)
        orphanedAssignments.removeAll(where: matches)
        return savedWindowAssignments.count != savedBefore
            || orphanedAssignments.count != orphansBefore
    }

    func restoreWindowAssignmentsIfNeeded() {
        guard isAccessibilityTrusted,
              !currentDisplays.isEmpty,
              !didAttemptWindowRestoration else { return }
        didAttemptWindowRestoration = true
        let preferred = preferredAssignmentsForCurrentTopology()
        let planned = normalizedAssignmentsForCurrentTopology(
            preferred,
            preferredWindowIDs: Set(preferred.map(\.id)),
            liveActiveWindowIDs: []
        )
        restoreApplicationSplitPairs(from: planned)
        let restored = restore(assignments: planned, excluding: [], allowingOrdinalFallback: true)
        // An application that is slow, still launching, or not running yet
        // leaves its record unmatched. Requeue those instead of letting the
        // next persist erase them, so this session keeps retrying them.
        // The retry clock restarts here: it bounds how long one session keeps
        // asking, so a record that arrived already expired still gets this
        // session's attempts.
        orphanedAssignments = planned
            .filter { !restored.contains($0.id) }
            .map { var pending = $0; pending.orphanedAt = now(); return pending }
        rebuildWindowReopenObservationIdentities()
        // A closed window can only reopen inside the process that closed it.
        // When that process is no longer running (its termination happened
        // while Panoptos was not watching), the record is dead: it would sit in
        // the file forever and turn into a relaunch record at the next quit.
        let deadReopenIDs = Set(orphanedAssignments.filter {
            $0.awaitsWindowReopen == true
                && windowReopenObservationIdentities[$0.processIdentifier] != $0.bundleIdentifier
        }.map(\.id))
        if !deadReopenIDs.isEmpty {
            forgetSavedWindowAssignments { deadReopenIDs.contains($0.id) }
            lifecycleLogger.info("Discarded \(deadReopenIDs.count) closed-window record(s) whose process is gone")
        }
        if !orphanedAssignments.isEmpty {
            lifecycleLogger.info("Retrying \(self.orphanedAssignments.count) window assignment(s) that did not match at launch")
        }
        // Establish an exact profile immediately. In particular, this keeps a
        // generated one-monitor fallback across a relaunch while preserving
        // the legacy/multi-monitor record it came from.
        if !planned.isEmpty { persistWindowAssignments() }
    }

    /// Moves every currently managed window into the profile for the newly
    /// connected display set. An exact saved profile wins; otherwise legacy
    /// locations and the outgoing profile are mapped onto the available zones.
    func migrateWindowAssignmentsToCurrentTopology(
        from previousTopology: [DisplayFingerprint]
    ) {
        let topology = currentDisplayTopology
        guard !topology.isEmpty else { return }

        let outgoing = savedWindowAssignments.filter {
            $0.displayTopology == previousTopology
        }
        let preferred = preferredAssignmentsForCurrentTopology()
        let preferredByID = preferred.reduce(into: [UUID: PersistedWindowAssignment]()) {
            $0[$1.id] = $1
        }
        let outgoingByID = outgoing.reduce(into: [UUID: PersistedWindowAssignment]()) {
            // The most recently saved inactive profile occurs last.
            $0[$1.id] = $1
        }
        let liveWindows = sections.values.flatMap(\.windows)
        let liveIDs = Set(liveWindows.map(\.id))
        let liveActiveWindowIDs = Set(sections.values.compactMap(\.activeWindowID))
        let allIDs = liveIDs
            .union(preferredByID.keys)
            .union(outgoingByID.keys)
        let desired = allIDs.compactMap { id in
            preferredByID[id]
                ?? outgoingByID[id]
                ?? location(ofWindowID: id).flatMap { location in
                    managedWindow(id: id).map {
                        assignment(for: $0, in: location, displayTopology: topology)
                    }
                }
        }
        let planned = normalizedAssignmentsForCurrentTopology(
            desired,
            preferredWindowIDs: Set(preferredByID.keys),
            liveActiveWindowIDs: liveActiveWindowIDs
        )
        // A non-empty managed/profile set must never be erased merely because
        // current section geometry was temporarily unavailable.
        guard !planned.isEmpty || allIDs.isEmpty else {
            lifecycleLogger.error(
                "Preserving window assignments because the new display topology exposed no usable sections"
            )
            return
        }
        restoreApplicationSplitPairs(from: planned)
        let windowsByID = Dictionary(uniqueKeysWithValues: liveWindows.map { ($0.id, $0) })
        var migratedSections: [UUID: LayoutSectionState] = [:]

        for assignment in planned.sorted(by: {
            if $0.liveSectionID == $1.liveSectionID { return $0.order < $1.order }
            return $0.liveSectionID.uuidString < $1.liveSectionID.uuidString
        }) {
            guard let window = windowsByID[assignment.id] else { continue }
            let liveSectionID = assignment.liveSectionID
            var section = migratedSections[liveSectionID]
                ?? LayoutSectionState(id: liveSectionID, coveredSectionIDs: assignment.coveredSectionIDs)
            section.windows.append(window)
            if assignment.isActive { section.activeWindowID = window.id }
            migratedSections[liveSectionID] = section
        }
        for (sectionID, var section) in migratedSections {
            if !section.windows.contains(where: { $0.id == section.activeWindowID }) {
                section.activeWindowID = section.windows.last?.id
            }
            migratedSections[sectionID] = section
        }
        let focusModeWillExit = focusedSectionID.map {
            migratedSections[$0]?.windows.isEmpty ?? true
        } ?? false
        sections = migratedSections
        orphanedAssignments = planned
            .filter { !liveIDs.contains($0.id) }
            .map { var pending = $0; pending.orphanedAt = now(); return pending }
        exitFocusModeIfSectionIsEmpty()
        if !focusModeWillExit {
            // A display change can leave the built-in section's existing panel
            // alive. Push the restored topology-specific order into that panel
            // in this turn instead of waiting for reconciliation. Focus-mode
            // exit already repaints every section with the settled state.
            onOverlayPresentationChanged?()
        }
        persistWindowAssignments()
    }

    private func preferredAssignmentsForCurrentTopology() -> [PersistedWindowAssignment] {
        let topology = currentDisplayTopology
        let exact = savedWindowAssignments.filter { $0.displayTopology == topology }
        if !exact.isEmpty { return exact }
        return savedWindowAssignments.filter { $0.displayTopology == nil }
    }

    /// Maps missing source zones, ordered by their persisted layouts, to
    /// current zones in stable reading order.
    /// Every window from the same unavailable source zone stays grouped in the
    /// same destination section.
    private func normalizedAssignmentsForCurrentTopology(
        _ assignments: [PersistedWindowAssignment],
        preferredWindowIDs: Set<UUID>,
        liveActiveWindowIDs: Set<UUID>
    ) -> [PersistedWindowAssignment] {
        let frames = layoutSectionFrames()
        let validSectionIDs = Set(frames.keys)
        let available = LayoutGeometry.readingOrder(
            leafIDs: Array(validSectionIDs),
            frames: frames
        )
        guard !available.isEmpty else { return [] }
        var fallbackBySource: [UUID: UUID] = [:]
        var nextFallback = 0
        let topology = currentDisplayTopology
        let sourceSectionOrder = Dictionary(
            uniqueKeysWithValues: layouts
                .sorted { $0.fingerprint.id < $1.fingerprint.id }
                .flatMap(\.root.leafIDs)
                .enumerated()
                .map { ($0.element, $0.offset) }
        )

        var normalized = assignments.sorted(by: {
            let leftOrder = sourceSectionOrder[$0.sectionID] ?? Int.max
            let rightOrder = sourceSectionOrder[$1.sectionID] ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.sectionID == $1.sectionID {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sectionID.uuidString < $1.sectionID.uuidString
        }).map { original in
            var assignment = original
            let validAdditional = assignment.additionalSectionIDs.intersection(validSectionIDs)
            if !validSectionIDs.contains(assignment.sectionID) {
                if let promoted = LayoutGeometry.readingOrder(
                    leafIDs: Array(validAdditional),
                    frames: frames
                ).first {
                    // The span lost its home section but still covers others;
                    // the first of those takes over rather than a fallback
                    // zone somewhere else entirely.
                    assignment.sectionID = promoted
                } else if let existing = fallbackBySource[assignment.sectionID] {
                    assignment.sectionID = existing
                } else {
                    let destination = available[nextFallback % available.count]
                    nextFallback += 1
                    fallbackBySource[assignment.sectionID] = destination
                    assignment.sectionID = destination
                }
            }
            assignment.additionalSectionIDs = validAdditional.subtracting([assignment.sectionID])
            assignment.displayTopology = topology
            assignment.orphanedAt = nil
            return assignment
        }
        let indicesBySection = Dictionary(grouping: normalized.indices) {
            normalized[$0].liveSectionID
        }
        for indices in indicesBySection.values {
            let orderedIndices: [Int]
            let preferredIndices = indices.filter {
                preferredWindowIDs.contains(normalized[$0].id)
            }
            if preferredIndices.isEmpty {
                orderedIndices = indices
            } else {
                // The preferred destination profile (exact when available,
                // otherwise legacy) owns this section's switcher order.
                // Windows absent from it are the only records allowed to enter
                // from the outgoing topology. Keep a new window beside its
                // existing application group; otherwise add its application
                // after every saved group.
                var merged = preferredIndices
                for index in indices where !preferredWindowIDs.contains(normalized[index].id) {
                    let bundleIdentifier = normalized[index].bundleIdentifier
                    if let lastGroupIndex = merged.lastIndex(where: {
                        normalized[$0].bundleIdentifier == bundleIdentifier
                    }) {
                        merged.insert(index, at: lastGroupIndex + 1)
                    } else {
                        merged.append(index)
                    }
                }
                orderedIndices = merged
            }
            // Topology profiles own organization, not current focus. Prefer
            // the active windows captured from the live outgoing sections; a
            // saved active marker is only a fallback when none remains live.
            let contiguousIndices = SwitcherOrder.grouped(orderedIndices) {
                normalized[$0].bundleIdentifier
            }
            let liveActiveIndex = contiguousIndices.last {
                liveActiveWindowIDs.contains(normalized[$0].id)
            }
            let activeIndex = liveActiveIndex
                ?? contiguousIndices.last { normalized[$0].isActive }
            for (order, index) in contiguousIndices.enumerated() {
                normalized[index].order = order
                normalized[index].isActive = index == activeIndex
            }
        }
        return normalized
    }

    func scheduleDisplayTopologyReflow() {
        guard !sections.isEmpty else { return }
        needsDisplayTopologyReflow = true
        nextDisplayTopologyReflowAttempt = nil
        displayTopologyReflowDeadline = nil
    }

    func clearDisplayTopologyReflow() {
        needsDisplayTopologyReflow = false
        nextDisplayTopologyReflowAttempt = nil
        displayTopologyReflowDeadline = nil
    }

    /// Reflow surviving windows after the transition settles, resolving fresh
    /// public AX elements only if the existing handles cannot be used.
    func retryDisplayTopologyReflowIfNeeded() {
        guard needsDisplayTopologyReflow, !isInSystemTransition else { return }
        // Sleeping/locking may outlast the entire retry budget. Start the
        // budget only when the first post-transition attempt can actually run.
        if displayTopologyReflowDeadline == nil {
            displayTopologyReflowDeadline = now().addingTimeInterval(
                Self.displayTopologyReflowRetryDuration
            )
        }
        if let displayTopologyReflowDeadline, now() >= displayTopologyReflowDeadline {
            clearDisplayTopologyReflow()
            return
        }
        if let nextDisplayTopologyReflowAttempt,
           now() < nextDisplayTopologyReflowAttempt { return }
        nextDisplayTopologyReflowAttempt = now().addingTimeInterval(
            Self.displayTopologyReflowRetryInterval
        )
        // Most reconnects keep their live handles. Do not enumerate and
        // reconstruct every application's windows unless that reflow fails.
        if reflowManagedWindows() {
            clearDisplayTopologyReflow()
            return
        }
        let assignments = liveWindowAssignments(displayTopology: currentDisplayTopology)
        _ = restore(
            assignments: assignments,
            excluding: [],
            allowingOrdinalFallback: false,
            reflowExistingWindows: false
        )
        if reflowManagedWindows() {
            clearDisplayTopologyReflow()
        }
    }

    /// Re-resolves persisted assignments against the applications' live windows
    /// and merges whatever matched into `sections`. Used both by launch
    /// restoration and by mid-session recovery of orphaned assignments.
    @discardableResult
    func restore(
        assignments: [PersistedWindowAssignment],
        excluding reservedHandles: Set<AXWindowHandle>,
        allowingOrdinalFallback: Bool,
        reopenedWindowHandle: AXWindowHandle? = nil,
        reflowExistingWindows: Bool = true
    ) -> Set<UUID> {
        let activeSplitsBeforeRestoration = activeApplicationSplitPairs()
        let sectionsPopulatedBeforeRestoration = Set(sections.compactMap { entry in
            entry.value.windows.isEmpty ? nil : entry.key
        })
        let validSectionIDs = Set(layoutSectionFrames().keys)
        let liveWindowIDsByHandle = Dictionary(
            sections.values.flatMap(\.windows).map { ($0.handle, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        // A window the user detached this session is not a candidate for any
        // record, however well its title or position matches.
        var claimedHandles = reservedHandles.union(allUserDetachedWindowHandles)
        var windowsByPID: [pid_t: [AXWindowSnapshot]] = [:]
        var plans: [WindowRestorationPlan] = []
        var restoredSections: [UUID: LayoutSectionState] = [:]
        var restoredIDs: Set<UUID> = []
        let durableOrders = durableWindowOrders(for: assignments)

        for assignment in assignments.sorted(by: {
            if $0.sectionID == $1.sectionID { return $0.order < $1.order }
            return $0.sectionID.uuidString < $1.sectionID.uuidString
        }) {
            // A known-closed window must never compete with the application's
            // live windows during launch or heuristic restoration. Only the
            // exact handle delivered by AXWindowCreated may reclaim it.
            guard assignment.awaitsWindowReopen != true || reopenedWindowHandle != nil,
                  validSectionIDs.contains(assignment.sectionID),
                  let application = runningApplication(for: assignment),
                  let snapshot = matchingWindow(
                      for: assignment,
                      pid: application.processIdentifier,
                      windowsByPID: &windowsByPID,
                      excluding: claimedHandles,
                      liveWindowIDsByHandle: liveWindowIDsByHandle,
                      allowingOrdinalFallback: allowingOrdinalFallback,
                      reopenedWindowHandle: reopenedWindowHandle
                  ),
                  snapshot.isResizable,
                  !snapshot.isFullScreen else { continue }

            let additionalSectionIDs = assignment.additionalSectionIDs
                .intersection(validSectionIDs)
                .subtracting([assignment.sectionID])
            plans.append(WindowRestorationPlan(
                assignment: assignment,
                application: application,
                snapshot: snapshot,
                additionalSectionIDs: additionalSectionIDs
            ))
            claimedHandles.insert(snapshot.handle)
        }

        // Resolve every candidate before moving any of them so a pair restored
        // at launch goes directly to its final halves instead of briefly using
        // two full-section frames.
        var projectedLiveBundles: [UUID: Set<String>] = [:]
        for (sectionID, section) in sections {
            projectedLiveBundles[sectionID] = Set(section.windows.map(\.bundleIdentifier))
        }
        for plan in plans where plan.additionalSectionIDs.isEmpty {
            projectedLiveBundles[plan.assignment.sectionID, default: []]
                .insert(plan.assignment.bundleIdentifier)
        }

        var hadFrameFailure = false
        for plan in plans {
            let assignment = plan.assignment
            let application = plan.application
            let snapshot = plan.snapshot
            let coveredSectionIDs = plan.additionalSectionIDs.isEmpty
                ? Set<UUID>()
                : plan.additionalSectionIDs.union([assignment.sectionID])
            let liveSectionID = coveredSectionIDs.isEmpty
                ? assignment.sectionID
                : SpannedSectionIdentity.id(covering: coveredSectionIDs)
            let destination = coveredSectionIDs.isEmpty
                ? contentFrame(
                    forApplication: assignment.bundleIdentifier,
                    inSection: assignment.sectionID,
                    assumingLiveBundleIdentifiers: projectedLiveBundles[assignment.sectionID] ?? []
                )
                : contentFrame(forSectionIDs: coveredSectionIDs)
            guard let destination else {
                hadFrameFailure = true
                continue
            }
            do {
                try accessibility.setFrame(Self.accessibilityFrame(fromAppKitFrame: destination), of: snapshot.handle)
            } catch {
                hadFrameFailure = true
                continue
            }

            let candidates = windowsByPID[application.processIdentifier] ?? []
            let ordinal = candidates.firstIndex { $0.handle == snapshot.handle } ?? assignment.windowOrdinal
            let window = ManagedWindow(
                id: assignment.id,
                handle: snapshot.handle,
                pid: snapshot.pid,
                bundleIdentifier: application.bundleIdentifier ?? assignment.bundleIdentifier,
                accessibilityIdentifier: snapshot.accessibilityIdentifier,
                windowOrdinal: ordinal,
                applicationName: application.localizedName ?? assignment.bundleIdentifier,
                icon: applicationIcon(for: application),
                title: snapshot.title,
                isMinimized: snapshot.isMinimized,
                finderTabGroup: snapshot.finderTabGroup,
                lastKnownFrame: snapshot.frame
            )
            var section = restoredSections[liveSectionID]
                ?? sections[liveSectionID]
                ?? LayoutSectionState(id: liveSectionID, coveredSectionIDs: coveredSectionIDs)
            section.windows.removeAll { $0.id == window.id || $0.handle == window.handle }
            // Reclaiming one window out of a populated section must put it back
            // where the user left it, not at the end. Its numeric order includes
            // dormant windows, while `section.windows` contains only live ones,
            // so compare durable slots instead of treating that number as an
            // index into the compacted live array. This keeps reopening several
            // applications in a different order from swapping their groups in
            // the switcher.
            section.windows.insert(
                window,
                at: restorationInsertionIndex(
                    for: assignment,
                    in: section,
                    durableOrders: durableOrders[liveSectionID] ?? [:]
                )
            )
            if assignment.isActive { section.activeWindowID = window.id }
            restoredSections[liveSectionID] = section
            restoredIDs.insert(assignment.id)
            // Reclaiming a window that was showing as a free-window icon has
            // to retire that record here, exactly as `attach(window:to:)`
            // does. It is a no-op for a window that was never one.
            removeUnattachedWindow(handle: snapshot.handle)
            // A successful reattachment consumes either kind of reopen
            // permission for this durable window across every saved display
            // profile.
            for index in savedWindowAssignments.indices
            where savedWindowAssignments[index].id == assignment.id {
                savedWindowAssignments[index].awaitsWindowReopen = nil
                savedWindowAssignments[index].awaitsApplicationRelaunch = nil
            }
            loadMenu(pid: snapshot.pid)
        }

        for (sectionID, var section) in restoredSections {
            if !section.windows.contains(where: { $0.id == section.activeWindowID }) {
                section.activeWindowID = section.windows.last?.id
            }
            sections[sectionID] = section
        }
        let activeSplitsAfterRestoration = activeApplicationSplitPairs()
        let changedSplitSections = Set(activeSplitsBeforeRestoration.keys)
            .union(activeSplitsAfterRestoration.keys)
            .filter {
                activeSplitsBeforeRestoration[$0] != activeSplitsAfterRestoration[$0]
            }
        if reflowExistingWindows,
           hadFrameFailure
            || !Set(changedSplitSections).isDisjoint(with: sectionsPopulatedBeforeRestoration) {
            let preservedCompatibilityError = compatibilityError
            reflowManagedWindows()
            compatibilityError = preservedCompatibilityError
        }
        return restoredIDs
    }

    /// The current topology's saved profile includes both live and dormant
    /// windows, so its order values describe the switcher's uncompressed slots.
    /// Restoration arguments win because display normalization may have moved a
    /// record to another section since the saved profile was read.
    private func durableWindowOrders(
        for assignments: [PersistedWindowAssignment]
    ) -> [UUID: [UUID: Int]] {
        let topology = currentDisplayTopology
        let exactProfile = savedWindowAssignments.filter {
            $0.displayTopology == topology
        }
        let preferredProfile = exactProfile.isEmpty
            ? savedWindowAssignments.filter { $0.displayTopology == nil }
            : exactProfile
        let currentOrphans = orphanedAssignments.filter {
            $0.displayTopology == nil || $0.displayTopology == topology
        }
        var orders: [UUID: [UUID: Int]] = [:]
        for assignment in preferredProfile + currentOrphans + assignments {
            orders[assignment.liveSectionID, default: [:]][assignment.id] = assignment.order
        }
        return orders
    }

    private func restorationInsertionIndex(
        for assignment: PersistedWindowAssignment,
        in section: LayoutSectionState,
        durableOrders: [UUID: Int]
    ) -> Int {
        let firstLaterWindow = section.windows.firstIndex { existing in
            guard let existingOrder = durableOrders[existing.id] else { return false }
            if existingOrder != assignment.order { return existingOrder > assignment.order }
            return existing.id.uuidString > assignment.id.uuidString
        }
        if let firstLaterWindow { return firstLaterWindow }
        if section.windows.contains(where: { durableOrders[$0.id] != nil }) {
            return section.windows.count
        }
        // Older or partially recovered files may not describe any live window.
        // Preserve the previous best effort until the next complete save gives
        // every member of the section a durable slot.
        return min(max(assignment.order, 0), section.windows.count)
    }

    private func runningApplication(for assignment: PersistedWindowAssignment) -> NSRunningApplication? {
        // Mid-session relaunch recovery is tied to the process that produced
        // the activation/window-created signal. Another running instance of
        // the same bundle must not claim this assignment first.
        if assignment.awaitsApplicationRelaunch == true,
           let relaunchPID = applicationRelaunchRecoveryPIDs[assignment.bundleIdentifier],
           let relaunched = runningApplication(pid: relaunchPID),
           (relaunched.bundleIdentifier ?? "pid.\(relaunched.processIdentifier)")
                == assignment.bundleIdentifier {
            return relaunched
        }
        if let exact = runningApplication(pid: assignment.processIdentifier),
           (exact.bundleIdentifier ?? "pid.\(exact.processIdentifier)") == assignment.bundleIdentifier {
            return exact
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == assignment.bundleIdentifier
        }
    }

    private func matchingWindow(
        for assignment: PersistedWindowAssignment,
        pid: pid_t,
        windowsByPID: inout [pid_t: [AXWindowSnapshot]],
        excluding claimedHandles: Set<AXWindowHandle>,
        liveWindowIDsByHandle: [AXWindowHandle: UUID],
        allowingOrdinalFallback: Bool,
        reopenedWindowHandle: AXWindowHandle?
    ) -> AXWindowSnapshot? {
        let windows: [AXWindowSnapshot]
        if let cached = windowsByPID[pid] {
            windows = cached
        } else {
            windows = (try? accessibility.windows(pid: pid)) ?? []
            windowsByPID[pid] = windows
        }
        // Reserve every managed handle for its own assignment, even before
        // that assignment is visited. A stale handle must not cause a title
        // or ordinal match to steal another window's surviving handle.
        let available = windows.enumerated().filter {
            let owner = liveWindowIDsByHandle[$0.element.handle]
            return !claimedHandles.contains($0.element.handle)
                && (owner == nil || owner == assignment.id)
        }
        guard !available.isEmpty else { return nil }
        let sameProcess = pid == assignment.processIdentifier
        let isActiveApplicationRelaunch = assignment.awaitsApplicationRelaunch == true
            && (allowingOrdinalFallback
                || applicationRelaunchRecoveryPIDs[assignment.bundleIdentifier] == pid)

        if assignment.awaitsWindowReopen == true {
            guard sameProcess, let reopenedWindowHandle else { return nil }
            return available.first { $0.element.handle == reopenedWindowHandle }?.element
        }

        // A surviving live handle is stronger than titles, identifiers, or AX
        // list order, all of which may be shared or change during reconnect.
        if sameProcess,
           let live = managedWindow(id: assignment.id),
           let exact = available.first(where: { $0.element.handle == live.handle }) {
            return exact.element
        }

        // Applications commonly give every window the same identifier (or an
        // empty one), so it identifies a window only when exactly one carries it.
        if let identifier = assignment.accessibilityIdentifier, !identifier.isEmpty {
            let identifierMatches = available.filter {
                $0.element.accessibilityIdentifier == identifier
            }
            if identifierMatches.count == 1 { return identifierMatches[0].element }
        }
        let ordinalMatch = available.first { $0.offset == assignment.windowOrdinal }?.element
        if sameProcess, let ordinalMatch, ordinalMatch.title == assignment.title {
            return ordinalMatch
        }
        let titleMatches = available.filter { $0.element.title == assignment.title }
        if titleMatches.count == 1 { return titleMatches[0].element }
        // Position alone is a weak signal: it identifies a window only because
        // nothing was managed yet when the list was captured.
        if (allowingOrdinalFallback && sameProcess) || isActiveApplicationRelaunch,
           let ordinalMatch {
            return ordinalMatch
        }
        return nil
    }
}
