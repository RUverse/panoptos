import AppKit
import Foundation

// Moving focus and windows between sections with keyboard shortcuts.
@MainActor
extension PanoptosModel {
    func focusedManagedWindowLocation() -> (sectionID: UUID, index: Int)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let handle = try? accessibility.focusedWindow(pid: pid) else { return nil }
        for (sectionID, section) in sections {
            if let index = section.windows.firstIndex(where: { $0.handle == handle }) {
                return (sectionID, index)
            }
        }
        return nil
    }

    func cycleWindow(step: Int) {
        guard hasWindowManagementAccess else { return }
        guard let location = focusedManagedWindowLocation() else { return }
        cycleWindow(from: location, step: step)
    }

    /// Moves the focused window's application group through its section's
    /// switcher while preserving the order of the application's windows. The
    /// visible switcher groups by bundle identifier, so moving one raw window
    /// across another application would not produce a visible reordering.
    func moveFocusedApplicationInSwitcher(step: Int) {
        guard hasWindowManagementAccess else { return }
        guard step != 0,
              let location = focusedManagedWindowLocation(),
              let section = sections[location.sectionID],
              section.windows.indices.contains(location.index) else { return }

        let groups = SwitcherOrder.groups(
            section.windows,
            bundleIdentifier: \ManagedWindow.bundleIdentifier
        )
        let bundleOrder = groups.map(\.bundleIdentifier)
        let windowsByBundle = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.bundleIdentifier, $0.elements) }
        )
        let units = SwitcherApplicationUnit.make(
            bundleOrder: bundleOrder,
            pairs: applicationSplitPairs[location.sectionID] ?? []
        )
        guard units.count > 1 else { return }

        let focusedBundle = section.windows[location.index].bundleIdentifier
        guard let sourceIndex = units.firstIndex(where: { $0.contains(focusedBundle) }) else { return }
        let destinationIndex = (sourceIndex + step % units.count + units.count)
            % units.count
        guard sourceIndex != destinationIndex else { return }
        var reorderedUnits = units
        let movedUnit = reorderedUnits.remove(at: sourceIndex)
        reorderedUnits.insert(movedUnit, at: destinationIndex)

        let orderedIDs = reorderedUnits.flatMap(\.bundleIdentifiers).flatMap { bundleIdentifier in
            windowsByBundle[bundleIdentifier, default: []].map(\.id)
        }
        reorderWindows(in: location.sectionID, to: orderedIDs)
        onOverlayPresentationChanged?()
    }

    private func cycleWindow(from location: (sectionID: UUID, index: Int), step: Int) {
        // Cycling follows the switcher, so a window it is not drawing — one
        // its application ordered out, or one on another Space — is skipped.
        guard let section = sections[location.sectionID] else { return }
        let ordered = SwitcherOrder.grouped(
            section.visibleWindows,
            bundleIdentifier: \ManagedWindow.bundleIdentifier
        )
        guard ordered.count > 1 else { return }
        let focusedID = section.windows[location.index].id
        guard let focusedIndex = ordered.firstIndex(where: { $0.id == focusedID }) else { return }
        let nextIndex = (focusedIndex + step % ordered.count + ordered.count) % ordered.count
        focus(windowID: ordered[nextIndex].id)
    }

    func focusWindowInSection(_ direction: HorizontalDirection) {
        guard hasWindowManagementAccess else { return }
        guard let location = focusedManagedWindowLocation() else { return }
        let frames = sectionFrames()
        let switcherSectionIDs = frames.keys.filter { sectionID in
            sections[sectionID]?.hasVisibleWindows == true
        }
        // Only a genuinely sole switcher turns the section shortcuts into
        // window cycling. Focus mode ordering other switchers out does not make
        // them cease to be navigation destinations.
        if switcherSectionIDs.count == 1,
           switcherSectionIDs.first == location.sectionID {
            cycleWindow(from: location, step: direction == .left ? -1 : 1)
            return
        }
        let occupiedFrames = frames.filter { sectionID, _ in
            sectionID == location.sectionID || sections[sectionID]?.activeWindow != nil
        }
        guard let destinationID = SectionNavigator.cyclingSection(
            from: location.sectionID,
            direction: direction,
            frames: occupiedFrames
        ), let window = sections[destinationID]?.activeWindow else { return }
        focus(windowID: window.id)
    }

    func moveFocusedWindow(_ direction: HorizontalDirection) {
        guard hasWindowManagementAccess else { return }
        guard let location = focusedManagedWindowLocation() else {
            attachFocusedWindow(toEdgeFor: direction)
            return
        }
        guard let source = sections[location.sectionID],
              source.windows.indices.contains(location.index) else { return }
        let frames = layoutSectionFrames()

        let window = source.windows[location.index]
        let originalFrame = try? accessibility.snapshot(window: window.handle).frame

        // A spanned window has no neighbour of its own. Moving it collapses it
        // into the covered section at that edge, which is also the only way
        // back out of a span.
        var collapseDestination = source.isSpanned
            ? edgeSection(of: source.coveredSectionIDs, direction: direction, frames: frames)
            : nil
        // A rejected frame means the window refuses the zone's size (e.g. a
        // minimum-size window in a small zone); keep trying zones until one
        // accepts it and tell the user which zones were skipped. Navigation is
        // always relative to the original source — retrying from a rejected
        // destination would change the row context and skip zones that do not
        // vertically overlap their rejected sibling. Removing each tried
        // candidate guarantees every eligible zone is attempted exactly once.
        var rejectedIDs: [UUID] = []
        var candidateFrames = frames
        func nextDestination() -> UUID? {
            if source.isSpanned {
                defer { collapseDestination = nil }
                return collapseDestination
            }
            guard let destinationID = SectionNavigator.cyclingSection(
                from: location.sectionID,
                direction: direction,
                frames: candidateFrames
            ) else { return nil }
            candidateFrames.removeValue(forKey: destinationID)
            return destinationID
        }
        while let destinationID = nextDestination() {
            guard let destinationFrame = contentFrame(
                forApplication: window.bundleIdentifier,
                inSection: destinationID
            ) else { continue }
            do {
                try accessibility.setFrame(Self.accessibilityFrame(fromAppKitFrame: destinationFrame), of: window.handle)
            } catch AccessibilityClientError.frameRejected {
                rejectedIDs.append(destinationID)
                continue
            } catch {
                if let originalFrame { try? accessibility.setFrame(originalFrame, of: window.handle) }
                compatibilityError = error.localizedDescription
                return
            }

            var updatedSource = source
            updatedSource.windows.remove(at: location.index)
            if updatedSource.activeWindowID == window.id { updatedSource.activeWindowID = updatedSource.windows.last?.id }
            if updatedSource.windows.isEmpty {
                sections.removeValue(forKey: location.sectionID)
                raisedSpannedSectionIDs.remove(location.sectionID)
            } else {
                sections[location.sectionID] = updatedSource
            }

            var destination = sections[destinationID] ?? LayoutSectionState(id: destinationID)
            destination.windows.append(window)
            destination.activeWindowID = window.id
            sections[destinationID] = destination
            presentLayer(for: destinationID)
            // Leaving a section can strand its partner on half of it, but the
            // window that just moved already has the frame it was given.
            if pruneApplicationSplitPairs() { reflowManagedWindows() }
            reconcileApplicationSplitVisibilityForCurrentFocus(
                fallbackSectionID: destinationID
            )
            // Keep the moved window targeted for the next shortcut, but never
            // roll back a successful frame change if AXRaise cannot complete.
            try? accessibility.focus(window: window.handle, pid: window.pid)
            focusedManagedWindowID = window.id
            lastFocusedSectionByPID[window.pid] = destinationID
            compatibilityError = nil
            onOverlayPresentationChanged?()
            loadMenu(pid: window.pid)
            persistWindowAssignments()
            flashNotice("\(window.applicationName) doesn't fit here", inSections: rejectedIDs)
            return
        }

        // No zone accepted the window; put it back and mark every zone that
        // turned it down.
        if !rejectedIDs.isEmpty, let originalFrame {
            try? accessibility.setFrame(originalFrame, of: window.handle)
        }
        flashNotice("\(window.applicationName) doesn't fit here", inSections: rejectedIDs)
    }

    private func flashNotice(_ text: String, inSections ids: [UUID]) {
        guard !ids.isEmpty else { return }
        noticeGeneration += 1
        let generation = noticeGeneration
        for id in ids { sectionNotices[id] = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.sectionNotices.removeAll()
        }
    }

    private func attachFocusedWindow(toEdgeFor direction: HorizontalDirection) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let handle = try? accessibility.focusedWindow(pid: pid),
              let snapshot = try? accessibility.snapshot(window: handle) else { return }
        let appKitFrame = appKitFrame(for: snapshot)
        guard let display = display(containing: appKitFrame) else { return }
        let sectionIDs = layout(for: display).root.leafIDs
        guard let firstSectionID = sectionIDs.first, let lastSectionID = sectionIDs.last else { return }
        attach(window: snapshot, to: direction == .left ? firstSectionID : lastSectionID)
    }

    private func display(containing windowFrame: CGRect) -> CurrentDisplay? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let display = currentDisplays.first(where: { $0.frame.contains(center) }) {
            return display
        }
        return currentDisplays.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(windowFrame)
            let rhsIntersection = rhs.frame.intersection(windowFrame)
            let lhsArea = lhsIntersection.isNull ? 0 : lhsIntersection.width * lhsIntersection.height
            let rhsArea = rhsIntersection.isNull ? 0 : rhsIntersection.width * rhsIntersection.height
            return lhsArea < rhsArea
        }
    }

    /// Grows the focused window over the next section in `direction` and moves
    /// it into the spanned section covering everything it now occupies. That
    /// section is a section like any other — its own switcher and menu bar sit
    /// above and below the spanned area — and it is raised as a layer over the
    /// sections beneath it.
    func spanFocusedWindow(_ direction: HorizontalDirection) {
        guard hasWindowManagementAccess else { return }
        guard let location = focusedManagedWindowLocation(),
              var source = sections[location.sectionID],
              source.windows.indices.contains(location.index) else { return }
        let window = source.windows[location.index]
        if !source.isSpanned,
           activeApplicationSplitPair(for: window.bundleIdentifier, inSection: location.sectionID) != nil {
            flashNotice("Unpair this application before spanning its window", inSections: [location.sectionID])
            return
        }
        let occupied = layoutSectionIDs(for: location.sectionID)
        guard let display = currentDisplays.first(where: {
            occupied.isSubset(of: Set(layout(for: $0).root.leafIDs))
        }) else { return }
        let frames = layout(for: display).frames(in: display.visibleFrame)
        guard occupied.isSubset(of: Set(frames.keys)),
              let edgeID = edgeSection(of: occupied, direction: direction, frames: frames),
              let adjacentID = SectionNavigator.adjacentSection(
                to: edgeID,
                direction: direction,
                frames: frames,
                excluding: occupied
              ) else { return }
        let expanded = occupied.union([adjacentID])
        guard let expandedFrame = contentFrame(forSectionIDs: expanded) else { return }

        do {
            try accessibility.setFrame(Self.accessibilityFrame(fromAppKitFrame: expandedFrame), of: window.handle)
        } catch {
            compatibilityError = error.localizedDescription
            return
        }

        source.windows.remove(at: location.index)
        if source.activeWindowID == window.id { source.activeWindowID = source.windows.last?.id }
        if source.windows.isEmpty {
            sections.removeValue(forKey: location.sectionID)
            raisedSpannedSectionIDs.remove(location.sectionID)
        } else {
            sections[location.sectionID] = source
        }
        var destination = spannedSectionState(covering: expanded)
        destination.windows.append(window)
        destination.activeWindowID = window.id
        sections[destination.id] = destination
        if !source.isSpanned {
            removeDormantApplicationSplitPair(
                for: window.bundleIdentifier,
                inSection: location.sectionID
            )
            // Leaving a section can strand its partner on half of it.
            if pruneApplicationSplitPairs() { reflowManagedWindows() }
        }
        // Focus mode follows the window it was entered for: the spanned
        // section now holds it, and everything else hides as before.
        if focusedSectionID == location.sectionID {
            focusedSectionID = destination.id
            hideApplicationsOutsideFocusedSection()
        }
        presentLayer(for: destination.id)
        try? accessibility.focus(window: window.handle, pid: window.pid)
        focusedManagedWindowID = window.id
        lastFocusedSectionByPID[window.pid] = destination.id
        reconcileApplicationSplitVisibilityForCurrentFocus(fallbackSectionID: destination.id)
        compatibilityError = nil
        persistWindowAssignments()
        onOverlayPresentationChanged?()
    }

    /// The covered section at the `direction` edge of a span.
    private func edgeSection(
        of sectionIDs: Set<UUID>,
        direction: HorizontalDirection,
        frames: [UUID: CGRect]
    ) -> UUID? {
        sectionIDs.compactMap { id -> (UUID, CGRect)? in frames[id].map { (id, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return direction == .left ? lhs.1.minX < rhs.1.minX : lhs.1.maxX > rhs.1.maxX
                }
                return lhs.0.uuidString < rhs.0.uuidString
            }
            .first?.0
    }

    // MARK: - Layers

    /// Whether a section is the layer on top of its area: focus mode has not
    /// ordered it out, and no raised spanned section is covering it. A span
    /// and the sections beneath it occupy the same area; every switcher stays
    /// on screen, but only the layer on top draws its menu bar.
    func isSectionOnTop(_ sectionID: UUID) -> Bool {
        guard isSectionVisible(sectionID) else { return false }
        if let section = sections[sectionID], section.isSpanned {
            return raisedSpannedSectionIDs.contains(sectionID)
        }
        return !sections.contains { otherID, other in
            other.isSpanned
                && other.coveredSectionIDs.contains(sectionID)
                && raisedSpannedSectionIDs.contains(otherID)
                && other.hasVisibleWindows
                && isSectionVisible(otherID)
        }
    }

    /// Puts the layer holding `sectionID` on top. A spanned section is raised
    /// over the sections it covers and lowers any other span it overlaps. Any
    /// span lowered this way leaves its window showing through beside the
    /// focused one, so the recorded active window of every other section it
    /// covered is raised — nonactivatingly — to cover it. Returns whether the
    /// presented layers changed.
    @discardableResult
    func presentLayer(for sectionID: UUID) -> Bool {
        raisedSpannedSectionIDs = raisedSpannedSectionIDs.filter { sections[$0] != nil }
        let previous = raisedSpannedSectionIDs
        guard let section = sections[sectionID] else { return false }
        let region = layoutSectionIDs(for: sectionID)
        var uncovered: Set<UUID> = []
        for (otherID, other) in sections where other.isSpanned && otherID != sectionID {
            guard !other.coveredSectionIDs.isDisjoint(with: region),
                  raisedSpannedSectionIDs.remove(otherID) != nil else { continue }
            uncovered.formUnion(other.coveredSectionIDs)
        }
        if section.isSpanned { raisedSpannedSectionIDs.insert(sectionID) }
        for siblingID in uncovered.subtracting(region).sorted(by: { $0.uuidString < $1.uuidString })
        where isSectionOnTop(siblingID) {
            guard let active = sections[siblingID]?.activeWindow,
                  !active.isMinimized, active.isOnActiveSpace else { continue }
            try? accessibility.raise(window: active.handle)
            // A split's other half covers the other half of that section.
            raiseApplicationSplitPartner(for: active, inSection: siblingID)
        }
        return raisedSpannedSectionIDs != previous
    }
}
