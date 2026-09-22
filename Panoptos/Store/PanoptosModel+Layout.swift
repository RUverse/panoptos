import AppKit
import Foundation

// Displays, section geometry, layout editing, and the conversions between
// AppKit and Accessibility coordinate spaces.
@MainActor
extension PanoptosModel {
    func refreshDisplays() {
        let refreshedDisplays = displayProvider()
        // NSScreen can be momentarily empty while the window server rebuilds
        // its display list. That is not a real topology to migrate into.
        guard !refreshedDisplays.isEmpty else { return }

        // Even an unchanged display identity may have replaced its AX windows
        // after reconnecting. Let expired assignments retry once it settles.
        renewOrphanRecovery()

        canonicalizeDisplayPersistence(using: refreshedDisplays)
        let previousTopology = currentDisplayTopology
        let nextTopology = Self.displayTopology(for: refreshedDisplays)
        let topologyChanged = !previousTopology.isEmpty && previousTopology != nextTopology
        if topologyChanged {
            // Capture the outgoing profile while its section geometry and
            // topology are still current.
            persistWindowAssignments()
        }
        currentDisplays = refreshedDisplays

        var changed = false
        for display in currentDisplays where !layouts.contains(where: { $0.fingerprint == display.fingerprint }) {
            layouts.append(DisplayLayout(fingerprint: display.fingerprint, root: .leaf(id: UUID())))
            changed = true
        }
        if changed { persistLayouts() }
        if topologyChanged {
            migrateWindowAssignmentsToCurrentTopology(from: previousTopology)
        }
        // Geometry and AX elements can change even when the connected display
        // identities do not. Keep a settled pass pending for every refresh;
        // an early successful move can still be undone by macOS during wake.
        scheduleDisplayTopologyReflow()
        guard !isInSystemTransition else { return }
        if reflowManagedWindows() {
            clearDisplayTopologyReflow()
        }
    }

    var currentDisplayTopology: [DisplayFingerprint] {
        Self.displayTopology(for: currentDisplays)
    }

    private static func displayTopology(for displays: [CurrentDisplay]) -> [DisplayFingerprint] {
        displays.map(\.fingerprint).sorted { $0.id < $1.id }
    }

    func layout(for display: CurrentDisplay) -> DisplayLayout {
        previewLayouts[display.id]
            ?? layouts.first(where: { $0.fingerprint == display.fingerprint })
            ?? DisplayLayout(fingerprint: display.fingerprint, root: .leaf(id: UUID()))
    }

    /// Every section that can hold windows: the layout's own sections plus
    /// the spanned sections currently in use, each covering the union of the
    /// sections it spans. Attachment targets and persistence want only the
    /// layout's sections; they use `layoutSectionFrames()`.
    func sectionFrames() -> [UUID: CGRect] {
        let layoutFrames = layoutSectionFrames()
        var result = layoutFrames
        for (sectionID, section) in sections where section.isSpanned {
            guard let frame = Self.union(of: section.coveredSectionIDs, in: layoutFrames) else { continue }
            result[sectionID] = frame
        }
        return result
    }

    func layoutSectionFrames() -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for display in currentDisplays {
            let layout = layout(for: display)
            result.merge(layout.frames(in: display.visibleFrame)) { _, rhs in rhs }
        }
        return result
    }

    private static func union(of ids: Set<UUID>, in frames: [UUID: CGRect]) -> CGRect? {
        let selected = ids.compactMap { frames[$0] }
        guard selected.count == ids.count, var frame = selected.first else { return nil }
        for next in selected.dropFirst() { frame = frame.union(next) }
        return frame
    }

    /// The layout sections a section occupies: itself, or everything a
    /// spanned section covers.
    func layoutSectionIDs(for sectionID: UUID) -> Set<UUID> {
        guard let covered = sections[sectionID]?.coveredSectionIDs, !covered.isEmpty else { return [sectionID] }
        return covered
    }

    /// The live spanned section covering exactly these layout sections, or a
    /// new empty one under the identity every later lookup will derive.
    func spannedSectionState(covering sectionIDs: Set<UUID>) -> LayoutSectionState {
        let id = SpannedSectionIdentity.id(covering: sectionIDs)
        return sections[id] ?? LayoutSectionState(id: id, coveredSectionIDs: sectionIDs)
    }

    func contentFrame(forSection id: UUID) -> CGRect? {
        contentFrame(forSectionIDs: [id])
    }

    func contentFrame(forSectionIDs ids: Set<UUID>) -> CGRect? {
        contentFrame(forSectionIDs: ids, in: layoutSectionFrames())
    }

    /// `frames` are layout-section frames; a spanned section among `ids`
    /// resolves to the sections it covers.
    private func contentFrame(forSectionIDs ids: Set<UUID>, in frames: [UUID: CGRect]) -> CGRect? {
        let layoutIDs = Set(ids.flatMap { layoutSectionIDs(for: $0) })
        let selected = layoutIDs.compactMap { frames[$0] }
        guard var frame = selected.first else { return nil }
        for next in selected.dropFirst() { frame = frame.union(next) }
        let barSpacing = sectionBarSpacing(forSectionIDs: layoutIDs)
        let topInset = showWindowMenuBars ? Self.chromeHeight + barSpacing : 0
        let bottomInset = WindowSwitcherSize.barHeight(for: windowSwitcherUIScale) + barSpacing
        guard frame.height > topInset + bottomInset else { return nil }
        return CGRect(
            x: frame.minX,
            y: frame.minY + bottomInset,
            width: frame.width,
            height: frame.height - topInset - bottomInset
        )
    }

    func sectionBarSpacing(forSectionIDs ids: Set<UUID>) -> CGFloat {
        currentDisplays.compactMap { display -> CGFloat? in
            let layout = layout(for: display)
            guard !ids.isDisjoint(with: layout.root.leafIDs) else { return nil }
            return layout.normalizedGutter
        }.max() ?? DisplayLayout.defaultGutter
    }

    func applicationSplitPair(
        for bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> ApplicationSplitPair? {
        applicationSplitPairs[sectionID]?.first { $0.contains(bundleIdentifier) }
    }

    func applicationSplitPartner(
        for bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> String? {
        applicationSplitPair(for: bundleIdentifier, inSection: sectionID)?.partner(of: bundleIdentifier)
    }

    /// A durable pair remains recorded while one application's last window is
    /// closed so reopening it can restore the split. Geometry and split-group
    /// interactions only treat it as active while both applications are live.
    func activeApplicationSplitPair(
        for bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> ApplicationSplitPair? {
        guard let section = sections[sectionID] else { return nil }
        let liveBundles = Set(section.windows.map(\.bundleIdentifier))
        return activeApplicationSplitPair(
            for: bundleIdentifier,
            inSection: sectionID,
            liveBundleIdentifiers: liveBundles
        )
    }

    private func activeApplicationSplitPair(
        for bundleIdentifier: String,
        inSection sectionID: UUID,
        liveBundleIdentifiers: Set<String>
    ) -> ApplicationSplitPair? {
        guard let pair = applicationSplitPair(
            for: bundleIdentifier,
            inSection: sectionID
        ), pair.bundleIdentifiers.allSatisfy(liveBundleIdentifiers.contains) else { return nil }
        return pair
    }

    func activeApplicationSplitPairs() -> [UUID: [ApplicationSplitPair]] {
        applicationSplitPairs.reduce(into: [:]) { active, entry in
            let (sectionID, pairs) = entry
            guard let section = sections[sectionID] else { return }
            let liveBundles = Set(section.windows.map(\.bundleIdentifier))
            let livePairs = pairs.filter {
                $0.bundleIdentifiers.allSatisfy(liveBundles.contains)
            }
            if !livePairs.isEmpty { active[sectionID] = livePairs }
        }
    }

    func applicationSplitAxis(inSection sectionID: UUID) -> SplitAxis? {
        sectionFrames()[sectionID].map(ApplicationSplitGeometry.axis(for:))
    }

    func contentFrame(
        forApplication bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> CGRect? {
        contentFrame(
            forApplication: bundleIdentifier,
            inSection: sectionID,
            sectionFrames: layoutSectionFrames()
        )
    }

    func contentFrame(
        forApplication bundleIdentifier: String,
        inSection sectionID: UUID,
        assumingLiveBundleIdentifiers liveBundleIdentifiers: Set<String>
    ) -> CGRect? {
        contentFrame(
            forApplication: bundleIdentifier,
            inSection: sectionID,
            sectionFrames: layoutSectionFrames(),
            liveBundleIdentifiers: liveBundleIdentifiers
        )
    }

    /// A spanned section has no application splits: its windows always get
    /// the whole spanned area.
    private func contentFrame(
        forApplication bundleIdentifier: String,
        inSection sectionID: UUID,
        sectionFrames frames: [UUID: CGRect],
        liveBundleIdentifiers: Set<String>? = nil
    ) -> CGRect? {
        let occupied = layoutSectionIDs(for: sectionID)
        let pair = liveBundleIdentifiers.map {
            activeApplicationSplitPair(
                for: bundleIdentifier,
                inSection: sectionID,
                liveBundleIdentifiers: $0
            )
        } ?? activeApplicationSplitPair(
            for: bundleIdentifier,
            inSection: sectionID
        )
        guard occupied == [sectionID],
              let pair,
              let split = applicationSplitFrames(inSection: sectionID, sectionFrames: frames) else {
            return contentFrame(forSectionIDs: occupied, in: frames)
        }
        return pair.firstBundleIdentifier == bundleIdentifier ? split.first : split.second
    }

    private func applicationSplitFrames(
        inSection sectionID: UUID,
        sectionFrames frames: [UUID: CGRect]
    ) -> ApplicationSplitFrames? {
        guard let sectionFrame = frames[sectionID],
              let content = contentFrame(forSectionIDs: [sectionID], in: frames) else { return nil }
        return ApplicationSplitGeometry.frames(
            in: content,
            gutter: sectionBarSpacing(forSectionIDs: [sectionID]),
            axis: ApplicationSplitGeometry.axis(for: sectionFrame)
        )
    }

    func canPairApplications(
        _ firstBundleIdentifier: String,
        _ secondBundleIdentifier: String,
        inSection sectionID: UUID
    ) -> Bool {
        guard firstBundleIdentifier != secondBundleIdentifier,
              activeApplicationSplitPair(for: firstBundleIdentifier, inSection: sectionID) == nil,
              activeApplicationSplitPair(for: secondBundleIdentifier, inSection: sectionID) == nil,
              let section = sections[sectionID],
              !section.isSpanned else { return false }
        var bundleOrder: [String] = []
        for window in section.windows where !bundleOrder.contains(window.bundleIdentifier) {
            bundleOrder.append(window.bundleIdentifier)
        }
        guard let firstIndex = bundleOrder.firstIndex(of: firstBundleIdentifier),
              let secondIndex = bundleOrder.firstIndex(of: secondBundleIdentifier),
              abs(firstIndex - secondIndex) == 1 else { return false }
        let candidates = Set([firstBundleIdentifier, secondBundleIdentifier])
        return candidates.allSatisfy { bundleIdentifier in
            section.windows.contains { $0.bundleIdentifier == bundleIdentifier }
        }
    }

    func toggleApplicationSplit(
        first firstBundleIdentifier: String,
        second secondBundleIdentifier: String,
        inSection sectionID: UUID
    ) {
        guard hasWindowManagementAccess else { return }
        if let pair = applicationSplitPair(for: firstBundleIdentifier, inSection: sectionID),
           pair.contains(secondBundleIdentifier) {
            applicationSplitPairs[sectionID]?.removeAll { $0 == pair }
            if applicationSplitPairs[sectionID]?.isEmpty == true {
                applicationSplitPairs.removeValue(forKey: sectionID)
            }
            reconcileApplicationSplitVisibilityForCurrentFocus(fallbackSectionID: sectionID)
            persistWindowAssignments()
            reflowManagedWindows()
            onOverlayPresentationChanged?()
            return
        }

        guard canPairApplications(firstBundleIdentifier, secondBundleIdentifier, inSection: sectionID),
              let section = sections[sectionID],
              let pair = orderedApplicationSplitPair(
                firstBundleIdentifier,
                secondBundleIdentifier,
                in: section
              ),
              let split = applicationSplitFrames(
                inSection: sectionID,
                sectionFrames: sectionFrames()
              ) else { return }
        let affected = section.windows.filter {
            !$0.isMinimized
                && ($0.bundleIdentifier == firstBundleIdentifier
                    || $0.bundleIdentifier == secondBundleIdentifier)
        }
        var originalFrames: [(AXWindowHandle, CGRect)] = []
        do {
            for window in affected {
                let original = try accessibility.snapshot(window: window.handle).frame
                originalFrames.append((window.handle, original))
                let destination = window.bundleIdentifier == pair.firstBundleIdentifier
                    ? split.first
                    : split.second
                try accessibility.setFrame(
                    Self.accessibilityFrame(fromAppKitFrame: destination),
                    of: window.handle
                )
            }
        } catch {
            // A rejected AX frame can still leave the window partially moved
            // (for example, an application may accept the position but snap
            // the size). Restore every window whose resize was attempted,
            // including the one that reported the rejection.
            for (handle, original) in originalFrames {
                try? accessibility.setFrame(original, of: handle)
            }
            compatibilityError = "Could not split these applications: \(error.localizedDescription)"
            return
        }

        // Either application may still have a dormant pair whose partner is
        // closed. Choosing a new visible pair replaces that dormant intent.
        let replacingBundles = Set([firstBundleIdentifier, secondBundleIdentifier])
        applicationSplitPairs[sectionID]?.removeAll { pair in
            !replacingBundles.isDisjoint(with: pair.bundleIdentifiers)
        }
        if applicationSplitPairs[sectionID]?.isEmpty == true {
            applicationSplitPairs.removeValue(forKey: sectionID)
        }

        applicationSplitPairs[sectionID, default: []].append(pair)
        compatibilityError = nil
        persistWindowAssignments()
        raiseApplicationSplitPair(pair, inSection: sectionID)
        reconcileApplicationSplitVisibilityForCurrentFocus(fallbackSectionID: sectionID)
        onOverlayPresentationChanged?()
    }

    @discardableResult
    func removeDormantApplicationSplitPair(
        for bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> Bool {
        guard activeApplicationSplitPair(
            for: bundleIdentifier,
            inSection: sectionID
        ) == nil, applicationSplitPair(
            for: bundleIdentifier,
            inSection: sectionID
        ) != nil else { return false }
        applicationSplitPairs[sectionID]?.removeAll { $0.contains(bundleIdentifier) }
        if applicationSplitPairs[sectionID]?.isEmpty == true {
            applicationSplitPairs.removeValue(forKey: sectionID)
        }
        return true
    }

    private func orderedApplicationSplitPair(
        _ firstBundleIdentifier: String,
        _ secondBundleIdentifier: String,
        in section: LayoutSectionState
    ) -> ApplicationSplitPair? {
        var order: [String] = []
        for window in section.windows where !order.contains(window.bundleIdentifier) {
            order.append(window.bundleIdentifier)
        }
        guard let firstIndex = order.firstIndex(of: firstBundleIdentifier),
              let secondIndex = order.firstIndex(of: secondBundleIdentifier) else { return nil }
        return firstIndex < secondIndex
            ? ApplicationSplitPair(
                firstBundleIdentifier: firstBundleIdentifier,
                secondBundleIdentifier: secondBundleIdentifier
            )
            : ApplicationSplitPair(
                firstBundleIdentifier: secondBundleIdentifier,
                secondBundleIdentifier: firstBundleIdentifier
            )
    }

    func restoreApplicationSplitPairs(from assignments: [PersistedWindowAssignment]) {
        var restored: [UUID: [ApplicationSplitPair]] = [:]
        // A spanned window lives in its own section, so it is neither part of
        // its home section's switcher order nor a candidate for its pairs.
        let unspanned = assignments.filter { $0.additionalSectionIDs.isEmpty }
        for (sectionID, sectionAssignments) in Dictionary(grouping: unspanned, by: \.sectionID) {
            let bundles = Set(sectionAssignments.map(\.bundleIdentifier))
            var claimed: Set<String> = []
            var orderedBundles: [String] = []
            for assignment in sectionAssignments.sorted(by: { $0.order < $1.order })
            where !orderedBundles.contains(assignment.bundleIdentifier) {
                orderedBundles.append(assignment.bundleIdentifier)
            }
            let bundleOrder = Dictionary(
                uniqueKeysWithValues: orderedBundles.enumerated().map { ($0.element, $0.offset) }
            )
            for assignment in sectionAssignments.sorted(by: { $0.order < $1.order }) {
                let first = assignment.bundleIdentifier
                guard let partner = assignment.splitPartnerBundleIdentifier,
                      partner != first,
                      bundles.contains(partner),
                      !claimed.contains(first),
                      !claimed.contains(partner),
                      let firstIndex = bundleOrder[first],
                      let partnerIndex = bundleOrder[partner],
                      abs(firstIndex - partnerIndex) == 1 else { continue }
                let ordered = [first, partner].sorted {
                    (bundleOrder[$0] ?? .max) < (bundleOrder[$1] ?? .max)
                }
                restored[sectionID, default: []].append(ApplicationSplitPair(
                    firstBundleIdentifier: ordered[0],
                    secondBundleIdentifier: ordered[1]
                ))
                claimed.formUnion(ordered)
            }
        }
        applicationSplitPairs = restored
    }

    /// Reports whether any pair changed. A dropped pair gives its surviving
    /// application the whole section back, so every caller has to reflow when
    /// this returns true.
    @discardableResult
    func pruneApplicationSplitPairs() -> Bool {
        let previous = applicationSplitPairs
        let topology = currentDisplayTopology
        for sectionID in Array(applicationSplitPairs.keys) {
            var liveOrder: [String] = []
            for window in sections[sectionID]?.windows ?? []
            where !liveOrder.contains(window.bundleIdentifier) {
                liveOrder.append(window.bundleIdentifier)
            }
            let liveBundles = Set(liveOrder)
            let orphanBundles = Set(orphanedAssignments.filter {
                $0.sectionID == sectionID
                    && ($0.displayTopology == nil || $0.displayTopology == topology)
            }.map(\.bundleIdentifier))
            let retained = liveBundles.union(orphanBundles)
            var claimed: Set<String> = []
            applicationSplitPairs[sectionID] = applicationSplitPairs[sectionID]?.compactMap { pair in
                guard retained.contains(pair.firstBundleIdentifier),
                      retained.contains(pair.secondBundleIdentifier),
                      !claimed.contains(pair.firstBundleIdentifier),
                      !claimed.contains(pair.secondBundleIdentifier) else { return nil }
                if let firstIndex = liveOrder.firstIndex(of: pair.firstBundleIdentifier),
                   let secondIndex = liveOrder.firstIndex(of: pair.secondBundleIdentifier) {
                    guard abs(firstIndex - secondIndex) == 1 else { return nil }
                    let normalized = firstIndex < secondIndex
                        ? pair
                        : ApplicationSplitPair(
                            firstBundleIdentifier: pair.secondBundleIdentifier,
                            secondBundleIdentifier: pair.firstBundleIdentifier
                        )
                    claimed.formUnion(normalized.bundleIdentifiers)
                    return normalized
                }
                claimed.formUnion(pair.bundleIdentifiers)
                return pair
            }
            if applicationSplitPairs[sectionID]?.isEmpty == true {
                applicationSplitPairs.removeValue(forKey: sectionID)
            }
        }
        return applicationSplitPairs != previous
    }

    /// Brings the partner application's representative window ahead of other
    /// applications before the requested window receives final focus. A plain
    /// AXRaise is not sufficient when the partner application is behind a
    /// third application because it may only reorder that application's own
    /// windows.
    func bringApplicationSplitPartnerForward(for window: ManagedWindow, inSection sectionID: UUID) {
        guard let partner = activeApplicationSplitPair(
            for: window.bundleIdentifier,
            inSection: sectionID
        )?.partner(of: window.bundleIdentifier), let partnerWindow = representativeWindow(
            for: partner,
            inSection: sectionID
        ) else { return }
        do {
            try accessibility.focus(window: partnerWindow.handle, pid: partnerWindow.pid)
        } catch {
            // Partner compatibility must not prevent the clicked window from
            // receiving focus. AXRaise is still a useful best-effort fallback.
            raiseApplicationSplitPartner(for: window, inSection: sectionID)
        }
    }

    /// A focus notification means the user or application already chose the
    /// requested window. Preserve that focus while restoring its paired half.
    func raiseApplicationSplitPartner(for window: ManagedWindow, inSection sectionID: UUID) {
        guard let partner = activeApplicationSplitPair(
            for: window.bundleIdentifier,
            inSection: sectionID
        )?.partner(of: window.bundleIdentifier), let partnerWindow = representativeWindow(
            for: partner,
            inSection: sectionID
        ) else { return }
        try? accessibility.raise(window: partnerWindow.handle)
    }

    /// Once a split pair is on top, another application's full-section window
    /// would show through the deliberate gutter between the two halves. Hide
    /// those applications exactly as section focus mode does (Command-H), and
    /// restore only the ones Panoptos hid when that section selects another
    /// group or the split no longer needs them hidden.
    func reconcileApplicationSplitVisibility(
        focusedWindow: ManagedWindow,
        inSection sectionID: UUID
    ) {
        guard hasWindowManagementAccess else { return }
        reconcileApplicationSplitVisibility(
            desired: applicationsHiddenBehindActiveSplitGroups(
                focusedWindow: focusedWindow,
                inSection: sectionID
            )
        )
    }

    private func reconcileApplicationSplitVisibility(
        desired: Set<HiddenApplication>
    ) {
        revealApplicationsNoLongerHiddenBehindSplitGroup(desired: desired)

        for application in desired.subtracting(applicationSplitHiddenApplications) {
            // An application the user or focus mode already hid is not this
            // split group's to reveal later.
            guard !focusModeHiddenApplications.contains(application),
                  !accessibility.isApplicationHidden(pid: application.pid) else { continue }
            do {
                try accessibility.setApplicationHidden(true, pid: application.pid)
                applicationSplitHiddenApplications.insert(application)
            } catch {
                lifecycleLogger.warning(
                    "Could not hide PID \(application.pid) behind a split group: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// A destination may itself be hidden behind the previously active split
    /// group. Reveal applications that the new destination needs before asking
    /// AX to focus it, but do not hide the old group until focus succeeds.
    @discardableResult
    func prepareApplicationSplitVisibilityForFocus(
        focusedWindow: ManagedWindow,
        inSection sectionID: UUID
    ) -> Bool {
        !revealApplicationsNoLongerHiddenBehindSplitGroup(
            desired: applicationsHiddenBehindActiveSplitGroups(
                focusedWindow: focusedWindow,
                inSection: sectionID
            )
        ).isEmpty
    }

    @discardableResult
    private func revealApplicationsNoLongerHiddenBehindSplitGroup(
        desired: Set<HiddenApplication>
    ) -> Set<pid_t> {
        let noLongerHidden = applicationSplitHiddenApplications.subtracting(desired)
        applicationSplitHiddenApplications.subtract(noLongerHidden)
        let revealedPIDs = restoreApplicationsHiddenByApplicationSplits(noLongerHidden)
        beginRestoringActiveWindowOrder(for: revealedPIDs)
        return revealedPIDs
    }

    func revealApplicationsHiddenByApplicationSplits() {
        guard !applicationSplitHiddenApplications.isEmpty else { return }
        let hidden = applicationSplitHiddenApplications
        applicationSplitHiddenApplications = []
        beginRestoringActiveWindowOrder(
            for: restoreApplicationsHiddenByApplicationSplits(hidden)
        )
    }

    private func restoreApplicationsHiddenByApplicationSplits(
        _ hidden: Set<HiddenApplication>
    ) -> Set<pid_t> {
        var revealedPIDs: Set<pid_t> = []
        for application in hidden {
            // Another Panoptos mode still owns this hidden state, or the pid
            // now names a different application. Neither is ours to reveal.
            guard !focusModeHiddenApplications.contains(application),
                  runningApplication(pid: application.pid).map({
                      $0.bundleIdentifier ?? "pid.\(application.pid)"
                  }) == application.bundleIdentifier else { continue }
            do {
                try accessibility.setApplicationHidden(false, pid: application.pid)
                revealedPIDs.insert(application.pid)
            } catch {
                lifecycleLogger.warning(
                    "Could not show PID \(application.pid) after leaving a split group: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return revealedPIDs
    }

    /// Pair removal can happen without focus moving (for example, clicking the
    /// split separator). Reconcile against that section's recorded active
    /// window so applications hidden behind the old pair return immediately.
    func reconcileApplicationSplitVisibilityForCurrentFocus(
        fallbackSectionID: UUID? = nil
    ) {
        guard hasWindowManagementAccess else { return }
        let focusedLocation = focusedManagedWindowID.flatMap {
            location(ofWindowID: $0)
        }
        let sectionID = focusedLocation?.sectionID ?? fallbackSectionID
        let focusedWindow = focusedManagedWindowID.flatMap { managedWindow(id: $0) }
        reconcileApplicationSplitVisibility(
            desired: applicationsHiddenBehindActiveSplitGroups(
                focusedWindow: focusedWindow,
                inSection: sectionID
            )
        )
    }

    /// Each visible section keeps its own selected group while focus moves
    /// elsewhere. Preserve the background hiding required by all of those
    /// split groups instead of treating the globally focused section as the
    /// only one still on top. The supplied window is prospective so a click
    /// can reveal its application before AX attempts to focus it.
    private func applicationsHiddenBehindActiveSplitGroups(
        focusedWindow: ManagedWindow? = nil,
        inSection focusedSectionID: UUID? = nil
    ) -> Set<HiddenApplication> {
        sections.reduce(into: Set<HiddenApplication>()) { hidden, entry in
            let (sectionID, section) = entry
            // A split under a raised span is not on top, so nothing needs
            // hiding behind it until its layer comes back up.
            guard isSectionOnTop(sectionID) else { return }
            let active = sectionID == focusedSectionID
                ? focusedWindow ?? section.activeWindow
                : section.activeWindow
            guard let active else { return }
            hidden.formUnion(applicationsHiddenBehindSplitGroup(
                focusedWindow: active,
                inSection: sectionID
            ))
        }
    }

    private func applicationsHiddenBehindSplitGroup(
        focusedWindow: ManagedWindow,
        inSection sectionID: UUID
    ) -> Set<HiddenApplication> {
        guard let pair = activeApplicationSplitPair(
            for: focusedWindow.bundleIdentifier,
            inSection: sectionID
        ), let section = sections[sectionID] else { return [] }
        // Hiding is per process. Keep both paired applications and every
        // application represented in another visible section: hiding one of
        // those would blank unrelated windows elsewhere on the desktop.
        let retainedPIDs = Set(section.windows.filter {
            pair.contains($0.bundleIdentifier)
        }.map(\.pid)).union(
            sections.flatMap { otherSectionID, otherSection in
                guard otherSectionID != sectionID,
                      isSectionVisible(otherSectionID) else { return [pid_t]() }
                return otherSection.windows.map(\.pid)
            }
        ).union([ownProcessIdentifier])
        return Set(section.windows.compactMap { window in
            guard !retainedPIDs.contains(window.pid) else { return nil }
            return HiddenApplication(pid: window.pid, bundleIdentifier: window.bundleIdentifier)
        })
    }

    private func raiseApplicationSplitPair(_ pair: ApplicationSplitPair, inSection sectionID: UUID) {
        guard let section = sections[sectionID] else { return }
        let activeBundle = section.activeWindow?.bundleIdentifier
        let order: [String]
        if let activeBundle, let partner = pair.partner(of: activeBundle) {
            order = [partner, activeBundle]
        } else {
            order = pair.bundleIdentifiers
        }
        for bundleIdentifier in order {
            guard let window = representativeWindow(for: bundleIdentifier, inSection: sectionID) else { continue }
            try? accessibility.raise(window: window.handle)
        }
    }

    private func representativeWindow(
        for bundleIdentifier: String,
        inSection sectionID: UUID
    ) -> ManagedWindow? {
        guard let section = sections[sectionID] else { return nil }
        if let active = section.activeWindow, active.bundleIdentifier == bundleIdentifier {
            return active
        }
        return section.windows.last { $0.bundleIdentifier == bundleIdentifier }
    }

    func window(atAppKitPoint point: CGPoint) throws -> AXWindowSnapshot {
        try accessibility.window(atAccessibilityPoint: Self.accessibilityPoint(fromAppKitPoint: point))
    }

    func appKitFrame(for snapshot: AXWindowSnapshot) -> CGRect {
        Self.appKitFrame(fromAccessibilityFrame: snapshot.frame)
    }
    @discardableResult
    func reflowManagedWindows() -> Bool {
        guard hasWindowManagementAccess, isAccessibilityTrusted,
              !isInSystemTransition else { return false }
        var reflowedEveryWindow = true
        let sectionFrames = layoutSectionFrames()
        for (sectionID, section) in sections {
            let occupied = layoutSectionIDs(for: sectionID)
            for window in section.windows where !window.isMinimized {
                guard occupied.isSubset(of: Set(sectionFrames.keys)),
                      let frame = contentFrame(
                        forApplication: window.bundleIdentifier,
                        inSection: sectionID,
                        sectionFrames: sectionFrames
                      ) else {
                    reflowedEveryWindow = false
                    continue
                }
                let accessibilityFrame = Self.accessibilityFrame(fromAppKitFrame: frame)
                do {
                    let current = try accessibility.snapshot(window: window.handle).frame
                    // A resizable window may expose an application-defined
                    // maximum smaller than its section. Once centered, that is
                    // a settled managed frame. Requesting the full frame again
                    // would make AX move/resize notifications feed an endless
                    // resize-center-reconcile loop.
                    guard !AccessibilityClient.isSettled(
                        actualFrame: current,
                        within: accessibilityFrame
                    ) else { continue }
                    try accessibility.setFrame(accessibilityFrame, of: window.handle)
                } catch {
                    reflowedEveryWindow = false
                    compatibilityError = error.localizedDescription
                }
            }
        }
        return reflowedEveryWindow
    }

    func beginLayoutPreview(for display: CurrentDisplay) {
        if previewSectionsBackup == nil {
            previewSectionsBackup = sections
            previewApplicationSplitPairsBackup = applicationSplitPairs
            previewRaisedSpannedSectionIDsBackup = raisedSpannedSectionIDs
        }
        previewLayouts[display.id] = layout(for: display)
    }

    func preview(_ layout: DisplayLayout, migrating: [UUID: UUID] = [:]) {
        previewLayouts[layout.id] = layout
        for (removed, survivor) in migrating {
            guard let removedState = sections.removeValue(forKey: removed) else { continue }
            var destination = sections[survivor] ?? LayoutSectionState(id: survivor)
            destination.windows.append(contentsOf: removedState.windows)
            destination.activeWindowID = removedState.activeWindowID ?? destination.activeWindowID
            sections[survivor] = destination
            let removedPairs = applicationSplitPairs.removeValue(forKey: removed) ?? []
            applicationSplitPairs[survivor, default: []].append(contentsOf: removedPairs)
        }
        normalizeSpannedSections(migrating: migrating)
        pruneApplicationSplitPairs()
        reflowManagedWindows()
        reconcileApplicationSplitVisibilityForCurrentFocus()
    }

    func cancelLayoutPreview(for display: CurrentDisplay) {
        previewLayouts.removeValue(forKey: display.id)
        if let backup = previewSectionsBackup { sections = backup }
        if let backup = previewApplicationSplitPairsBackup { applicationSplitPairs = backup }
        if let backup = previewRaisedSpannedSectionIDsBackup { raisedSpannedSectionIDs = backup }
        previewSectionsBackup = nil
        previewApplicationSplitPairsBackup = nil
        previewRaisedSpannedSectionIDsBackup = nil
        reflowManagedWindows()
        reconcileApplicationSplitVisibilityForCurrentFocus()
    }

    func commit(_ layout: DisplayLayout) {
        if let index = layouts.firstIndex(where: { $0.fingerprint == layout.fingerprint }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
        previewLayouts.removeValue(forKey: layout.id)
        previewSectionsBackup = nil
        previewApplicationSplitPairsBackup = nil
        previewRaisedSpannedSectionIDsBackup = nil
        normalizeSpannedSections()
        persistLayouts()
        persistWindowAssignments()
        reflowManagedWindows()
        reconcileApplicationSplitVisibilityForCurrentFocus()
    }
    private func persistLayouts() {
        do { try persistence.save(layouts) }
        catch { compatibilityError = "Could not save layouts: \(error.localizedDescription)" }
    }

    /// Layout edits can remove sections a span covers. Each affected spanned
    /// section is re-keyed to what it still covers, folded back into its one
    /// remaining section, or — when every covered section is gone — moved
    /// where the layout editor moved those sections' own windows.
    func normalizeSpannedSections(migrating: [UUID: UUID] = [:]) {
        let frames = layoutSectionFrames()
        let valid = Set(frames.keys)
        guard !valid.isEmpty else { return }
        for sectionID in Array(sections.keys) {
            guard let section = sections[sectionID], section.isSpanned else { continue }
            let survivors = section.coveredSectionIDs.intersection(valid)
            guard survivors != section.coveredSectionIDs else { continue }
            let destinationID: UUID
            if survivors.count > 1 {
                destinationID = SpannedSectionIdentity.id(covering: survivors)
            } else if let survivor = survivors.first {
                destinationID = survivor
            } else if let mapped = section.coveredSectionIDs.compactMap({ migrating[$0] }).first(where: valid.contains)
                        ?? LayoutGeometry.readingOrder(leafIDs: Array(valid), frames: frames).first {
                destinationID = mapped
            } else {
                continue
            }
            sections.removeValue(forKey: sectionID)
            let wasRaised = raisedSpannedSectionIDs.remove(sectionID) != nil
            var destination = survivors.count > 1
                ? spannedSectionState(covering: survivors)
                : sections[destinationID] ?? LayoutSectionState(id: destinationID)
            destination.windows.append(contentsOf: section.windows)
            destination.activeWindowID = section.activeWindowID ?? destination.activeWindowID
            sections[destinationID] = destination
            if wasRaised, destination.isSpanned { raisedSpannedSectionIDs.insert(destinationID) }
        }
    }
    static func accessibilityPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return CGPoint(
                x: bounds.minX + point.x - screen.frame.minX,
                y: bounds.minY + screen.frame.maxY - point.y
            )
        }
        let top = NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: top - point.y)
    }

    static func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect {
        let midpoint = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard bounds.contains(midpoint) else { continue }
            return CGRect(
                x: screen.frame.minX + frame.minX - bounds.minX,
                y: screen.frame.maxY - (frame.minY - bounds.minY) - frame.height,
                width: frame.width,
                height: frame.height
            )
        }
        let top = NSScreen.main?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    static func accessibilityFrame(fromAppKitFrame frame: CGRect) -> CGRect {
        let midpoint = CGPoint(x: frame.midX, y: frame.midY)
        for screen in NSScreen.screens where screen.frame.contains(midpoint) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return CGRect(
                x: bounds.minX + frame.minX - screen.frame.minX,
                y: bounds.minY + screen.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
        let top = NSScreen.main?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

}
