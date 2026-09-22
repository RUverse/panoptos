import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Panoptos

private final class SwitcherHoverFixture {
    let scrollView = NSScrollView()
    let firstButton = FirstMouseButton()
    let secondButton = FirstMouseButton()

    init() {
        scrollView.drawsBackground = false
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        firstButton.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        secondButton.frame = CGRect(x: 100, y: 0, width: 100, height: 30)
        document.addSubview(firstButton)
        document.addSubview(secondButton)
        scrollView.documentView = document
    }
}

private struct SwitcherHoverFixtureView: NSViewRepresentable {
    let fixture: SwitcherHoverFixture

    func makeNSView(context: Context) -> NSScrollView {
        fixture.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

@MainActor
private func settleHostedSwitcher(_ hostingView: NSView) {
    for _ in 0..<4 {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
    }
}

private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
    let current = view as? NSScrollView
    return (current.map { [$0] } ?? []) + view.subviews.flatMap(descendantScrollViews(in:))
}

private func descendantFirstMouseButtons(in view: NSView) -> [FirstMouseButton] {
    let current = view as? FirstMouseButton
    return (current.map { [$0] } ?? []) + view.subviews.flatMap(descendantFirstMouseButtons(in:))
}

private func descendantVisualEffectViews(in view: NSView) -> [NSVisualEffectView] {
    let current = view as? NSVisualEffectView
    return (current.map { [$0] } ?? []) + view.subviews.flatMap(descendantVisualEffectViews(in:))
}

final class LoginLaunchWindowStateTests: XCTestCase {
    func testLoginLaunchDismissesOnlyItsAutomaticSettingsWindow() {
        var state = LoginLaunchWindowState()
        state.recordLaunch(isDefaultLaunch: false)

        XCTAssertTrue(state.shouldDismissSettingsWindow())
        XCTAssertFalse(state.shouldDismissSettingsWindow())
    }

    func testExplicitSettingsRequestCancelsPendingLoginLaunchDismissal() {
        var state = LoginLaunchWindowState()
        state.recordLaunch(isDefaultLaunch: false)

        state.userRequestedSettingsWindow()

        XCTAssertFalse(state.shouldDismissSettingsWindow())
    }

    func testExternalReopenCancelsPendingLoginLaunchDismissal() {
        var state = LoginLaunchWindowState()
        state.recordLaunch(isDefaultLaunch: false)
        let context = PanoptosLaunchContext(windowState: state)

        let shouldReopen = context.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        XCTAssertTrue(shouldReopen)
        XCTAssertFalse(context.shouldDismissSettingsWindow())
    }

    func testNormalLaunchNeverDismissesSettingsWindow() {
        var state = LoginLaunchWindowState()
        state.recordLaunch(isDefaultLaunch: true)

        XCTAssertFalse(state.shouldDismissSettingsWindow())
    }
}

final class LayoutModelTests: XCTestCase {
    @MainActor
    func testFrameAcceptanceAllowsTerminalCharacterGridSnapping() {
        let requested = CGRect(x: 10, y: 41, width: 1_424, height: 1_509)
        let terminalResult = CGRect(x: 10, y: 41, width: 1_427, height: 1_504)

        XCTAssertTrue(AccessibilityClient.accepts(actualFrame: terminalResult, requestedFrame: requested))
    }

    @MainActor
    func testFrameAcceptanceStillRejectsPositionAndMeaningfulSizeDifferences() {
        let requested = CGRect(x: 10, y: 41, width: 1_424, height: 1_509)

        XCTAssertFalse(AccessibilityClient.accepts(
            actualFrame: requested.offsetBy(dx: 3, dy: 0),
            requestedFrame: requested
        ))
        XCTAssertFalse(AccessibilityClient.accepts(
            actualFrame: CGRect(x: 10, y: 41, width: 1_433, height: 1_509),
            requestedFrame: requested
        ))
    }

    @MainActor
    func testFrameFittingCentersWidthConstrainedWindow() {
        let requested = CGRect(x: 10, y: 40, width: 1_000, height: 800)
        let constrained = CGRect(x: 10, y: 40, width: 600, height: 800)

        XCTAssertEqual(
            AccessibilityClient.fittedFrame(actualFrame: constrained, within: requested),
            CGRect(x: 210, y: 40, width: 600, height: 800)
        )
    }

    @MainActor
    func testFrameFittingCentersWindowConstrainedInBothDimensions() {
        let requested = CGRect(x: 10, y: 40, width: 1_000, height: 800)
        let constrained = CGRect(x: 10, y: 40, width: 600, height: 500)

        XCTAssertEqual(
            AccessibilityClient.fittedFrame(actualFrame: constrained, within: requested),
            CGRect(x: 210, y: 190, width: 600, height: 500)
        )
    }

    @MainActor
    func testFrameFittingKeepsExactAndTerminalQuantizedFrames() {
        let requested = CGRect(x: 10, y: 41, width: 1_424, height: 1_509)
        let terminalResultLarger = CGRect(x: 10, y: 41, width: 1_427, height: 1_504)
        let terminalResultSmaller = CGRect(x: 10, y: 41, width: 1_421, height: 1_504)

        XCTAssertEqual(
            AccessibilityClient.fittedFrame(actualFrame: requested, within: requested),
            requested
        )
        XCTAssertEqual(
            AccessibilityClient.fittedFrame(actualFrame: terminalResultLarger, within: requested),
            terminalResultLarger
        )
        XCTAssertEqual(
            AccessibilityClient.fittedFrame(actualFrame: terminalResultSmaller, within: requested),
            terminalResultSmaller
        )
        XCTAssertTrue(AccessibilityClient.isSettled(
            actualFrame: terminalResultLarger,
            within: requested
        ))
        XCTAssertTrue(AccessibilityClient.isSettled(
            actualFrame: terminalResultSmaller,
            within: requested
        ))
    }

    @MainActor
    func testFrameFittingRejectsWindowLargerThanDestination() {
        let requested = CGRect(x: 10, y: 40, width: 1_000, height: 800)

        XCTAssertNil(AccessibilityClient.fittedFrame(
            actualFrame: CGRect(x: 10, y: 40, width: 1_009, height: 700),
            within: requested
        ))
        XCTAssertNil(AccessibilityClient.fittedFrame(
            actualFrame: CGRect(x: 10, y: 40, width: 900, height: 809),
            within: requested
        ))
    }

    @MainActor
    func testOnlyCenteredConstrainedFrameIsSettled() {
        let requested = CGRect(x: 10, y: 40, width: 1_000, height: 800)
        let centered = CGRect(x: 210, y: 40, width: 600, height: 800)

        XCTAssertTrue(AccessibilityClient.isSettled(
            actualFrame: centered,
            within: requested
        ))
        XCTAssertFalse(AccessibilityClient.isSettled(
            actualFrame: centered.offsetBy(dx: -200, dy: 0),
            within: requested
        ))
    }

    func testSplitTreeProducesGapSeparatedFrames() {
        let first = UUID()
        let second = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.25,
            first: .leaf(id: first),
            second: .leaf(id: second)
        )

        let frames = root.frames(in: CGRect(x: -1440, y: 25, width: 1440, height: 875), dividerWidth: 6)

        XCTAssertEqual(frames[first], CGRect(x: -1440, y: 25, width: 359, height: 875))
        XCTAssertEqual(frames[second], CGRect(x: -1075, y: 25, width: 1075, height: 875))
        XCTAssertEqual(frames[second]!.minX - frames[first]!.maxX, 6)
    }

    func testSplittingPreservesOriginalLeafAndAddsOneLeaf() {
        let original = UUID()
        let root = LayoutNode.leaf(id: original).splitting(leafID: original, axis: .vertical)

        XCTAssertEqual(root.leafIDs.count, 2)
        XCTAssertTrue(root.leafIDs.contains(original))
        guard case .split(_, let axis, let ratio, _, _) = root else {
            return XCTFail("Expected a split")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(ratio, 0.5)
    }

    func testVerticalSplitMatchesEditorTopToBottomOrder() {
        let top = UUID()
        let bottom = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(id: top),
            second: .leaf(id: bottom)
        )

        let frames = root.frames(in: CGRect(x: 0, y: 20, width: 1000, height: 806), dividerWidth: 6)

        XCTAssertEqual(frames[top], CGRect(x: 0, y: 426, width: 1000, height: 400))
        XCTAssertEqual(frames[bottom], CGRect(x: 0, y: 20, width: 1000, height: 400))
    }

    func testRemovingLeafReturnsSiblingMigrationTarget() {
        let removed = UUID()
        let sibling = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: removed),
            second: .leaf(id: sibling)
        )

        let result = root.removing(leafID: removed)

        XCTAssertEqual(result?.node, .leaf(id: sibling))
        XCTAssertEqual(result?.survivor, sibling)
    }

    func testRatioReplacementIsClamped() {
        let splitID = UUID()
        let root = LayoutNode.split(
            id: splitID,
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: UUID()),
            second: .leaf(id: UUID())
        )

        guard case .split(_, _, let ratio, _, _) = root.replacingSplit(id: splitID, ratio: 2) else {
            return XCTFail("Expected a split")
        }
        XCTAssertEqual(ratio, 0.9)
    }

    func testLayoutPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("layouts.json")
        let store = LayoutPersistence(url: url)
        let layout = DisplayLayout(
            fingerprint: DisplayFingerprint(
                vendor: 1,
                model: 2,
                serial: 3,
                name: "Studio Display",
                stableIdentifier: "557594A6-D674-4830-8C43-87A6047E97A7"
            ),
            root: .leaf(id: UUID()),
            gutter: 12
        )

        try store.save([layout])

        XCTAssertEqual(store.load(), [layout])
    }

    func testLegacyDisplayFingerprintWithoutStableIdentifierStillDecodes() throws {
        let fingerprint = DisplayFingerprint(
            vendor: 1,
            model: 2,
            serial: 3,
            name: "Studio Display",
            stableIdentifier: "9D0E4F36-6E37-4E62-843C-BE1FC2E7C132"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fingerprint)) as? [String: Any]
        )
        object.removeValue(forKey: "stableIdentifier")

        let decoded = try JSONDecoder().decode(
            DisplayFingerprint.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.stableIdentifier)
        XCTAssertEqual(decoded.vendor, fingerprint.vendor)
        XCTAssertEqual(decoded.model, fingerprint.model)
        XCTAssertEqual(decoded.serial, fingerprint.serial)
        XCTAssertEqual(decoded.name, fingerprint.name)
    }

    func testWindowAssignmentPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("window-assignments.json")
        let store = WindowAssignmentPersistence(url: url)
        let assignment = PersistedWindowAssignment(
            id: UUID(),
            sectionID: UUID(),
            additionalSectionIDs: [UUID()],
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            accessibilityIdentifier: "document-window",
            title: "Notes",
            windowOrdinal: 1,
            order: 0,
            isActive: true,
            splitPartnerBundleIdentifier: "com.example.Browser",
            awaitsWindowReopen: true,
            awaitsApplicationRelaunch: true,
            displayTopology: [
                DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Studio Display")
            ]
        )

        try store.save([assignment])

        XCTAssertEqual(store.load(), [assignment])
    }

    func testLegacyWindowAssignmentWithoutDisplayTopologyStillDecodes() throws {
        let assignment = PersistedWindowAssignment(
            id: UUID(),
            sectionID: UUID(),
            additionalSectionIDs: [],
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            accessibilityIdentifier: nil,
            title: "Notes",
            windowOrdinal: 0,
            order: 0,
            isActive: true
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(assignment)) as? [String: Any]
        )
        object.removeValue(forKey: "displayTopology")
        object.removeValue(forKey: "awaitsWindowReopen")
        object.removeValue(forKey: "awaitsApplicationRelaunch")
        object.removeValue(forKey: "splitPartnerBundleIdentifier")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PersistedWindowAssignment.self, from: legacy)

        XCTAssertNil(decoded.displayTopology)
        XCTAssertNil(decoded.awaitsWindowReopen)
        XCTAssertNil(decoded.awaitsApplicationRelaunch)
        XCTAssertNil(decoded.splitPartnerBundleIdentifier)
        XCTAssertEqual(decoded.id, assignment.id)
        XCTAssertEqual(decoded.sectionID, assignment.sectionID)
    }

    func testApplicationSupportRenameMigratesOnlyMissingDurableFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = base.appendingPathComponent("Panoptes")
        let current = base.appendingPathComponent("Panoptos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

        for fileName in ApplicationSupportMigration.durableFileNames {
            try Data("legacy-\(fileName)".utf8).write(to: legacy.appendingPathComponent(fileName))
        }
        try Data("current-settings".utf8).write(to: current.appendingPathComponent("settings.json"))

        try ApplicationSupportMigration.migrateLegacyData(in: base)

        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("settings.json"), encoding: .utf8),
            "current-settings"
        )
        for fileName in ApplicationSupportMigration.durableFileNames where fileName != "settings.json" {
            XCTAssertEqual(
                try String(contentsOf: current.appendingPathComponent(fileName), encoding: .utf8),
                "legacy-\(fileName)"
            )
        }
    }

    func testApplicationSupportMigrationContinuesAfterOneFileFails() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = base.appendingPathComponent("Panoptes")
        let current = base.appendingPathComponent("Panoptos")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for fileName in ApplicationSupportMigration.durableFileNames {
            try Data(fileName.utf8).write(to: legacy.appendingPathComponent(fileName))
        }

        try ApplicationSupportMigration.migrateLegacyData(in: base) { source, destination in
            if source.lastPathComponent == "layouts.json" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("layouts.json").path))
        for fileName in ApplicationSupportMigration.durableFileNames where fileName != "layouts.json" {
            XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(fileName).path))
        }
    }

    func testSettingsPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        let store = SettingsPersistence(url: url)
        let settings = PanoptosSettings(
            attachAllApplicationWindowsWithControlShift: false,
            sectionBarsFillAvailableWidth: false,
            sectionBarsCentered: true,
            showWindowMenuBars: false,
            showUnattachedWindowIcons: false,
            windowSwitcherUIScale: 2.25,
            windowSwitcherTitleMode: .whenNeeded,
            limitWindowSwitcherTitleCharacters: true,
            invokeWithoutActivation: true,
            keepMacAwake: true,
            keepScreenOn: true,
            hasCompletedOnboarding: true,
            windowDragShortcuts: WindowDragShortcuts(
                attachWindow: [.option],
                attachApplicationWindows: [.command, .shift]
            )
        )

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
        XCTAssertTrue(store.load().hasCompletedOnboarding)
    }

    func testPersistenceFallsBackToLegacyFileWhenCurrentFileIsUnreadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let currentURL = directory.appendingPathComponent("Panoptos/settings.json")
        let legacyURL = directory.appendingPathComponent("Panoptes/settings.json")
        let legacySettings = PanoptosSettings(
            attachAllApplicationWindowsWithControlShift: false,
            sectionBarsFillAvailableWidth: false,
            sectionBarsCentered: true,
            windowSwitcherTitleMode: .whenNeeded,
            limitWindowSwitcherTitleCharacters: true,
            invokeWithoutActivation: true
        )
        try SettingsPersistence(url: legacyURL).save(legacySettings)
        try FileManager.default.createDirectory(at: currentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("incomplete migration".utf8).write(to: currentURL)

        let loaded = SettingsPersistence(url: currentURL, fallbackURL: legacyURL).load()

        XCTAssertEqual(loaded, legacySettings)
    }

    /// The only key in this file is the removed window-manager switch, so it
    /// also covers a settings file whose every remaining field must default.
    func testLegacySettingsIgnoreRemovedWindowManagerSwitchAndDefaultTheRest() throws {
        let data = Data(#"{"showWindowManager":false}"#.utf8)

        let settings = try JSONDecoder().decode(PanoptosSettings.self, from: data)

        XCTAssertEqual(settings, .defaults)
        XCTAssertEqual(settings.windowSwitcherTitleMode, .whenNeeded)
        XCTAssertEqual(settings.windowSwitcherUIScale, 1.5)
        XCTAssertFalse(settings.showWindowMenuBars)
        XCTAssertTrue(settings.showUnattachedWindowIcons)
        XCTAssertFalse(settings.limitWindowSwitcherTitleCharacters)
        XCTAssertFalse(settings.keepMacAwake)
        XCTAssertFalse(settings.keepScreenOn)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.windowDragShortcuts.attachWindow, [.shift])
        XCTAssertEqual(settings.windowDragShortcuts.attachApplicationWindows, [.control, .shift])
    }

    func testWindowSwitcherScaleDecodingClampsAndSnapsToQuarterSteps() throws {
        let cases: [(Double, Double)] = [
            (0.5, 1),
            (2.13, 2.25),
            (4.9, 3)
        ]

        for (saved, expected) in cases {
            let data = Data(#"{"windowSwitcherUIScale":\#(saved)}"#.utf8)
            let settings = try JSONDecoder().decode(PanoptosSettings.self, from: data)

            XCTAssertEqual(settings.windowSwitcherUIScale, expected)
        }
    }

    func testLegacyDisabledAttachAllSettingMigratesToDisabledDragShortcut() throws {
        let data = Data(#"{"attachAllApplicationWindowsWithControlShift":false}"#.utf8)

        let settings = try JSONDecoder().decode(PanoptosSettings.self, from: data)

        XCTAssertEqual(settings.windowDragShortcuts.attachWindow, [.shift])
        XCTAssertNil(settings.windowDragShortcuts.attachApplicationWindows)
    }

    func testDisplayLayoutAppliesGutterBetweenSectionsAndAroundDisplayEdges() throws {
        let left = UUID()
        let right = UUID()
        let layout = DisplayLayout(
            fingerprint: DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Display"),
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: left),
                second: .leaf(id: right)
            ),
            gutter: 10
        )

        let frames = layout.frames(in: CGRect(x: 100, y: 50, width: 1000, height: 800))
        let leftFrame = try XCTUnwrap(frames[left])
        let rightFrame = try XCTUnwrap(frames[right])

        XCTAssertEqual(leftFrame, CGRect(x: 110, y: 60, width: 485, height: 780))
        XCTAssertEqual(rightFrame, CGRect(x: 605, y: 60, width: 485, height: 780))
        XCTAssertEqual(rightFrame.minX - leftFrame.maxX, 10)
        XCTAssertEqual(leftFrame.minX - 100, 10)
        XCTAssertEqual(1_100 - rightFrame.maxX, 10)
        XCTAssertEqual(leftFrame.minY - 50, 10)
        XCTAssertEqual(850 - leftFrame.maxY, 10)
    }

    func testSectionReadingOrderIsTopToBottomThenLeadingToTrailing() throws {
        let topLeft = UUID()
        let topRight = UUID()
        let bottom = UUID()
        let layout = DisplayLayout(
            fingerprint: DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Display"),
            root: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.5,
                first: .split(
                    id: UUID(),
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(id: topLeft),
                    second: .leaf(id: topRight)
                ),
                second: .leaf(id: bottom)
            ),
            gutter: 10
        )

        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let ordered = LayoutGeometry.readingOrder(leafIDs: layout.root.leafIDs, frames: frames)

        XCTAssertEqual(ordered, [topLeft, topRight, bottom])
        XCTAssertEqual(LayoutGeometry.sizeLabel(try XCTUnwrap(frames[topLeft])), "485 × 385")
        XCTAssertEqual(LayoutGeometry.sizeLabel(try XCTUnwrap(frames[bottom])), "980 × 385")
    }

    func testSectionReadingOrderSkipsLeavesWithoutFrames() {
        let known = UUID()
        let missing = UUID()

        let ordered = LayoutGeometry.readingOrder(
            leafIDs: [missing, known],
            frames: [known: CGRect(x: 0, y: 0, width: 100, height: 100)]
        )

        XCTAssertEqual(ordered, [known])
    }

    func testLegacyLayoutWithoutGutterUsesDefault() throws {
        let fingerprint = DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Display")
        let root = LayoutNode.leaf(id: UUID())
        let current = try JSONEncoder().encode(DisplayLayout(fingerprint: fingerprint, root: root))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object.removeValue(forKey: "gutter")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DisplayLayout.self, from: legacy)

        XCTAssertEqual(decoded.gutter, DisplayLayout.defaultGutter)
    }

    func testOverlayTooltipSitsUnderItsControlAndFlipsAtTheScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 120, height: 22)

        let below = OverlayTooltipLayout.frame(
            size: size,
            anchor: CGRect(x: 400, y: 700, width: 28, height: 28),
            screen: screen
        )
        XCTAssertEqual(below, CGRect(x: 354, y: 673, width: 120, height: 22))

        // The bottom bar's buttons sit on the screen's lower edge, where there
        // is no room underneath.
        let flipped = OverlayTooltipLayout.frame(
            size: size,
            anchor: CGRect(x: 400, y: 2, width: 28, height: 28),
            screen: screen
        )
        XCTAssertEqual(flipped, CGRect(x: 354, y: 35, width: 120, height: 22))

        let clamped = OverlayTooltipLayout.frame(
            size: size,
            anchor: CGRect(x: 0, y: 400, width: 28, height: 28),
            screen: screen
        )
        XCTAssertEqual(clamped.minX, screen.minX)
    }

    func testSwitcherDragPlacesAButtonWhereItPassesItsNeighboursMidpoints() {
        let first = SectionBarDragItem.application("first")
        let second = SectionBarDragItem.application("second")
        let third = SectionBarDragItem.application("third")
        // Midpoints: 20, 78, 136.
        let frames: [SectionBarDragItem: CGRect] = [
            first: CGRect(x: 0, y: 0, width: 40, height: 27),
            second: CGRect(x: 48, y: 0, width: 60, height: 27),
            third: CGRect(x: 116, y: 0, width: 40, height: 27)
        ]
        var drag = SectionBarDrag(item: first, siblings: [first, second, third], frames: frames)

        XCTAssertEqual(drag.reorderedSiblings, [first, second, third])
        XCTAssertFalse(drag.movesAnything)

        drag.translation = 50
        XCTAssertEqual(drag.reorderedSiblings, [first, second, third])
        XCTAssertFalse(drag.movesAnything)

        drag.translation = 60
        XCTAssertEqual(drag.reorderedSiblings, [second, first, third])
        XCTAssertTrue(drag.movesAnything)

        drag.translation = 120
        XCTAssertEqual(drag.reorderedSiblings, [second, third, first])
        // Past the trailing edge of the last button that stayed put.
        XCTAssertEqual(drag.markerX, 160)

        drag.translation = -100
        XCTAssertEqual(drag.reorderedSiblings, [first, second, third])
        XCTAssertEqual(drag.markerX, 44)
    }

    func testSwitcherDragOfAMiddleButtonMarksTheGapItWouldDropInto() {
        let first = SectionBarDragItem.window(UUID())
        let second = SectionBarDragItem.window(UUID())
        let third = SectionBarDragItem.window(UUID())
        let frames: [SectionBarDragItem: CGRect] = [
            first: CGRect(x: 0, y: 0, width: 40, height: 27),
            second: CGRect(x: 48, y: 0, width: 60, height: 27),
            third: CGRect(x: 116, y: 0, width: 40, height: 27)
        ]
        var drag = SectionBarDrag(item: second, siblings: [first, second, third], frames: frames)

        // Held still, the marker sits in the gap the button came out of.
        XCTAssertEqual(drag.markerX, 78)
        XCTAssertFalse(drag.movesAnything)

        drag.translation = -60
        XCTAssertEqual(drag.reorderedSiblings, [second, first, third])
        XCTAssertEqual(drag.markerX, -4)

        drag.translation = 60
        XCTAssertEqual(drag.reorderedSiblings, [first, third, second])
        XCTAssertEqual(drag.markerX, 160)
    }

    func testSectionBarsCanFillFitAndCenterWithinSectionWidth() {
        let section = CGRect(x: 100, y: 50, width: 500, height: 400)

        let filled = SectionBarLayout.frames(
            in: section,
            fillsAvailableWidth: true,
            centersBars: false,
            topContentWidth: 220,
            bottomContentWidth: 160
        )
        XCTAssertEqual(filled.top, CGRect(x: 100, y: 412, width: 500, height: 38))
        XCTAssertEqual(filled.bottom, CGRect(x: 100, y: 50, width: 500, height: 38))

        let compact = SectionBarLayout.frames(
            in: section,
            fillsAvailableWidth: false,
            centersBars: false,
            topContentWidth: 220,
            bottomContentWidth: 160
        )
        XCTAssertEqual(compact.top, CGRect(x: 100, y: 412, width: 220, height: 38))
        XCTAssertEqual(compact.bottom, CGRect(x: 100, y: 50, width: 160, height: 38))

        let centered = SectionBarLayout.frames(
            in: section,
            fillsAvailableWidth: false,
            centersBars: true,
            topContentWidth: 220,
            bottomContentWidth: 160
        )
        XCTAssertEqual(centered.top, CGRect(x: 240, y: 412, width: 220, height: 38))
        XCTAssertEqual(centered.bottom, CGRect(x: 270, y: 50, width: 160, height: 38))

        let overflowing = SectionBarLayout.frames(
            in: section,
            fillsAvailableWidth: false,
            centersBars: true,
            topContentWidth: 800,
            bottomContentWidth: 700
        )
        XCTAssertEqual(overflowing.top.width, section.width)
        XCTAssertEqual(overflowing.bottom.width, section.width)

        let scaledSwitcher = SectionBarLayout.frames(
            in: section,
            fillsAvailableWidth: false,
            centersBars: false,
            topContentWidth: 220,
            bottomContentWidth: 160,
            bottomHeight: WindowSwitcherSize.barHeight(for: 3)
        )
        XCTAssertEqual(scaledSwitcher.top, CGRect(x: 100, y: 412, width: 220, height: 38))
        XCTAssertEqual(scaledSwitcher.bottom, CGRect(x: 100, y: 50, width: 160, height: 80))
    }

    func testSpannedSwitcherSitsBetweenTheCoveredSwitchersWhichGiveWay() throws {
        let first = UUID()
        let second = UUID()
        let span = UUID()
        let frames = [
            first: CGRect(x: 0, y: 0, width: 600, height: 800),
            second: CGRect(x: 606, y: 0, width: 594, height: 800),
            span: CGRect(x: 0, y: 0, width: 1200, height: 800)
        ]

        let placements = SwitcherStripLayout.placements(
            frames: frames,
            coveredSectionIDs: [span: [first, second]],
            contentWidths: [span: 200, first: 300, second: 87],
            spacing: 10,
            height: 38
        )

        // Centered on the boundary between the two sections, whole strip available.
        let spanned = try XCTUnwrap(placements[span])
        XCTAssertEqual(spanned.anchorX, 603)
        XCTAssertEqual(spanned.strip, CGRect(x: 0, y: 0, width: 1200, height: 38))
        // The neighbours keep what lies outside the spanned switcher plus spacing.
        XCTAssertEqual(placements[first], .init(strip: CGRect(x: 0, y: 0, width: 493, height: 38), anchorX: nil))
        XCTAssertEqual(placements[second], .init(strip: CGRect(x: 713, y: 0, width: 487, height: 38), anchorX: nil))

        func placement(_ id: UUID, fills: Bool, centers: Bool) -> SectionBarPlacement {
            let strip = placements[id]!
            return SectionBarPlacement(
                frame: frames[id]!,
                switcherStrip: strip.strip,
                switcherAnchorX: strip.anchorX,
                fillsAvailableWidth: fills,
                centersBars: centers,
                bottomHeight: 38
            )
        }
        // The spanned switcher keeps its content width even when bars fill.
        XCTAssertEqual(
            SectionBarLayout.frames(placement: placement(span, fills: true, centers: false), topContentWidth: 400, bottomContentWidth: 200).bottom,
            CGRect(x: 503, y: 0, width: 200, height: 38)
        )
        // The neighbours fill only what is left to them, or sit within it.
        XCTAssertEqual(
            SectionBarLayout.frames(placement: placement(first, fills: true, centers: false), topContentWidth: 400, bottomContentWidth: 300).bottom,
            CGRect(x: 0, y: 0, width: 493, height: 38)
        )
        XCTAssertEqual(
            SectionBarLayout.frames(placement: placement(second, fills: false, centers: true), topContentWidth: 400, bottomContentWidth: 87).bottom,
            CGRect(x: 913, y: 0, width: 87, height: 38)
        )
        XCTAssertEqual(
            SectionBarLayout.frames(placement: placement(second, fills: false, centers: false), topContentWidth: 400, bottomContentWidth: 87).bottom,
            CGRect(x: 713, y: 0, width: 87, height: 38)
        )
        // The menu bar still belongs to the whole spanned area.
        XCTAssertEqual(
            SectionBarLayout.frames(placement: placement(span, fills: false, centers: true), topContentWidth: 400, bottomContentWidth: 200).top,
            CGRect(x: 400, y: 762, width: 400, height: 38)
        )
        // A spanned switcher wider than the room at its anchor stays inside the strip.
        var edge = placement(span, fills: false, centers: true)
        edge.switcherAnchorX = 50
        XCTAssertEqual(
            SectionBarLayout.frames(placement: edge, topContentWidth: 400, bottomContentWidth: 200).bottom,
            CGRect(x: 0, y: 0, width: 200, height: 38)
        )
    }

    func testSpannedSwitcherAnchorsAtTheBoundaryNearestTheMiddleOfTheSpan() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let span = UUID()

        // Three covered sections: the boundary nearer the middle wins.
        let three = SwitcherStripLayout.placements(
            frames: [
                first: CGRect(x: 0, y: 0, width: 300, height: 800),
                second: CGRect(x: 306, y: 0, width: 394, height: 800),
                third: CGRect(x: 706, y: 0, width: 494, height: 800),
                span: CGRect(x: 0, y: 0, width: 1200, height: 800)
            ],
            coveredSectionIDs: [span: [first, second, third]],
            contentWidths: [span: 100],
            spacing: 10,
            height: 38
        )
        XCTAssertEqual(three[span]?.anchorX, 703)
        XCTAssertEqual(three[first]?.strip, CGRect(x: 0, y: 0, width: 300, height: 38))
        XCTAssertEqual(three[second]?.strip, CGRect(x: 306, y: 0, width: 337, height: 38))
        XCTAssertEqual(three[third]?.strip, CGRect(x: 763, y: 0, width: 437, height: 38))

        // Unequal sections: between the switchers means the boundary, not the middle.
        let unequal = SwitcherStripLayout.placements(
            frames: [
                first: CGRect(x: 0, y: 0, width: 400, height: 800),
                second: CGRect(x: 406, y: 0, width: 794, height: 800),
                span: CGRect(x: 0, y: 0, width: 1200, height: 800)
            ],
            coveredSectionIDs: [span: [first, second]],
            contentWidths: [span: 100],
            spacing: 10,
            height: 38
        )
        XCTAssertEqual(unequal[span]?.anchorX, 403)
    }

    func testUnmeasuredSpannedSwitcherTakesNoRoomAndSpansSharingABoundaryLineUp() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let pairSpan = UUID()
        let wholeSpan = UUID()
        let frames = [
            first: CGRect(x: 0, y: 0, width: 600, height: 800),
            second: CGRect(x: 606, y: 0, width: 300, height: 800),
            third: CGRect(x: 912, y: 0, width: 288, height: 800),
            pairSpan: CGRect(x: 0, y: 0, width: 906, height: 800),
            wholeSpan: CGRect(x: 0, y: 0, width: 1200, height: 800)
        ]

        let unmeasured = SwitcherStripLayout.placements(
            frames: frames,
            coveredSectionIDs: [pairSpan: [first, second]],
            contentWidths: [:],
            spacing: 10,
            height: 38
        )
        XCTAssertEqual(unmeasured[pairSpan]?.anchorX, 603)
        XCTAssertEqual(unmeasured[first]?.strip, CGRect(x: 0, y: 0, width: 600, height: 38))
        XCTAssertEqual(unmeasured[second]?.strip, CGRect(x: 606, y: 0, width: 300, height: 38))
        let sliver = SectionBarLayout.frames(
            placement: SectionBarPlacement(
                frame: frames[pairSpan]!,
                switcherStrip: unmeasured[pairSpan]!.strip,
                switcherAnchorX: unmeasured[pairSpan]!.anchorX,
                fillsAvailableWidth: true,
                centersBars: true,
                bottomHeight: 38
            ),
            topContentWidth: 0,
            bottomContentWidth: 0
        ).bottom
        XCTAssertLessThanOrEqual(sliver.width, 2)
        XCTAssertEqual(sliver.midX, 603, accuracy: 1)

        // Both spans choose the boundary at 603; they line up around it.
        let shared = SwitcherStripLayout.placements(
            frames: frames,
            coveredSectionIDs: [pairSpan: [first, second], wholeSpan: [first, second, third]],
            contentWidths: [pairSpan: 200, wholeSpan: 100],
            spacing: 10,
            height: 38
        )
        let bars = [pairSpan, wholeSpan].map { id -> ClosedRange<CGFloat> in
            let width: CGFloat = id == pairSpan ? 200 : 100
            let anchorX = shared[id]!.anchorX!
            return (anchorX - width / 2)...(anchorX + width / 2)
        }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertEqual(bars[0].lowerBound, 448)
        XCTAssertEqual(bars[0].upperBound + 10, bars[1].lowerBound)
        XCTAssertEqual(bars[1].upperBound, 758)
        XCTAssertEqual(shared[first]?.strip, CGRect(x: 0, y: 0, width: 438, height: 38))
        XCTAssertEqual(shared[second]?.strip, CGRect(x: 768, y: 0, width: 138, height: 38))
        XCTAssertEqual(shared[third]?.strip, CGRect(x: 912, y: 0, width: 288, height: 38))
    }

    func testCoveredSectionKeepsItsWholeStripWhenNothingUsableRemains() {
        let first = UUID()
        let second = UUID()
        let span = UUID()

        let placements = SwitcherStripLayout.placements(
            frames: [
                first: CGRect(x: 0, y: 0, width: 600, height: 800),
                second: CGRect(x: 606, y: 0, width: 60, height: 800),
                span: CGRect(x: 0, y: 0, width: 666, height: 800)
            ],
            coveredSectionIDs: [span: [first, second]],
            contentWidths: [span: 100],
            spacing: 10,
            height: 38
        )

        XCTAssertEqual(placements[span]?.anchorX, 603)
        XCTAssertEqual(placements[first]?.strip, CGRect(x: 0, y: 0, width: 543, height: 38))
        // Only three points are left beside the spanned switcher: an
        // overlapping switcher beats a missing one.
        XCTAssertEqual(placements[second]?.strip, CGRect(x: 606, y: 0, width: 60, height: 38))
    }

    func testWindowSwitcherMetricsScaleControlsButKeepLabelsAtDefaultSize() {
        let current = WindowSwitcherMetrics(scale: 1)
        XCTAssertEqual(current.buttonHeight, 23)
        XCTAssertEqual(current.iconHeight, 19)
        XCTAssertEqual(current.titleFontSize, 11)
        // Two points of highlight around the icon, on every side.
        XCTAssertEqual(current.iconOnlyWidth, 23)
        XCTAssertEqual(current.horizontalContentPadding, 8)
        XCTAssertEqual(current.iconAndTitlePadding, 31)
        XCTAssertEqual(current.titleOnlyHorizontalPadding, 8)
        XCTAssertEqual(current.cornerRadius, 5)
        XCTAssertEqual(current.separatorHeight, 12)
        XCTAssertEqual(current.outerBarPadding, 5.5)
        XCTAssertEqual(WindowSwitcherSize.barHeight(for: 1), 34)
        XCTAssertEqual(WindowSwitcherSize.barHeight(for: WindowSwitcherSize.defaultScale), 46)

        let largest = WindowSwitcherMetrics(scale: 3)
        XCTAssertEqual(largest.buttonHeight, 69)
        XCTAssertEqual(largest.iconHeight, 57)
        XCTAssertEqual(largest.titleFontSize, 11)
        XCTAssertEqual(largest.iconOnlyWidth, 69)
        XCTAssertEqual(largest.horizontalContentPadding, 24)
        XCTAssertEqual(largest.iconAndTitlePadding, 93)
        XCTAssertEqual(largest.titleOnlyHorizontalPadding, 24)
        XCTAssertEqual(largest.cornerRadius, 15)
        XCTAssertEqual(largest.separatorHeight, 36)
        XCTAssertEqual(largest.outerBarPadding, 5.5)
        XCTAssertEqual(WindowSwitcherSize.barHeight(for: 3), 80)
    }

    func testScrollingReconcilesHoverForAStationaryPointer() {
        let fixture = SwitcherHoverFixture()
        let root = SwitcherHoverFixtureView(fixture: fixture)
            .frame(width: 100, height: 30)
        let hosting = FirstMouseHostingView(rootView: AnyView(root))
        hosting.frame = CGRect(x: 0, y: 0, width: 100, height: 30)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        fixture.firstButton.setPointerHovered(true)
        fixture.secondButton.setPointerHovered(true)
        let stationaryPoint = fixture.firstButton.convert(
            NSPoint(x: fixture.firstButton.bounds.midX, y: fixture.firstButton.bounds.midY),
            to: nil
        )
        fixture.scrollView.contentView.scroll(to: NSPoint(x: 100, y: 0))
        fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)

        hosting.reconcileButtonHover(at: stationaryPoint)

        XCTAssertFalse(fixture.firstButton.isPointerHovered)
        XCTAssertTrue(fixture.secondButton.isPointerHovered)
        _ = window
    }

    func testApplicationIconImagePreservesSizeAndTemplateState() {
        let source = NSImage(size: NSSize(width: 32, height: 16))
        source.isTemplate = true

        let image = ApplicationIconImage.make(from: source, height: 19)

        XCTAssertEqual(image.size, NSSize(width: 38, height: 19))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.cacheMode, .bySize)
    }

    func testApplicationIconImageUsesTwoXSourceOnOneXDisplay() {
        func representation(pixels: Int, color: NSColor) -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            rep.size = NSSize(width: 19, height: 19)
            rep.bitmapData?.initialize(repeating: 0, count: rep.bytesPerRow * rep.pixelsHigh)
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            color.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: rep.size)).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        let source = NSImage(size: NSSize(width: 19, height: 19))
        source.addRepresentation(representation(pixels: 19, color: .systemRed))
        source.addRepresentation(representation(pixels: 38, color: .systemBlue))
        let image = ApplicationIconImage.make(from: source, height: 19)
        let destination = representation(pixels: 19, color: .clear)
        let context = NSGraphicsContext(bitmapImageRep: destination)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        let color = destination.colorAt(x: 9, y: 9)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(color.blueComponent, 0.9)
        XCTAssertLessThan(color.redComponent, 0.1)
    }

    func testApplicationIconResolverKeepsAnInstalledApplicationOnItsOwnProcessIcon() {
        let processIcon = NSImage()
        var hostLookups = 0
        var bundleLoads = 0
        var genericLoads = 0

        let resolved = ApplicationIconResolver.resolve(
            processIcon: processIcon,
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            isGenericIcon: { _ in false },
            hostBundleURL: { _ in
                hostLookups += 1
                return URL(fileURLWithPath: "/Applications/Host.app")
            },
            registeredBundleURL: { _ in nil },
            bundleIconLoader: { _ in
                bundleLoads += 1
                return NSImage()
            },
            genericIconLoader: {
                genericLoads += 1
                return NSImage()
            }
        )

        XCTAssertTrue(resolved === processIcon)
        XCTAssertEqual(hostLookups, 0)
        XCTAssertEqual(bundleLoads, 0)
        XCTAssertEqual(genericLoads, 0)
    }

    func testApplicationIconResolverPrefersTheRegisteredCopyOverAnUnregisteredRuntimeBundle() {
        // IconServices answers a copy LaunchServices never registered with the
        // legacy icns rather than the asset-catalog icon the Dock shows.
        let runtimeIcon = NSImage()
        let registeredIcon = NSImage()
        let runtimeURL = URL(fileURLWithPath: "/Library/Application Support/Steam/Steam.AppBundle/Steam")
        let registeredURL = URL(fileURLWithPath: "/Applications/Steam.app")

        let resolved = ApplicationIconResolver.resolve(
            processIcon: runtimeIcon,
            bundleURL: runtimeURL,
            isGenericIcon: { _ in false },
            hostBundleURL: { _ in nil },
            registeredBundleURL: { $0 == runtimeURL ? registeredURL : nil },
            bundleIconLoader: { $0 == registeredURL ? registeredIcon : nil },
            genericIconLoader: { NSImage() }
        )

        XCTAssertTrue(resolved === registeredIcon)
    }

    func testApplicationIconResolverPrefersTheHostIconOverAHelpersGenericProcessIcon() {
        let genericProcessIcon = NSImage()
        let hostIcon = NSImage()
        let helperURL = URL(fileURLWithPath: "/Apps/Steam/Contents/Frameworks/Steam Helper.app")
        let hostURL = URL(fileURLWithPath: "/Apps/Steam")
        var requestedIconURLs: [URL] = []

        let resolved = ApplicationIconResolver.resolve(
            processIcon: genericProcessIcon,
            bundleURL: helperURL,
            isGenericIcon: { $0 === genericProcessIcon },
            hostBundleURL: { $0 == helperURL ? hostURL : nil },
            registeredBundleURL: { _ in nil },
            bundleIconLoader: {
                requestedIconURLs.append($0)
                return $0 == hostURL ? hostIcon : nil
            },
            genericIconLoader: { NSImage() }
        )

        XCTAssertTrue(resolved === hostIcon)
        XCTAssertEqual(requestedIconURLs, [hostURL])
    }

    func testApplicationIconResolverPrefersTheHostsRegisteredCopyOverTheHostBundleItself() {
        let genericProcessIcon = NSImage()
        let runtimeHostIcon = NSImage()
        let registeredHostIcon = NSImage()
        let helperURL = URL(fileURLWithPath: "/Runtime/Steam/Contents/Frameworks/Steam Helper.app")
        let hostURL = URL(fileURLWithPath: "/Runtime/Steam")
        let registeredURL = URL(fileURLWithPath: "/Applications/Steam.app")

        let resolved = ApplicationIconResolver.resolve(
            processIcon: genericProcessIcon,
            bundleURL: helperURL,
            isGenericIcon: { $0 === genericProcessIcon },
            hostBundleURL: { $0 == helperURL ? hostURL : nil },
            registeredBundleURL: { $0 == hostURL ? registeredURL : nil },
            bundleIconLoader: {
                switch $0 {
                case registeredURL: return registeredHostIcon
                case hostURL: return runtimeHostIcon
                default: return nil
                }
            },
            genericIconLoader: { NSImage() }
        )

        XCTAssertTrue(resolved === registeredHostIcon)
    }

    func testApplicationIconResolverIgnoresARegisteredCopyThatIsAlsoGeneric() {
        let processIcon = NSImage()
        let genericRegisteredIcon = NSImage()

        let resolved = ApplicationIconResolver.resolve(
            processIcon: processIcon,
            bundleURL: URL(fileURLWithPath: "/Downloads/Example.app"),
            isGenericIcon: { $0 === genericRegisteredIcon },
            hostBundleURL: { _ in nil },
            registeredBundleURL: { _ in URL(fileURLWithPath: "/Applications/Example.app") },
            bundleIconLoader: { _ in genericRegisteredIcon },
            genericIconLoader: { NSImage() }
        )

        XCTAssertTrue(resolved === processIcon)
    }

    func testApplicationIconResolverKeepsAGenericProcessIconWhenTheHostIconIsGenericToo() {
        let genericProcessIcon = NSImage()
        let genericHostIcon = NSImage()
        let lastResort = NSImage()

        let resolved = ApplicationIconResolver.resolve(
            processIcon: genericProcessIcon,
            bundleURL: URL(fileURLWithPath: "/Apps/Host.app/Contents/XPCServices/Service.app"),
            isGenericIcon: { _ in true },
            hostBundleURL: { _ in URL(fileURLWithPath: "/Apps/Host.app") },
            registeredBundleURL: { _ in nil },
            bundleIconLoader: { _ in genericHostIcon },
            genericIconLoader: { lastResort }
        )

        XCTAssertTrue(resolved === genericProcessIcon)
    }

    func testApplicationIconResolverFallsBackToTheProcessIconWhenNoHostBundleEncloses() {
        let processIcon = NSImage()

        let resolved = ApplicationIconResolver.resolve(
            processIcon: processIcon,
            bundleURL: URL(fileURLWithPath: "/Applications/Unadorned.app"),
            isGenericIcon: { _ in true },
            hostBundleURL: { _ in nil },
            registeredBundleURL: { _ in nil },
            bundleIconLoader: { _ in nil },
            genericIconLoader: { NSImage() }
        )

        XCTAssertTrue(resolved === processIcon)
    }

    func testApplicationIconResolverFallsBackToGenericWithoutABundleURL() {
        let generic = NSImage()

        let resolved = ApplicationIconResolver.resolve(
            processIcon: nil,
            bundleURL: nil,
            isGenericIcon: { _ in true },
            hostBundleURL: { _ in nil },
            registeredBundleURL: { _ in nil },
            bundleIconLoader: { _ in nil },
            genericIconLoader: { generic }
        )

        XCTAssertTrue(resolved === generic)
    }

    func testApplicationIconResolverWalksOutOfANestedHelperToItsHostBundle() {
        let helperURL = URL(fileURLWithPath: "/Apps/Steam/Contents/Frameworks/Steam Helper.app")
        let hostURL = URL(fileURLWithPath: "/Apps/Steam")

        // `deleteLastPathComponent()` leaves a trailing slash, so the walk is
        // compared by path the same way the icon loader consumes it.
        let resolved = ApplicationIconResolver.hostBundleURL(for: helperURL) {
            $0.path == hostURL.path
        }

        XCTAssertEqual(resolved?.path, hostURL.path)
    }

    func testApplicationIconResolverReportsNoHostBundleForATopLevelApplication() {
        var examined: [String] = []

        let resolved = ApplicationIconResolver.hostBundleURL(
            for: URL(fileURLWithPath: "/Applications/Example.app")
        ) { candidate in
            examined.append(candidate.path)
            return false
        }

        XCTAssertNil(resolved)
        // The walk stops at the volume root rather than running its full bound.
        XCTAssertEqual(examined, ["/Applications"])
    }

    func testApplicationIconResolverReportsNoRegisteredCopyForAnInstalledApplication() throws {
        // Any bundle LaunchServices resolves back to itself must not redirect,
        // which is what keeps ordinary applications on the process icon.
        let finderURL = try XCTUnwrap(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")
        )

        XCTAssertNil(ApplicationIconResolver.registeredBundleURL(for: finderURL))
    }

    func testApplicationIconResolverLeavesADuplicateApplicationCopyOnItsOwnIcon() throws {
        // A portable, preview, developer, or external-volume copy shares an
        // installed application's bundle identifier and must keep its own icon.
        // Only the extension-less updater layout defers to the installed copy.
        let enclosingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanoptosIconResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: enclosingURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: enclosingURL) }

        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.apple.finder",
                "CFBundlePackageType": "APPL"
            ] as [String: Any],
            format: .xml,
            options: 0
        )

        func makeBundle(named name: String) throws -> URL {
            let bundleURL = enclosingURL.appendingPathComponent(name, isDirectory: true)
            let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
            try info.write(to: contentsURL.appendingPathComponent("Info.plist"))
            return bundleURL
        }

        XCTAssertNil(ApplicationIconResolver.registeredBundleURL(for: try makeBundle(named: "Duplicate.app")))
        XCTAssertEqual(
            ApplicationIconResolver.registeredBundleURL(for: try makeBundle(named: "Updater"))?.lastPathComponent,
            "Finder.app"
        )
    }

    func testApplicationIconResolverRecognizesTheGenericApplicationPlaceholder() {
        let generic = NSWorkspace.shared.icon(for: .applicationBundle)
        XCTAssertTrue(ApplicationIconResolver.isGenericApplicationIcon(generic))

        let distinct = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        XCTAssertFalse(ApplicationIconResolver.isGenericApplicationIcon(distinct))
    }

    func testWindowSwitcherTitleMeasurementAlwaysReservesSelectedWeight() {
        let regular = WindowSwitcherTitleFont.display(size: 11, isSelected: false)
        let selected = WindowSwitcherTitleFont.display(size: 11, isSelected: true)
        let measurement = WindowSwitcherTitleFont.measurement(size: 11)

        XCTAssertEqual(regular.fontDescriptor.symbolicTraits.contains(.bold), false)
        XCTAssertEqual(selected, measurement)
    }

    func testWindowSwitcherHighlightsEachSectionsActiveWindowAtItsFocusStrength() {
        let active = selectionWindow(bundleIdentifier: "com.example.Active", ordinal: 0)
        let inactive = selectionWindow(bundleIdentifier: "com.example.Inactive", ordinal: 1)
        let section = LayoutSectionState(
            id: UUID(),
            windows: [inactive, active],
            activeWindowID: active.id
        )

        let focusedSelection = WindowSwitcherSelection.resolve(
            windowID: active.id,
            section: section,
            isSectionFocused: true
        )
        let inactiveSelection = WindowSwitcherSelection.resolve(
            windowID: active.id,
            section: section,
            isSectionFocused: false
        )
        let unselected = WindowSwitcherSelection.resolve(
            windowID: inactive.id,
            section: section,
            isSectionFocused: true
        )

        XCTAssertEqual(focusedSelection, .focusedSectionActiveWindow)
        XCTAssertEqual(focusedSelection.backgroundOpacity, 0.14)
        XCTAssertTrue(focusedSelection.isSelected)
        XCTAssertEqual(inactiveSelection, .inactiveSectionActiveWindow)
        XCTAssertEqual(inactiveSelection.backgroundOpacity, 0.07)
        XCTAssertTrue(inactiveSelection.isSelected)
        XCTAssertEqual(unselected, .none)
        XCTAssertEqual(unselected.backgroundOpacity, 0)
        XCTAssertFalse(unselected.isSelected)
    }

    func testWindowSwitcherHighlightsFallbackActiveWindowWhenNoActiveIDIsStored() {
        let first = selectionWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let fallback = selectionWindow(bundleIdentifier: "com.example.Fallback", ordinal: 1)
        let section = LayoutSectionState(id: UUID(), windows: [first, fallback])

        XCTAssertEqual(
            WindowSwitcherSelection.resolve(
                windowID: fallback.id,
                section: section,
                isSectionFocused: false
            ),
            .inactiveSectionActiveWindow
        )
        XCTAssertEqual(
            WindowSwitcherSelection.resolve(
                windowID: first.id,
                section: section,
                isSectionFocused: false
            ),
            .none
        )
    }

    func testWindowSwitcherBothActiveSelectionStrengthsUseSelectedTitleWeight() {
        let selectedFont = WindowSwitcherTitleFont.display(size: 11, isSelected: true)

        for selection in [
            .inactiveSectionActiveWindow,
            .focusedSectionActiveWindow
        ] as [WindowSwitcherSelection] {
            XCTAssertEqual(
                WindowSwitcherTitleFont.display(size: 11, isSelected: selection.isSelected),
                selectedFont
            )
        }
    }

    func testWindowTitleFormatterPreservesFullTitle() {
        XCTAssertEqual(
            WindowTitleFormatter.display("A long window title", limitCharacters: false),
            "A long window title"
        )
        XCTAssertEqual(WindowTitleFormatter.display("", limitCharacters: false), "Window")
    }

    func testWindowTitleFormatterCanLimitExtendedGraphemeClusters() {
        let grapheme = "👨‍👩‍👧‍👦"
        let title = String(repeating: grapheme, count: WindowTitleFormatter.characterLimit + 1)
        let expected = String(repeating: grapheme, count: WindowTitleFormatter.characterLimit) + "…"

        XCTAssertEqual(
            WindowTitleFormatter.display(title, limitCharacters: true),
            expected
        )
        XCTAssertEqual(
            WindowTitleFormatter.display("", limitCharacters: true),
            "Window"
        )
    }

    func testWindowSwitcherTitleModes() {
        XCTAssertTrue(WindowSwitcherTitleMode.always.showsTitles(applicationWindowCount: 1))
        XCTAssertTrue(WindowSwitcherTitleMode.always.showsTitles(applicationWindowCount: 2))
        XCTAssertFalse(WindowSwitcherTitleMode.whenNeeded.showsTitles(applicationWindowCount: 1))
        XCTAssertTrue(WindowSwitcherTitleMode.whenNeeded.showsTitles(applicationWindowCount: 2))
    }

    func testShortcutDefaultsMatchRequestedBindings() {
        XCTAssertEqual(ShortcutCommand.cycleNextWindow.defaultShortcut?.displayText, "⌃⌥↓")
        XCTAssertEqual(ShortcutCommand.cyclePreviousWindow.defaultShortcut?.displayText, "⌃⌥↑")
        XCTAssertEqual(ShortcutCommand.cycleWindowLeft.defaultShortcut?.displayText, "⌃⌥⇧←")
        XCTAssertEqual(ShortcutCommand.cycleWindowRight.defaultShortcut?.displayText, "⌃⌥⇧→")
        XCTAssertEqual(ShortcutCommand.moveApplicationEarlier.defaultShortcut?.displayText, "⌃⌥⇧↑")
        XCTAssertEqual(ShortcutCommand.moveApplicationLater.defaultShortcut?.displayText, "⌃⌥⇧↓")
        XCTAssertEqual(ShortcutCommand.moveApplicationEarlier.group, .windowMovement)
        XCTAssertEqual(ShortcutCommand.moveApplicationLater.group, .windowMovement)
        XCTAssertEqual(ShortcutCommand.focusPreviousSection.defaultShortcut?.displayText, "⌃⌥←")
        XCTAssertEqual(ShortcutCommand.focusNextSection.defaultShortcut?.displayText, "⌃⌥→")
        XCTAssertEqual(ShortcutCommand.toggleSectionFocus.defaultShortcut?.displayText, "⌃⌥F")
        XCTAssertEqual(ShortcutCommand.toggleSectionFocus.group, .sectionFocus)
        XCTAssertEqual(ShortcutCommand.spanWindowLeft.defaultShortcut?.displayText, "⌃⌥⌘←")
        XCTAssertEqual(ShortcutCommand.spanWindowRight.defaultShortcut?.displayText, "⌃⌥⌘→")
        XCTAssertEqual(ShortcutCommand.spanWindowLeft.group, .windowMovement)
        XCTAssertEqual(ShortcutPersistence.defaults[.spanWindowLeft], ShortcutCommand.spanWindowLeft.defaultShortcut)
        XCTAssertEqual(ShortcutPersistence.defaults[.spanWindowRight], ShortcutCommand.spanWindowRight.defaultShortcut)
    }

    func testShortcutPersistenceAddsTheSectionFocusDefaultToAnOlderFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .toggleSectionFocus)
        stored.removeValue(forKey: .cycleNextWindow)
        let fixture = StoredShortcutsFixture(version: 4, shortcuts: stored)
        try JSONEncoder().encode(fixture).write(to: url)

        let loaded = ShortcutPersistence(url: url).load()

        XCTAssertEqual(loaded[.toggleSectionFocus], ShortcutCommand.toggleSectionFocus.defaultShortcut)
        // Migrating a new command must not resurrect one the user turned off.
        XCTAssertNil(loaded[.cycleNextWindow])
    }

    func testSectionFocusDefaultYieldsToAUserBindingOnTheSameKeys() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .toggleSectionFocus)
        stored[.spanWindowLeft] = try XCTUnwrap(ShortcutCommand.toggleSectionFocus.defaultShortcut)
        let fixture = StoredShortcutsFixture(version: 4, shortcuts: stored)
        try JSONEncoder().encode(fixture).write(to: url)

        let loaded = ShortcutPersistence(url: url).load()

        XCTAssertNil(loaded[.toggleSectionFocus])
        XCTAssertEqual(loaded[.spanWindowLeft], ShortcutCommand.toggleSectionFocus.defaultShortcut)
    }

    func testShortcutPersistenceAddsSwitcherMovementDefaultsToAnOlderFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .moveApplicationEarlier)
        stored.removeValue(forKey: .moveApplicationLater)
        let fixture = StoredShortcutsFixture(version: 6, shortcuts: stored)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture).write(to: url)

        let loaded = ShortcutPersistence(url: url).load()

        XCTAssertEqual(
            loaded[.moveApplicationEarlier],
            ShortcutCommand.moveApplicationEarlier.defaultShortcut
        )
        XCTAssertEqual(
            loaded[.moveApplicationLater],
            ShortcutCommand.moveApplicationLater.defaultShortcut
        )
    }

    func testSwitcherMovementDefaultDoesNotClaimAUserBinding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .moveApplicationEarlier)
        let userBinding = try XCTUnwrap(ShortcutCommand.moveApplicationEarlier.defaultShortcut)
        stored[.spanWindowLeft] = userBinding
        let fixture = StoredShortcutsFixture(version: 6, shortcuts: stored)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture).write(to: url)

        let loaded = ShortcutPersistence(url: url).load()

        XCTAssertNil(loaded[.moveApplicationEarlier])
        XCTAssertEqual(loaded[.spanWindowLeft], userBinding)
    }

    func testShortcutPersistencePreservesDisabledCommands() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        var shortcuts = ShortcutPersistence.defaults
        shortcuts.removeValue(forKey: .cycleNextWindow)

        try store.save(shortcuts)

        XCTAssertNil(store.load()[.cycleNextWindow])
        XCTAssertEqual(store.load()[.cyclePreviousWindow], ShortcutCommand.cyclePreviousWindow.defaultShortcut)
    }

    func testShortcutPersistenceRoundTripsCustomAndUnassignedBindings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        var shortcuts = ShortcutPersistence.defaults
        shortcuts[.spanWindowLeft] = GlobalShortcut(
            keyCode: UInt32(kVK_F6),
            keyLabel: "F6",
            modifiers: [.control, .option, .command]
        )
        shortcuts.removeValue(forKey: .focusNextSection)

        try store.save(shortcuts)

        XCTAssertEqual(store.load(), shortcuts)
    }

    func testShortcutPersistenceMigratesPreviousDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        let oldCycle = GlobalShortcut(
            keyCode: UInt32(kVK_UpArrow),
            keyLabel: "↑",
            modifiers: [.control, .option]
        )
        let oldSpan = GlobalShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            keyLabel: "←",
            modifiers: [.control, .option, .shift]
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([
            ShortcutCommand.cycleNextWindow: oldCycle,
            .spanWindowLeft: oldSpan
        ]).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.cycleNextWindow]?.displayText, "⌃⌥↓")
        // The historical ⌃⌥⇧← span binding collided with window movement, so
        // it is dropped, and the command then starts on its current default.
        XCTAssertEqual(migrated[.spanWindowLeft], ShortcutCommand.spanWindowLeft.defaultShortcut)
        XCTAssertEqual(migrated[.spanWindowRight], ShortcutCommand.spanWindowRight.defaultShortcut)
        XCTAssertEqual(migrated[.focusPreviousSection]?.displayText, "⌃⌥←")
        XCTAssertEqual(migrated[.focusNextSection]?.displayText, "⌃⌥→")
    }

    func testShortcutPersistenceRepairsVersionTwoSpanConflictWithoutReenablingDisabledCommands() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        var shortcuts = ShortcutPersistence.defaults
        shortcuts.removeValue(forKey: .focusNextSection)
        shortcuts[.spanWindowLeft] = GlobalShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            keyLabel: "←",
            modifiers: [.control, .option, .shift]
        )
        let stored = StoredShortcutsFixture(version: 2, shortcuts: shortcuts)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.spanWindowLeft], ShortcutCommand.spanWindowLeft.defaultShortcut)
        XCTAssertNil(migrated[.focusNextSection])
        XCTAssertEqual(migrated[.focusPreviousSection], ShortcutCommand.focusPreviousSection.defaultShortcut)
    }

    func testShortcutPersistenceAddsTheSpanDefaultsToAVersionSevenFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .spanWindowLeft)
        stored.removeValue(forKey: .spanWindowRight)
        let fixture = StoredShortcutsFixture(version: 7, shortcuts: stored)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture).write(to: url, options: .atomic)

        let state = ShortcutPersistence(url: url).loadState()

        XCTAssertEqual(state.bindings[.spanWindowLeft]?.displayText, "⌃⌥⌘←")
        XCTAssertEqual(state.bindings[.spanWindowRight]?.displayText, "⌃⌥⌘→")
        XCTAssertEqual(state.bindings[.cycleWindowLeft], ShortcutCommand.cycleWindowLeft.defaultShortcut)
        XCTAssertTrue(state.disabledCommands.isEmpty)
        // The migrated file is rewritten at the current version so the next
        // launch does not migrate again.
        XCTAssertEqual(ShortcutPersistence(url: url).loadState(), state)
    }

    func testShortcutPersistenceLeavesASpanDefaultUnboundWhenTheUserAlreadyUsesThoseKeys() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        var stored = ShortcutPersistence.defaults
        stored.removeValue(forKey: .spanWindowLeft)
        stored.removeValue(forKey: .spanWindowRight)
        let userBinding = try XCTUnwrap(ShortcutCommand.spanWindowRight.defaultShortcut)
        stored[.cycleNextWindow] = userBinding
        let fixture = StoredShortcutsFixture(version: 7, shortcuts: stored)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture).write(to: url, options: .atomic)

        let loaded = ShortcutPersistence(url: url).load()

        XCTAssertEqual(loaded[.cycleNextWindow], userBinding)
        XCTAssertNil(loaded[.spanWindowRight])
        XCTAssertEqual(loaded[.spanWindowLeft], ShortcutCommand.spanWindowLeft.defaultShortcut)
    }

    func testShortcutPersistenceRoundTripsDisabledCommandsAndDecodesFilesWithoutThem() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        var bindings = ShortcutPersistence.defaults
        bindings.removeValue(forKey: .spanWindowLeft)
        let state = ShortcutState(bindings: bindings, disabledCommands: [.spanWindowLeft])

        try store.save(state)

        XCTAssertEqual(store.loadState(), state)
        XCTAssertEqual(store.load(), bindings)

        // A current-version file written before disabled commands were
        // recorded has none.
        try JSONEncoder()
            .encode(StoredShortcutsFixture(version: 8, shortcuts: bindings))
            .write(to: url, options: .atomic)
        XCTAssertEqual(store.loadState(), ShortcutState(bindings: bindings, disabledCommands: []))
    }

    func testShortcutPersistenceRestoresVersionThreeWindowCyclingDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        var shortcuts = ShortcutPersistence.defaults
        shortcuts[.cycleNextWindow] = GlobalShortcut(
            keyCode: UInt32(kVK_UpArrow),
            keyLabel: "↑",
            modifiers: [.control, .option, .shift]
        )
        shortcuts[.cyclePreviousWindow] = GlobalShortcut(
            keyCode: UInt32(kVK_DownArrow),
            keyLabel: "↓",
            modifiers: [.control, .option, .shift]
        )
        shortcuts.removeValue(forKey: .focusNextSection)
        let stored = StoredShortcutsFixture(version: 3, shortcuts: shortcuts)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.cycleNextWindow]?.displayText, "⌃⌥↓")
        XCTAssertEqual(migrated[.cyclePreviousWindow]?.displayText, "⌃⌥↑")
        XCTAssertNil(migrated[.focusNextSection])
    }

    func testShortcutPersistenceSwapsPreviousWindowCyclingDefaults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        let stored = StoredShortcutsFixture(version: 5, shortcuts: [
            .cycleNextWindow: GlobalShortcut(
                keyCode: UInt32(kVK_UpArrow),
                keyLabel: "↑",
                modifiers: [.control, .option]
            ),
            .cyclePreviousWindow: GlobalShortcut(
                keyCode: UInt32(kVK_DownArrow),
                keyLabel: "↓",
                modifiers: [.control, .option]
            )
        ])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.cycleNextWindow]?.displayText, "⌃⌥↓")
        XCTAssertEqual(migrated[.cyclePreviousWindow]?.displayText, "⌃⌥↑")
    }

    func testWindowCyclingDefaultMigrationPreservesDisabledBinding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        let stored = StoredShortcutsFixture(version: 5, shortcuts: [
            .cycleNextWindow: GlobalShortcut(
                keyCode: UInt32(kVK_UpArrow),
                keyLabel: "↑",
                modifiers: [.control, .option]
            )
        ])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.cycleNextWindow]?.displayText, "⌃⌥↓")
        XCTAssertNil(migrated[.cyclePreviousWindow])
    }

    func testShortcutMigrationDoesNotOverwriteAConflictingUserBinding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        let historicalMovementShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            keyLabel: "←",
            modifiers: [.control, .option]
        )
        let userBindingAtNewDefault = GlobalShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            keyLabel: "←",
            modifiers: [.control, .option, .shift]
        )
        let stored = StoredShortcutsFixture(version: 2, shortcuts: [
            .cycleWindowLeft: historicalMovementShortcut,
            .cycleNextWindow: userBindingAtNewDefault
        ])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url, options: .atomic)

        let migrated = store.load()

        XCTAssertEqual(migrated[.cycleWindowLeft], historicalMovementShortcut)
        XCTAssertEqual(migrated[.cycleNextWindow], userBindingAtNewDefault)
        XCTAssertFalse(try XCTUnwrap(migrated[.cycleWindowLeft]).conflicts(with: userBindingAtNewDefault))
    }

    func testFutureShortcutFileIgnoresUnknownCommandsWithoutResettingKnownBindings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("shortcuts.json")
        let store = ShortcutPersistence(url: url)
        let knownShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_F7),
            keyLabel: "F7",
            modifiers: [.control, .option, .command]
        )
        let shortcutObject: (GlobalShortcut) -> [String: Any] = { shortcut in
            [
                "keyCode": shortcut.keyCode,
                "keyLabel": shortcut.keyLabel,
                "modifiers": shortcut.modifiers.rawValue
            ]
        }
        let futureShortcut = try XCTUnwrap(ShortcutCommand.focusNextSection.defaultShortcut)
        let object: [String: Any] = [
            "version": 999,
            "shortcuts": [
                ShortcutCommand.cycleNextWindow.rawValue,
                shortcutObject(knownShortcut),
                "commandAddedByFuturePanoptos",
                shortcutObject(futureShortcut)
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)

        let loaded = store.load()

        XCTAssertEqual(loaded, [.cycleNextWindow: knownShortcut])
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testSectionNavigatorFindsNeighborAndWrapsWithinRow() throws {
        let left = UUID()
        let middle = UUID()
        let right = UUID()
        let bottom = UUID()
        let frames = [
            left: CGRect(x: 0, y: 100, width: 100, height: 100),
            middle: CGRect(x: 106, y: 100, width: 100, height: 100),
            right: CGRect(x: 212, y: 100, width: 100, height: 100),
            bottom: CGRect(x: 0, y: 0, width: 312, height: 94)
        ]

        XCTAssertEqual(SectionNavigator.adjacentSection(to: middle, direction: .left, frames: frames), left)
        XCTAssertEqual(SectionNavigator.adjacentSection(to: middle, direction: .right, frames: frames), right)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: left, direction: .left, frames: frames), right)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: right, direction: .right, frames: frames), left)
    }

    func testSectionNavigatorSweepsThroughASpanAndTheSectionsItCovers() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let span = UUID()
        let frames = [
            first: CGRect(x: 0, y: 0, width: 600, height: 800),
            second: CGRect(x: 600, y: 0, width: 600, height: 800),
            third: CGRect(x: 1200, y: 0, width: 600, height: 800),
            span: CGRect(x: 0, y: 0, width: 1800, height: 800)
        ]

        // Left edge first, then right edge: first, the span starting there,
        // the next covered section, and so on, wrapping at either end.
        XCTAssertEqual(SectionNavigator.cyclingSection(from: first, direction: .right, frames: frames), span)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: span, direction: .right, frames: frames), second)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: second, direction: .right, frames: frames), third)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: third, direction: .right, frames: frames), first)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: third, direction: .left, frames: frames), second)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: second, direction: .left, frames: frames), span)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: span, direction: .left, frames: frames), first)
        XCTAssertEqual(SectionNavigator.cyclingSection(from: first, direction: .left, frames: frames), third)
        // Spanning only asks about the layout's own sections.
        XCTAssertEqual(
            SectionNavigator.adjacentSection(to: second, direction: .right, frames: frames, excluding: [first, second, span]),
            third
        )
    }

    private func selectionWindow(bundleIdentifier: String, ordinal: Int) -> ManagedWindow {
        ManagedWindow(
            id: UUID(),
            handle: AXWindowHandle(element: AXUIElementCreateApplication(pid_t(ordinal + 100))),
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            accessibilityIdentifier: nil,
            windowOrdinal: ordinal,
            applicationName: bundleIdentifier,
            icon: NSImage(),
            title: "Window \(ordinal)",
            isMinimized: false
        )
    }
}

final class OnboardingTests: XCTestCase {
    func testPagesRunFromWelcomeToShortcutsInOrder() {
        XCTAssertEqual(OnboardingPage.allCases.first, .welcome)
        XCTAssertEqual(OnboardingPage.allCases.last, .shortcuts)
        XCTAssertTrue(OnboardingPage.welcome.isFirst)
        XCTAssertNil(OnboardingPage.welcome.previous)
        XCTAssertTrue(OnboardingPage.shortcuts.isLast)
        XCTAssertNil(OnboardingPage.shortcuts.next)
        XCTAssertEqual(OnboardingPage.welcome.next, .accessibility)
        XCTAssertEqual(OnboardingPage.attach.previous, .layout)
        XCTAssertEqual(
            Array(OnboardingPage.allCases.dropFirst()),
            OnboardingPage.allCases.dropLast().compactMap(\.next)
        )
    }

    func testAttachPageQuotesConfiguredDragModifiers() {
        let defaults = OnboardingPage.attach.detail(.defaults)
        XCTAssertTrue(defaults.contains("Hold ⇧ "))
        XCTAssertTrue(defaults.contains("hold ⌃⇧ "))

        var custom = OnboardingShortcutSummary.defaults
        custom.attachWindow = [.option, .command]
        custom.attachApplicationWindows = nil
        let single = OnboardingPage.attach.detail(custom)
        XCTAssertTrue(single.contains("Hold ⌥⌘ "))
        XCTAssertFalse(single.contains("every window"))

        custom.attachWindow = nil
        custom.attachApplicationWindows = [.control, .shift]
        XCTAssertTrue(OnboardingPage.attach.detail(custom).contains("Hold ⌃⇧ as you finish dragging a window to attach every window"))

        custom.attachApplicationWindows = []
        let off = OnboardingPage.attach.detail(custom)
        XCTAssertTrue(off.contains("turned off"))
        XCTAssertTrue(off.contains("Shortcuts › Window dragging"))
    }

    /// The move-window shortcuts also attach an unattached focused window, so
    /// the attach page quotes them and drops the sentence when both are off.
    func testAttachPageQuotesTheMoveShortcutsThatAttachAFocusedWindow() {
        let defaults = OnboardingPage.attach.detail(.defaults)
        XCTAssertTrue(defaults.contains("With an unattached window focused, ⌃⌥⇧← or ⌃⌥⇧→ attaches it"))
        XCTAssertEqual(OnboardingShortcutSummary.defaults.edgeAttachKeys, ["⌃⌥⇧←", "⌃⌥⇧→"])

        var custom = OnboardingShortcutSummary.defaults
        custom.bindings[.cycleWindowLeft] = nil
        let rightOnly = OnboardingPage.attach.detail(custom)
        XCTAssertTrue(rightOnly.contains("focused, ⌃⌥⇧→ attaches it"))
        XCTAssertFalse(rightOnly.contains("⌃⌥⇧←"))

        custom.bindings[.cycleWindowRight] = nil
        XCTAssertTrue(custom.edgeAttachKeys.isEmpty)
        XCTAssertFalse(OnboardingPage.attach.detail(custom).contains("unattached window focused"))
    }

    func testShortcutRowsFollowBindingsAndMarkDisabledCommands() {
        let rows = OnboardingShortcutSummary.defaults.rows
        XCTAssertEqual(rows.map(\.title), ["Cycle windows", "Switch section", "Move window", "Focus section"])
        XCTAssertEqual(rows[0].keys, ["⌃⌥↑", "⌃⌥↓"])
        XCTAssertEqual(rows[1].keys, ["⌃⌥←", "⌃⌥→"])
        XCTAssertEqual(rows[2].keys, ["⌃⌥⇧←", "⌃⌥⇧→"])
        XCTAssertEqual(rows[3].keys, ["⌃⌥F"])

        var custom = OnboardingShortcutSummary.defaults
        custom.bindings[.cycleNextWindow] = nil
        custom.bindings[.toggleSectionFocus] = GlobalShortcut(keyCode: 0, keyLabel: "A", modifiers: [.command])
        let customRows = custom.rows
        XCTAssertEqual(customRows[0].keys, ["⌃⌥↑", nil])
        XCTAssertEqual(customRows[3].keys, ["⌘A"])
    }

    func testEveryPageHasTitleAndDetail() {
        for page in OnboardingPage.allCases {
            XCTAssertFalse(page.title.isEmpty, "\(page) has no title")
            XCTAssertFalse(page.detail(.defaults).isEmpty, "\(page) has no detail")
        }
        XCTAssertTrue(OnboardingPage.welcome.detail(.defaults).contains("menu bar"))
        XCTAssertTrue(OnboardingPage.layout.detail(.defaults).contains("Layout tab"))
        XCTAssertTrue(OnboardingPage.bars.detail(.defaults).contains("off by default"))
        XCTAssertTrue(OnboardingPage.bars.detail(.defaults).contains("Show Menu Bars"))
        XCTAssertTrue(OnboardingPage.shortcuts.detail(.defaults).contains("Shortcuts tab"))
    }
}

/// The tour is a sheet on the settings window, so these host the real
/// settings view in a window and order it on screen: a sheet only attaches to
/// a visible window, which is exactly what the presentation has to get right.
@MainActor
final class OnboardingPresentationTests: XCTestCase {
    func testTourSheetAttachesOnceTheSettingsWindowIsOnScreen() {
        XCTAssertNotNil(attachedSheetAfterShowingSettings(onboardingCompleted: false))
    }

    func testTourSheetStaysAwayOnceCompleted() {
        XCTAssertNil(attachedSheetAfterShowingSettings(onboardingCompleted: true))
    }

    private func attachedSheetAfterShowingSettings(onboardingCompleted: Bool) -> NSWindow? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = PanoptosModel(
            accessibility: MockAccessibility(),
            persistence: LayoutPersistence(url: directory.appendingPathComponent("layouts.json")),
            windowAssignmentPersistence: WindowAssignmentPersistence(
                url: directory.appendingPathComponent("window-assignments.json")
            ),
            settingsPersistence: SettingsPersistence(url: directory.appendingPathComponent("settings.json")),
            shortcutPersistence: ShortcutPersistence(url: directory.appendingPathComponent("shortcuts.json")),
            shortcutRegistrar: MockShortcutRegistrar(),
            keepAwakeController: MockKeepAwakeController(),
            loginItemController: MockLoginItemController(),
            updateController: MockUpdateController(),
            ownProcessIdentifier: -1
        )
        if onboardingCompleted { model.completeOnboarding() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // The test keeps its own reference, so AppKit must not release the
        // window on close.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        // XCTest may reopen its host on an inactive Space. Bring this fixture
        // onto the current desktop before testing visibility-driven presentation.
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // A sheet attaches within a few run-loop turns of the window being
        // ordered in; the negative case only needs a comparable settling time.
        let deadline = Date(timeIntervalSinceNow: onboardingCompleted ? 0.6 : 2)
        while window.attachedSheet == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let sheet = window.attachedSheet
        if let sheet { window.endSheet(sheet) }
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        return sheet
    }
}

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    func testRecorderLabelsCoverEmptyAssignedAndRecordingStates() {
        let view = ShortcutRecorderNSView(frame: NSRect(x: 0, y: 0, width: 154, height: 28))

        XCTAssertEqual(view.displayedShortcutText, "None")
        XCTAssertFalse(view.isClearControlVisible)

        for command in ShortcutCommand.allCases {
            view.shortcut = command.defaultShortcut
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.displayedShortcutText, command.defaultShortcut?.displayText ?? "None")
            XCTAssertEqual(view.isClearControlVisible, command.defaultShortcut != nil)
        }

        view.shortcut = ShortcutCommand.cycleNextWindow.defaultShortcut
        XCTAssertTrue(view.becomeFirstResponder())
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.displayedShortcutText, "Type shortcut")
        XCTAssertFalse(view.isClearControlVisible)

        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(view.displayedShortcutText, ShortcutCommand.cycleNextWindow.defaultShortcut?.displayText)
        XCTAssertTrue(view.isClearControlVisible)
    }

    func testHitTestingUsesSuperviewCoordinates() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let view = ShortcutRecorderNSView(frame: NSRect(x: 100, y: 50, width: 154, height: 28))
        parent.addSubview(view)

        XCTAssertTrue(view.hitTest(NSPoint(x: 110, y: 60)) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHiddenClearControlDoesNotClearWhileRecording() {
        let view = ShortcutRecorderNSView(frame: NSRect(x: 0, y: 0, width: 154, height: 28))
        view.shortcut = ShortcutCommand.cycleNextWindow.defaultShortcut
        let clearPoint = NSPoint(x: view.bounds.maxX - 12, y: view.bounds.midY)

        XCTAssertTrue(view.shouldClearShortcut(at: clearPoint))
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertFalse(view.shouldClearShortcut(at: clearPoint))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(view.shouldClearShortcut(at: clearPoint))
    }
}

@MainActor
final class WindowManagementTests: XCTestCase {
    func testReleaseSourceLinkUsesExactVersionTag() {
        XCTAssertEqual(
            PanoptosLinks.releaseSource(version: "1.4.0").absoluteString,
            "https://github.com/RUverse/panoptos/releases/tag/v1.4.0"
        )
    }

    func testWindowActivationDoesNotRaisePreviouslyFocusedSibling() throws {
        // The old key window could be attached in another section or entirely
        // unmanaged. Ordinary app activation raises whichever window is key.
        var keyWindow = "sibling"
        var raisedWindows: [String] = []
        var activationCount = 0
        try AccessibilityClient.performWindowFocus(
            isApplicationActive: false,
            selectWindow: { keyWindow = "requested"; return .success },
            activateApplication: {
                activationCount += 1
                raisedWindows.append(keyWindow)
                return true
            },
            makeApplicationFrontmost: {
                raisedWindows.append(keyWindow)
                return .success
            },
            raiseWindow: { raisedWindows.append("requested") }
        )
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(keyWindow, "requested")
        XCTAssertFalse(raisedWindows.contains("sibling"))
        XCTAssertEqual(raisedWindows.last, "requested")
    }

    func testSwitchingWindowsInActiveApplicationDoesNotReactivateIt() throws {
        var selected = false
        var raised = false
        try AccessibilityClient.performWindowFocus(
            isApplicationActive: true,
            selectWindow: { selected = true; return .success },
            activateApplication: { XCTFail("Same-app switching must not activate the app"); return true },
            makeApplicationFrontmost: { XCTFail("Same-app switching must not set AXFrontmost"); return .success },
            raiseWindow: { raised = true }
        )
        XCTAssertTrue(selected)
        XCTAssertTrue(raised)
    }

    func testWindowFocusRetriesSelectionAfterActivatingIncompatibleAXServer() throws {
        var active = false
        var focused = false
        try AccessibilityClient.performWindowFocus(
            isApplicationActive: false,
            selectWindow: {
                guard active else { return .cannotComplete }
                focused = true
                return .success
            },
            activateApplication: { true }, // Accepted, but still inactive.
            makeApplicationFrontmost: { active = true; return .success },
            raiseWindow: { XCTAssertTrue(focused) }
        )
        XCTAssertTrue(focused)
    }

    func testRejectedActivationUsesAXFallbackWithRequestedWindowSelected() throws {
        var selected = false
        var active = false
        try AccessibilityClient.performWindowFocus(
            isApplicationActive: false,
            selectWindow: { selected = true; return .success },
            activateApplication: { false },
            makeApplicationFrontmost: {
                XCTAssertTrue(selected)
                active = true
                return .success
            },
            raiseWindow: { XCTAssertTrue(active) }
        )
        XCTAssertTrue(active)
    }

    func testFailedActivationDoesNotRaiseWindow() {
        XCTAssertThrowsError(try AccessibilityClient.performWindowFocus(
            isApplicationActive: false,
            selectWindow: { .success },
            activateApplication: { false },
            makeApplicationFrontmost: { .cannotComplete },
            raiseWindow: { XCTFail("Failed activation must not raise the window") }
        ))
    }

    func testFailedWindowSelectionDoesNotReportSuccessfulFocus() {
        XCTAssertThrowsError(try AccessibilityClient.performWindowFocus(
            isApplicationActive: true,
            selectWindow: { .cannotComplete },
            activateApplication: { true },
            makeApplicationFrontmost: { .success },
            raiseWindow: { XCTFail("Failed selection must not raise the window") }
        ))
    }

    func testFailedWindowRaiseDoesNotReportSuccessfulFocus() {
        XCTAssertThrowsError(try AccessibilityClient.performWindowFocus(
            isApplicationActive: true,
            selectWindow: { .success },
            activateApplication: { true },
            makeApplicationFrontmost: { .success },
            raiseWindow: { throw AccessibilityClientError.attribute(kAXRaiseAction as String, .cannotComplete) }
        ))
    }

    func testFocusedSwitcherTargetUsesTheRenderedWindowAndFallsBackToItsApplication() {
        let first = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 1)
        let section = LayoutSectionState(
            id: UUID(),
            windows: [first, second],
            activeWindowID: second.id
        )

        XCTAssertEqual(
            SectionBarFocusedScrollTarget.resolve(
                section: section,
                isSectionFocused: true,
                renderedWindowIDs: [first.id, second.id]
            ),
            .window(second.id)
        )
        XCTAssertEqual(
            SectionBarFocusedScrollTarget.resolve(
                section: section,
                isSectionFocused: true,
                renderedWindowIDs: []
            ),
            .application(second.bundleIdentifier)
        )
        XCTAssertNil(SectionBarFocusedScrollTarget.resolve(
            section: section,
            isSectionFocused: false,
            renderedWindowIDs: [first.id, second.id]
        ))
    }

    func testOverflowingSwitcherRevealsFocusedWindowsInBothDirections() throws {
        let model = makeModel(mock: MockAccessibility())
        model.windowSwitcherTitleMode = .always
        var editorWindows = (0..<4).map {
            managedWindow(bundleIdentifier: "com.example.Editor", ordinal: $0)
        }
        for index in editorWindows.indices {
            editorWindows[index].title = "Editor document \(index + 1)"
        }
        var browser = managedWindow(bundleIdentifier: "com.example.Browser", ordinal: 4)
        browser.title = "Browser window"
        let sectionID = UUID()
        let section = LayoutSectionState(
            id: sectionID,
            windows: editorWindows + [browser],
            activeWindowID: editorWindows[0].id
        )
        model.sections[sectionID] = section
        let presentation = SectionPresentation(sectionID: sectionID, section: section)
        let hosting = FirstMouseHostingView(rootView: AnyView(
            SectionWindowBar(presentation: presentation)
                .environmentObject(model)
                .frame(
                    width: 320,
                    height: WindowSwitcherSize.barHeight(for: model.windowSwitcherUIScale)
                )
        ))
        hosting.frame = CGRect(
            x: 0,
            y: 0,
            width: 320,
            height: WindowSwitcherSize.barHeight(for: model.windowSwitcherUIScale)
        )
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        settleHostedSwitcher(hosting)
        let scrollView = try XCTUnwrap(descendantScrollViews(in: hosting).first)
        XCTAssertGreaterThan(
            scrollView.documentView?.frame.width ?? 0,
            scrollView.contentView.bounds.width,
            "The hosted fixture must overflow before reveal behavior is meaningful"
        )
        let initialOffset = scrollView.contentView.bounds.minX

        // The adjacent editor control is already visible. Revealing it must
        // not disturb a switcher the user has positioned at its leading edge.
        var update = presentation.section
        update.activeWindowID = editorWindows[1].id
        presentation.section = update
        settleHostedSwitcher(hosting)
        XCTAssertEqual(scrollView.contentView.bounds.minX, initialOffset, accuracy: 1)

        // Same-application focus changes have no application activation
        // notification; the presentation update itself must reveal them in
        // either direction.
        update.activeWindowID = editorWindows[3].id
        presentation.section = update
        settleHostedSwitcher(hosting)
        let rightwardOffset = scrollView.contentView.bounds.minX
        XCTAssertGreaterThan(rightwardOffset, initialOffset + 1)

        update.activeWindowID = editorWindows[0].id
        presentation.section = update
        settleHostedSwitcher(hosting)
        let returnedOffset = scrollView.contentView.bounds.minX
        XCTAssertLessThan(returnedOffset, rightwardOffset - 1)

        // Once the user manually scrolls the focused control out of view,
        // unrelated content and layout changes must preserve that position.
        // Only a subsequent focus transition is allowed to reveal a target.
        let manualOffset = min(
            150,
            max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width)
        )
        XCTAssertGreaterThan(manualOffset, returnedOffset + 1)
        scrollView.contentView.scroll(to: NSPoint(x: manualOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        update.windows[4].title = String(repeating: "Renamed browser tab ", count: 8)
        presentation.section = update
        settleHostedSwitcher(hosting)
        XCTAssertEqual(scrollView.contentView.bounds.minX, manualOffset, accuracy: 1)

        model.windowSwitcherTitleMode = .whenNeeded
        settleHostedSwitcher(hosting)
        XCTAssertEqual(scrollView.contentView.bounds.minX, manualOffset, accuracy: 1)

        let unrelated = managedWindow(bundleIdentifier: "com.example.Terminal", ordinal: 5)
        update.windows.append(unrelated)
        presentation.section = update
        settleHostedSwitcher(hosting)
        XCTAssertEqual(scrollView.contentView.bounds.minX, manualOffset, accuracy: 1)

        scrollView.contentView.scroll(to: NSPoint(x: returnedOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // A focus update for another section is ignored. When the section
        // becomes focused—matching a Cmd-Tab-style external activation—the
        // already-published browser target is revealed.
        presentation.isFocused = false
        update.activeWindowID = browser.id
        presentation.section = update
        settleHostedSwitcher(hosting)
        XCTAssertEqual(scrollView.contentView.bounds.minX, returnedOffset, accuracy: 1)

        presentation.isFocused = true
        settleHostedSwitcher(hosting)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minX, returnedOffset + 1)
        _ = window
    }

    func testOnboardingCompletionSurvivesModelRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = makeModel(mock: MockAccessibility(), directory: directory)
        XCTAssertFalse(first.hasCompletedOnboarding, "A fresh install shows the welcome tour")

        first.completeOnboarding()
        XCTAssertTrue(first.hasCompletedOnboarding)

        let relaunched = makeModel(mock: MockAccessibility(), directory: directory)
        XCTAssertTrue(relaunched.hasCompletedOnboarding, "The tour must not come back on the next launch")
    }

    func testOnboardingSummaryQuotesTheModelsCurrentBindings() {
        let model = makeModel(mock: MockAccessibility())
        model.setWindowDragShortcut([.option, .command], for: .attachWindow)
        model.setWindowDragShortcut(nil, for: .attachApplicationWindows)
        model.setShortcut(nil, for: .cycleNextWindow)

        let summary = OnboardingShortcutSummary(model: model)

        XCTAssertEqual(summary.attachWindow, [.option, .command])
        XCTAssertNil(summary.attachApplicationWindows)
        XCTAssertNil(summary.displayText(for: .cycleNextWindow))
        XCTAssertEqual(summary.displayText(for: .cyclePreviousWindow), "⌃⌥↑")
        XCTAssertTrue(OnboardingPage.attach.detail(summary).contains("Hold ⌥⌘"))
    }

    func testRuntimeStopPreservesManagedAssignmentsAndCleansUp() {
        let registrar = MockShortcutRegistrar()
        let keepAwake = MockKeepAwakeController()
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            keepAwakeController: keepAwake,
            shortcutRegistrar: registrar
        )
        let sectionID = model.layouts[0].root.leafIDs[0]
        let window = managedWindow(bundleIdentifier: "com.example.Managed", ordinal: 0, pid: 4401)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [window],
            activeWindowID: window.id
        )
        model.keepMacAwake = true
        XCTAssertEqual(keepAwake.startCallCount, 1)

        model.stopWindowManagementRuntime()

        XCTAssertFalse(model.isWindowManagementRuntimeStarted)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [window.id])
        XCTAssertTrue(model.workspaceObservers.isEmpty)
        XCTAssertEqual(registrar.updates.last, [:])
        XCTAssertEqual(keepAwake.stopCallCount, 1)
        XCTAssertTrue(model.keepMacAwake, "Stopping runtime must preserve the preference")
    }

    func testRuntimeStopRevealsEveryApplicationPanoptosHid() throws {
        let mock = MockAccessibility()
        let model = makeModel(mock: mock)
        let pids = try foreignApplicationPIDs(2)
        let applications = try pids.map { pid in
            let application = try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
            return HiddenApplication(
                pid: pid,
                bundleIdentifier: application.bundleIdentifier ?? "pid.\(pid)"
            )
        }
        let first = applications[0]
        let second = applications[1]
        mock.hiddenPIDs = [first.pid, second.pid]
        model.focusedSectionID = model.layouts[0].root.leafIDs[0]
        model.focusModeHiddenApplications = [first]
        model.applicationSplitHiddenApplications = [second]

        model.stopWindowManagementRuntime()

        XCTAssertTrue(model.focusModeHiddenApplications.isEmpty)
        XCTAssertTrue(model.applicationSplitHiddenApplications.isEmpty)
        XCTAssertTrue(mock.hideRequests.contains { $0.pid == first.pid && !$0.hidden })
        XCTAssertTrue(mock.hideRequests.contains { $0.pid == second.pid && !$0.hidden })
    }

    func testRuntimeStartIsIdempotent() {
        let registrar = MockShortcutRegistrar()
        let model = makeModel(
            mock: MockAccessibility(),
            shortcutRegistrar: registrar
        )
        let observerCount = model.workspaceObservers.count
        let registrationCount = registrar.updates.count
        XCTAssertTrue(model.isWindowManagementRuntimeStarted)
        XCTAssertGreaterThan(observerCount, 0)

        model.startWindowManagementRuntime()

        XCTAssertEqual(model.workspaceObservers.count, observerCount)
        XCTAssertEqual(registrar.updates.count, registrationCount)
    }

    func testRuntimeStopAndRestartNotifyOverlayCoordinator() {
        let model = makeModel(mock: MockAccessibility())
        var states: [Bool] = []
        model.onWindowManagementRuntimeChanged = { states.append($0) }

        model.stopWindowManagementRuntime()
        model.startWindowManagementRuntime()

        XCTAssertEqual(states, [false, true])
        XCTAssertTrue(model.isWindowManagementRuntimeStarted)
    }
    func testApplicationSplitGeometryChoosesOrientationAndUsesGutter() {
        let wide = ApplicationSplitGeometry.frames(
            in: CGRect(x: 0, y: 0, width: 100, height: 40),
            gutter: 10
        )
        XCTAssertEqual(wide.axis, .horizontal)
        XCTAssertEqual(wide.first, CGRect(x: 0, y: 0, width: 45, height: 40))
        XCTAssertEqual(wide.second, CGRect(x: 55, y: 0, width: 45, height: 40))

        let square = ApplicationSplitGeometry.frames(
            in: CGRect(x: 5, y: 10, width: 100, height: 100),
            gutter: 10
        )
        XCTAssertEqual(square.axis, .horizontal)
        XCTAssertEqual(square.first, CGRect(x: 5, y: 10, width: 45, height: 100))
        XCTAssertEqual(square.second, CGRect(x: 60, y: 10, width: 45, height: 100))

        let tall = ApplicationSplitGeometry.frames(
            in: CGRect(x: 0, y: 0, width: 40, height: 100),
            gutter: 10
        )
        XCTAssertEqual(tall.axis, .vertical)
        XCTAssertEqual(tall.first, CGRect(x: 0, y: 55, width: 40, height: 45))
        XCTAssertEqual(tall.second, CGRect(x: 0, y: 0, width: 40, height: 45))
    }

    func testApplicationSplitOrientationUsesSectionAspectNotBarAdjustedContentAspect() throws {
        let fingerprint = DisplayFingerprint(vendor: 3, model: 3, serial: 3, name: "Tall")
        let display = currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 500, height: 520)
        )
        let sectionID = UUID()
        let model = makeModel(
            mock: MockAccessibility(),
            root: .leaf(id: sectionID),
            displayProvider: { [display] }
        )
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: second.bundleIdentifier
        )]

        let content = try XCTUnwrap(model.contentFrame(forSection: sectionID))
        XCTAssertLessThan(content.height, content.width)
        XCTAssertEqual(model.applicationSplitAxis(inSection: sectionID), .vertical)
        XCTAssertGreaterThan(
            try XCTUnwrap(model.contentFrame(
                forApplication: first.bundleIdentifier,
                inSection: sectionID
            )).minY,
            try XCTUnwrap(model.contentFrame(
                forApplication: second.bundleIdentifier,
                inSection: sectionID
            )).minY
        )
    }

    func testSwitcherApplicationUnitsKeepIndependentPairsTogether() {
        let firstPair = ApplicationSplitPair(
            firstBundleIdentifier: "a",
            secondBundleIdentifier: "b"
        )
        let secondPair = ApplicationSplitPair(
            firstBundleIdentifier: "d",
            secondBundleIdentifier: "e"
        )

        XCTAssertEqual(
            SwitcherApplicationUnit.make(
                bundleOrder: ["a", "b", "c", "d", "e"],
                pairs: [firstPair, secondPair]
            ),
            [.pair(firstPair), .application("c"), .pair(secondPair)]
        )
    }

    func testSwitcherOrderGroupsInterleavedWindowsByFirstSeenApplication() {
        struct Item: Equatable {
            let name: String
            let bundleIdentifier: String
        }
        let input = [
            Item(name: "A1", bundleIdentifier: "A"),
            Item(name: "B1", bundleIdentifier: "B"),
            Item(name: "A2", bundleIdentifier: "A"),
            Item(name: "C1", bundleIdentifier: "C"),
            Item(name: "B2", bundleIdentifier: "B")
        ]

        XCTAssertEqual(
            SwitcherOrder.grouped(input, bundleIdentifier: \.bundleIdentifier).map(\.name),
            ["A1", "A2", "B1", "B2", "C1"]
        )
    }

    /// The strip drags only the windows it draws. Windows off screen at the
    /// time rejoin the order beside their application so the model's
    /// whole-section check still passes and nothing leaves the section.
    func testSwitcherOrderCompletesRenderedOrderWithOffScreenWindows() {
        struct Item: Identifiable {
            let id: String
            let bundleIdentifier: String
        }
        let items = [
            Item(id: "A1", bundleIdentifier: "A"),
            Item(id: "A2-off", bundleIdentifier: "A"),
            Item(id: "B1", bundleIdentifier: "B"),
            Item(id: "C1-off", bundleIdentifier: "C"),
            Item(id: "B2", bundleIdentifier: "B"),
            Item(id: "C2-off", bundleIdentifier: "C")
        ]

        // The user dragged B ahead of A while A2 and every C window were off screen.
        XCTAssertEqual(
            SwitcherOrder.completing(["B1", "B2", "A1"], with: items, bundleIdentifier: \.bundleIdentifier),
            ["B1", "B2", "A1", "A2-off", "C1-off", "C2-off"]
        )
        // Nothing hidden: the rendered order is the whole order.
        XCTAssertEqual(
            SwitcherOrder.completing(
                ["B1", "B2", "A1"],
                with: items.filter { !$0.id.hasSuffix("off") },
                bundleIdentifier: \.bundleIdentifier
            ),
            ["B1", "B2", "A1"]
        )
    }

    func testDisplayAliasMigrationKeepsMostCompleteLayoutsAndAssignmentProfiles() throws {
        let airPlay = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: " (AirPlay)"
        )
        let current = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: "LG HDR WQHD+",
            stableIdentifier: "EA727D2D-E05B-4010-A1D6-56139337B7DD"
        )
        let firstSection = UUID()
        let secondSection = UUID()
        let thirdSection = UUID()
        let richRoot = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSection),
            second: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(id: secondSection),
                second: .leaf(id: thirdSection)
            )
        )
        let layoutResult = DisplayPersistenceMigration.layouts(
            [
                DisplayLayout(fingerprint: current, root: .leaf(id: UUID())),
                DisplayLayout(fingerprint: airPlay, root: richRoot)
            ],
            current: [current]
        )

        XCTAssertTrue(layoutResult.changed)
        XCTAssertEqual(layoutResult.layouts.count, 1)
        XCTAssertEqual(layoutResult.layouts[0].root, richRoot)
        XCTAssertEqual(layoutResult.layouts[0].fingerprint.storageKey, current.storageKey)

        let editorOneID = UUID()
        let browserID = UUID()
        let editorTwoID = UUID()
        let terminalID = UUID()
        let missingID = UUID()
        func assignment(
            _ id: UUID,
            bundleIdentifier: String,
            order: Int,
            topology: [DisplayFingerprint]
        ) -> PersistedWindowAssignment {
            PersistedWindowAssignment(
                id: id,
                sectionID: firstSection,
                additionalSectionIDs: [],
                bundleIdentifier: bundleIdentifier,
                processIdentifier: 42,
                accessibilityIdentifier: id.uuidString,
                title: id.uuidString,
                windowOrdinal: order,
                order: order,
                isActive: order == 3,
                displayTopology: topology
            )
        }
        let airPlayProfile = [
            assignment(editorOneID, bundleIdentifier: "Editor", order: 0, topology: [airPlay]),
            assignment(browserID, bundleIdentifier: "Browser", order: 1, topology: [airPlay]),
            assignment(editorTwoID, bundleIdentifier: "Editor", order: 2, topology: [airPlay]),
            assignment(terminalID, bundleIdentifier: "Terminal", order: 3, topology: [airPlay])
        ]
        let currentNameProfile = [
            assignment(browserID, bundleIdentifier: "Browser", order: 0, topology: [current]),
            assignment(editorOneID, bundleIdentifier: "Editor", order: 1, topology: [current]),
            assignment(missingID, bundleIdentifier: "Notes", order: 2, topology: [current])
        ]

        let migrated = DisplayPersistenceMigration.assignments(
            currentNameProfile + airPlayProfile,
            current: [current]
        )

        XCTAssertEqual(migrated.map(\.id), [editorOneID, editorTwoID, browserID, terminalID, missingID])
        XCTAssertEqual(Set(migrated.map(\.id)).count, 5)
        XCTAssertTrue(migrated.allSatisfy {
            $0.displayTopology?.map(\.storageKey) == [current.storageKey]
        })
        XCTAssertEqual(migrated.map(\.order), Array(0..<5))
    }

    func testDisplayCanonicalizationPreservesSparseOrphanSwitcherSlots() {
        let legacy = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: " (AirPlay)"
        )
        let current = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: "LG HDR WQHD+",
            stableIdentifier: "DC1396D7-D35F-41F7-8E62-D41BA8C4085B"
        )
        let sectionID = UUID()
        func orphan(order: Int) -> PersistedWindowAssignment {
            PersistedWindowAssignment(
                id: UUID(),
                sectionID: sectionID,
                additionalSectionIDs: [],
                bundleIdentifier: "com.example.Editor",
                processIdentifier: 42,
                accessibilityIdentifier: nil,
                title: "Closed window \(order)",
                windowOrdinal: order,
                order: order,
                isActive: false,
                orphanedAt: Date(),
                awaitsWindowReopen: true,
                displayTopology: [legacy]
            )
        }
        let closedLast = orphan(order: 5)
        let closedFirst = orphan(order: 0)
        let model = makeModel(mock: MockAccessibility())
        model.orphanedAssignments = [closedLast, closedFirst]

        model.canonicalizeDisplayPersistence(using: [currentDisplay(
            fingerprint: current,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )])

        XCTAssertEqual(model.orphanedAssignments.map(\.id), [closedLast.id, closedFirst.id])
        XCTAssertEqual(model.orphanedAssignments.map(\.order), [5, 0])
        XCTAssertTrue(model.orphanedAssignments.allSatisfy {
            $0.displayTopology?.map(\.storageKey) == [current.storageKey]
        })
    }

    func testDisplayAliasMigrationUsesCurrentNameToBreakCompletenessTies() {
        let airPlay = DisplayFingerprint(vendor: 10, model: 20, serial: 30, name: " (AirPlay)")
        let current = DisplayFingerprint(
            vendor: 10,
            model: 20,
            serial: 30,
            name: "LG HDR WQHD+",
            stableIdentifier: "E60F652A-F6B5-43FC-A162-FA8EF73A1795"
        )
        let airPlaySection = UUID()
        let currentSection = UUID()
        let migratedLayouts = DisplayPersistenceMigration.layouts(
            [
                DisplayLayout(fingerprint: airPlay, root: .leaf(id: airPlaySection)),
                DisplayLayout(fingerprint: current, root: .leaf(id: currentSection))
            ],
            current: [current]
        ).layouts
        XCTAssertEqual(migratedLayouts.first?.root.leafIDs, [currentSection])

        let first = UUID()
        let second = UUID()
        func assignment(
            _ id: UUID,
            order: Int,
            topology: [DisplayFingerprint]
        ) -> PersistedWindowAssignment {
            PersistedWindowAssignment(
                id: id,
                sectionID: currentSection,
                additionalSectionIDs: [],
                bundleIdentifier: id.uuidString,
                processIdentifier: 42,
                accessibilityIdentifier: nil,
                title: id.uuidString,
                windowOrdinal: order,
                order: order,
                isActive: order == 1,
                displayTopology: topology
            )
        }
        let migratedAssignments = DisplayPersistenceMigration.assignments(
            [
                assignment(first, order: 0, topology: [airPlay]),
                assignment(second, order: 1, topology: [airPlay]),
                assignment(second, order: 0, topology: [current]),
                assignment(first, order: 1, topology: [current])
            ],
            current: [current]
        )

        XCTAssertEqual(migratedAssignments.map(\.id), [second, first])
    }

    func testApplicationSplitSeparatorAppearsOnEligibleHoverAndStaysForActivePair() {
        XCTAssertFalse(ApplicationSplitSeparatorState.showsIcon(
            isActive: false,
            isEligible: true,
            isHovered: false
        ))
        XCTAssertTrue(ApplicationSplitSeparatorState.showsIcon(
            isActive: false,
            isEligible: true,
            isHovered: true
        ))
        XCTAssertTrue(ApplicationSplitSeparatorState.showsIcon(
            isActive: true,
            isEligible: true,
            isHovered: false
        ))
        XCTAssertFalse(ApplicationSplitSeparatorState.showsIcon(
            isActive: false,
            isEligible: false,
            isHovered: true
        ))
        // A linked pair keeps the glyph but drops the bordered button, which
        // only comes back under the pointer that can click it.
        XCTAssertFalse(ApplicationSplitSeparatorState.showsChrome(
            isActive: true,
            isEligible: false,
            isHovered: false
        ))
        XCTAssertTrue(ApplicationSplitSeparatorState.showsChrome(
            isActive: true,
            isEligible: false,
            isHovered: true
        ))
        XCTAssertTrue(ApplicationSplitSeparatorState.showsChrome(
            isActive: false,
            isEligible: true,
            isHovered: true
        ))
        XCTAssertFalse(ApplicationSplitSeparatorState.showsChrome(
            isActive: false,
            isEligible: false,
            isHovered: true
        ))
        XCTAssertEqual(ApplicationSplitSeparatorLayout.expandedWidth(scale: 1), 11.5)
        XCTAssertEqual(ApplicationSplitSeparatorLayout.iconPointSize(scale: 1), 7.5)
        XCTAssertEqual(ApplicationSplitSeparatorLayout.hoverOutset, 2)
        XCTAssertEqual(ApplicationSplitSeparatorLayout.applicationSpacing, 8)
    }

    func testApplicationSplitButtonStaysClearOfTheHighlightBoxesAtEverySwitcherSize() {
        // The layout slot is a divider's width at every switcher size, so the
        // gap between two application groups never depends on the split
        // control: only its overhang, which grows inside that gap, does.
        for scale in [1.0, 1.5, 2.0, 3.0] {
            let expanded = ApplicationSplitSeparatorLayout.expandedWidth(scale: scale)
            let overhang = ApplicationSplitSeparatorLayout.horizontalOverhang(scale: scale)
            XCTAssertEqual(
                expanded - 2 * overhang,
                ApplicationSplitSeparatorLayout.collapsedWidth,
                accuracy: 0.0001
            )
            XCTAssertGreaterThan(overhang, 0)
            // The gap is fixed while the switcher scales, so the button has to
            // stop growing to keep its clearance on both sides.
            XCTAssertGreaterThanOrEqual(
                (ApplicationSplitSeparatorLayout.gapWidth - expanded) / 2,
                ApplicationSplitSeparatorLayout.buttonClearance
            )
            // The button is a square around its glyph, never the strip's full
            // height, and the glyph keeps its margin inside the border.
            XCTAssertEqual(ApplicationSplitSeparatorLayout.buttonSide(scale: scale), expanded)
            XCTAssertLessThan(
                ApplicationSplitSeparatorLayout.buttonSide(scale: scale),
                WindowSwitcherMetrics(scale: scale).buttonHeight
            )
            XCTAssertLessThanOrEqual(
                ApplicationSplitSeparatorLayout.iconPointSize(scale: scale),
                expanded - 2 * ApplicationSplitSeparatorLayout.iconInset
            )
        }
    }

    func testApplicationSplitButtonRoundsLikeTheSwitcherButtonsWithoutTurningIntoACircle() {
        for scale in [1.0, 1.5, 3.0] {
            let radius = ApplicationSplitSeparatorLayout.cornerRadius(scale: scale)
            let side = ApplicationSplitSeparatorLayout.expandedWidth(scale: scale)
            XCTAssertGreaterThan(radius, 0)
            XCTAssertLessThanOrEqual(radius, WindowSwitcherMetrics(scale: scale).cornerRadius)
            // Rounded, but a rounded square rather than a circle.
            XCTAssertLessThanOrEqual(radius, side / 3)
        }
    }

    func testSectionAllowsIndependentPairsButOnlyOnePairPerApplication() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let windows = (0..<4).map {
            managedWindow(bundleIdentifier: "app.\($0)", ordinal: $0)
        }
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: windows)
        for window in windows {
            mock.windowSnapshotsByHandle[window.handle] = snapshot(
                handle: window.handle,
                title: window.title
            )
        }

        model.toggleApplicationSplit(
            first: windows[0].bundleIdentifier,
            second: windows[1].bundleIdentifier,
            inSection: sectionID
        )
        model.toggleApplicationSplit(
            first: windows[2].bundleIdentifier,
            second: windows[3].bundleIdentifier,
            inSection: sectionID
        )

        XCTAssertEqual(model.applicationSplitPairs[sectionID]?.count, 2)
        XCTAssertFalse(model.canPairApplications(
            windows[1].bundleIdentifier,
            windows[2].bundleIdentifier,
            inSection: sectionID
        ))
    }

    func testDroppingApplicationSplitReflowsTheSurvivingPartnerBackToTheWholeSection() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        for window in [first, second] {
            mock.windowSnapshotsByHandle[window.handle] = snapshot(
                handle: window.handle,
                title: window.title
            )
        }
        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )
        let content = try XCTUnwrap(model.contentFrame(forSection: sectionID))
        XCTAssertLessThan(
            try XCTUnwrap(model.contentFrame(
                forApplication: second.bundleIdentifier,
                inSection: sectionID
            )).width,
            content.width
        )

        let requestCountBeforeDetach = mock.setFrameRequests.count
        model.detach(windowID: first.id)

        XCTAssertNil(model.applicationSplitPairs[sectionID])
        let survivor = try XCTUnwrap(
            mock.setFrameRequests
                .dropFirst(requestCountBeforeDetach)
                .last { $0.window == second.handle }?
                .frame
        )
        XCTAssertEqual(survivor.width, content.width, accuracy: 0.5)
    }

    func testClosingAndReopeningSplitWindowSuspendsAndRestoresSplitGeometry() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(
            bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier),
            ordinal: 0,
            pid: pid
        )
        let second = managedWindow(
            bundleIdentifier: "com.example.SplitPartner",
            ordinal: 1,
            pid: pid + 1
        )
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [first, second],
            activeWindowID: second.id
        )
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title, pid: first.pid),
            second.handle: snapshot(handle: second.handle, title: second.title, pid: second.pid)
        ]
        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )
        let pair = try XCTUnwrap(model.applicationSplitPairs[sectionID]?.first)
        let wholeSection = try XCTUnwrap(model.contentFrame(forSection: sectionID))

        let requestCountBeforeClose = mock.setFrameRequests.count
        model.confirmWindowDestroyed(first.handle)

        XCTAssertEqual(model.applicationSplitPairs[sectionID], [pair])
        XCTAssertEqual(
            model.contentFrame(forApplication: second.bundleIdentifier, inSection: sectionID),
            wholeSection
        )
        let expandedFrame = try XCTUnwrap(
            mock.setFrameRequests
                .dropFirst(requestCountBeforeClose)
                .last { $0.window == second.handle }?
                .frame
        )
        XCTAssertEqual(expandedFrame.width, wholeSection.width, accuracy: 0.5)

        let reopenedHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let reopened = snapshot(
            handle: reopenedHandle,
            title: "Reopened",
            pid: pid
        )
        mock.windowSnapshots = [reopened]
        mock.windowSnapshotsByHandle[reopenedHandle] = reopened
        mock.listedWindowHandles = [reopenedHandle]
        let requestCountBeforeReopen = mock.setFrameRequests.count

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(reopenedHandle, pid: pid),
            .attached
        )
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [first.id, second.id])
        XCTAssertLessThan(
            try XCTUnwrap(model.contentFrame(
                forApplication: second.bundleIdentifier,
                inSection: sectionID
            )).width,
            wholeSection.width
        )
        XCTAssertEqual(model.applicationSplitPairs[sectionID], [pair])
        let reopenRequests = mock.setFrameRequests.dropFirst(requestCountBeforeReopen)
        let expectedSecondFrame = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forApplication: second.bundleIdentifier, inSection: sectionID)
        ))
        XCTAssertTrue(reopenRequests.contains {
            $0.window == second.handle && $0.frame == expectedSecondFrame
        })
        XCTAssertFalse(reopenRequests.contains {
            $0.window == reopenedHandle
                && abs($0.frame.width - wholeSection.width) < 0.5
        })
    }

    func testClosingUnpairedWindowDoesNotReflowUnrelatedWindows() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        mock.windowSnapshotsByHandle[second.handle] = snapshot(
            handle: second.handle,
            title: second.title
        )

        let requestCountBeforeClose = mock.setFrameRequests.count
        model.confirmWindowDestroyed(first.handle)

        XCTAssertEqual(mock.setFrameRequests.count, requestCountBeforeClose)
    }

    func testAutomaticSplitReactivationPreservesExistingCompatibilityError() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let incomingBundleIdentifier = try XCTUnwrap(
            model.runningApplication(pid: pid)?.bundleIdentifier
        )
        let survivor = managedWindow(
            bundleIdentifier: "com.example.SplitPartner",
            ordinal: 1,
            pid: pid + 1
        )
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [survivor])
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: incomingBundleIdentifier,
            secondBundleIdentifier: survivor.bundleIdentifier
        )]
        mock.windowSnapshotsByHandle[survivor.handle] = snapshot(
            handle: survivor.handle,
            title: survivor.title,
            pid: survivor.pid
        )
        mock.setFrameErrorsByHandle[survivor.handle] = [AccessibilityClientError.frameRejected]
        model.compatibilityError = "Existing compatibility result"
        let incomingHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let incoming = snapshot(handle: incomingHandle, title: "Incoming", pid: pid)
        mock.windowSnapshotsByHandle[incomingHandle] = incoming

        XCTAssertTrue(model.attach(
            window: incoming,
            to: sectionID,
            focusAfterAttachment: false,
            reportsCompatibilityErrors: false
        ))
        XCTAssertEqual(model.compatibilityError, "Existing compatibility result")
    }

    func testSwitcherMovementMovesPairedApplicationsAsOneUnit() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1)
        let third = managedWindow(bundleIdentifier: "third", ordinal: 2)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [first, second, third],
            activeWindowID: first.id
        )
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: second.bundleIdentifier
        )]
        mock.focusedHandle = first.handle

        model.performShortcut(.moveApplicationLater)

        XCTAssertEqual(
            model.sections[sectionID]?.windows.map(\.bundleIdentifier),
            [third.bundleIdentifier, first.bundleIdentifier, second.bundleIdentifier]
        )
    }

    func testSwitcherDragMovesPairedApplicationsAsOneUnit() {
        let pair = ApplicationSplitPair(
            firstBundleIdentifier: "first",
            secondBundleIdentifier: "second"
        )
        let pairItem = SectionBarDragItem.applicationPair(pair)
        let thirdItem = SectionBarDragItem.application("third")
        let drag = SectionBarDrag(
            item: pairItem,
            siblings: [pairItem, thirdItem],
            frames: [
                pairItem: CGRect(x: 0, y: 0, width: 100, height: 30),
                thirdItem: CGRect(x: 120, y: 0, width: 40, height: 30)
            ],
            translation: 200
        )

        XCTAssertEqual(drag.reorderedSiblings, [thirdItem, pairItem])
    }

    func testApplicationPairResizesPersistsRaisesAndUnpairs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fingerprint = DisplayFingerprint(vendor: 9, model: 8, serial: 7, name: "Test")
        let display = currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        let displays = MockDisplayProvider([display])
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            directory: directory,
            displayProvider: { displays.displays }
        )
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [first, second],
            activeWindowID: first.id
        )
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title),
            second.handle: snapshot(handle: second.handle, title: second.title)
        ]

        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )

        let pair = try XCTUnwrap(model.applicationSplitPairs[sectionID]?.first)
        XCTAssertEqual(pair.firstBundleIdentifier, first.bundleIdentifier)
        XCTAssertEqual(pair.secondBundleIdentifier, second.bundleIdentifier)
        let firstFrame = try XCTUnwrap(model.contentFrame(
            forApplication: first.bundleIdentifier,
            inSection: sectionID
        ))
        let secondFrame = try XCTUnwrap(model.contentFrame(
            forApplication: second.bundleIdentifier,
            inSection: sectionID
        ))
        XCTAssertEqual(firstFrame.maxX + DisplayLayout.defaultGutter, secondFrame.minX)
        XCTAssertEqual(mock.raisedHandles, [second.handle, first.handle])

        let stored = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
        XCTAssertEqual(
            stored.first { $0.bundleIdentifier == first.bundleIdentifier }?.splitPartnerBundleIdentifier,
            second.bundleIdentifier
        )
        XCTAssertEqual(
            stored.first { $0.bundleIdentifier == second.bundleIdentifier }?.splitPartnerBundleIdentifier,
            first.bundleIdentifier
        )

        mock.resetRaiseRequests()
        var focusedHandles: [AXWindowHandle] = []
        mock.onFocus = { handle, _ in focusedHandles.append(handle) }
        model.focus(windowID: first.id)
        XCTAssertEqual(focusedHandles, [second.handle, first.handle])
        XCTAssertEqual(mock.focusedHandle, first.handle)

        focusedHandles.removeAll()
        model.focus(windowID: second.id)
        XCTAssertEqual(focusedHandles, [first.handle, second.handle])
        XCTAssertEqual(mock.focusedHandle, second.handle)

        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )
        XCTAssertNil(model.applicationSplitPairs[sectionID])
        XCTAssertEqual(
            model.contentFrame(forApplication: first.bundleIdentifier, inSection: sectionID),
            model.contentFrame(forSection: sectionID)
        )
    }

    func testFocusingSplitGroupHidesAndLaterRestoresOtherApplicationsInItsSection() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let foreignPIDs = try foreignApplicationPIDs(2)
        let firstHandle = try attachWindow(
            titled: "First",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )
        let partnerHandle = try attachWindow(
            titled: "Partner",
            pid: foreignPIDs[0],
            to: sectionID,
            in: model,
            mock: mock
        )
        let hiddenHandle = try attachWindow(
            titled: "Behind",
            pid: foreignPIDs[1],
            to: sectionID,
            in: model,
            mock: mock
        )
        let focused = try XCTUnwrap(model.managedWindow(matching: firstHandle))
        let partner = try XCTUnwrap(model.managedWindow(matching: partnerHandle))
        let hidden = try XCTUnwrap(model.managedWindow(matching: hiddenHandle))
        try XCTSkipIf(
            Set([focused.bundleIdentifier, partner.bundleIdentifier, hidden.bundleIdentifier]).count < 3,
            "Needs three distinct running applications"
        )
        model.sections[sectionID]?.activeWindowID = focused.id
        model.focusedManagedWindowID = focused.id

        model.toggleApplicationSplit(
            first: focused.bundleIdentifier,
            second: partner.bundleIdentifier,
            inSection: sectionID
        )

        // The overlay is nonactivating, so creating the split while one of its
        // applications is already focused must hide the old full-section app
        // without waiting for another focus notification.
        XCTAssertEqual(mock.hideRequests.map(\.pid), [hidden.pid])
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])

        model.focus(windowID: focused.id)

        XCTAssertEqual(mock.focusedHandle, focused.handle)
        XCTAssertEqual(mock.hideRequests.map(\.pid), [hidden.pid])
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(mock.hiddenPIDs.contains(hidden.pid))

        model.toggleApplicationSplit(
            first: focused.bundleIdentifier,
            second: partner.bundleIdentifier,
            inSection: sectionID
        )

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true, false])
        XCTAssertFalse(mock.hiddenPIDs.contains(hidden.pid))

        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: focused.bundleIdentifier,
            secondBundleIdentifier: partner.bundleIdentifier
        )]
        model.focus(windowID: focused.id)
        model.focus(windowID: hidden.id)

        XCTAssertEqual(mock.hideRequests.map(\.pid), Array(repeating: hidden.pid, count: 4))
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true, false, true, false])
        XCTAssertFalse(mock.hiddenPIDs.contains(hidden.pid))

        // A later Command-H belongs to the user. Selecting the split group
        // must not claim that hidden state as something Panoptos can restore.
        mock.hiddenPIDs.insert(hidden.pid)
        model.focus(windowID: focused.id)

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true, false, true, false])
        XCTAssertTrue(mock.hiddenPIDs.contains(hidden.pid))
        XCTAssertTrue(model.applicationSplitHiddenApplications.isEmpty)

        // A state change with unchanged focus also reconciles visibility. Once
        // this application's last window leaves the section, it is no longer
        // allowed to remain hidden behind the split.
        mock.hiddenPIDs.remove(hidden.pid)
        model.focus(windowID: hidden.id)
        model.focus(windowID: focused.id)
        XCTAssertEqual(mock.hideRequests.last?.hidden, true)
        model.sections[sectionID]?.windows.removeAll { $0.id == hidden.id }
        mock.focusedHandle = focused.handle

        model.refreshRuntime(reportedFrontmostPID: focused.pid)

        XCTAssertEqual(mock.hideRequests.suffix(2).map(\.hidden), [true, false])
        XCTAssertFalse(mock.hiddenPIDs.contains(hidden.pid))
    }

    func testObservedFocusOnSplitGroupAlsoHidesOtherApplicationsInItsSection() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let foreignPIDs = try foreignApplicationPIDs(2)
        let focusedHandle = try attachWindow(
            titled: "First",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )
        let partnerHandle = try attachWindow(
            titled: "Partner",
            pid: foreignPIDs[0],
            to: sectionID,
            in: model,
            mock: mock
        )
        let behindHandle = try attachWindow(
            titled: "Behind",
            pid: foreignPIDs[1],
            to: sectionID,
            in: model,
            mock: mock
        )
        let focused = try XCTUnwrap(model.managedWindow(matching: focusedHandle))
        let partner = try XCTUnwrap(model.managedWindow(matching: partnerHandle))
        let behind = try XCTUnwrap(model.managedWindow(matching: behindHandle))
        try XCTSkipIf(
            Set([focused.bundleIdentifier, partner.bundleIdentifier, behind.bundleIdentifier]).count < 3,
            "Needs three distinct running applications"
        )
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: focused.bundleIdentifier,
            secondBundleIdentifier: partner.bundleIdentifier
        )]
        mock.focusedHandle = focused.handle

        XCTAssertTrue(model.refreshFocusedWindow(
            reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier
        ))

        XCTAssertEqual(mock.raisedHandles, [partner.handle])
        XCTAssertEqual(mock.hideRequests.map(\.pid), [behind.pid])
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
    }

    func testSplitGroupDoesNotHideAnApplicationWithAWindowInAnotherVisibleSection() throws {
        let splitSectionID = UUID()
        let otherSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: splitSectionID),
            second: .leaf(id: otherSectionID)
        ))
        let foreignPIDs = try foreignApplicationPIDs(2)
        let focusedHandle = try attachWindow(
            titled: "First",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: splitSectionID,
            in: model,
            mock: mock
        )
        let partnerHandle = try attachWindow(
            titled: "Partner",
            pid: foreignPIDs[0],
            to: splitSectionID,
            in: model,
            mock: mock
        )
        let behindHandle = try attachWindow(
            titled: "Behind split",
            pid: foreignPIDs[1],
            to: splitSectionID,
            in: model,
            mock: mock
        )
        _ = try attachWindow(
            titled: "Same app, other section",
            pid: foreignPIDs[1],
            to: otherSectionID,
            in: model,
            mock: mock
        )
        let focused = try XCTUnwrap(model.managedWindow(matching: focusedHandle))
        let partner = try XCTUnwrap(model.managedWindow(matching: partnerHandle))
        let behind = try XCTUnwrap(model.managedWindow(matching: behindHandle))
        try XCTSkipIf(
            Set([focused.bundleIdentifier, partner.bundleIdentifier, behind.bundleIdentifier]).count < 3,
            "Needs three distinct running applications"
        )
        model.applicationSplitPairs[splitSectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: focused.bundleIdentifier,
            secondBundleIdentifier: partner.bundleIdentifier
        )]

        model.focus(windowID: focused.id)

        XCTAssertTrue(mock.hideRequests.isEmpty)
        XCTAssertFalse(mock.hiddenPIDs.contains(behind.pid))
        XCTAssertTrue(model.applicationSplitHiddenApplications.isEmpty)

        model.toggleFocusMode(for: splitSectionID)

        XCTAssertEqual(mock.hideRequests.map(\.pid), [behind.pid])
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(mock.hiddenPIDs.contains(behind.pid))

        model.toggleFocusMode(for: splitSectionID)

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true, false])
        XCTAssertFalse(mock.hiddenPIDs.contains(behind.pid))
    }

    func testFocusingAnotherSectionKeepsTheActiveSplitGroupBackgroundHidden() throws {
        let splitSectionID = UUID()
        let otherSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: splitSectionID),
            second: .leaf(id: otherSectionID)
        ))
        let foreignPIDs = try foreignApplicationPIDs(3)
        let firstHandle = try attachWindow(
            titled: "First split half",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: splitSectionID,
            in: model,
            mock: mock
        )
        let partnerHandle = try attachWindow(
            titled: "Second split half",
            pid: foreignPIDs[0],
            to: splitSectionID,
            in: model,
            mock: mock
        )
        let behindHandle = try attachWindow(
            titled: "Behind split",
            pid: foreignPIDs[1],
            to: splitSectionID,
            in: model,
            mock: mock
        )
        let otherHandle = try attachWindow(
            titled: "Other section",
            pid: foreignPIDs[2],
            to: otherSectionID,
            in: model,
            mock: mock
        )
        let first = try XCTUnwrap(model.managedWindow(matching: firstHandle))
        let partner = try XCTUnwrap(model.managedWindow(matching: partnerHandle))
        let behind = try XCTUnwrap(model.managedWindow(matching: behindHandle))
        let other = try XCTUnwrap(model.managedWindow(matching: otherHandle))
        try XCTSkipIf(
            Set([first, partner, behind, other].map(\.bundleIdentifier)).count < 4,
            "Needs four distinct running applications"
        )
        model.applicationSplitPairs[splitSectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: partner.bundleIdentifier
        )]

        model.focus(windowID: first.id)

        XCTAssertEqual(mock.hideRequests.map(\.pid), [behind.pid])
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])

        model.focus(windowID: other.id)

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(mock.hiddenPIDs.contains(behind.pid))

        model.focus(windowID: behind.id)

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true, false])
        XCTAssertFalse(mock.hiddenPIDs.contains(behind.pid))
    }

    func testUnmanagedFocusKeepsTheActiveSplitGroupBackgroundHidden() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let foreignPIDs = try foreignApplicationPIDs(2)
        let firstHandle = try attachWindow(
            titled: "First split half",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )
        let partnerHandle = try attachWindow(
            titled: "Second split half",
            pid: foreignPIDs[0],
            to: sectionID,
            in: model,
            mock: mock
        )
        let behindHandle = try attachWindow(
            titled: "Behind split",
            pid: foreignPIDs[1],
            to: sectionID,
            in: model,
            mock: mock
        )
        let first = try XCTUnwrap(model.managedWindow(matching: firstHandle))
        let partner = try XCTUnwrap(model.managedWindow(matching: partnerHandle))
        let behind = try XCTUnwrap(model.managedWindow(matching: behindHandle))
        try XCTSkipIf(
            Set([first, partner, behind].map(\.bundleIdentifier)).count < 3,
            "Needs three distinct running applications"
        )
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: partner.bundleIdentifier
        )]
        model.focus(windowID: first.id)
        let unmanagedPID = foreignPIDs[1] + 100_000

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])

        XCTAssertTrue(model.refreshFocusedWindow(reportedFrontmostPID: unmanagedPID))

        XCTAssertNil(model.focusedManagedWindowID)
        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(mock.hiddenPIDs.contains(behind.pid))

        model.refreshRuntime(reportedFrontmostPID: unmanagedPID)

        XCTAssertEqual(mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(mock.hiddenPIDs.contains(behind.pid))
    }

    func testApplicationPairRollsBackEveryAttemptedWindowWhenAWindowRejectsTheSplit() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        let original = CGRect(x: 25, y: 35, width: 640, height: 480)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title, frame: original),
            second.handle: snapshot(handle: second.handle, title: second.title, frame: original)
        ]
        mock.setFrameErrorsByHandle[second.handle] = [AccessibilityClientError.frameRejected]

        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )

        XCTAssertNil(model.applicationSplitPairs[sectionID])
        XCTAssertEqual(mock.setFrameRequests.suffix(2).map(\.window), [first.handle, second.handle])
        XCTAssertEqual(mock.setFrameRequests.suffix(2).map(\.frame), [original, original])
        XCTAssertEqual(
            model.compatibilityError,
            "Could not split these applications: The application did not accept the requested window size."
        )
    }

    func testMinimizedApplicationWindowAdoptsItsSplitHalfOnNextReflow() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        var minimized = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        minimized.isMinimized = true
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, minimized])
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title),
            minimized.handle: snapshot(handle: minimized.handle, title: minimized.title)
        ]

        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: minimized.bundleIdentifier,
            inSection: sectionID
        )

        XCTAssertFalse(mock.setFrameRequests.contains { $0.window == minimized.handle })
        let requestCountBeforeRestore = mock.setFrameRequests.count
        model.sections[sectionID]?.windows[1].isMinimized = false
        XCTAssertTrue(model.reflowManagedWindows())
        let expected = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forApplication: minimized.bundleIdentifier, inSection: sectionID)
        ))
        XCTAssertTrue(mock.setFrameRequests.dropFirst(requestCountBeforeRestore).contains {
            $0.window == minimized.handle && $0.frame == expected
        })
    }

    func testApplicationPairReflowsFromSideBySideToTopAndBottomAfterAspectChange() throws {
        let fingerprint = DisplayFingerprint(vendor: 10, model: 11, serial: 12, name: "Resizable")
        let sectionID = UUID()
        let displays = MockDisplayProvider([currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )])
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { displays.displays }
        )
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title),
            second.handle: snapshot(handle: second.handle, title: second.title)
        ]
        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )
        XCTAssertEqual(model.applicationSplitAxis(inSection: sectionID), .horizontal)

        let requestCountBeforeResize = mock.setFrameRequests.count
        displays.displays = [currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 500, height: 900)
        )]
        model.refreshDisplays()

        XCTAssertEqual(model.applicationSplitAxis(inSection: sectionID), .vertical)
        let expectedFirst = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forApplication: first.bundleIdentifier, inSection: sectionID)
        ))
        let expectedSecond = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forApplication: second.bundleIdentifier, inSection: sectionID)
        ))
        XCTAssertEqual(
            mock.setFrameRequests.dropFirst(requestCountBeforeResize).map(\.frame),
            [expectedFirst, expectedSecond]
        )
        // Accessibility coordinates are top-down, so the earlier/top app has
        // the smaller y value after conversion from AppKit coordinates.
        XCTAssertLessThan(expectedFirst.minY, expectedSecond.minY)
    }

    func testClearingAShortcutRecordsItAsDisabledAndRestoringDefaultsForgetsThat() throws {
        let mock = MockAccessibility()
        let model = makeModel(mock: mock)

        model.setShortcut(nil, for: .spanWindowRight)

        XCTAssertNil(model.shortcuts[.spanWindowRight])
        XCTAssertEqual(model.disabledShortcutCommands, [.spanWindowRight])
        XCTAssertEqual(model.shortcutPersistence.loadState().disabledCommands, [.spanWindowRight])

        let relaunched = PanoptosModel(
            accessibility: mock,
            persistence: model.persistence,
            windowAssignmentPersistence: model.windowAssignmentPersistence,
            settingsPersistence: model.settingsPersistence,
            shortcutPersistence: model.shortcutPersistence,
            shortcutRegistrar: MockShortcutRegistrar(),
            keepAwakeController: MockKeepAwakeController(),
            loginItemController: MockLoginItemController(),
            updateController: MockUpdateController()
        )
        XCTAssertNil(relaunched.shortcuts[.spanWindowRight])
        XCTAssertEqual(relaunched.disabledShortcutCommands, [.spanWindowRight])

        relaunched.setShortcut(ShortcutCommand.spanWindowRight.defaultShortcut, for: .spanWindowRight)
        XCTAssertTrue(relaunched.disabledShortcutCommands.isEmpty)

        relaunched.setShortcut(nil, for: .spanWindowRight)
        relaunched.resetShortcuts()
        XCTAssertEqual(relaunched.shortcuts, ShortcutPersistence.defaults)
        XCTAssertTrue(relaunched.disabledShortcutCommands.isEmpty)
        XCTAssertTrue(relaunched.shortcutPersistence.loadState().disabledCommands.isEmpty)
    }

    func testSpanningDoesNotLeaveASingleSectionDisplay() throws {
        for direction in [HorizontalDirection.left, .right] {
            let sectionID = UUID()
            let display = currentDisplay(
                fingerprint: DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Source"),
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            let neighbor = currentDisplay(
                fingerprint: DisplayFingerprint(vendor: 1, model: 1, serial: 2, name: "Neighbor"),
                frame: CGRect(x: direction == .left ? -1200 : 1200, y: 0, width: 1200, height: 800)
            )
            let mock = MockAccessibility()
            let model = makeModel(
                mock: mock,
                root: .leaf(id: sectionID),
                displayProvider: { [display, neighbor] }
            )
            let window = managedWindow(bundleIdentifier: "com.example.Window", ordinal: 0)
            model.sections[sectionID] = LayoutSectionState(
                id: sectionID,
                windows: [window],
                activeWindowID: window.id
            )
            mock.focusedHandle = window.handle
            model.compatibilityError = "Existing compatibility error"

            model.spanFocusedWindow(direction)

            XCTAssertTrue(mock.setFrameRequests.isEmpty)
            XCTAssertEqual(model.sections.keys.sorted { $0.uuidString < $1.uuidString }, [sectionID])
            XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [window.id])
            XCTAssertEqual(model.sections[sectionID]?.activeWindowID, window.id)
            XCTAssertEqual(model.compatibilityError, "Existing compatibility error")
        }
    }

    func testSpanningExpandsWithinDisplayAndStopsAtItsEdge() throws {
        for direction in [HorizontalDirection.left, .right] {
            let leftSection = UUID()
            let middleSection = UUID()
            let rightSection = UUID()
            let sourceSection = direction == .left ? rightSection : leftSection
            let display = currentDisplay(
                fingerprint: DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Source"),
                frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
            )
            let neighbor = currentDisplay(
                fingerprint: DisplayFingerprint(vendor: 1, model: 1, serial: 2, name: "Neighbor"),
                frame: CGRect(x: direction == .left ? -1200 : 1200, y: 0, width: 1200, height: 800)
            )
            let mock = MockAccessibility()
            let model = makeModel(
                mock: mock,
                root: .split(
                    id: UUID(),
                    axis: .horizontal,
                    ratio: 1.0 / 3.0,
                    first: .leaf(id: leftSection),
                    second: .split(
                        id: UUID(),
                        axis: .horizontal,
                        ratio: 0.5,
                        first: .leaf(id: middleSection),
                        second: .leaf(id: rightSection)
                    )
                ),
                displayProvider: { [display, neighbor] }
            )
            let window = managedWindow(bundleIdentifier: "com.example.Window", ordinal: 0)
            model.sections[sourceSection] = LayoutSectionState(
                id: sourceSection,
                windows: [window],
                activeWindowID: window.id
            )
            mock.focusedHandle = window.handle

            model.spanFocusedWindow(direction)

            let twoSectionID = SpannedSectionIdentity.id(covering: [sourceSection, middleSection])
            XCTAssertNil(model.sections[sourceSection])
            XCTAssertEqual(model.sections[twoSectionID]?.coveredSectionIDs, [sourceSection, middleSection])
            XCTAssertEqual(model.sections[twoSectionID]?.windows.map(\.id), [window.id])
            XCTAssertEqual(model.sections[twoSectionID]?.activeWindowID, window.id)
            XCTAssertEqual(mock.setFrameRequests.count, 1)
            XCTAssertEqual(mock.setFrameRequests.last?.frame, PanoptosModel.accessibilityFrame(
                fromAppKitFrame: try XCTUnwrap(model.contentFrame(forSectionIDs: [sourceSection, middleSection]))
            ))

            model.spanFocusedWindow(direction)

            let threeSectionID = SpannedSectionIdentity.id(covering: [leftSection, middleSection, rightSection])
            XCTAssertNil(model.sections[twoSectionID])
            XCTAssertEqual(
                model.sections[threeSectionID]?.coveredSectionIDs,
                [leftSection, middleSection, rightSection]
            )
            XCTAssertEqual(model.sections[threeSectionID]?.windows.map(\.id), [window.id])
            XCTAssertEqual(mock.setFrameRequests.count, 2)
            let expandedFrame = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
                model.contentFrame(forSectionIDs: [leftSection, middleSection, rightSection])
            ))
            XCTAssertEqual(mock.setFrameRequests.last?.frame, expandedFrame)
            XCTAssertEqual(
                model.contentFrame(forSection: threeSectionID),
                model.contentFrame(forSectionIDs: [leftSection, middleSection, rightSection])
            )
            let persistedAssignments = try Data(contentsOf: model.windowAssignmentPersistence.url)

            model.spanFocusedWindow(direction)

            XCTAssertEqual(
                model.sections[threeSectionID]?.coveredSectionIDs,
                [leftSection, middleSection, rightSection]
            )
            XCTAssertEqual(mock.setFrameRequests.count, 2)
            XCTAssertEqual(mock.setFrameRequests.last?.frame, expandedFrame)
            XCTAssertEqual(try Data(contentsOf: model.windowAssignmentPersistence.url), persistedAssignments)
        }
    }

    /// The layout used by the layer tests: two sections side by side, the
    /// first holding two windows and the second one, with the first section's
    /// first window spanned across both.
    private struct SpannedLayoutFixture {
        let model: PanoptosModel
        let mock: MockAccessibility
        let firstSectionID: UUID
        let secondSectionID: UUID
        let spannedSectionID: UUID
        let spanned: ManagedWindow
        let sibling: ManagedWindow
        let neighbor: ManagedWindow
    }

    private func makeSpannedLayoutFixture(
        directory: URL? = nil
    ) throws -> SpannedLayoutFixture {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: firstSectionID),
                second: .leaf(id: secondSectionID)
            ),
            directory: directory
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let spannedHandle = try attachWindow(titled: "Spanned", pid: pid, to: firstSectionID, in: model, mock: mock)
        let siblingHandle = try attachWindow(titled: "Sibling", pid: pid, to: firstSectionID, in: model, mock: mock)
        let neighborHandle = try attachWindow(titled: "Neighbor", pid: pid, to: secondSectionID, in: model, mock: mock)
        let spanned = try XCTUnwrap(model.sections[firstSectionID]?.windows.first { $0.handle == spannedHandle })
        let sibling = try XCTUnwrap(model.sections[firstSectionID]?.windows.first { $0.handle == siblingHandle })
        let neighbor = try XCTUnwrap(model.sections[secondSectionID]?.windows.first { $0.handle == neighborHandle })
        model.focus(windowID: spanned.id)
        model.spanFocusedWindow(.right)
        return SpannedLayoutFixture(
            model: model,
            mock: mock,
            firstSectionID: firstSectionID,
            secondSectionID: secondSectionID,
            spannedSectionID: SpannedSectionIdentity.id(covering: [firstSectionID, secondSectionID]),
            spanned: spanned,
            sibling: sibling,
            neighbor: neighbor
        )
    }

    func testSpanningMovesTheWindowIntoItsOwnRaisedSectionAboveTheOldOnes() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model

        XCTAssertEqual(model.sections[fixture.firstSectionID]?.windows.map(\.id), [fixture.sibling.id])
        XCTAssertEqual(model.sections[fixture.firstSectionID]?.activeWindowID, fixture.sibling.id)
        XCTAssertEqual(model.sections[fixture.secondSectionID]?.windows.map(\.id), [fixture.neighbor.id])
        let spannedSection = try XCTUnwrap(model.sections[fixture.spannedSectionID])
        XCTAssertEqual(spannedSection.coveredSectionIDs, [fixture.firstSectionID, fixture.secondSectionID])
        XCTAssertEqual(spannedSection.windows.map(\.id), [fixture.spanned.id])
        XCTAssertEqual(spannedSection.activeWindowID, fixture.spanned.id)
        XCTAssertEqual(model.focusedManagedWindowID, fixture.spanned.id)

        // The spanned section's bars sit above and below the whole spanned
        // area, and it is the layer on top: the sections beneath order out.
        let layoutFrames = model.layoutSectionFrames()
        let union = try XCTUnwrap(layoutFrames[fixture.firstSectionID])
            .union(try XCTUnwrap(layoutFrames[fixture.secondSectionID]))
        XCTAssertEqual(model.sectionFrames()[fixture.spannedSectionID], union)
        XCTAssertNil(layoutFrames[fixture.spannedSectionID])
        XCTAssertEqual(fixture.mock.setFrameRequests.last?.frame, PanoptosModel.accessibilityFrame(
            fromAppKitFrame: try XCTUnwrap(model.contentFrame(forSectionIDs: [fixture.firstSectionID, fixture.secondSectionID]))
        ))
        XCTAssertTrue(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertFalse(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertFalse(model.isSectionOnTop(fixture.secondSectionID))

        // The file keeps naming layout sections: the first covered section in
        // reading order plus the other one.
        let record = try XCTUnwrap(model.savedWindowAssignments.first { $0.id == fixture.spanned.id })
        XCTAssertEqual(record.sectionID, fixture.firstSectionID)
        XCTAssertEqual(record.additionalSectionIDs, [fixture.secondSectionID])
        XCTAssertEqual(record.liveSectionID, fixture.spannedSectionID)
        XCTAssertEqual(record.order, 0)
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(
            model.savedWindowAssignments.first { $0.id == fixture.sibling.id }?.order,
            0
        )
    }

    func testFocusingAWindowUnderASpanLowersTheSpanAndRaisesTheNeighbouringSection() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        var presentedAtRepaint: [Bool] = []
        model.onOverlayPresentationChanged = {
            presentedAtRepaint = [
                model.isSectionOnTop(fixture.spannedSectionID),
                model.isSectionOnTop(fixture.firstSectionID),
                model.isSectionOnTop(fixture.secondSectionID)
            ]
        }
        fixture.mock.resetRaiseRequests()

        model.focus(windowID: fixture.sibling.id)

        XCTAssertEqual(fixture.mock.focusedHandle, fixture.sibling.handle)
        XCTAssertFalse(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertTrue(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertTrue(model.isSectionOnTop(fixture.secondSectionID))
        XCTAssertEqual(presentedAtRepaint, [false, true, true])
        // The other section the span covered comes up too, without being
        // activated, so the spanned window is fully covered.
        XCTAssertEqual(fixture.mock.raisedHandles, [fixture.neighbor.handle])
        XCTAssertEqual(fixture.mock.focusRequests.last?.handle, fixture.sibling.handle)

        fixture.mock.resetRaiseRequests()
        model.focus(windowID: fixture.spanned.id)

        XCTAssertTrue(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertFalse(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertFalse(model.isSectionOnTop(fixture.secondSectionID))
        XCTAssertEqual(presentedAtRepaint, [true, false, false])
        XCTAssertTrue(fixture.mock.raisedHandles.isEmpty)

        fixture.mock.resetRaiseRequests()
        model.focus(windowID: fixture.neighbor.id)

        XCTAssertFalse(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertEqual(fixture.mock.raisedHandles, [fixture.sibling.handle])
    }

    func testFocusChangesMadeOutsidePanoptosSwitchLayersToo() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        let pid = ProcessInfo.processInfo.processIdentifier
        fixture.mock.resetRaiseRequests()

        fixture.mock.focusedHandle = fixture.sibling.handle
        XCTAssertTrue(model.refreshFocusedWindow(reportedFrontmostPID: pid))

        XCTAssertEqual(model.focusedManagedWindowID, fixture.sibling.id)
        XCTAssertFalse(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertTrue(model.isSectionOnTop(fixture.secondSectionID))
        XCTAssertEqual(fixture.mock.raisedHandles, [fixture.neighbor.handle])

        fixture.mock.resetRaiseRequests()
        fixture.mock.focusedHandle = fixture.spanned.handle
        model.refreshRuntime(reportedFrontmostPID: pid)

        XCTAssertEqual(model.focusedManagedWindowID, fixture.spanned.id)
        XCTAssertTrue(model.isSectionOnTop(fixture.spannedSectionID))
        XCTAssertFalse(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertTrue(fixture.mock.raisedHandles.isEmpty)

        // The same focus again is not a layer change and costs no raise.
        model.refreshRuntime(reportedFrontmostPID: pid)
        XCTAssertTrue(fixture.mock.raisedHandles.isEmpty)
    }

    func testSectionShortcutsSweepThroughEveryLayer() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.spanned.handle)

        model.performShortcut(.focusNextSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.neighbor.handle)
        XCTAssertFalse(model.isSectionOnTop(fixture.spannedSectionID))

        model.performShortcut(.focusNextSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.sibling.handle)

        model.performShortcut(.focusNextSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.spanned.handle)
        XCTAssertTrue(model.isSectionOnTop(fixture.spannedSectionID))

        model.performShortcut(.focusPreviousSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.sibling.handle)
        XCTAssertFalse(model.isSectionOnTop(fixture.spannedSectionID))

        model.performShortcut(.focusPreviousSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.neighbor.handle)

        model.performShortcut(.focusPreviousSection)
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.spanned.handle)
    }

    func testMovingASpannedWindowCollapsesItIntoTheSectionAtThatEdge() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.spanned.handle)

        model.moveFocusedWindow(.right)

        XCTAssertNil(model.sections[fixture.spannedSectionID])
        XCTAssertEqual(
            model.sections[fixture.secondSectionID]?.windows.map(\.id),
            [fixture.neighbor.id, fixture.spanned.id]
        )
        XCTAssertEqual(model.sections[fixture.secondSectionID]?.activeWindowID, fixture.spanned.id)
        XCTAssertEqual(fixture.mock.setFrameRequests.last?.frame, PanoptosModel.accessibilityFrame(
            fromAppKitFrame: try XCTUnwrap(model.contentFrame(forSection: fixture.secondSectionID))
        ))
        XCTAssertTrue(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertTrue(model.isSectionOnTop(fixture.secondSectionID))
        let record = try XCTUnwrap(model.savedWindowAssignments.first { $0.id == fixture.spanned.id })
        XCTAssertEqual(record.sectionID, fixture.secondSectionID)
        XCTAssertTrue(record.additionalSectionIDs.isEmpty)

        model.moveFocusedWindow(.left)

        XCTAssertEqual(model.sections[fixture.firstSectionID]?.windows.map(\.id), [fixture.sibling.id, fixture.spanned.id])
    }

    func testSpannedWindowReturnsToItsSpannedSectionAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        firstMock.windowSnapshot = AXWindowSnapshot(
            handle: firstHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "document-window",
            title: "Document",
            frame: CGRect(x: 50, y: 50, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        let firstModel = makeModel(
            mock: firstMock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: firstSectionID),
                second: .leaf(id: secondSectionID)
            ),
            directory: directory
        )
        firstModel.attach(window: try XCTUnwrap(firstMock.windowSnapshot), to: firstSectionID)
        let originalID = try XCTUnwrap(firstModel.sections[firstSectionID]?.activeWindowID)
        firstMock.focusedHandle = firstHandle
        firstModel.spanFocusedWindow(.right)
        let spannedSectionID = SpannedSectionIdentity.id(covering: [firstSectionID, secondSectionID])
        XCTAssertEqual(firstModel.sections[spannedSectionID]?.windows.map(\.id), [originalID])

        let secondMock = MockAccessibility()
        // Nothing is focused while the relaunched model restores, so the file
        // alone decides what it knows about the span.
        secondMock.focusedWindowError = AccessibilityClientError.attribute(
            kAXFocusedWindowAttribute as String,
            .noValue
        )
        let reconstructedHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        secondMock.windowSnapshot = AXWindowSnapshot(
            handle: reconstructedHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "document-window",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )

        let relaunched = makeModel(mock: secondMock, directory: directory)

        XCTAssertNil(relaunched.sections[firstSectionID])
        XCTAssertNil(relaunched.sections[secondSectionID])
        let restored = try XCTUnwrap(relaunched.sections[spannedSectionID])
        XCTAssertEqual(restored.coveredSectionIDs, [firstSectionID, secondSectionID])
        XCTAssertEqual(restored.windows.map(\.id), [originalID])
        XCTAssertEqual(restored.activeWindow?.handle, reconstructedHandle)
        XCTAssertEqual(secondMock.lastSetFrame, PanoptosModel.accessibilityFrame(
            fromAppKitFrame: try XCTUnwrap(relaunched.contentFrame(forSectionIDs: [firstSectionID, secondSectionID]))
        ))
        XCTAssertNil(secondMock.focusedHandle)
        // Layers are session-only: the file does not say the span was on top,
        // so the first focus that lands in it is what raises it.
        XCTAssertFalse(relaunched.isSectionOnTop(spannedSectionID))
        XCTAssertTrue(relaunched.isSectionOnTop(firstSectionID))
        secondMock.focusedWindowError = nil
        secondMock.focusedHandle = reconstructedHandle
        relaunched.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(relaunched.isSectionOnTop(spannedSectionID))
        XCTAssertFalse(relaunched.isSectionOnTop(firstSectionID))
    }

    func testRemovingACoveredSectionFoldsTheSpanBackAndCancelRestoresIt() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        let display = try XCTUnwrap(model.currentDisplays.first)
        model.beginLayoutPreview(for: display)
        var preview = model.layout(for: display)
        preview.root = .leaf(id: fixture.firstSectionID)

        model.preview(preview, migrating: [fixture.secondSectionID: fixture.firstSectionID])

        XCTAssertNil(model.sections[fixture.spannedSectionID])
        XCTAssertNil(model.sections[fixture.secondSectionID])
        XCTAssertEqual(
            Set(model.sections[fixture.firstSectionID]?.windows.map(\.id) ?? []),
            [fixture.sibling.id, fixture.neighbor.id, fixture.spanned.id]
        )
        XCTAssertEqual(model.sections[fixture.firstSectionID]?.activeWindowID, fixture.spanned.id)
        XCTAssertTrue(model.isSectionOnTop(fixture.firstSectionID))

        model.cancelLayoutPreview(for: display)

        XCTAssertEqual(model.sections[fixture.spannedSectionID]?.windows.map(\.id), [fixture.spanned.id])
        XCTAssertEqual(model.sections[fixture.firstSectionID]?.windows.map(\.id), [fixture.sibling.id])
        XCTAssertEqual(model.sections[fixture.secondSectionID]?.windows.map(\.id), [fixture.neighbor.id])
        XCTAssertTrue(model.isSectionOnTop(fixture.spannedSectionID))
    }

    func testRestoringWindowOrderRaisesTheLayerOnTopLast() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model
        let pid = ProcessInfo.processInfo.processIdentifier
        let covered: Set<AXWindowHandle> = [fixture.sibling.handle, fixture.neighbor.handle]

        // The span is on top: the sections beneath come first, the span last.
        fixture.mock.resetRaiseRequests()
        model.beginRestoringActiveWindowOrder(for: [pid])
        XCTAssertEqual(fixture.mock.raisedHandles.count, 3)
        XCTAssertEqual(Set(fixture.mock.raisedHandles.dropLast()), covered)
        XCTAssertEqual(fixture.mock.raisedHandles.last, fixture.spanned.handle)

        // Lowered: the span comes first and the covered sections end on top,
        // matching the menu bars they show.
        model.focus(windowID: fixture.sibling.id)
        fixture.mock.resetRaiseRequests()
        model.beginRestoringActiveWindowOrder(for: [pid])
        XCTAssertEqual(fixture.mock.raisedHandles.count, 3)
        XCTAssertEqual(fixture.mock.raisedHandles.first, fixture.spanned.handle)
        XCTAssertEqual(Set(fixture.mock.raisedHandles.dropFirst()), covered)

        // Restoring only the span still restores the whole stack over its area.
        fixture.mock.resetRaiseRequests()
        model.beginRestoringActiveWindowOrder(for: [pid])
        XCTAssertEqual(fixture.mock.raisedHandles.count, 3)
    }

    func testLoweringASpanRaisesBothHalvesOfASplitBeneathIt() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        ))
        let pid = ProcessInfo.processInfo.processIdentifier
        let spannedHandle = try attachWindow(titled: "Spanned", pid: pid, to: firstSectionID, in: model, mock: mock)
        let siblingHandle = try attachWindow(titled: "Sibling", pid: pid, to: firstSectionID, in: model, mock: mock)
        let left = managedWindow(bundleIdentifier: "com.example.Left", ordinal: 10)
        let right = managedWindow(bundleIdentifier: "com.example.Right", ordinal: 11)
        model.sections[secondSectionID] = LayoutSectionState(
            id: secondSectionID,
            windows: [left, right],
            activeWindowID: left.id
        )
        model.applicationSplitPairs[secondSectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: left.bundleIdentifier,
            secondBundleIdentifier: right.bundleIdentifier
        )]
        let spanned = try XCTUnwrap(model.sections[firstSectionID]?.windows.first { $0.handle == spannedHandle })
        let sibling = try XCTUnwrap(model.sections[firstSectionID]?.windows.first { $0.handle == siblingHandle })
        model.focus(windowID: spanned.id)
        model.spanFocusedWindow(.right)
        mock.resetRaiseRequests()

        model.focus(windowID: sibling.id)

        XCTAssertEqual(mock.raisedHandles, [left.handle, right.handle])
    }

    func testNewWindowJoinsAnApplicationThatLivesOnlyInASpan() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        ))
        let pid = ProcessInfo.processInfo.processIdentifier
        let spannedHandle = try attachWindow(titled: "Spanned", pid: pid, to: firstSectionID, in: model, mock: mock)
        model.spanFocusedWindow(.right)
        let spannedSectionID = SpannedSectionIdentity.id(covering: [firstSectionID, secondSectionID])
        XCTAssertNil(model.sections[firstSectionID])
        XCTAssertEqual(model.sections[spannedSectionID]?.windows.map(\.handle), [spannedHandle])
        // As after a relaunch: nothing remembered about where the application
        // was last focused, and no managed window focused.
        model.lastFocusedSectionByPID.removeAll()
        model.focusedManagedWindowID = nil
        let createdHandle = AXWindowHandle(element: AXUIElementCreateApplication(77))
        let created = snapshot(handle: createdHandle, title: "New", pid: pid)
        mock.windowSnapshotsByHandle[createdHandle] = created
        mock.windowSnapshots = Array(mock.windowSnapshotsByHandle.values)

        let result = model.attachNewlyCreatedWindow(createdHandle, pid: pid, reportedFrontmostPID: -1)

        XCTAssertEqual(result, .attached)
        XCTAssertEqual(model.sections[spannedSectionID]?.windows.map(\.handle), [spannedHandle, createdHandle])
        XCTAssertEqual(mock.setFrameRequests.last?.window, createdHandle)
        XCTAssertEqual(mock.setFrameRequests.last?.frame, PanoptosModel.accessibilityFrame(
            fromAppKitFrame: try XCTUnwrap(model.contentFrame(forSectionIDs: [firstSectionID, secondSectionID]))
        ))
    }

    func testDetachingTheLastSpannedWindowRemovesItsSection() throws {
        let fixture = try makeSpannedLayoutFixture()
        let model = fixture.model

        model.detach(windowID: fixture.spanned.id)

        XCTAssertNil(model.sections[fixture.spannedSectionID])
        XCTAssertTrue(model.isSectionOnTop(fixture.firstSectionID))
        XCTAssertTrue(model.isSectionOnTop(fixture.secondSectionID))
        XCTAssertNil(model.savedWindowAssignments.first { $0.id == fixture.spanned.id })
    }

    func testSpannedSectionIdentityIsStableAndOrderIndependent() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            SpannedSectionIdentity.id(covering: [first, second]),
            SpannedSectionIdentity.id(covering: [second, first])
        )
        XCTAssertNotEqual(
            SpannedSectionIdentity.id(covering: [first, second]),
            SpannedSectionIdentity.id(covering: [first, second, third])
        )
        XCTAssertNotEqual(SpannedSectionIdentity.id(covering: [first, second]), first)
        let record = PersistedWindowAssignment(
            id: UUID(),
            sectionID: second,
            additionalSectionIDs: [first],
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            accessibilityIdentifier: nil,
            title: "Notes",
            windowOrdinal: 0,
            order: 0,
            isActive: true
        )
        XCTAssertEqual(record.liveSectionID, SpannedSectionIdentity.id(covering: [first, second]))
        XCTAssertEqual(record.coveredSectionIDs, [first, second])
    }

    func testApplicationPairIsUnavailableInASpannedSectionAndSpanShortcutRespectsPairs() {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        ))
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        let spannedSectionID = SpannedSectionIdentity.id(covering: [firstSectionID, secondSectionID])
        model.sections[spannedSectionID] = LayoutSectionState(
            id: spannedSectionID,
            windows: [first, second],
            coveredSectionIDs: [firstSectionID, secondSectionID]
        )
        XCTAssertFalse(model.canPairApplications(
            first.bundleIdentifier,
            second.bundleIdentifier,
            inSection: spannedSectionID
        ))

        model.sections.removeValue(forKey: spannedSectionID)
        model.sections[firstSectionID] = LayoutSectionState(id: firstSectionID, windows: [first, second])
        model.applicationSplitPairs[firstSectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: second.bundleIdentifier
        )]
        mock.focusedHandle = first.handle

        model.spanFocusedWindow(.right)

        XCTAssertEqual(
            model.sectionNotices[firstSectionID],
            "Unpair this application before spanning its window"
        )
        XCTAssertEqual(model.sections[firstSectionID]?.windows.map(\.id), [first.id, second.id])
        XCTAssertNil(model.sections[spannedSectionID])
    }

    func testSuspendedApplicationPairAllowsSpanningAndClearsDormantPair() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        ))
        let survivor = managedWindow(bundleIdentifier: "first", ordinal: 0)
        model.sections[firstSectionID] = LayoutSectionState(
            id: firstSectionID,
            windows: [survivor],
            activeWindowID: survivor.id
        )
        model.applicationSplitPairs[firstSectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: survivor.bundleIdentifier,
            secondBundleIdentifier: "closed-partner"
        )]
        mock.focusedHandle = survivor.handle

        model.spanFocusedWindow(.right)

        let spannedSectionID = SpannedSectionIdentity.id(covering: [firstSectionID, secondSectionID])
        XCTAssertNil(model.sections[firstSectionID])
        XCTAssertEqual(model.sections[spannedSectionID]?.windows.map(\.id), [survivor.id])
        XCTAssertNil(model.applicationSplitPairs[firstSectionID])
        XCTAssertNil(model.sectionNotices[firstSectionID])
    }

    func testNewPairReplacesSuspendedPair() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let third = managedWindow(bundleIdentifier: "third", ordinal: 1)
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, third])
        model.applicationSplitPairs[sectionID] = [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: "closed-partner"
        )]
        mock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title),
            third.handle: snapshot(handle: third.handle, title: third.title)
        ]

        XCTAssertTrue(model.canPairApplications(
            first.bundleIdentifier,
            third.bundleIdentifier,
            inSection: sectionID
        ))
        model.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: third.bundleIdentifier,
            inSection: sectionID
        )

        XCTAssertEqual(model.applicationSplitPairs[sectionID], [ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: third.bundleIdentifier
        )])
    }

    func testApplicationPairSurvivesModelRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fingerprint = DisplayFingerprint(vendor: 6, model: 5, serial: 4, name: "Test")
        let display = currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        let displays = MockDisplayProvider([display])
        let sectionID = UUID()
        let firstModel = makeModel(
            mock: MockAccessibility(),
            root: .leaf(id: sectionID),
            directory: directory,
            displayProvider: { displays.displays }
        )
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        firstModel.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        let firstMock = firstModel.accessibility as! MockAccessibility
        firstMock.windowSnapshotsByHandle = [
            first.handle: snapshot(handle: first.handle, title: first.title),
            second.handle: snapshot(handle: second.handle, title: second.title)
        ]
        firstModel.toggleApplicationSplit(
            first: first.bundleIdentifier,
            second: second.bundleIdentifier,
            inSection: sectionID
        )

        let relaunched = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            displayProvider: { displays.displays }
        )

        XCTAssertEqual(
            relaunched.applicationSplitPairs[sectionID],
            [ApplicationSplitPair(
                firstBundleIdentifier: first.bundleIdentifier,
                secondBundleIdentifier: second.bundleIdentifier
            )]
        )
    }

    func testSuspendedApplicationPairSurvivesRelaunchAndReactivatesOnWindowReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fingerprint = DisplayFingerprint(vendor: 16, model: 15, serial: 14, name: "Test")
        let display = currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        let displays = MockDisplayProvider([display])
        let sectionID = UUID()
        let closedPID = ProcessInfo.processInfo.processIdentifier
        let survivorPID = try foreignApplicationPIDs(1)[0]
        let firstMock = MockAccessibility()
        let firstModel = makeModel(
            mock: firstMock,
            root: .leaf(id: sectionID),
            directory: directory,
            displayProvider: { displays.displays }
        )
        let closedHandle = try attachWindow(
            titled: "Closed side",
            pid: closedPID,
            to: sectionID,
            in: firstModel,
            mock: firstMock
        )
        let survivorHandle = try attachWindow(
            titled: "Surviving side",
            pid: survivorPID,
            to: sectionID,
            in: firstModel,
            mock: firstMock
        )
        let closedWindow = try XCTUnwrap(firstModel.managedWindow(matching: closedHandle))
        let survivorWindow = try XCTUnwrap(firstModel.managedWindow(matching: survivorHandle))
        firstModel.toggleApplicationSplit(
            first: closedWindow.bundleIdentifier,
            second: survivorWindow.bundleIdentifier,
            inSection: sectionID
        )
        let pair = try XCTUnwrap(firstModel.applicationSplitPairs[sectionID]?.first)
        let survivorSnapshot = try XCTUnwrap(firstMock.windowSnapshotsByHandle[survivorHandle])

        firstModel.confirmWindowDestroyed(closedHandle)

        let relaunchedMock = MockAccessibility()
        relaunchedMock.windowSnapshots = [survivorSnapshot]
        relaunchedMock.windowSnapshotsByHandle[survivorHandle] = survivorSnapshot
        relaunchedMock.listedWindowHandles = [survivorHandle]
        let relaunched = makeModel(
            mock: relaunchedMock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        let wholeSection = try XCTUnwrap(relaunched.contentFrame(forSection: sectionID))

        XCTAssertEqual(relaunched.applicationSplitPairs[sectionID], [pair])
        XCTAssertEqual(relaunched.sections[sectionID]?.windows.map(\.id), [survivorWindow.id])
        XCTAssertEqual(
            relaunched.contentFrame(
                forApplication: survivorWindow.bundleIdentifier,
                inSection: sectionID
            ),
            wholeSection
        )

        let reopenedHandle = AXWindowHandle(element: AXUIElementCreateApplication(closedPID))
        let reopened = snapshot(handle: reopenedHandle, title: "Reopened side", pid: closedPID)
        relaunchedMock.windowSnapshots = [survivorSnapshot, reopened]
        relaunchedMock.windowSnapshotsByHandle[reopenedHandle] = reopened
        relaunchedMock.listedWindowHandles = [survivorHandle, reopenedHandle]

        XCTAssertEqual(
            relaunched.attachNewlyCreatedWindow(reopenedHandle, pid: closedPID),
            .attached
        )
        XCTAssertLessThan(
            try XCTUnwrap(relaunched.contentFrame(
                forApplication: survivorWindow.bundleIdentifier,
                inSection: sectionID
            )).width,
            wholeSection.width
        )
        XCTAssertEqual(relaunched.applicationSplitPairs[sectionID], [pair])
    }

    func testApplicationTerminationRetainsSplitPairThroughOrphanedAssignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        let first = managedWindow(
            bundleIdentifier: "com.example.First",
            ordinal: 0,
            pid: 41_001
        )
        let second = managedWindow(
            bundleIdentifier: "com.example.Second",
            ordinal: 1,
            pid: 41_002
        )
        let pair = ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: second.bundleIdentifier
        )
        model.sections[sectionID] = LayoutSectionState(id: sectionID, windows: [first, second])
        model.applicationSplitPairs[sectionID] = [pair]
        model.persistWindowAssignments()

        model.confirmApplicationTerminated(
            pid: first.pid,
            bundleIdentifier: first.bundleIdentifier
        )

        XCTAssertEqual(model.applicationSplitPairs[sectionID], [pair])
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [second.id])
        XCTAssertEqual(model.orphanedAssignments.map(\.id), [first.id])
        let stored = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(
            stored.first { $0.id == first.id }?.splitPartnerBundleIdentifier,
            second.bundleIdentifier
        )
    }

    func testNewWindowFromPairedApplicationUsesItsHalf() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "New", pid: pid)
        mock.windowSnapshots = [existing]
        mock.windowSnapshotsByHandle = [existingHandle: existing]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: existing, to: sectionID)
        let attached = try XCTUnwrap(model.sections[sectionID]?.windows.first)
        let partner = managedWindow(bundleIdentifier: "com.example.Partner", ordinal: 8)
        model.sections[sectionID]?.windows.append(partner)
        mock.windowSnapshotsByHandle[partner.handle] = snapshot(
            handle: partner.handle,
            title: partner.title,
            pid: pid
        )
        model.toggleApplicationSplit(
            first: attached.bundleIdentifier,
            second: partner.bundleIdentifier,
            inSection: sectionID
        )
        let expected = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forApplication: attached.bundleIdentifier, inSection: sectionID)
        ))

        mock.windowSnapshots = [existing, newlyCreated]
        mock.windowSnapshotsByHandle[newHandle] = newlyCreated
        mock.focusedHandle = newHandle

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )
        XCTAssertEqual(mock.setFrameRequests.last?.window, newHandle)
        XCTAssertEqual(mock.setFrameRequests.last?.frame, expected)
    }

    func testLayoutPreviewMigratesAndRestoresApplicationPairs() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1)
        model.sections[secondSectionID] = LayoutSectionState(
            id: secondSectionID,
            windows: [first, second]
        )
        let pair = ApplicationSplitPair(
            firstBundleIdentifier: first.bundleIdentifier,
            secondBundleIdentifier: second.bundleIdentifier
        )
        model.applicationSplitPairs[secondSectionID] = [pair]
        let display = try XCTUnwrap(model.currentDisplays.first)
        model.beginLayoutPreview(for: display)
        var preview = model.layout(for: display)
        preview.root = .leaf(id: firstSectionID)

        model.preview(preview, migrating: [secondSectionID: firstSectionID])

        XCTAssertNil(model.applicationSplitPairs[secondSectionID])
        XCTAssertEqual(model.applicationSplitPairs[firstSectionID], [pair])

        model.cancelLayoutPreview(for: display)

        XCTAssertNil(model.applicationSplitPairs[firstSectionID])
        XCTAssertEqual(model.applicationSplitPairs[secondSectionID], [pair])
    }
    func testWindowSwitcherContextMenuListsWindowAndApplicationActionsInOrder() {
        var focusToggleCount = 0
        let coordinator = SectionStackButton.Coordinator(
            activate: {},
            detach: {},
            sectionFocusTitle: "Focus Section",
            sectionFocusShortcut: ShortcutCommand.toggleSectionFocus.defaultShortcut,
            toggleSectionFocus: { focusToggleCount += 1 },
            close: {},
            quitApplicationTitle: "Quit Editor",
            quitApplication: {}
        )

        let menu = SectionStackButton.contextMenu(for: coordinator)

        XCTAssertEqual(menu?.numberOfItems, 5)
        XCTAssertEqual(menu?.item(at: 0)?.title, "Detach Window")
        XCTAssertEqual(menu?.item(at: 1)?.title, "Focus Section")
        XCTAssertEqual(menu?.item(at: 1)?.keyEquivalent, "f")
        XCTAssertEqual(menu?.item(at: 1)?.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(menu?.item(at: 2)?.title, "Close Window")
        XCTAssertTrue(menu?.item(at: 3)?.isSeparatorItem == true)
        XCTAssertEqual(menu?.item(at: 4)?.title, "Quit Editor")
        XCTAssertTrue(menu?.delegate === coordinator)
        menu?.performActionForItem(at: 1)
        XCTAssertEqual(focusToggleCount, 1)
    }

    func testApplicationOnlyContextMenuHasNamedQuitWithoutLeadingSeparator() {
        let coordinator = SectionStackButton.Coordinator(
            activate: {},
            detach: nil,
            close: nil,
            quitApplicationTitle: "Quit Editor",
            quitApplication: {}
        )

        let menu = SectionStackButton.contextMenu(for: coordinator)

        XCTAssertEqual(menu?.numberOfItems, 1)
        XCTAssertEqual(menu?.item(at: 0)?.title, "Quit Editor")
        XCTAssertFalse(menu?.item(at: 0)?.isSeparatorItem == true)
    }

    func testSectionStackButtonRoutesSecondClickToDoubleClickAction() {
        var singleClickCount = 0
        var doubleClickCount = 0
        let coordinator = SectionStackButton.Coordinator(
            activate: { singleClickCount += 1 },
            doubleActivate: { doubleClickCount += 1 },
            detach: nil,
            close: nil,
            quitApplicationTitle: nil,
            quitApplication: nil
        )

        coordinator.performActivation(clickCount: 1)
        coordinator.performActivation(clickCount: 2)

        XCTAssertEqual(singleClickCount, 1)
        XCTAssertEqual(doubleClickCount, 1)
    }

    func testManagedWindowCountIncludesSameApplicationWindowsInOtherSections() {
        let model = makeModel(mock: MockAccessibility())
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let icon = NSImage()
        func window(id: UUID, bundleIdentifier: String, ordinal: Int) -> ManagedWindow {
            ManagedWindow(
                id: id,
                handle: AXWindowHandle(element: AXUIElementCreateApplication(pid_t(ordinal + 1))),
                pid: pid_t(ordinal + 1),
                bundleIdentifier: bundleIdentifier,
                accessibilityIdentifier: nil,
                windowOrdinal: ordinal,
                applicationName: "Editor",
                icon: icon,
                title: "Window \(ordinal)",
                isMinimized: false
            )
        }
        let first = window(id: UUID(), bundleIdentifier: "com.example.Editor", ordinal: 0)
        let second = window(id: UUID(), bundleIdentifier: "com.example.Editor", ordinal: 1)
        let other = window(id: UUID(), bundleIdentifier: "com.example.Other", ordinal: 2)
        model.sections = [
            firstSectionID: LayoutSectionState(id: firstSectionID, windows: [first]),
            secondSectionID: LayoutSectionState(id: secondSectionID, windows: [second, other])
        ]

        XCTAssertEqual(model.managedWindowCount(bundleIdentifier: "com.example.Editor"), 2)
        XCTAssertEqual(model.managedWindowCount(bundleIdentifier: "com.example.Other"), 1)
    }

    func testCloseWindowRequestsExactHandleWithoutDetaching() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)
        let focusCallCount = mock.focusCallCount

        model.close(windowID: windowID)

        XCTAssertEqual(mock.closedHandles, [handle])
        XCTAssertEqual(mock.focusCallCount, focusCallCount)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [windowID])
        XCTAssertNil(model.compatibilityError)
    }

    func testCloseWindowFailureKeepsWindowAndReportsCompatibilityError() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        mock.closeError = AccessibilityClientError.attribute(kAXCloseButtonAttribute as String, .noValue)
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        model.close(windowID: windowID)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [windowID])
        XCTAssertEqual(
            model.compatibilityError,
            "Could not close window: Could not read AXCloseButton (AX error \(AXError.noValue.rawValue))."
        )
    }

    func testQuitApplicationRequestsOwningPIDWithoutActivatingOrDetaching() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)
        let focusCallCount = mock.focusCallCount

        model.quitApplication(windowID: windowID)

        XCTAssertEqual(mock.quitApplicationPIDs, [window.pid])
        XCTAssertEqual(mock.focusCallCount, focusCallCount)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [windowID])
        XCTAssertNil(model.compatibilityError)
    }

    func testQuitApplicationFailureKeepsWindowAndReportsCompatibilityError() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        mock.quitApplicationError = AccessibilityClientError.applicationQuitRejected
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        model.quitApplication(windowID: windowID)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [windowID])
        XCTAssertEqual(
            model.compatibilityError,
            "Could not quit Panoptos: The application did not accept the quit request."
        )
    }

    func testQuitApplicationIgnoresPanoptosOwnWindow() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Settings")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            ownProcessIdentifier: window.pid
        )
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        model.quitApplication(windowID: windowID)

        XCTAssertFalse(model.canQuitApplication(pid: window.pid))
        XCTAssertTrue(mock.quitApplicationPIDs.isEmpty)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [windowID])
    }

    func testContentFrameUsesLayoutGutterBetweenBothBarsAndWindow() throws {
        for gutter: CGFloat in [0, 24] {
            let sectionID = UUID()
            let model = makeModel(mock: MockAccessibility(), root: .leaf(id: sectionID), gutter: gutter)
            model.showWindowMenuBars = true
            let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])
            let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))

            XCTAssertEqual(
                contentFrame.minY - sectionFrame.minY,
                WindowSwitcherSize.barHeight(for: WindowSwitcherSize.defaultScale) + gutter
            )
            XCTAssertEqual(
                sectionFrame.maxY - contentFrame.maxY,
                PanoptosModel.chromeHeight + gutter
            )
        }
    }

    func testBottomSwitcherStaysAboveTheDockWithLayoutGutterSpacing() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Test")
        let display = CurrentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 820),
            scale: 2
        )
        let model = makeModel(
            mock: MockAccessibility(),
            root: .leaf(id: sectionID),
            gutter: 18,
            displayProvider: { [display] }
        )
        let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])
        let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))
        let switcherFrame = SectionBarLayout.frames(
            in: sectionFrame,
            fillsAvailableWidth: true,
            centersBars: false,
            topContentWidth: 0,
            bottomContentWidth: 0,
            bottomHeight: WindowSwitcherSize.barHeight(for: WindowSwitcherSize.defaultScale)
        ).bottom

        XCTAssertEqual(switcherFrame.minY - display.visibleFrame.minY, 18)
        XCTAssertGreaterThanOrEqual(switcherFrame.minY, display.visibleFrame.minY)
        XCTAssertEqual(contentFrame.minY - switcherFrame.maxY, 18)
    }

    func testTopMenuMatchesWindowSpacingAtTheUsableScreenEdge() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 1, model: 2, serial: 3, name: "Test")
        let display = CurrentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 900),
            visibleFrame: CGRect(x: 0, y: 40, width: 1000, height: 820),
            scale: 2
        )
        let model = makeModel(
            mock: MockAccessibility(),
            root: .leaf(id: sectionID),
            gutter: 18,
            displayProvider: { [display] }
        )
        model.showWindowMenuBars = true
        let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])
        let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))
        let menuFrame = SectionBarLayout.frames(
            in: sectionFrame,
            fillsAvailableWidth: true,
            centersBars: false,
            topContentWidth: 0,
            bottomContentWidth: 0
        ).top

        XCTAssertEqual(display.visibleFrame.maxY - menuFrame.maxY, 18)
        XCTAssertEqual(menuFrame.minY - contentFrame.maxY, 18)
    }

    func testHidingMenuBarsGivesTheirReservedStripBackToTheWindow() throws {
        let sectionID = UUID()
        let model = makeModel(mock: MockAccessibility(), root: .leaf(id: sectionID))
        model.showWindowMenuBars = true
        let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])
        let inset = WindowSwitcherSize.barHeight(for: WindowSwitcherSize.defaultScale)
            + DisplayLayout.defaultGutter

        model.showWindowMenuBars = false
        let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))

        XCTAssertEqual(contentFrame.minY - sectionFrame.minY, inset)
        XCTAssertEqual(sectionFrame.maxY - contentFrame.maxY, 0)
    }

    func testSwitcherScaleReservesItsDynamicHeightWithoutChangingTheMenuBarSpacing() throws {
        let sectionID = UUID()
        let model = makeModel(mock: MockAccessibility(), root: .leaf(id: sectionID))
        model.showWindowMenuBars = true
        let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])

        model.setWindowSwitcherUIScale(3)
        let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))

        XCTAssertEqual(
            contentFrame.minY - sectionFrame.minY,
            WindowSwitcherSize.barHeight(for: 3) + DisplayLayout.defaultGutter
        )
        XCTAssertEqual(
            sectionFrame.maxY - contentFrame.maxY,
            PanoptosModel.chromeHeight + DisplayLayout.defaultGutter
        )
    }

    func testScaledSwitcherInsetRemainsWhenMenuBarsAreHidden() throws {
        let sectionID = UUID()
        let model = makeModel(mock: MockAccessibility(), root: .leaf(id: sectionID))
        let sectionFrame = try XCTUnwrap(model.sectionFrames()[sectionID])

        model.showWindowMenuBars = false
        model.setWindowSwitcherUIScale(3)
        let contentFrame = try XCTUnwrap(model.contentFrame(forSection: sectionID))

        XCTAssertEqual(
            contentFrame.minY - sectionFrame.minY,
            WindowSwitcherSize.barHeight(for: 3) + DisplayLayout.defaultGutter
        )
        XCTAssertEqual(sectionFrame.maxY - contentFrame.maxY, 0)
    }

    func testAttachingResizableWindowCreatesActiveSectionAndFitsFrame() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = AXWindowSnapshot(
            handle: handle,
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "Document",
            frame: CGRect(x: 50, y: 50, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)

        model.attach(window: mock.windowSnapshot!, to: sectionID)

        XCTAssertEqual(model.sections[sectionID]?.windows.count, 1)
        XCTAssertEqual(model.sections[sectionID]?.activeWindow?.title, "Document")
        XCTAssertEqual(mock.focusedHandle, handle)
        XCTAssertNotNil(mock.lastSetFrame)
    }

    func testConstrainedWindowRemainsAttachedAndCenteredAfterReflow() throws {
        let fingerprint = DisplayFingerprint(vendor: 70, model: 71, serial: 72, name: "Resizable")
        let sectionID = UUID()
        let displays = MockDisplayProvider([currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )])
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Constrained")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        mock.maximumFrameSizesByHandle[handle] = CGSize(width: 600, height: 10_000)
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { displays.displays }
        )

        model.attach(window: window, to: sectionID)

        let initialDestination = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forSection: sectionID)
        ))
        let requestsAfterAttachment = mock.setFrameRequests.count
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
        XCTAssertEqual(
            mock.placedFramesByHandle[handle],
            CGRect(
                x: initialDestination.midX - 300,
                y: initialDestination.minY,
                width: 600,
                height: initialDestination.height
            )
        )
        XCTAssertTrue(model.reflowManagedWindows())
        XCTAssertEqual(mock.setFrameRequests.count, requestsAfterAttachment)

        displays.displays = [currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1_500, height: 900)
        )]
        model.refreshDisplays()

        let reflowDestination = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            model.contentFrame(forSection: sectionID)
        ))
        let requestsAfterDisplayReflow = mock.setFrameRequests.count
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
        XCTAssertEqual(
            mock.placedFramesByHandle[handle],
            CGRect(
                x: reflowDestination.midX - 300,
                y: reflowDestination.minY,
                width: 600,
                height: reflowDestination.height
            )
        )
        XCTAssertTrue(model.reflowManagedWindows())
        XCTAssertEqual(mock.setFrameRequests.count, requestsAfterDisplayReflow)
    }

    func testConstrainedWindowRestoresAttachedAndCenteredAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fingerprint = DisplayFingerprint(vendor: 80, model: 81, serial: 82, name: "Persistent")
        let sectionID = UUID()
        let displays = MockDisplayProvider([currentDisplay(
            fingerprint: fingerprint,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )])
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let firstWindow = snapshot(handle: firstHandle, title: "Constrained")
        firstMock.windowSnapshots = [firstWindow]
        firstMock.windowSnapshotsByHandle[firstHandle] = firstWindow
        let firstModel = makeModel(
            mock: firstMock,
            root: .leaf(id: sectionID),
            directory: directory,
            displayProvider: { displays.displays }
        )
        firstModel.attach(window: firstWindow, to: sectionID)

        let restoredHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let restoredWindow = snapshot(handle: restoredHandle, title: "Constrained")
        let restoredMock = MockAccessibility()
        restoredMock.windowSnapshots = [restoredWindow]
        restoredMock.windowSnapshotsByHandle[restoredHandle] = restoredWindow
        restoredMock.maximumFrameSizesByHandle[restoredHandle] = CGSize(width: 600, height: 10_000)

        let restoredModel = makeModel(
            mock: restoredMock,
            root: .leaf(id: sectionID),
            directory: directory,
            displayProvider: { displays.displays }
        )

        let destination = PanoptosModel.accessibilityFrame(fromAppKitFrame: try XCTUnwrap(
            restoredModel.contentFrame(forSection: sectionID)
        ))
        XCTAssertEqual(restoredModel.sections[sectionID]?.windows.map(\.handle), [restoredHandle])
        XCTAssertEqual(
            restoredMock.placedFramesByHandle[restoredHandle],
            CGRect(
                x: destination.midX - 300,
                y: destination.minY,
                width: 600,
                height: destination.height
            )
        )
    }

    func testResizeFailureLeavesWindowUnattached() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = AXWindowSnapshot(
            handle: handle,
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "Rigid",
            frame: CGRect(x: 0, y: 0, width: 300, height: 300),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        mock.frameError = AccessibilityClientError.frameRejected
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)

        model.attach(window: mock.windowSnapshot!, to: sectionID)

        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNotNil(model.compatibilityError)
    }

    func testAttachmentSurvivesRaiseFailure() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: handle, title: "Dragged")
        mock.focusError = AccessibilityClientError.frameRejected
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)

        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: sectionID)

        XCTAssertEqual(model.sections[sectionID]?.activeWindow?.handle, handle)
        XCTAssertNotNil(mock.lastSetFrame)
        XCTAssertNil(model.compatibilityError)
    }

    func testTransientSnapshotFailurePreservesEveryAttachedWindowAndPersistedAssignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(mock: mock, directory: directory)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)

        mock.snapshotError = AccessibilityClientError.attribute(kAXPositionAttribute as String, .cannotComplete)
        model.refreshRuntime(reportedFrontmostPID: nil)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.count, 2)
        XCTAssertEqual(
            WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json")).load().count,
            2
        )
    }

    func testSustainedInvalidElementDetachesOnlyAfterApplicationStopsListingWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = MockClock()
        let mock = MockAccessibility()
        let missingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let liveHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let missing = snapshot(handle: missingHandle, title: "Closed")
        let live = snapshot(handle: liveHandle, title: "Live")
        mock.windowSnapshots = [missing, live]
        mock.windowSnapshotsByHandle = [missingHandle: missing, liveHandle: live]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: missing, to: sectionID)
        model.attach(window: live, to: sectionID)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [missingHandle, liveHandle])

        mock.snapshotErrorsByHandle[missingHandle] = AccessibilityClientError.attribute(
            kAXPositionAttribute as String,
            .invalidUIElement
        )
        // The application still lists the element, so it is not gone yet.
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [missingHandle, liveHandle])

        mock.listedWindowHandles = [liveHandle]
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [liveHandle])
        // The record survives so the window can be reclaimed or restored.
        XCTAssertEqual(
            Set(
                WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
                    .load()
                    .map(\.title)
            ),
            ["Live", "Closed"]
        )
    }

    func testInvalidElementWithinTheGracePeriodKeepsWindowAttached() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        model.attach(window: window, to: sectionID)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(5)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
    }

    func testInvalidElementDuringSystemSleepKeepsWindowAttachedAcrossWake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: window, to: sectionID)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])

        // Locking and sleeping invalidate the element while the window server
        // tears the display down, and the application stops listing it.
        model.beginSystemTransition(.sessionInactive)
        model.beginSystemTransition(.screenSleep)
        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        for _ in 0..<5 {
            clock.advance(30)
            model.refreshRuntime(reportedFrontmostPID: nil)
        }
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])

        // Unlocking restores the element well inside the settle period.
        model.endSystemTransition(.screenSleep)
        model.endSystemTransition(.sessionInactive)
        clock.advance(1)
        mock.snapshotErrorsByHandle.removeValue(forKey: handle)
        mock.listedWindowHandles = nil
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
        XCTAssertEqual(
            WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
                .load()
                .map(\.title),
            ["Managed"]
        )
    }

    func testOrphanedWindowIsReclaimedWhenItsApplicationReplacesTheElement() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let oldHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: oldHandle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[oldHandle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        model.attach(window: window, to: sectionID)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [oldHandle])

        mock.snapshotErrorsByHandle[oldHandle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])

        // The application publishes a fresh element for the same window.
        let newHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let replacement = snapshot(handle: newHandle, title: "Managed")
        mock.windowSnapshots = [replacement]
        mock.windowSnapshotsByHandle[newHandle] = replacement
        mock.listedWindowHandles = nil
        clock.advance(5)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [newHandle])
        XCTAssertEqual(model.sections[sectionID]?.activeWindowID, model.sections[sectionID]?.windows.first?.id)
    }

    func testUnrecoveredOrphanStopsRetryingButKeepsItsPersistedAssignment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: window, to: sectionID)

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(store.load().map(\.title), ["Managed"])

        // Long past the retry window: Panoptos stops asking, but the user's
        // assignment is not the model's to throw away.
        clock.advance(3_600)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertEqual(store.load().first?.orphanedAt != nil, true)
    }

    func testRefreshWindowsAndMenusRereadsATreeTheApplicationRebuiltOnItsOwn() throws {
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        mock.menusByPID[pid] = [menu(titled: "File")]
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: window, to: sectionID)
        XCTAssertEqual(model.menusByPID[pid]?.map(\.title), ["File"])

        // The application published a different tree without Panoptos invoking
        // anything, so nothing has invalidated the cached one.
        mock.menusByPID[pid] = [menu(titled: "File"), menu(titled: "Edit")]
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.menusByPID[pid]?.map(\.title), ["File"])

        model.refreshWindowsAndMenus(reportedFrontmostPID: nil)

        XCTAssertEqual(model.menusByPID[pid]?.map(\.title), ["File", "Edit"])
    }

    func testExplicitRefreshRecoversAnExpiredOrphanWithoutStealingFocus() throws {
        let (model, mock, _, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
        let focusCount = mock.focusCallCount
        model.compatibilityError = "Keep this compatibility notice"

        model.refreshWindowsAndMenus(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
        XCTAssertEqual(mock.focusCallCount, focusCount)
        XCTAssertEqual(model.compatibilityError, "Keep this compatibility notice")
        XCTAssertTrue(model.orphanedAssignments.isEmpty)
        XCTAssertEqual(model.windowAssignmentPersistence.load().map(\.title), [replacement.title])
        XCTAssertNil(model.windowAssignmentPersistence.load().first?.orphanedAt)
    }

    func testWakeAndUnlockRecoverExpiredOrphansOnlyAfterAllTransitionsSettle() throws {
        for reason in SystemTransition.allCases {
            let (model, mock, clock, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
            model.beginSystemTransition(reason)
            clock.advance(3_600)
            model.endSystemTransition(reason)
            mock.resetWindowsCallCount()

            model.refreshRuntime(reportedFrontmostPID: nil)
            XCTAssertNil(model.sections[sectionID])
            XCTAssertEqual(mock.windowsCallCount, 0)

            clock.advance(PanoptosModel.transitionSettleInterval + 1)
            model.refreshRuntime(reportedFrontmostPID: nil)
            XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
        }
    }

    func testDisplayRefreshRecoversExpiredOrphansWithAnUnchangedTopology() throws {
        let (model, _, _, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
        let topology = model.currentDisplayTopology

        model.refreshDisplays()
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.currentDisplayTopology, topology)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
    }

    func testRecoveryBudgetDoesNotExpireDuringWakeSettling() throws {
        let (model, _, clock, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
        model.beginSystemTransition(.systemSleep)
        model.beginSystemTransition(.screenSleep)
        // At wake this record has only one second of its old budget left.
        model.orphanedAssignments[0].orphanedAt = clock.now.addingTimeInterval(
            -PanoptosModel.orphanRetentionInterval + 1
        )
        model.endSystemTransition(.systemSleep)
        clock.advance(PanoptosModel.transitionSettleInterval + 1)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])

        model.endSystemTransition(.screenSleep)
        clock.advance(PanoptosModel.transitionSettleInterval + 1)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
    }

    func testAccessibilityPermissionRestorationRecoversExpiredOrphans() throws {
        let (model, mock, _, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
        mock.isTrusted = false
        model.refreshPermissionState()
        mock.isTrusted = true

        model.refreshPermissionState()

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
    }

    func testApplicationRecoveryRenewsOnlyItsExpiredOrphansAndPreservesPacing() throws {
        let (model, mock, clock, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
        let original = try XCTUnwrap(model.orphanedAssignments.first)
        let unrelated = PersistedWindowAssignment(
            id: UUID(),
            sectionID: sectionID,
            additionalSectionIDs: [],
            bundleIdentifier: "example.unrelated",
            processIdentifier: -1,
            accessibilityIdentifier: nil,
            title: "Other application",
            windowOrdinal: 0,
            order: 1,
            isActive: false,
            orphanedAt: original.orphanedAt,
            displayTopology: original.displayTopology
        )
        model.orphanedAssignments.append(unrelated)
        let expiredDate = unrelated.orphanedAt

        model.prepareApplicationRelaunchRecovery(
            pid: replacement.pid,
            bundleIdentifier: model.orphanedAssignments[0].bundleIdentifier
        )
        XCTAssertEqual(model.orphanedAssignments.last?.orphanedAt, expiredDate)

        // An activation renews eligibility, but a second event inside the
        // normal interval must not cause another read of an unavailable app.
        mock.windowSnapshots = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        let readCount = mock.windowsCallCount
        mock.windowSnapshots = [replacement]
        model.prepareApplicationRelaunchRecovery(
            pid: replacement.pid,
            bundleIdentifier: model.orphanedAssignments[0].bundleIdentifier
        )
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(mock.windowsCallCount, readCount)
        XCTAssertNil(model.sections[sectionID])

        clock.advance(PanoptosModel.orphanRecoveryInterval)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement.handle])
    }

    func testExpiredRecoveryDoesNotReattachKnownClosedOrUnrelatedWindows() throws {
        for knownClosed in [false, true] {
            let (model, mock, _, replacement, sectionID) = makeExpiredOrphanRecoveryScenario()
            if knownClosed {
                model.orphanedAssignments[0].awaitsWindowReopen = true
            } else {
                // Same ordinal and process are insufficient when the title
                // changed and there is no stable Accessibility identifier.
                let unrelated = snapshot(handle: replacement.handle, title: "Unrelated")
                mock.windowSnapshots = [unrelated]
                mock.windowSnapshotsByHandle = [unrelated.handle: unrelated]
            }

            model.refreshWindowsAndMenus(reportedFrontmostPID: nil)

            XCTAssertNil(model.sections[sectionID])
            XCTAssertEqual(model.orphanedAssignments.count, 1)
        }
    }

    private func makeExpiredOrphanRecoveryScenario() -> (
        PanoptosModel, MockAccessibility, MockClock, AXWindowSnapshot, UUID
    ) {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle = [handle: window]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        model.attach(window: window, to: sectionID)
        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String, .invalidUIElement
        )
        mock.listedWindowHandles = []
        mock.windowSnapshots = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(PanoptosModel.invalidWindowFailureDuration + 1)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(model.orphanedAssignments.count, 1)
        clock.advance(PanoptosModel.orphanRetentionInterval + 1)

        let newHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let replacement = snapshot(handle: newHandle, title: "Managed")
        mock.windowSnapshots = [replacement]
        mock.windowSnapshotsByHandle = [newHandle: replacement]
        mock.listedWindowHandles = nil
        // A readable replacement alone does not renew the expired idle budget.
        mock.resetWindowsCallCount()
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(mock.windowsCallCount, 0)
        return (model, mock, clock, replacement, sectionID)
    }

    func testRefreshWindowsAndMenusRetriesOrphansAheadOfTheirPacingInterval() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        model.attach(window: window, to: sectionID)

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])

        // The replacement element arrives inside the recovery pacing window,
        // so the ambient refresh declines to look for it yet.
        let replacement = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let republished = snapshot(handle: replacement, title: "Managed")
        mock.snapshotErrorsByHandle.removeValue(forKey: handle)
        mock.windowSnapshots = [republished]
        mock.windowSnapshotsByHandle = [replacement: republished]
        mock.listedWindowHandles = nil
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])

        model.refreshWindowsAndMenus(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [replacement])
    }

    func testAssignmentsThatDoNotMatchAtLaunchAreRetriedLater() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let sectionID = UUID()
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: firstHandle, title: "Managed")
        firstMock.windowSnapshots = [window]
        firstMock.windowSnapshotsByHandle[firstHandle] = window
        let firstModel = makeModel(mock: firstMock, root: .leaf(id: sectionID), directory: directory)
        firstModel.attach(window: window, to: sectionID)
        XCTAssertEqual(store.load().map(\.title), ["Managed"])

        // The application is still launching, so nothing matches at startup.
        let clock = MockClock()
        let relaunchMock = MockAccessibility()
        let relaunchedModel = makeModel(mock: relaunchMock, directory: directory, clock: clock)
        XCTAssertNil(relaunchedModel.sections[sectionID])

        let lateHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let late = snapshot(handle: lateHandle, title: "Managed")
        relaunchMock.windowSnapshots = [late]
        relaunchMock.windowSnapshotsByHandle[lateHandle] = late
        clock.advance(5)
        relaunchedModel.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.handle), [lateHandle])
        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertNil(store.load().first?.orphanedAt)
    }

    func testTerminatingAnApplicationWithOnlyOrphansPreservesItForRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: window, to: sectionID)

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(store.load().count, 1)

        model.confirmApplicationTerminated(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertEqual(store.load().first?.awaitsApplicationRelaunch, true)
    }

    func testApplicationTerminationPreservesLiveAssignmentForRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: window, to: sectionID)
        let managed = try XCTUnwrap(model.sections[sectionID]?.windows.first)

        model.confirmApplicationTerminated(
            pid: managed.pid,
            bundleIdentifier: managed.bundleIdentifier
        )

        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(store.load().map(\.sectionID), [sectionID])
        XCTAssertNotNil(store.load().first?.orphanedAt)
        XCTAssertEqual(store.load().first?.awaitsApplicationRelaunch, true)
    }

    func testClosingFocusedWindowFocusesSurvivorAndKeepsCyclingShortcutsWorking() throws {
        for differentApplication in [false, true] {
            for focusNotificationArrivedFirst in [false, true] {
                let (model, mock, sectionID, windows) = makeWindowCloseFocusFixture(
                    differentApplication: differentApplication
                )
                let closed = windows[2]
                let survivor = windows[1]
                let requestsBeforeClose = mock.focusRequests.count
                if focusNotificationArrivedFirst {
                    model.refreshFocusedWindow(reportedFrontmostPID: nil)
                    XCTAssertNil(model.focusedManagedWindowID)
                }
                mock.focusedHandle = nil
                mock.focusedWindowError = AccessibilityClientError.attribute(
                    kAXFocusedWindowAttribute as String, .noValue
                )
                mock.onFocus = { _, _ in mock.focusedWindowError = nil }

                model.confirmWindowDestroyed(closed.handle, reportedFrontmostPID: closed.pid)

                XCTAssertEqual(model.sections[sectionID]?.activeWindowID, survivor.id)
                XCTAssertEqual(model.focusedManagedWindowID, survivor.id)
                XCTAssertEqual(mock.focusRequests.dropFirst(requestsBeforeClose).map(\.handle), [survivor.handle])
                XCTAssertEqual(mock.focusRequests.last?.pid, survivor.pid)
                XCTAssertEqual(model.lastFocusedSectionByPID[survivor.pid], sectionID)
                model.performShortcut(.cycleNextWindow)
                XCTAssertEqual(mock.focusedHandle, windows[0].handle)
                model.performShortcut(.cyclePreviousWindow)
                XCTAssertEqual(mock.focusedHandle, survivor.handle)
                model.performShortcut(.focusNextSection)
                XCTAssertEqual(mock.focusedHandle, windows[0].handle)
            }
        }
    }

    func testClosingFocusedWindowWithStaleAXFocusKeepsSectionFocusMode() {
        let (model, mock, sectionID, windows) = makeWindowCloseFocusFixture()
        model.toggleFocusMode(for: sectionID)
        XCTAssertEqual(mock.focusedHandle, windows[2].handle)

        model.confirmWindowDestroyed(windows[2].handle, reportedFrontmostPID: windows[2].pid)

        XCTAssertEqual(mock.focusedHandle, windows[1].handle)
        XCTAssertEqual(model.focusedManagedWindowID, windows[1].id)
        XCTAssertEqual(model.focusedSectionID, sectionID)
    }

    func testClosingWindowDoesNotStealFocusOrActivateDuringSystemTransitions() {
        for scenario in ["background window", "other section", "other application", "unattached window", "sleep"] {
            let (model, mock, sectionID, windows) = makeWindowCloseFocusFixture()
            var closed = windows[2]
            var frontmostPID = closed.pid
            switch scenario {
            case "background window":
                closed = windows[0]
            case "other section":
                let otherSection = UUID()
                let other = managedWindow(bundleIdentifier: "other", ordinal: 3)
                model.sections[otherSection] = LayoutSectionState(
                    id: otherSection, windows: [other], activeWindowID: other.id
                )
                model.focus(windowID: other.id)
            case "other application":
                frontmostPID += 10
            case "unattached window":
                // The AX focus event has not reached the model yet; the fresh
                // read must still respect the user's newly focused window.
                mock.focusedHandle = AXWindowHandle(element: AXUIElementCreateApplication(12345))
            case "sleep":
                model.beginSystemTransition(.systemSleep)
            default:
                XCTFail("Unknown close scenario")
            }
            let focusedBeforeClose = mock.focusedHandle
            let requestsBeforeClose = mock.focusRequests.count

            model.confirmWindowDestroyed(closed.handle, reportedFrontmostPID: frontmostPID)

            XCTAssertFalse(model.sections[sectionID]?.windows.contains { $0.id == closed.id } ?? true, scenario)
            XCTAssertEqual(mock.focusRequests.count, requestsBeforeClose, scenario)
            XCTAssertEqual(mock.focusedHandle, focusedBeforeClose, scenario)
        }
    }

    func testClosingLastWindowDoesNotFocusAnotherSection() {
        let (model, mock, sectionID, windows) = makeWindowCloseFocusFixture()
        model.sections[sectionID]?.windows = [windows[2]]
        let otherSection = UUID()
        model.sections[otherSection] = LayoutSectionState(
            id: otherSection, windows: [windows[0]], activeWindowID: windows[0].id
        )
        let requestsBeforeClose = mock.focusRequests.count

        model.confirmWindowDestroyed(windows[2].handle, reportedFrontmostPID: windows[2].pid)

        XCTAssertNil(model.sections[sectionID])
        XCTAssertNil(model.focusedManagedWindowID)
        XCTAssertEqual(mock.focusRequests.count, requestsBeforeClose)
    }

    private func makeWindowCloseFocusFixture(
        differentApplication: Bool = false
    ) -> (PanoptosModel, MockAccessibility, UUID, [ManagedWindow]) {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let pid = ProcessInfo.processInfo.processIdentifier
        let windows = (0..<3).map { index in
            managedWindow(
                bundleIdentifier: differentApplication && index == 1 ? "survivor" : "editor",
                ordinal: index,
                pid: differentApplication && index == 1 ? pid + 1 : pid
            )
        }
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID, windows: windows, activeWindowID: windows[2].id
        )
        for window in windows {
            mock.windowSnapshotsByHandle[window.handle] = snapshot(
                handle: window.handle, title: window.title, pid: window.pid
            )
        }
        model.focus(windowID: windows[2].id)
        return (model, mock, sectionID, windows)
    }

    func testDestroyedWindowIsPreservedWhenItsApplicationThenTerminates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: window, to: sectionID)
        let managed = try XCTUnwrap(model.sections[sectionID]?.windows.first)

        model.confirmWindowDestroyed(handle)
        model.confirmApplicationTerminated(
            pid: managed.pid,
            bundleIdentifier: managed.bundleIdentifier
        )
        model.finalizeWindowDestructions([managed.id])

        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertEqual(store.load().first?.awaitsApplicationRelaunch, true)
    }

    func testDetachingLastWindowClearsClosedAssignmentsAndStaysDetachedAfterRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let closedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let remainingHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let closed = snapshot(handle: closedHandle, title: "Closed")
        let remaining = snapshot(handle: remainingHandle, title: "Remaining")
        let newlyCreated = snapshot(handle: newHandle, title: "New")
        mock.windowSnapshots = [closed, remaining]
        mock.windowSnapshotsByHandle = [closedHandle: closed, remainingHandle: remaining]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: closed, to: sectionID)
        model.attach(window: remaining, to: sectionID)
        let closedID = try XCTUnwrap(model.managedWindow(matching: closedHandle)?.id)
        let remainingID = try XCTUnwrap(model.managedWindow(matching: remainingHandle)?.id)

        mock.windowSnapshots = [remaining]
        model.confirmWindowDestroyed(closedHandle)
        XCTAssertEqual(model.orphanedAssignments.map(\.id), [closedID])
        model.detach(windowID: remainingID)
        model.finalizeWindowDestructions([closedID])

        XCTAssertTrue(model.orphanedAssignments.isEmpty)
        XCTAssertTrue(model.pendingDestroyedWindows.isEmpty)
        XCTAssertNil(model.windowReopenObservationIdentities[pid])
        XCTAssertNil(model.lastFocusedSectionByPID[pid])
        XCTAssertTrue(store.load().isEmpty)
        mock.windowSnapshots = [remaining, newlyCreated]
        mock.windowSnapshotsByHandle[newHandle] = newlyCreated
        let frameCalls = mock.setFrameHandles.count
        XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .ignored)
        XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid, isDeferredRetry: true), .ignored)
        XCTAssertEqual(mock.setFrameHandles.count, frameCalls)

        let relaunched = makeModel(mock: mock, directory: directory)
        XCTAssertTrue(relaunched.sections.values.allSatisfy { $0.windows.isEmpty })
        XCTAssertEqual(relaunched.attachNewlyCreatedWindow(newHandle, pid: pid), .ignored)
        XCTAssertEqual(mock.setFrameHandles.count, frameCalls)

        relaunched.attach(window: remaining, to: sectionID)
        XCTAssertEqual(relaunched.attachNewlyCreatedWindow(newHandle, pid: pid), .attached)
    }

    func testDetachingOneWindowKeepsAutomaticAttachmentInOtherSection() throws {
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let closedHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        let closed = snapshot(handle: closedHandle, title: "Closed")
        mock.windowSnapshots = [first, second, closed]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second, closedHandle: closed]
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .leaf(id: firstSectionID), second: .leaf(id: secondSectionID)
        ))
        model.attach(window: first, to: firstSectionID)
        model.attach(window: second, to: secondSectionID)
        model.attach(window: closed, to: secondSectionID)
        let firstID = try XCTUnwrap(model.managedWindow(matching: firstHandle)?.id)
        let closedID = try XCTUnwrap(model.managedWindow(matching: closedHandle)?.id)
        model.confirmWindowDestroyed(closedHandle)
        model.detach(windowID: firstID)

        XCTAssertEqual(model.orphanedAssignments.map(\.id), [closedID])
        XCTAssertEqual(model.attachNewlyCreatedWindow(closedHandle, pid: pid), .attached)
        XCTAssertEqual(model.managedWindow(matching: closedHandle)?.id, closedID)
        XCTAssertEqual(model.sections[secondSectionID]?.windows.map(\.handle), [secondHandle, closedHandle])
    }

    func testDetachedWindowIsNotReclaimedByAStaleRelaunchRecord() throws {
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)
        let firstID = try XCTUnwrap(model.managedWindow(matching: firstHandle)?.id)
        let bundleIdentifier = try XCTUnwrap(model.managedWindow(matching: firstHandle)?.bundleIdentifier)
        // A record left behind by an earlier process of the same application.
        // Its window never came back, but it still names this window's index.
        model.orphanedAssignments = [PersistedWindowAssignment(
            id: UUID(),
            sectionID: sectionID,
            additionalSectionIDs: [],
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid - 1,
            accessibilityIdentifier: nil,
            title: "Before quit",
            windowOrdinal: 0,
            order: 0,
            isActive: false,
            orphanedAt: Date(),
            awaitsApplicationRelaunch: true,
            displayTopology: model.currentDisplayTopology
        )]
        model.prepareApplicationRelaunchRecovery(pid: pid, bundleIdentifier: bundleIdentifier)

        model.detach(windowID: firstID)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertNil(model.managedWindow(matching: firstHandle))
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [secondHandle])
        XCTAssertEqual(model.attachNewlyCreatedWindow(firstHandle, pid: pid), .ignored)
        XCTAssertNil(model.managedWindow(matching: firstHandle))

        // Explicit attachment is the user's decision and always wins.
        model.attach(window: first, to: sectionID)
        XCTAssertNotNil(model.managedWindow(matching: firstHandle))
    }

    func testDetachedWindowIgnoresALaterCreationNotificationUntilReattached() throws {
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)
        let firstID = try XCTUnwrap(model.managedWindow(matching: firstHandle)?.id)

        model.detach(windowID: firstID)
        XCTAssertEqual(model.attachNewlyCreatedWindow(firstHandle, pid: pid), .ignored)
        XCTAssertEqual(model.attachNewlyCreatedWindow(firstHandle, pid: pid, isDeferredRetry: true), .ignored)
        XCTAssertNil(model.managedWindow(matching: firstHandle))

        // The window closing ends the exemption; a later element is a new window.
        model.confirmWindowDestroyed(firstHandle)
        XCTAssertTrue(model.userDetachedWindowHandles.isEmpty)
    }

    func testTerminationDiscardsRelaunchRecordsTheProcessNeverClaimed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Live")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: window, to: sectionID)
        let liveID = try XCTUnwrap(model.managedWindow(matching: handle)?.id)
        let bundleIdentifier = try XCTUnwrap(model.managedWindow(matching: handle)?.bundleIdentifier)
        let stale = PersistedWindowAssignment(
            id: UUID(),
            sectionID: sectionID,
            additionalSectionIDs: [],
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid - 1,
            accessibilityIdentifier: nil,
            title: "Never came back",
            windowOrdinal: 3,
            order: 1,
            isActive: false,
            orphanedAt: Date(),
            awaitsApplicationRelaunch: true,
            displayTopology: model.currentDisplayTopology
        )
        model.orphanedAssignments = [stale]
        model.prepareApplicationRelaunchRecovery(pid: pid, bundleIdentifier: bundleIdentifier)
        model.persistWindowAssignments()
        XCTAssertEqual(Set(store.load().map(\.id)), [liveID, stale.id])

        model.confirmApplicationTerminated(pid: pid, bundleIdentifier: bundleIdentifier)

        XCTAssertEqual(store.load().map(\.id), [liveID])
        XCTAssertEqual(store.load().first?.awaitsApplicationRelaunch, true)
        XCTAssertEqual(model.orphanedAssignments.map(\.id), [liveID])
    }

    func testLaunchDiscardsReopenRecordsWhoseProcessIsGone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let sectionID = UUID()
        let firstModel = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        let application = try XCTUnwrap(firstModel.runningApplication(pid: pid))
        let bundleIdentifier = try XCTUnwrap(application.bundleIdentifier)
        func record(pid: pid_t, title: String) -> PersistedWindowAssignment {
            PersistedWindowAssignment(
                id: UUID(),
                sectionID: sectionID,
                additionalSectionIDs: [],
                bundleIdentifier: bundleIdentifier,
                processIdentifier: pid,
                accessibilityIdentifier: nil,
                title: title,
                windowOrdinal: 0,
                order: 0,
                isActive: false,
                orphanedAt: Date(),
                awaitsWindowReopen: true,
                displayTopology: firstModel.currentDisplayTopology
            )
        }
        let live = record(pid: pid, title: "Closed in a running process")
        let dead = record(pid: pid - 1, title: "Closed in a process that quit")
        try store.save([live, dead])

        let relaunched = makeModel(mock: mock, directory: directory)

        XCTAssertEqual(relaunched.orphanedAssignments.map(\.id), [live.id])
        XCTAssertEqual(store.load().map(\.id), [live.id])
    }

    func testDestroyedWindowIsPreservedForReopenWhenApplicationRemainsRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: window, to: sectionID)
        let managed = try XCTUnwrap(model.sections[sectionID]?.windows.first)

        model.confirmWindowDestroyed(handle)
        model.finalizeWindowDestructions([managed.id])

        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertEqual(store.load().first?.awaitsWindowReopen, true)
        XCTAssertTrue(model.windowObservationPIDs.contains(managed.pid))
    }

    func testClosedWindowReattachesAfterPanoptosRelaunchWhileApplicationStaysOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let clock = MockClock()
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let first = snapshot(handle: firstHandle, title: "Document before close")
        firstMock.windowSnapshots = [first]
        firstMock.windowSnapshotsByHandle[firstHandle] = first
        let sectionID = UUID()
        let firstModel = makeModel(
            mock: firstMock,
            root: .leaf(id: sectionID),
            directory: directory,
            clock: clock
        )
        firstModel.attach(window: first, to: sectionID)
        let originalID = try XCTUnwrap(firstModel.sections[sectionID]?.windows.first?.id)

        firstMock.windowSnapshots = []
        firstMock.listedWindowHandles = []
        firstModel.confirmWindowDestroyed(firstHandle)
        clock.advance(PanoptosModel.windowDestructionTerminationMaxWait + 1)
        firstModel.finalizeWindowDestructions([originalID])
        XCTAssertEqual(store.load().first?.awaitsWindowReopen, true)

        let relaunchedMock = MockAccessibility()
        let relaunchedModel = makeModel(mock: relaunchedMock, directory: directory, clock: clock)
        XCTAssertTrue(relaunchedModel.windowObservationPIDs.contains(first.pid))

        let reopenedHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let reopened = snapshot(handle: reopenedHandle, title: "Document after reopen")
        relaunchedMock.windowSnapshots = [reopened]
        relaunchedMock.windowSnapshotsByHandle[reopenedHandle] = reopened
        relaunchedMock.listedWindowHandles = [reopenedHandle]

        XCTAssertEqual(
            relaunchedModel.attachNewlyCreatedWindow(reopenedHandle, pid: reopened.pid),
            .attached
        )
        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.id), [originalID])
        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.handle), [reopenedHandle])
        XCTAssertNil(store.load().first?.awaitsWindowReopen)
    }

    func testReopenedWindowReturnsToItsVacatedSectionInsteadOfFollowingASibling() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let closedHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let first = snapshot(handle: firstHandle, title: "First", pid: pid)
        let closed = snapshot(handle: closedHandle, title: "Second before close", pid: pid)
        mock.windowSnapshots = [first, closed]
        mock.windowSnapshotsByHandle = [firstHandle: first, closedHandle: closed]
        let model = makeModel(mock: mock, root: root)
        model.attach(window: first, to: firstSectionID)
        model.attach(window: closed, to: secondSectionID)
        let closedID = try XCTUnwrap(model.sections[secondSectionID]?.windows.first?.id)

        mock.windowSnapshots = [first]
        mock.listedWindowHandles = [firstHandle]
        model.confirmWindowDestroyed(closedHandle)

        let reopenedHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let reopened = snapshot(handle: reopenedHandle, title: "Second after reopen", pid: pid)
        mock.windowSnapshots = [first, reopened]
        mock.windowSnapshotsByHandle[reopenedHandle] = reopened
        mock.listedWindowHandles = [firstHandle, reopenedHandle]

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(reopenedHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )
        XCTAssertEqual(model.sections[firstSectionID]?.windows.map(\.handle), [firstHandle])
        XCTAssertEqual(model.sections[secondSectionID]?.windows.map(\.handle), [reopenedHandle])
        XCTAssertEqual(model.sections[secondSectionID]?.windows.map(\.id), [closedID])
        XCTAssertNil(model.pendingDestroyedWindows[closedID])
    }

    func testReopenedWindowsRestoreReservedSwitcherSlotsWhenOpenedOutOfOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let thirdHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 2))
        let first = snapshot(handle: firstHandle, title: "First", pid: pid)
        let second = snapshot(handle: secondHandle, title: "Second", pid: pid)
        let third = snapshot(handle: thirdHandle, title: "Third", pid: pid)
        mock.windowSnapshots = [first, second, third]
        mock.windowSnapshotsByHandle = [
            firstHandle: first,
            secondHandle: second,
            thirdHandle: third
        ]
        let sectionID = UUID()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            directory: directory
        )
        for window in [first, second, third] {
            model.attach(window: window, to: sectionID)
        }
        let originalIDs = try XCTUnwrap(model.sections[sectionID]?.windows.map(\.id))
        XCTAssertEqual(originalIDs.count, 3)

        model.confirmWindowDestroyed(firstHandle)
        model.confirmWindowDestroyed(secondHandle)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [originalIDs[2]])

        // Reopen the second slot while the first is still reserved. Comparing
        // its absolute order directly with the one-item live array used to put
        // it after the third slot and permanently swap their switcher order.
        let reopenedSecondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 3))
        let reopenedSecond = snapshot(handle: reopenedSecondHandle, title: "Second", pid: pid)
        mock.windowSnapshots = [third, reopenedSecond]
        mock.windowSnapshotsByHandle[reopenedSecondHandle] = reopenedSecond
        mock.listedWindowHandles = [thirdHandle, reopenedSecondHandle]

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(reopenedSecondHandle, pid: pid),
            .attached
        )
        XCTAssertEqual(
            model.sections[sectionID]?.windows.map(\.id),
            [originalIDs[1], originalIDs[2]]
        )

        let reopenedFirstHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 4))
        let reopenedFirst = snapshot(handle: reopenedFirstHandle, title: "First", pid: pid)
        mock.windowSnapshots = [reopenedSecond, third, reopenedFirst]
        mock.windowSnapshotsByHandle[reopenedFirstHandle] = reopenedFirst
        mock.listedWindowHandles = [reopenedSecondHandle, thirdHandle, reopenedFirstHandle]

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(reopenedFirstHandle, pid: pid),
            .attached
        )
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), originalIDs)
        XCTAssertEqual(
            WindowAssignmentPersistence(
                url: directory.appendingPathComponent("window-assignments.json")
            ).load().sorted(by: { $0.order < $1.order }).map(\.id),
            originalIDs
        )
    }

    func testLaunchRestoreDoesNotLetAClosedRecordClaimALiveSibling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstMock = MockAccessibility()
        let closedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let siblingHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let closed = snapshot(handle: closedHandle, title: "Alpha", pid: pid)
        let sibling = snapshot(handle: siblingHandle, title: "Beta", pid: pid)
        firstMock.windowSnapshots = [closed, sibling]
        firstMock.windowSnapshotsByHandle = [closedHandle: closed, siblingHandle: sibling]
        let firstModel = makeModel(
            mock: firstMock,
            root: root,
            directory: directory
        )
        firstModel.attach(window: closed, to: firstSectionID)
        firstModel.attach(window: sibling, to: secondSectionID)
        let closedID = try XCTUnwrap(firstModel.sections[firstSectionID]?.windows.first?.id)
        let siblingID = try XCTUnwrap(firstModel.sections[secondSectionID]?.windows.first?.id)

        firstMock.windowSnapshots = [sibling]
        firstMock.listedWindowHandles = [siblingHandle]
        firstModel.confirmWindowDestroyed(closedHandle)
        firstModel.finalizeWindowDestructions([closedID])

        let relaunchMock = MockAccessibility()
        relaunchMock.windowSnapshots = [sibling]
        relaunchMock.windowSnapshotsByHandle[siblingHandle] = sibling
        relaunchMock.listedWindowHandles = [siblingHandle]
        let relaunchedModel = makeModel(mock: relaunchMock, directory: directory)

        XCTAssertNil(relaunchedModel.sections[firstSectionID])
        XCTAssertEqual(relaunchedModel.sections[secondSectionID]?.windows.map(\.id), [siblingID])
        XCTAssertEqual(relaunchedModel.sections[secondSectionID]?.windows.map(\.handle), [siblingHandle])
        XCTAssertEqual(relaunchedModel.orphanedAssignments.map(\.id), [closedID])
    }

    func testApplicationTerminationDropsFinalizedClosedRecordsButPreservesLiveWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let closedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let liveHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let closed = snapshot(handle: closedHandle, title: "Closed", pid: pid)
        let live = snapshot(handle: liveHandle, title: "Live", pid: pid)
        mock.windowSnapshots = [closed, live]
        mock.windowSnapshotsByHandle = [closedHandle: closed, liveHandle: live]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: closed, to: sectionID)
        model.attach(window: live, to: sectionID)
        let closedID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        mock.windowSnapshots = [live]
        mock.listedWindowHandles = [liveHandle]
        model.confirmWindowDestroyed(closedHandle)
        model.finalizeWindowDestructions([closedID])
        model.confirmApplicationTerminated(
            pid: pid,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

        XCTAssertEqual(store.load().map(\.title), ["Live"])
        XCTAssertEqual(store.load().first?.awaitsApplicationRelaunch, true)
        XCTAssertNil(store.load().first?.awaitsWindowReopen)
    }

    func testPendingDestroyedWindowCannotClaimAnUnmanagedSibling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let mock = MockAccessibility()
        let attachedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let freeHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let attached = snapshot(handle: attachedHandle, title: "Inbox")
        let free = snapshot(handle: freeHandle, title: "Inbox")
        mock.windowSnapshots = [attached, free]
        mock.windowSnapshotsByHandle = [attachedHandle: attached, freeHandle: free]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: attached, to: sectionID)

        model.confirmWindowDestroyed(attachedHandle)
        mock.windowSnapshots = [free]
        mock.listedWindowHandles = [freeHandle]
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(mock.setFrameHandles.filter { $0 == freeHandle }, [])

        let destroyedID = try XCTUnwrap(store.load().first?.id)
        model.finalizeWindowDestructions([destroyedID])
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(store.load().map(\.title), ["Inbox"])
        XCTAssertEqual(store.load().first?.awaitsWindowReopen, true)
        XCTAssertNil(model.sections[sectionID])
        XCTAssertEqual(mock.setFrameHandles.filter { $0 == freeHandle }, [])
    }

    func testEmptyWindowListExtendsDestructionGraceForSlowApplicationQuit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            directory: directory,
            clock: clock
        )
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        mock.windowSnapshots = []
        mock.listedWindowHandles = []
        model.confirmWindowDestroyed(handle)
        model.finalizeWindowDestructions([windowID])

        XCTAssertEqual(store.load().map(\.title), ["Managed"])

        clock.advance(PanoptosModel.windowDestructionTerminationMaxWait + 1)
        model.finalizeWindowDestructions([windowID])
        XCTAssertEqual(store.load().map(\.title), ["Managed"])
        XCTAssertEqual(store.load().first?.awaitsWindowReopen, true)
    }

    func testModelRelaunchUsesQuitRecordAcrossAChangedPIDAndTitle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mock = MockAccessibility()
        let reopenedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let reopened = snapshot(handle: reopenedHandle, title: "Untitled after reopen")
        mock.windowSnapshots = [reopened]
        mock.windowSnapshotsByHandle[reopenedHandle] = reopened
        let sectionID = UUID()
        let firstModel = makeModel(
            mock: MockAccessibility(),
            root: .leaf(id: sectionID),
            directory: directory
        )
        let application = try XCTUnwrap(firstModel.runningApplication(pid: reopened.pid))
        let assignment = PersistedWindowAssignment(
            id: UUID(),
            sectionID: sectionID,
            additionalSectionIDs: [],
            bundleIdentifier: try XCTUnwrap(application.bundleIdentifier),
            processIdentifier: reopened.pid - 1,
            accessibilityIdentifier: nil,
            title: "Document before quit",
            windowOrdinal: 0,
            order: 0,
            isActive: true,
            orphanedAt: Date(),
            awaitsApplicationRelaunch: true,
            displayTopology: firstModel.currentDisplayTopology
        )
        try WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).save([assignment])

        let relaunchedModel = makeModel(mock: mock, directory: directory)

        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.handle), [reopenedHandle])
        XCTAssertEqual(relaunchedModel.sections[sectionID]?.activeWindowID, assignment.id)
        XCTAssertTrue(relaunchedModel.orphanedAssignments.isEmpty)
        XCTAssertNil(relaunchedModel.savedWindowAssignments.first?.awaitsApplicationRelaunch)
    }

    func testTerminatingADifferentApplicationThatReusedThePIDKeepsTheOrphan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WindowAssignmentPersistence(url: directory.appendingPathComponent("window-assignments.json"))
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: window, to: sectionID)

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(store.load().count, 1)

        // macOS handed the orphan's pid to something else, which then quit.
        model.confirmApplicationTerminated(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: "com.example.unrelated"
        )

        XCTAssertEqual(store.load().map(\.title), ["Managed"])
    }

    func testAnAlreadyExpiredPersistedOrphanIsRetriedInTheNewSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sectionID = UUID()
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: firstHandle, title: "Managed")
        firstMock.windowSnapshots = [window]
        firstMock.windowSnapshotsByHandle[firstHandle] = window
        let firstClock = MockClock()
        let firstModel = makeModel(
            mock: firstMock,
            root: .leaf(id: sectionID),
            directory: directory,
            clock: firstClock
        )
        firstModel.attach(window: window, to: sectionID)
        firstMock.snapshotErrorsByHandle[firstHandle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        firstMock.listedWindowHandles = []
        firstModel.refreshRuntime(reportedFrontmostPID: nil)
        firstClock.advance(60)
        firstModel.refreshRuntime(reportedFrontmostPID: nil)

        // Relaunching days later must not inherit a retry window that has
        // already run out.
        let relaunchClock = MockClock()
        relaunchClock.advance(7 * 24 * 3_600)
        let relaunchMock = MockAccessibility()
        let relaunchedModel = makeModel(mock: relaunchMock, directory: directory, clock: relaunchClock)
        XCTAssertNil(relaunchedModel.sections[sectionID])

        let lateHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let late = snapshot(handle: lateHandle, title: "Managed")
        relaunchMock.windowSnapshots = [late]
        relaunchMock.windowSnapshotsByHandle[lateHandle] = late
        relaunchClock.advance(5)
        relaunchedModel.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.handle), [lateHandle])
    }

    func testReclaimedWindowReturnsToItsOriginalPositionInTheSection() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        // Distinct pids only to obtain three distinct AX elements; the
        // snapshots still report this process, which is what the model reads.
        let handles = (0..<3).map { AXWindowHandle(element: AXUIElementCreateApplication(pid_t(901 + $0))) }
        let titles = ["First", "Second", "Third"]
        var snapshots = zip(handles, titles).map { snapshot(handle: $0, title: $1) }
        mock.windowSnapshots = snapshots
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: zip(handles, snapshots))
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        for snapshot in snapshots { model.attach(window: snapshot, to: sectionID) }
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), titles)

        // The middle window's element is replaced.
        mock.snapshotErrorsByHandle[handles[1]] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = [handles[0], handles[2]]
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), ["First", "Third"])

        let replacementHandle = AXWindowHandle(element: AXUIElementCreateApplication(904))
        let replacement = snapshot(handle: replacementHandle, title: "Second")
        snapshots[1] = replacement
        mock.snapshotErrorsByHandle.removeValue(forKey: handles[1])
        mock.windowSnapshots = snapshots
        mock.windowSnapshotsByHandle[replacementHandle] = replacement
        mock.listedWindowHandles = nil
        clock.advance(5)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), titles)
    }

    func testInvalidWindowsReadTheirApplicationsWindowListOncePerRefresh() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)

        let invalid = AccessibilityClientError.attribute(kAXRoleAttribute as String, .invalidUIElement)
        mock.snapshotErrorsByHandle = [firstHandle: invalid, secondHandle: invalid]
        // Both windows are still listed, so neither is removed and both keep
        // asking on every pass.
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        mock.resetWindowHandlesCallCount()
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.count, 2)
        XCTAssertEqual(mock.windowHandlesCallCount, 1)
    }

    func testHeuristicDetachStillRestoresTheWindowOnRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory, clock: clock)
        model.attach(window: window, to: sectionID)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .invalidUIElement
        )
        mock.listedWindowHandles = []
        model.refreshRuntime(reportedFrontmostPID: nil)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.sections[sectionID])

        let relaunchMock = MockAccessibility()
        let relaunchHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let relaunched = snapshot(handle: relaunchHandle, title: "Managed")
        relaunchMock.windowSnapshots = [relaunched]
        relaunchMock.windowSnapshotsByHandle[relaunchHandle] = relaunched
        let relaunchedModel = makeModel(mock: relaunchMock, directory: directory)

        XCTAssertEqual(relaunchedModel.sections[sectionID]?.windows.map(\.title), ["Managed"])
    }

    func testTransientSnapshotFailureRetainsFocusedManagedWindow() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Focused")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        let focusedID = try XCTUnwrap(model.sections[sectionID]?.activeWindowID)

        mock.snapshotError = AccessibilityClientError.attribute(kAXPositionAttribute as String, .cannotComplete)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        XCTAssertEqual(model.focusedManagedWindowID, focusedID)
    }

    func testFocusedWindowReadFailureRetainsPreviousManagedFocusForFrontmostApplication() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Focused")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        let focusedID = try XCTUnwrap(model.focusedManagedWindowID)

        mock.focusedWindowError = AccessibilityClientError.attribute(
            kAXFocusedWindowAttribute as String,
            .cannotComplete
        )
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        XCTAssertEqual(model.focusedManagedWindowID, focusedID)
    }

    func testFocusedUnmanagedWindowClearsPreviousManagedFocusForSameApplication() throws {
        let mock = MockAccessibility()
        let managedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let managedWindow = snapshot(handle: managedHandle, title: "Managed")
        mock.windowSnapshot = managedWindow
        mock.windowSnapshotsByHandle[managedHandle] = managedWindow
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: managedWindow, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(model.focusedManagedWindowID)

        mock.focusedHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        XCTAssertNil(model.focusedManagedWindowID)
    }

    /// The overlay repaints its focused appearance from this, so it must reach
    /// the answer without the per-window Accessibility sweep that made the
    /// appearance trail the click.
    func testRefreshFocusedWindowResolvesFocusWithoutSnapshottingEveryManagedWindow() throws {
        let first = UUID()
        let second = UUID()
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: first),
                second: .leaf(id: second)
            )
        )
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let firstWindow = snapshot(handle: firstHandle, title: "First")
        let secondWindow = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [firstWindow, secondWindow]
        mock.windowSnapshotsByHandle[firstHandle] = firstWindow
        mock.windowSnapshotsByHandle[secondHandle] = secondWindow
        model.attach(window: firstWindow, to: first)
        model.attach(window: secondWindow, to: second)
        mock.focusedHandle = firstHandle
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        let firstID = try XCTUnwrap(model.sections[first]?.windows.first?.id)
        let secondID = try XCTUnwrap(model.sections[second]?.windows.first?.id)
        XCTAssertEqual(model.focusedManagedWindowID, firstID)

        var repaints = 0
        model.onOverlayPresentationChanged = { repaints += 1 }
        mock.focusedHandle = secondHandle
        mock.resetSnapshotCallCount()
        XCTAssertTrue(model.refreshFocusedWindow(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier))

        XCTAssertEqual(model.focusedManagedWindowID, secondID)
        XCTAssertEqual(model.sections[second]?.activeWindowID, secondID)
        XCTAssertEqual(repaints, 1)
        XCTAssertEqual(mock.snapshotCallCount, 0)
    }

    func testRefreshFocusedWindowReportsNoChangeAndDoesNotRepaintWhenFocusIsUnmoved() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Focused")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        var repaints = 0
        model.onOverlayPresentationChanged = { repaints += 1 }
        XCTAssertFalse(model.refreshFocusedWindow(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier))

        XCTAssertEqual(repaints, 0)
    }

    /// An unreadable focused window must not flicker the overlay, exactly as in
    /// the full runtime pass.
    func testRefreshFocusedWindowRetainsPreviousFocusWhenTheReadFails() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Focused")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        let focusedID = try XCTUnwrap(model.focusedManagedWindowID)

        mock.focusedWindowError = AccessibilityClientError.attribute(
            kAXFocusedWindowAttribute as String,
            .cannotComplete
        )
        model.refreshFocusedWindow(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        XCTAssertEqual(model.focusedManagedWindowID, focusedID)
    }

    func testRefreshFocusedWindowClearsFocusWhenTheFrontmostApplicationIsUnmanaged() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Focused")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { [] }
        )
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        XCTAssertNotNil(model.focusedManagedWindowID)

        var repaints = 0
        model.onOverlayPresentationChanged = { repaints += 1 }
        model.refreshFocusedWindow(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier + 1)

        XCTAssertNil(model.focusedManagedWindowID)
        XCTAssertEqual(repaints, 1)
    }

    /// `refreshRuntime()` only persists an active-window change it observed
    /// itself, so the cheap path that runs ahead of it has to persist its own.
    func testRefreshFocusedWindowPersistsTheActiveWindowItChose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mock = MockAccessibility()
        let sectionID = UUID()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let firstWindow = snapshot(handle: firstHandle, title: "First")
        let secondWindow = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [firstWindow, secondWindow]
        mock.windowSnapshotsByHandle[firstHandle] = firstWindow
        mock.windowSnapshotsByHandle[secondHandle] = secondWindow
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: firstWindow, to: sectionID)
        model.attach(window: secondWindow, to: sectionID)
        mock.focusedHandle = firstHandle
        model.refreshRuntime(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)

        mock.focusedHandle = secondHandle
        model.refreshFocusedWindow(reportedFrontmostPID: ProcessInfo.processInfo.processIdentifier)
        let chosen = try XCTUnwrap(model.sections[sectionID]?.activeWindowID)
        XCTAssertEqual(model.managedWindow(id: chosen)?.title, "Second")

        let relaunched = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        XCTAssertEqual(relaunched.sections[sectionID]?.activeWindow?.title, "Second")
    }

    func testFocusingAWindowRepaintsBeforeReadingItsMenu() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Target")
        mock.windowSnapshot = window
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        let windowID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)

        var focusedIDAtRepaint: UUID??
        var menuReadsAtRepaint: Int?
        model.onOverlayPresentationChanged = {
            focusedIDAtRepaint = model.focusedManagedWindowID
            menuReadsAtRepaint = mock.readMenuPIDs.count
        }
        // Force the menu read `focus(windowID:)` would otherwise skip as cached.
        // It is the blocking call the repaint must not queue behind.
        model.menusByPID.removeAll()
        let menuReadsBeforeFocus = mock.readMenuPIDs.count
        model.focus(windowID: windowID)

        XCTAssertEqual(focusedIDAtRepaint, windowID)
        XCTAssertEqual(menuReadsAtRepaint, menuReadsBeforeFocus)
    }

    func testRenameMigrationRestoresUserVisibleModelStateOnRelaunch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacyDirectory = base.appendingPathComponent("Panoptes")
        let currentDirectory = base.appendingPathComponent("Panoptos")
        let sectionID = UUID()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let firstSnapshot = AXWindowSnapshot(
            handle: firstHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "migrated-document",
            title: "Before rename",
            frame: CGRect(x: 50, y: 50, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        let firstMock = MockAccessibility()
        firstMock.windowSnapshot = firstSnapshot
        let firstModel = makeModel(mock: firstMock, root: .leaf(id: sectionID), directory: legacyDirectory)
        firstModel.attach(window: firstSnapshot, to: sectionID)
        firstModel.sectionBarsCentered = true
        let customShortcut = GlobalShortcut(keyCode: 0, keyLabel: "A", modifiers: [.control, .option])
        firstModel.setShortcut(customShortcut, for: .cycleNextWindow)

        try ApplicationSupportMigration.migrateLegacyData(in: base)

        let restoredHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let secondMock = MockAccessibility()
        secondMock.windowSnapshot = AXWindowSnapshot(
            handle: restoredHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "migrated-document",
            title: "After rename",
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )

        let relaunchedModel = makeModel(mock: secondMock, directory: currentDirectory)

        XCTAssertTrue(relaunchedModel.sectionBarsCentered)
        XCTAssertEqual(relaunchedModel.shortcuts[.cycleNextWindow], customShortcut)
        XCTAssertEqual(relaunchedModel.sections[sectionID]?.activeWindow?.handle, restoredHandle)
    }

    func testRelaunchRestoresPersistedWindowToItsSectionUsingAccessibilityIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sectionID = UUID()
        let firstMock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        firstMock.windowSnapshot = AXWindowSnapshot(
            handle: firstHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "document-window",
            title: "Document",
            frame: CGRect(x: 50, y: 50, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        let firstModel = makeModel(mock: firstMock, root: .leaf(id: sectionID), directory: directory)
        firstModel.attach(window: try XCTUnwrap(firstMock.windowSnapshot), to: sectionID)
        let originalID = try XCTUnwrap(firstModel.sections[sectionID]?.activeWindowID)

        let secondMock = MockAccessibility()
        let reconstructedHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        secondMock.windowSnapshot = AXWindowSnapshot(
            handle: reconstructedHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "document-window",
            title: "Document renamed while Panoptos was closed",
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )

        let relaunchedModel = makeModel(mock: secondMock, directory: directory)

        XCTAssertEqual(relaunchedModel.sections[sectionID]?.activeWindowID, originalID)
        XCTAssertEqual(relaunchedModel.sections[sectionID]?.activeWindow?.handle, reconstructedHandle)
        XCTAssertNotNil(secondMock.lastSetFrame)
        XCTAssertNil(secondMock.focusedHandle)
    }

    func testRelaunchRestoresBehaviorAndSectionBarSettings() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstModel = makeModel(mock: MockAccessibility(), directory: directory)
        firstModel.setWindowDragShortcut(nil, for: .attachApplicationWindows)
        firstModel.sectionBarsFillAvailableWidth = false
        firstModel.sectionBarsCentered = true
        firstModel.showWindowMenuBars = true
        firstModel.showUnattachedWindowIcons = false
        firstModel.setWindowSwitcherUIScale(2.75)
        firstModel.windowSwitcherTitleMode = .whenNeeded
        firstModel.limitWindowSwitcherTitleCharacters = true
        firstModel.invokeWithoutActivation = true
        firstModel.keepMacAwake = true
        firstModel.keepScreenOn = true
        firstModel.setWindowDragShortcut([.option], for: .attachWindow)
        firstModel.setWindowDragShortcut([.command, .shift], for: .attachApplicationWindows)

        let relaunchedModel = makeModel(mock: MockAccessibility(), directory: directory)

        XCTAssertTrue(relaunchedModel.attachAllApplicationWindowsWithControlShift)
        XCTAssertFalse(relaunchedModel.sectionBarsFillAvailableWidth)
        XCTAssertTrue(relaunchedModel.sectionBarsCentered)
        XCTAssertTrue(relaunchedModel.showWindowMenuBars)
        XCTAssertFalse(relaunchedModel.showUnattachedWindowIcons)
        XCTAssertEqual(relaunchedModel.windowSwitcherUIScale, 2.75)
        XCTAssertEqual(relaunchedModel.windowSwitcherTitleMode, .whenNeeded)
        XCTAssertTrue(relaunchedModel.limitWindowSwitcherTitleCharacters)
        XCTAssertTrue(relaunchedModel.invokeWithoutActivation)
        XCTAssertTrue(relaunchedModel.keepMacAwake)
        XCTAssertTrue(relaunchedModel.keepScreenOn)
        XCTAssertEqual(relaunchedModel.windowDragShortcut(for: .attachWindow), [.option])
        XCTAssertEqual(
            relaunchedModel.windowDragShortcut(for: .attachApplicationWindows),
            [.command, .shift]
        )
    }

    func testLaunchAtLoginWritesToTheSystemAndIsReadBackFromItOnRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loginItem = MockLoginItemController(state: .disabled)
        let firstModel = makeModel(mock: MockAccessibility(), directory: directory, loginItemController: loginItem)
        XCTAssertFalse(firstModel.launchAtLogin)

        firstModel.launchAtLogin = true

        XCTAssertEqual(loginItem.requestedValues, [true])
        XCTAssertEqual(loginItem.state, .enabled)
        XCTAssertNil(firstModel.launchAtLoginNotice)

        let relaunchedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            loginItemController: loginItem
        )

        XCTAssertTrue(relaunchedModel.launchAtLogin)

        // The system is the only source of truth: a relaunch that finds the
        // login item gone must show the toggle off, even though the same
        // settings file is still in place.
        let clearedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            loginItemController: MockLoginItemController(state: .disabled)
        )

        XCTAssertFalse(clearedModel.launchAtLogin)
    }

    func testLaunchAtLoginFailureRestoresTheToggleAndReportsTheReason() {
        let loginItem = MockLoginItemController(state: .disabled, failureToThrow: MockLoginItemFailure())
        let model = makeModel(mock: MockAccessibility(), loginItemController: loginItem)

        model.launchAtLogin = true

        XCTAssertEqual(loginItem.requestedValues, [true])
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(
            model.launchAtLoginNotice,
            "Could not add Panoptos to your login items: Operation not permitted"
        )
    }

    func testLaunchAtLoginReportsPendingApprovalAndPicksUpExternalChanges() {
        let loginItem = MockLoginItemController(state: .requiresApproval)
        let model = makeModel(mock: MockAccessibility(), loginItemController: loginItem)

        XCTAssertFalse(model.launchAtLogin)
        XCTAssertTrue(model.launchAtLoginNeedsSystemSettings)
        XCTAssertEqual(
            model.launchAtLoginNotice,
            "Panoptos is already a login item but macOS has it switched off. Turn it back on in Login Items."
        )

        loginItem.state = .enabled
        model.refreshLaunchAtLoginState()

        XCTAssertTrue(model.launchAtLogin)
        XCTAssertNil(model.launchAtLoginNotice)
        XCTAssertFalse(model.launchAtLoginNeedsSystemSettings)
        XCTAssertEqual(loginItem.requestedValues, [], "Reading the system state must not write to it")
    }

    /// Pending approval already means registered, so re-registering cannot fix
    /// it and would only replace the actionable notice with a failure.
    func testLaunchAtLoginDoesNotReregisterWhileApprovalIsPending() {
        let loginItem = MockLoginItemController(state: .requiresApproval)
        let model = makeModel(mock: MockAccessibility(), loginItemController: loginItem)

        model.launchAtLogin = true

        XCTAssertEqual(loginItem.requestedValues, [])
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertTrue(model.launchAtLoginNeedsSystemSettings)
        XCTAssertEqual(
            model.launchAtLoginNotice,
            "Panoptos is already a login item but macOS has it switched off. Turn it back on in Login Items."
        )
    }

    /// The re-registration guard covers enabling only. Unregistering must still
    /// reach the system, since that is what leaves pending-approval limbo.
    func testLaunchAtLoginStillUnregistersWhileApprovalIsPending() {
        let loginItem = MockLoginItemController(state: .requiresApproval)
        let model = makeModel(mock: MockAccessibility(), loginItemController: loginItem)
        XCTAssertFalse(model.launchAtLogin)

        model.launchAtLogin = false

        XCTAssertEqual(loginItem.requestedValues, [false])
        XCTAssertEqual(loginItem.state, .disabled)
        XCTAssertNil(model.launchAtLoginNotice)
        XCTAssertFalse(model.launchAtLoginNeedsSystemSettings)
    }

    func testAutomaticUpdateCheckPreferenceIsReadBackFromTheUpdaterOnRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let updater = MockUpdateController(automaticallyChecksForUpdates: true)
        let firstModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            updateController: updater
        )
        XCTAssertTrue(firstModel.automaticallyChecksForUpdates)

        firstModel.automaticallyChecksForUpdates = false

        XCTAssertFalse(updater.automaticallyChecksForUpdates)

        let relaunchedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            updateController: updater
        )

        XCTAssertFalse(relaunchedModel.automaticallyChecksForUpdates)
    }

    /// Sparkle owns this preference, so a relaunch has to follow the updater
    /// rather than anything Panoptos wrote. Nothing about it belongs in
    /// settings.json, and a stale copy there must not be able to win.
    func testAutomaticUpdateCheckPreferenceFollowsTheUpdaterNotTheSettingsFile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            updateController: MockUpdateController(automaticallyChecksForUpdates: false)
        )
        XCTAssertFalse(firstModel.automaticallyChecksForUpdates)

        // Same settings directory, an updater that reports the opposite value.
        let relaunchedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            updateController: MockUpdateController(automaticallyChecksForUpdates: true)
        )

        XCTAssertTrue(relaunchedModel.automaticallyChecksForUpdates)
    }

    func testCheckingForUpdatesAsksTheUpdaterOnce() {
        let updater = MockUpdateController()
        let model = makeModel(mock: MockAccessibility(), updateController: updater)

        model.checkForUpdatesNow()

        XCTAssertEqual(updater.checkCallCount, 1)
    }

    func testSettingTheSameUpdatePreferenceDoesNotTouchTheUpdater() {
        final class RecordingUpdateController: UpdateControlling {
            var storedValue = true
            private(set) var writeCount = 0
            var automaticallyChecksForUpdates: Bool {
                get { storedValue }
                set {
                    writeCount += 1
                    storedValue = newValue
                }
            }
            var lastUpdateCheckDate: Date?
            var canCheckForUpdates = true
            func checkForUpdates() {}
        }

        let updater = RecordingUpdateController()
        let model = makeModel(mock: MockAccessibility(), updateController: updater)

        model.automaticallyChecksForUpdates = true

        XCTAssertEqual(updater.writeCount, 0)

        model.automaticallyChecksForUpdates = false

        XCTAssertEqual(updater.writeCount, 1)
    }

    func testUpdateCheckButtonIsUnavailableWhileACheckIsRunning() {
        let model = makeModel(
            mock: MockAccessibility(),
            updateController: MockUpdateController(canCheckForUpdates: false)
        )

        XCTAssertFalse(model.canCheckForUpdates)
    }

    func testKeepMacAwakeControlsSleepAssertionAndRestoresItOnRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstController = MockKeepAwakeController()
        let firstModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            keepAwakeController: firstController
        )

        firstModel.keepMacAwake = true

        XCTAssertEqual(firstController.startCallCount, 1)
        XCTAssertEqual(firstController.displayStartCallCount, 0)

        let relaunchedController = MockKeepAwakeController()
        let relaunchedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            keepAwakeController: relaunchedController
        )

        XCTAssertTrue(relaunchedModel.keepMacAwake)
        XCTAssertFalse(relaunchedModel.keepScreenOn)
        XCTAssertEqual(relaunchedController.startCallCount, 1)
        XCTAssertEqual(relaunchedController.displayStartCallCount, 0)

        relaunchedModel.keepMacAwake = false

        XCTAssertEqual(relaunchedController.stopCallCount, 1)
    }

    func testKeepScreenOnEnablesAwakeAndRestoresBothAssertionsOnRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstController = MockKeepAwakeController()
        let firstModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            keepAwakeController: firstController
        )

        firstModel.keepScreenOn = true

        XCTAssertTrue(firstModel.keepMacAwake)
        XCTAssertTrue(firstModel.keepScreenOn)
        XCTAssertEqual(firstController.startCallCount, 1)
        XCTAssertEqual(firstController.displayStartCallCount, 1)

        let relaunchedController = MockKeepAwakeController()
        let relaunchedModel = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            keepAwakeController: relaunchedController
        )

        XCTAssertTrue(relaunchedModel.keepMacAwake)
        XCTAssertTrue(relaunchedModel.keepScreenOn)
        XCTAssertEqual(relaunchedController.startCallCount, 1)
        XCTAssertEqual(relaunchedController.displayStartCallCount, 1)

        relaunchedModel.keepMacAwake = false

        XCTAssertFalse(relaunchedModel.keepMacAwake)
        XCTAssertFalse(relaunchedModel.keepScreenOn)
        XCTAssertEqual(relaunchedController.stopCallCount, 1)
        XCTAssertEqual(relaunchedController.displayStopCallCount, 1)
    }

    func testWindowDragShortcutsMatchConfiguredModifierKeysExactly() {
        let model = makeModel(mock: MockAccessibility())
        model.setWindowDragShortcut([.option], for: .attachWindow)
        model.setWindowDragShortcut([.control, .option], for: .attachApplicationWindows)

        XCTAssertEqual(model.windowDragAction(for: [.option]), .attachWindow)
        XCTAssertEqual(model.windowDragAction(for: [.control, .option]), .attachApplicationWindows)
        XCTAssertNil(model.windowDragAction(for: [.option, .shift]))
        XCTAssertNil(model.windowDragAction(for: []))
    }

    func testSuccessfulWindowDragShortcutEditDoesNotClearUnrelatedShortcutError() {
        let model = makeModel(mock: MockAccessibility())
        model.setWindowDragShortcut([.control, .shift], for: .attachWindow)
        XCTAssertNotNil(model.shortcutError)

        let registrationError = "macOS could not register a global shortcut."
        model.shortcutError = registrationError
        model.setWindowDragShortcut([.option], for: .attachWindow)

        XCTAssertEqual(model.shortcutError, registrationError)
    }

    func testControlShiftAttachmentAddsAllResizableApplicationWindowsAndKeepsDraggedWindowActive() throws {
        let mock = MockAccessibility()
        let draggedHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let otherHandle = AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        let rigidHandle = AXWindowHandle(element: AXUIElementCreateApplication(0))
        let dragged = snapshot(handle: draggedHandle, title: "Dragged")
        let other = snapshot(handle: otherHandle, title: "Other")
        let rigid = AXWindowSnapshot(
            handle: rigidHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "Rigid",
            frame: CGRect(x: 100, y: 100, width: 300, height: 200),
            isMinimized: false,
            isFullScreen: false,
            isResizable: false
        )
        mock.windowSnapshot = dragged
        mock.windowSnapshots = [dragged, other, rigid]
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)

        XCTAssertTrue(model.attachAllApplicationWindowsWithControlShift)
        model.attachApplicationWindows(containing: dragged, to: sectionID)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [otherHandle, draggedHandle])
        XCTAssertEqual(model.sections[sectionID]?.activeWindow?.handle, draggedHandle)
        XCTAssertEqual(mock.focusedHandle, draggedHandle)
        XCTAssertEqual(mock.setFrameHandles, [otherHandle, draggedHandle])
    }

    @MainActor
    func testNewApplicationWindowAutomaticallyAttachesToExistingWindowSection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "New", pid: pid)
        mock.windowSnapshots = [existing]
        mock.windowSnapshotsByHandle = [existingHandle: existing]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: existing, to: sectionID)
        let focusCallsAfterExplicitAttachment = mock.focusCallCount

        mock.windowSnapshots = [existing, newlyCreated]
        mock.windowSnapshotsByHandle[newHandle] = newlyCreated
        mock.focusedHandle = newHandle

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), ["Existing", "New"])
        XCTAssertEqual(model.sections[sectionID]?.activeWindow?.handle, newHandle)
        XCTAssertEqual(mock.focusCallCount, focusCallsAfterExplicitAttachment)
        let frameCallsAfterAutomaticAttachment = mock.setFrameHandles.count
        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: pid),
            .ignored
        )
        XCTAssertEqual(mock.setFrameHandles.count, frameCallsAfterAutomaticAttachment)

        let stored = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.title == "New" && $0.sectionID == sectionID })
    }

    @MainActor
    func testWindowCreatedDuringWakeSettlingAttachesAfterSettlingWithoutAnotherNotification() throws {
        for (incompleteFirstRead, observerRetryDelay) in [
            (false, 0.25), (true, 0.25), (true, PanoptosModel.transitionSettleInterval + 1)
        ] {
            let clock = MockClock()
            let mock = MockAccessibility()
            let sectionID = UUID()
            let pid = ProcessInfo.processInfo.processIdentifier
            let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
            let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
            let existing = snapshot(handle: existingHandle, title: "Existing")
            let newWindow = snapshot(handle: newHandle, title: "Opened after wake")
            mock.windowSnapshots = [existing, newWindow]
            mock.windowSnapshotsByHandle = [existingHandle: existing, newHandle: newWindow]
            let model = makeModel(mock: mock, root: .leaf(id: sectionID), clock: clock)
            model.attach(window: existing, to: sectionID)
            let focusCalls = mock.focusCallCount
            model.compatibilityError = "Keep this notice"
            model.beginSystemTransition(.screenSleep)
            model.endSystemTransition(.screenSleep)
            mock.resetSnapshotCallCount()
            mock.resetWindowsCallCount()
            mock.resetWindowHandlesCallCount()

            XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .retry)
            clock.advance(observerRetryDelay)
            // The observer callback can land before or after the settle deadline;
            // neither consumes the queued creation's first real attempt.
            XCTAssertEqual(model.attachNewlyCreatedWindow(
                newHandle, pid: pid, isDeferredRetry: true
            ), .retry)
            if model.isInSystemTransition { model.refreshRuntime(reportedFrontmostPID: nil) }
            XCTAssertEqual(mock.snapshotCallCount, 0)
            XCTAssertEqual(mock.windowsCallCount, 0)
            XCTAssertEqual(mock.windowHandlesCallCount, 0)
            XCTAssertNil(model.managedWindow(matching: newHandle))

            clock.advance(PanoptosModel.transitionSettleInterval + 1)
            if incompleteFirstRead {
                mock.snapshotErrorsByHandle[newHandle] = AccessibilityClientError.attribute(
                    kAXRoleAttribute as String, .noValue
                )
            }
            var repaints = 0
            model.onOverlayPresentationChanged = { repaints += 1 }
            model.refreshRuntime(reportedFrontmostPID: nil)
            if incompleteFirstRead {
                XCTAssertNil(model.managedWindow(matching: newHandle))
                mock.snapshotErrorsByHandle.removeValue(forKey: newHandle)
                model.refreshRuntime(reportedFrontmostPID: nil)
                XCTAssertNil(model.managedWindow(matching: newHandle), "The second attempt must be deferred")
                clock.advance(0.25)
                model.refreshRuntime(reportedFrontmostPID: nil)
            }

            XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [existingHandle, newHandle])
            XCTAssertEqual(mock.focusCallCount, focusCalls)
            XCTAssertEqual(model.compatibilityError, "Keep this notice")
            XCTAssertGreaterThan(repaints, 0)
            XCTAssertTrue(model.windowAssignmentPersistence.load().contains {
                $0.title == newWindow.title && $0.sectionID == sectionID
            })
        }
    }

    func testQueuedWindowCreationGetsOnlyOneRetryAfterSettling() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let existing = snapshot(handle: existingHandle, title: "Existing")
        let newWindow = snapshot(handle: newHandle, title: "Incomplete")
        mock.windowSnapshots = [existing, newWindow]
        mock.windowSnapshotsByHandle = [existingHandle: existing, newHandle: newWindow]
        let model = makeModel(mock: mock, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: existing, to: sectionID)
        model.beginSystemTransition(.screenSleep)
        XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .retry)
        model.endSystemTransition(.screenSleep)
        clock.advance(PanoptosModel.transitionSettleInterval + 1)
        mock.snapshotErrorsByHandle[newHandle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String, .noValue
        )

        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.pendingWindowCreations.count, 1)
        mock.resetSnapshotCallCount()
        XCTAssertFalse(model.retryPendingWindowCreations(reportedFrontmostPID: nil))
        XCTAssertEqual(mock.snapshotCallCount, 0)
        clock.advance(PanoptosModel.windowCreationRetryInterval)
        XCTAssertFalse(model.retryPendingWindowCreations(reportedFrontmostPID: nil))
        XCTAssertTrue(model.pendingWindowCreations.isEmpty)

        mock.snapshotErrorsByHandle.removeValue(forKey: newHandle)
        clock.advance(60)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertNil(model.managedWindow(matching: newHandle), "An exhausted creation must not poll forever")
    }

    func testQueuedWindowCreationsAreCancelledByDestructionTerminationDetachmentAndRuntimeStop() throws {
        for cancellation in ["destruction", "termination", "detachment", "runtime stop"] {
            let clock = MockClock()
            let mock = MockAccessibility()
            let pid = ProcessInfo.processInfo.processIdentifier
            let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
            let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
            let existing = snapshot(handle: existingHandle, title: "Existing")
            let newWindow = snapshot(handle: newHandle, title: "Queued")
            mock.windowSnapshots = [existing, newWindow]
            mock.windowSnapshotsByHandle = [existingHandle: existing, newHandle: newWindow]
            let model = makeModel(mock: mock, clock: clock)
            let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
            model.attach(window: existing, to: sectionID)
            model.beginSystemTransition(.screenSleep)
            model.endSystemTransition(.screenSleep)
            XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .retry)
            XCTAssertEqual(model.pendingWindowCreations.count, 1)

            switch cancellation {
            case "destruction":
                model.confirmWindowDestroyed(newHandle, reportedFrontmostPID: nil)
            case "termination":
                model.confirmApplicationTerminated(
                    pid: pid, bundleIdentifier: model.managedWindow(matching: existingHandle)?.bundleIdentifier
                )
            case "detachment":
                model.attach(window: newWindow, to: sectionID)
                model.detach(windowID: try XCTUnwrap(model.managedWindow(matching: newHandle)?.id))
            default:
                model.stopWindowManagementRuntime()
                model.startWindowManagementRuntime()
            }
            XCTAssertTrue(model.pendingWindowCreations.isEmpty, cancellation)
            clock.advance(PanoptosModel.transitionSettleInterval + 1)
            model.refreshRuntime(reportedFrontmostPID: nil)
            XCTAssertNil(model.managedWindow(matching: newHandle), cancellation)
        }
    }

    func testReplacementCreationPreservesDurableSwitcherOrderWithEarlierOrphans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mock = MockAccessibility()
        let pid = ProcessInfo.processInfo.processIdentifier
        let handles = (0..<5).map {
            AXWindowHandle(element: AXUIElementCreateApplication(pid + pid_t($0)))
        }
        let windows = handles.enumerated().map { snapshot(handle: $0.element, title: "Document \($0.offset)") }
        mock.windowSnapshots = windows
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: zip(handles, windows))
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        for window in windows { model.attach(window: window, to: sectionID) }
        let originalIDs = try XCTUnwrap(model.sections[sectionID]?.windows.map(\.id))
        model.confirmWindowDestroyed(handles[0], reportedFrontmostPID: nil)
        model.confirmWindowDestroyed(handles[1], reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), Array(originalIDs.dropFirst(2)))

        let replacementHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let replacement = snapshot(handle: replacementHandle, title: windows[4].title)
        mock.windowSnapshots = [windows[2], windows[3], replacement]
        mock.windowSnapshotsByHandle[replacementHandle] = replacement
        mock.listedWindowHandles = [handles[2], handles[3], replacementHandle]
        XCTAssertEqual(model.attachNewlyCreatedWindow(replacementHandle, pid: pid), .attached)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), Array(originalIDs.dropFirst(2)))
        XCTAssertEqual(model.windowAssignmentPersistence.load().sorted { $0.order < $1.order }.map(\.id), originalIDs)
        let relaunched = makeModel(mock: mock, directory: directory)
        XCTAssertEqual(relaunched.sections[sectionID]?.windows.map(\.id), Array(originalIDs.dropFirst(2)))
    }

    func testReplacementCreationKeepsItsSectionBeforeAndAfterHeuristicRemoval() throws {
        for orphanFirst in [false, true] {
            let left = UUID()
            let laptop = UUID()
            let clock = MockClock()
            let mock = MockAccessibility()
            let pid = ProcessInfo.processInfo.processIdentifier
            let oldHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
            let survivingHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
            let replacementHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
            let old = snapshot(handle: oldHandle, title: "External document")
            let surviving = snapshot(handle: survivingHandle, title: "Laptop document")
            mock.windowSnapshots = [old, surviving]
            mock.windowSnapshotsByHandle = [oldHandle: old, survivingHandle: surviving]
            let model = makeModel(mock: mock, root: .split(
                id: UUID(), axis: .horizontal, ratio: 0.5,
                first: .leaf(id: left), second: .leaf(id: laptop)
            ), clock: clock)
            model.attach(window: old, to: left)
            model.attach(window: surviving, to: laptop)
            let originalID = try XCTUnwrap(model.managedWindow(matching: oldHandle)?.id)
            let focusCalls = mock.focusCallCount
            mock.snapshotErrorsByHandle[oldHandle] = AccessibilityClientError.attribute(
                kAXRoleAttribute as String, .invalidUIElement
            )
            mock.windowSnapshots = [surviving]
            mock.listedWindowHandles = [survivingHandle]
            if orphanFirst {
                model.refreshRuntime(reportedFrontmostPID: nil)
                clock.advance(PanoptosModel.invalidWindowFailureDuration + 1)
                model.refreshRuntime(reportedFrontmostPID: nil)
                XCTAssertNil(model.managedWindow(id: originalID))
                XCTAssertTrue(model.orphanedAssignments.contains { $0.id == originalID })
            }
            let replacement = snapshot(handle: replacementHandle, title: old.title)
            mock.windowSnapshots = [surviving, replacement]
            mock.windowSnapshotsByHandle[replacementHandle] = replacement
            mock.listedWindowHandles = [survivingHandle, replacementHandle]
            model.compatibilityError = "Preserve this notice"

            // A failed recovery must not fall through to generic placement.
            mock.frameError = AccessibilityClientError.frameRejected
            XCTAssertEqual(model.attachNewlyCreatedWindow(replacementHandle, pid: pid), .retry)
            XCTAssertEqual(model.sections[laptop]?.windows.map(\.handle), [survivingHandle])
            XCTAssertNil(model.managedWindow(matching: replacementHandle))
            mock.frameError = nil

            XCTAssertEqual(model.attachNewlyCreatedWindow(
                replacementHandle, pid: pid, reportedFrontmostPID: nil
            ), .attached)

            XCTAssertEqual(model.sections[left]?.windows.map(\.id), [originalID])
            XCTAssertEqual(model.sections[left]?.windows.map(\.handle), [replacementHandle])
            XCTAssertEqual(model.sections[laptop]?.windows.map(\.handle), [survivingHandle])
            XCTAssertFalse(model.orphanedAssignments.contains { $0.id == originalID })
            XCTAssertEqual(mock.focusCallCount, focusCalls)
            XCTAssertEqual(model.compatibilityError, "Preserve this notice")
            XCTAssertEqual(model.windowAssignmentPersistence.load().first {
                $0.id == originalID
            }?.sectionID, left)
        }
    }

    func testRelaunchRecoveryPlacesSecondWindowBeforeGenericAutomaticAttachment() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSectionID),
            second: .leaf(id: secondSectionID)
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let first = snapshot(handle: firstHandle, title: "First", pid: pid)
        let second = snapshot(handle: secondHandle, title: "Second after reopen", pid: pid)
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(mock: mock, root: root)
        model.attach(window: first, to: firstSectionID)
        let firstManaged = try XCTUnwrap(model.sections[firstSectionID]?.windows.first)
        let secondAssignment = PersistedWindowAssignment(
            id: UUID(),
            sectionID: secondSectionID,
            additionalSectionIDs: [],
            bundleIdentifier: firstManaged.bundleIdentifier,
            processIdentifier: pid - 1,
            accessibilityIdentifier: nil,
            title: "Second before quit",
            windowOrdinal: 1,
            order: 0,
            isActive: true,
            orphanedAt: Date(),
            awaitsApplicationRelaunch: true,
            displayTopology: model.currentDisplayTopology
        )
        model.orphanedAssignments = [secondAssignment]

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(secondHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )

        XCTAssertEqual(model.sections[firstSectionID]?.windows.map(\.handle), [firstHandle])
        XCTAssertEqual(model.sections[secondSectionID]?.windows.map(\.handle), [secondHandle])
    }

    @MainActor
    func testAmbiguousClosedRecordsFallThroughToNormalAutomaticPlacement() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "Brand new", pid: pid)
        mock.windowSnapshots = [existing]
        mock.windowSnapshotsByHandle[existingHandle] = existing
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: existing, to: sectionID)
        let managed = try XCTUnwrap(model.sections[sectionID]?.windows.first)
        model.orphanedAssignments = [4, 5].map { ordinal in
            PersistedWindowAssignment(
                id: UUID(),
                sectionID: sectionID,
                additionalSectionIDs: [],
                bundleIdentifier: managed.bundleIdentifier,
                processIdentifier: pid,
                accessibilityIdentifier: nil,
                title: "Closed \(ordinal)",
                windowOrdinal: ordinal,
                order: ordinal,
                isActive: false,
                orphanedAt: Date(),
                awaitsWindowReopen: true,
                displayTopology: model.currentDisplayTopology
            )
        }

        mock.windowSnapshots = [existing, newlyCreated]
        mock.windowSnapshotsByHandle[newHandle] = newlyCreated
        mock.listedWindowHandles = [existingHandle, newHandle]

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [existingHandle, newHandle])
        XCTAssertEqual(model.orphanedAssignments.count, 2)
    }

    @MainActor
    func testNewApplicationWindowFollowsFocusedWindowWhenAppOccupiesMultipleSections() throws {
        let firstSectionID = UUID()
        let secondSectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: firstSectionID),
                second: .leaf(id: secondSectionID)
            )
        )
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let first = snapshot(handle: firstHandle, title: "First", pid: pid)
        let second = snapshot(handle: secondHandle, title: "Second", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "New", pid: pid)
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        model.attach(window: first, to: firstSectionID)
        model.attach(window: second, to: secondSectionID)
        mock.focusedHandle = secondHandle
        model.refreshRuntime(reportedFrontmostPID: pid)

        mock.windowSnapshots = [first, second, newlyCreated]
        mock.windowSnapshotsByHandle[newHandle] = newlyCreated
        // macOS may report focus on the new, unmanaged element before its
        // creation notification. That clears the live managed focus, but must
        // not erase the last confirmed section used for automatic placement.
        mock.focusedHandle = newHandle
        model.refreshFocusedWindow(reportedFrontmostPID: pid)
        XCTAssertNil(model.focusedManagedWindowID)

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: pid),
            .attached
        )
        XCTAssertEqual(model.sections[firstSectionID]?.windows.map(\.title), ["First"])
        XCTAssertEqual(model.sections[secondSectionID]?.windows.map(\.title), ["Second", "New"])
    }

    @MainActor
    func testAutomaticAttachmentCanRetryAnEarlyIncompleteWindowSnapshot() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "New", pid: pid)
        mock.windowSnapshots = [existing, newlyCreated]
        mock.windowSnapshotsByHandle = [existingHandle: existing, newHandle: newlyCreated]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: existing, to: sectionID)
        mock.snapshotErrorsByHandle[newHandle] = AccessibilityClientError.attribute(
            kAXRoleAttribute as String,
            .noValue
        )

        XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .retry)
        XCTAssertNil(model.managedWindow(matching: newHandle))

        mock.snapshotErrorsByHandle.removeValue(forKey: newHandle)

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, isDeferredRetry: true),
            .attached
        )
        XCTAssertNotNil(model.managedWindow(matching: newHandle))
    }

    @MainActor
    func testAutomaticAttachmentDoesNotAttachWindowsFromAnUnmanagedApplication() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let newHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newlyCreated = snapshot(handle: newHandle, title: "Unmanaged", pid: pid)
        mock.windowSnapshots = [newlyCreated]
        mock.windowSnapshotsByHandle = [newHandle: newlyCreated]
        let model = makeModel(mock: mock)

        XCTAssertEqual(model.attachNewlyCreatedWindow(newHandle, pid: pid), .ignored)
        XCTAssertTrue(model.sections.values.flatMap(\.windows).isEmpty)
        XCTAssertTrue(mock.setFrameHandles.isEmpty)
    }

    @MainActor
    func testAutomaticAttachmentIgnoresUnsupportedNewWindows() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let rigidHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let fullScreenHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let rigid = AXWindowSnapshot(
            handle: rigidHandle,
            pid: pid,
            title: "Rigid",
            frame: existing.frame,
            isMinimized: false,
            isFullScreen: false,
            isResizable: false
        )
        let fullScreen = AXWindowSnapshot(
            handle: fullScreenHandle,
            pid: pid,
            title: "Full Screen",
            frame: existing.frame,
            isMinimized: false,
            isFullScreen: true,
            isResizable: true
        )
        mock.windowSnapshots = [existing, rigid, fullScreen]
        mock.windowSnapshotsByHandle = [
            existingHandle: existing,
            rigidHandle: rigid,
            fullScreenHandle: fullScreen
        ]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: existing, to: sectionID)

        XCTAssertEqual(model.attachNewlyCreatedWindow(rigidHandle, pid: pid), .retry)
        XCTAssertEqual(
            model.attachNewlyCreatedWindow(rigidHandle, pid: pid, isDeferredRetry: true),
            .ignored
        )
        XCTAssertEqual(model.attachNewlyCreatedWindow(fullScreenHandle, pid: pid), .ignored)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), ["Existing"])
    }

    @MainActor
    func testBackgroundAutomaticAttachmentPreservesActiveWindowAndCompatibilityError() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let mock = MockAccessibility()
        let existingHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let failingHandle = AXWindowHandle(element: AXUIElementCreateApplication(pid + 1))
        let existing = snapshot(handle: existingHandle, title: "Existing", pid: pid)
        let newlyCreated = snapshot(handle: newHandle, title: "Background", pid: pid)
        let failing = snapshot(handle: failingHandle, title: "Failing", pid: pid)
        mock.windowSnapshots = [existing, newlyCreated, failing]
        mock.windowSnapshotsByHandle = [
            existingHandle: existing,
            newHandle: newlyCreated,
            failingHandle: failing
        ]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: existing, to: sectionID)
        let originalActiveID = try XCTUnwrap(model.sections[sectionID]?.activeWindowID)
        model.compatibilityError = "Keep this error"

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(newHandle, pid: pid, reportedFrontmostPID: nil),
            .attached
        )
        XCTAssertEqual(model.sections[sectionID]?.activeWindowID, originalActiveID)
        XCTAssertEqual(model.compatibilityError, "Keep this error")

        mock.frameError = AccessibilityClientError.frameRejected

        XCTAssertEqual(
            model.attachNewlyCreatedWindow(failingHandle, pid: pid, reportedFrontmostPID: nil),
            .retry
        )
        XCTAssertEqual(
            model.attachNewlyCreatedWindow(
                failingHandle,
                pid: pid,
                reportedFrontmostPID: nil,
                isDeferredRetry: true
            ),
            .ignored
        )
        XCTAssertNil(model.managedWindow(matching: failingHandle))
        XCTAssertEqual(model.compatibilityError, "Keep this error")
    }

    func testReorderedSwitcherWindowsKeepTheirOrderOnRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sectionID = UUID()
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(mock: mock, root: .leaf(id: sectionID), directory: directory)
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)
        let attached = try XCTUnwrap(model.sections[sectionID]?.windows)
        XCTAssertEqual(attached.map(\.title), ["First", "Second"])

        model.reorderWindows(in: sectionID, to: [attached[1].id, attached[0].id])

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), ["Second", "First"])
        XCTAssertEqual(model.sections[sectionID]?.activeWindowID, attached[1].id)

        let relaunched = makeModel(mock: mock, directory: directory)

        XCTAssertEqual(relaunched.sections[sectionID]?.windows.map(\.title), ["Second", "First"])
        XCTAssertEqual(relaunched.sections[sectionID]?.activeWindow?.title, "Second")
    }

    func testDisplayAliasKeepsOneLayoutAcrossDisconnectReconnectAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtIn = DisplayFingerprint(
            vendor: 1,
            model: 1,
            serial: 1,
            name: "Built-in",
            stableIdentifier: "BC0960F7-9050-4625-981B-3D37668C77AE"
        )
        let legacyAirPlay = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: " (AirPlay)"
        )
        let airPlayConnection = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: " (AirPlay)",
            stableIdentifier: "AD660803-0870-4660-A4D4-4B9049EAE064"
        )
        let renamedConnection = DisplayFingerprint(
            vendor: 7789,
            model: 30542,
            serial: 60658,
            name: "LG HDR WQHD+",
            stableIdentifier: "AD660803-0870-4660-A4D4-4B9049EAE064"
        )
        let builtInSection = UUID()
        let externalSection = UUID()
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtIn, root: .leaf(id: builtInSection)),
            DisplayLayout(fingerprint: legacyAirPlay, root: .leaf(id: externalSection))
        ])
        let builtInDisplay = currentDisplay(
            fingerprint: builtIn,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let displays = MockDisplayProvider([
            builtInDisplay,
            currentDisplay(
                fingerprint: airPlayConnection,
                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            )
        ])
        let model = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            displayProvider: { displays.displays }
        )
        XCTAssertEqual(model.layouts.count, 2)
        XCTAssertEqual(
            model.layouts.first { $0.fingerprint.stableIdentifier == airPlayConnection.stableIdentifier }?
                .root.leafIDs,
            [externalSection]
        )

        displays.displays = [builtInDisplay]
        model.refreshDisplays()
        displays.displays = [
            builtInDisplay,
            currentDisplay(
                fingerprint: renamedConnection,
                frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
            )
        ]
        model.refreshDisplays()

        XCTAssertEqual(model.layouts.count, 2)
        let reconnected = try XCTUnwrap(model.layouts.first {
            $0.fingerprint.stableIdentifier == renamedConnection.stableIdentifier
        })
        XCTAssertEqual(reconnected.fingerprint.name, "LG HDR WQHD+")
        XCTAssertEqual(reconnected.root.leafIDs, [externalSection])

        let relaunched = makeModel(
            mock: MockAccessibility(),
            directory: directory,
            displayProvider: { displays.displays }
        )
        XCTAssertEqual(relaunched.layouts.count, 2)
        let restored = try XCTUnwrap(relaunched.layouts.first {
            $0.fingerprint.stableIdentifier == renamedConnection.stableIdentifier
        })
        XCTAssertEqual(restored.fingerprint.name, "LG HDR WQHD+")
        XCTAssertEqual(restored.root.leafIDs, [externalSection])
    }

    func testDisplayTopologyFallbackPersistsAndOriginalZoneReturnsOnReconnect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let builtInSection = UUID()
        let externalSection = UUID()
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtInFingerprint, root: .leaf(id: builtInSection)),
            DisplayLayout(fingerprint: externalFingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let originalHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let original = snapshot(handle: originalHandle, title: "Document")
        mock.windowSnapshots = [original]
        mock.windowSnapshotsByHandle[originalHandle] = original
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.attach(window: original, to: externalSection)
        let stableWindowID = try XCTUnwrap(model.sections[externalSection]?.windows.first?.id)

        displays.displays = [builtIn]
        model.refreshDisplays()

        XCTAssertEqual(model.sections[builtInSection]?.windows.map(\.id), [stableWindowID])
        XCTAssertNil(model.sections[externalSection])
        let store = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        )
        XCTAssertEqual(Set(store.load().compactMap(\.displayTopology)), Set([
            [builtInFingerprint],
            [builtInFingerprint, externalFingerprint]
        ]))

        // Relaunch while only the built-in display is present. A fresh AX
        // element stands in for the replacement commonly published after a
        // real display reconfiguration.
        let replacementMock = MockAccessibility()
        let replacementHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let replacement = snapshot(handle: replacementHandle, title: "Document")
        replacementMock.windowSnapshots = [replacement]
        replacementMock.windowSnapshotsByHandle[replacementHandle] = replacement
        let relaunched = makeModel(
            mock: replacementMock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        XCTAssertEqual(relaunched.sections[builtInSection]?.windows.map(\.id), [stableWindowID])

        displays.displays = [builtIn, external]
        relaunched.refreshDisplays()

        XCTAssertEqual(relaunched.sections[externalSection]?.windows.map(\.id), [stableWindowID])
        XCTAssertNil(relaunched.sections[builtInSection])

        relaunched.detach(windowID: stableWindowID)

        XCTAssertTrue(store.load().isEmpty)
    }

    func testDisplayProfilesShareCurrentWindowDetailsAndCloseStateAcrossRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtIn = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in"),
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External"),
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let laptopSection = UUID()
        let externalSection = UUID()
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtIn.fingerprint, root: .leaf(id: laptopSection)),
            DisplayLayout(fingerprint: external.fingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let oldHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let old = snapshot(handle: oldHandle, title: "Old browser page")
        mock.windowSnapshots = [old]
        mock.windowSnapshotsByHandle[oldHandle] = old
        let model = makeModel(mock: mock, directory: directory, displayProvider: { displays.displays })
        model.attach(window: old, to: externalSection)
        let originalID = try XCTUnwrap(model.managedWindow(matching: oldHandle)?.id)
        let externalTopology = model.currentDisplayTopology

        displays.displays = [builtIn]
        model.refreshDisplays()
        let updated = snapshot(handle: oldHandle, title: "New browser page")
        mock.windowSnapshots = [updated]
        mock.windowSnapshotsByHandle[oldHandle] = updated
        model.refreshRuntime(reportedFrontmostPID: nil)
        model.confirmWindowDestroyed(oldHandle, reportedFrontmostPID: nil)
        mock.windowSnapshots = []
        mock.listedWindowHandles = []

        let storedExternal = try XCTUnwrap(model.windowAssignmentPersistence.load().first {
            $0.id == originalID && $0.displayTopology == externalTopology
        })
        XCTAssertEqual(storedExternal.sectionID, externalSection)
        XCTAssertEqual(storedExternal.title, updated.title)
        XCTAssertEqual(storedExternal.awaitsWindowReopen, true)

        // Reconnect without restarting, then launch a fresh model from disk.
        displays.displays = [builtIn, external]
        model.refreshDisplays()
        XCTAssertEqual(model.orphanedAssignments.first?.title, updated.title)
        XCTAssertEqual(model.orphanedAssignments.first?.awaitsWindowReopen, true)
        let relaunched = makeModel(mock: mock, directory: directory, displayProvider: { displays.displays })
        XCTAssertEqual(relaunched.orphanedAssignments.first?.sectionID, externalSection)
        XCTAssertEqual(relaunched.orphanedAssignments.first?.awaitsWindowReopen, true)
        let newHandle = AXWindowHandle(element: AXUIElementCreateApplication(old.pid))
        let reopened = snapshot(handle: newHandle, title: "Reopened browser page")
        mock.windowSnapshots = [reopened]
        mock.windowSnapshotsByHandle[newHandle] = reopened
        mock.listedWindowHandles = [newHandle]
        XCTAssertEqual(relaunched.attachNewlyCreatedWindow(newHandle, pid: old.pid), .attached)
        XCTAssertEqual(relaunched.sections[externalSection]?.windows.map(\.id), [originalID])
        XCTAssertNil(relaunched.sections[laptopSection])
        XCTAssertTrue(relaunched.windowAssignmentPersistence.load().allSatisfy {
            $0.title == reopened.title && $0.awaitsWindowReopen == nil
        })
    }

    func testDisplayTopologiesKeepIndependentApplicationAndWindowOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let builtInSection = UUID()
        let externalSection = UUID()
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtInFingerprint, root: .leaf(id: builtInSection)),
            DisplayLayout(fingerprint: externalFingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let editorFirst = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 0)
        let browser = managedWindow(bundleIdentifier: "com.example.Browser", ordinal: 1)
        let terminal = managedWindow(bundleIdentifier: "com.example.Terminal", ordinal: 2)
        let editorSecond = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 3)
        let allWindows = [editorFirst, browser, terminal, editorSecond]
        mock.windowSnapshots = allWindows.map {
            snapshot(handle: $0.handle, title: $0.title, pid: $0.pid)
        }
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: mock.windowSnapshots!.map {
            ($0.handle, $0)
        })
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.sections = [
            builtInSection: LayoutSectionState(
                id: builtInSection,
                windows: [editorFirst, browser],
                activeWindowID: browser.id
            ),
            externalSection: LayoutSectionState(
                id: externalSection,
                windows: [terminal, editorSecond],
                activeWindowID: terminal.id
            )
        ]
        model.persistWindowAssignments()

        var presentationCount = 0
        model.onOverlayPresentationChanged = { presentationCount += 1 }
        displays.displays = [builtIn]
        model.refreshDisplays()

        XCTAssertGreaterThan(presentationCount, 0)
        XCTAssertEqual(
            model.sections[builtInSection]?.windows.map(\.id),
            [editorFirst.id, editorSecond.id, browser.id, terminal.id]
        )

        let laptopOrder = [terminal.id, browser.id, editorSecond.id, editorFirst.id]
        model.reorderWindows(in: builtInSection, to: laptopOrder)

        displays.displays = [builtIn, external]
        model.refreshDisplays()

        XCTAssertEqual(
            model.sections[builtInSection]?.windows.map(\.id),
            [editorFirst.id, browser.id]
        )
        XCTAssertEqual(
            model.sections[externalSection]?.windows.map(\.id),
            [terminal.id, editorSecond.id]
        )

        // These windows did not exist in the saved laptop-only profile. Their
        // outgoing orders deliberately collide with saved laptop orders in the
        // same section, so a plain section/order sort would put Notes in the
        // middle and make the result depend on UUID ordering. Notes must join
        // after the saved groups, while the new Editor window must join the end
        // of its saved application group.
        let notes = managedWindow(bundleIdentifier: "com.example.Notes", ordinal: 4)
        let editorThird = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 5)
        let addedSnapshots = [notes, editorThird].map {
            snapshot(handle: $0.handle, title: $0.title, pid: $0.pid)
        }
        mock.windowSnapshots?.append(contentsOf: addedSnapshots)
        for snapshot in addedSnapshots {
            mock.windowSnapshotsByHandle[snapshot.handle] = snapshot
        }
        var builtInState = try XCTUnwrap(model.sections[builtInSection])
        builtInState.windows.append(contentsOf: [notes, editorThird])
        builtInState.activeWindowID = notes.id
        model.sections[builtInSection] = builtInState
        model.persistWindowAssignments()

        displays.displays = [builtIn]
        model.refreshDisplays()

        let restoredLaptopOrder = laptopOrder + [editorThird.id, notes.id]
        XCTAssertEqual(
            model.sections[builtInSection]?.windows.map(\.id),
            restoredLaptopOrder
        )
        XCTAssertEqual(model.sections[builtInSection]?.activeWindowID, notes.id)
        let storedLaptopOrder = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
            .filter { $0.displayTopology == [builtInFingerprint] }
            .sorted { $0.order < $1.order }
            .map(\.id)
        XCTAssertEqual(storedLaptopOrder, restoredLaptopOrder)
    }

    func testFallbackOnlySectionKeepsItsOutgoingWindowOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let savedSection = UUID()
        let fallbackOnlySection = UUID()
        let externalSection = UUID()
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(
                fingerprint: builtInFingerprint,
                root: .split(
                    id: UUID(),
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(id: savedSection),
                    second: .leaf(id: fallbackOnlySection)
                )
            ),
            DisplayLayout(fingerprint: externalFingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let saved = managedWindow(bundleIdentifier: "com.example.Saved", ordinal: 0)
        let editorFirst = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 1)
        let browser = managedWindow(bundleIdentifier: "com.example.Browser", ordinal: 2)
        let editorSecond = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 3)
        let allWindows = [saved, editorFirst, browser, editorSecond]
        let snapshots = allWindows.map {
            snapshot(handle: $0.handle, title: $0.title, pid: $0.pid)
        }
        mock.windowSnapshots = snapshots
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.sections[savedSection] = LayoutSectionState(
            id: savedSection,
            windows: [saved],
            activeWindowID: saved.id
        )
        model.persistWindowAssignments()

        // Establish a laptop-only profile containing another section, then
        // introduce an interleaved fallback-only section while both displays
        // are connected.
        displays.displays = [builtIn]
        model.refreshDisplays()
        displays.displays = [builtIn, external]
        model.refreshDisplays()
        model.sections[fallbackOnlySection] = LayoutSectionState(
            id: fallbackOnlySection,
            windows: [editorFirst, browser, editorSecond],
            activeWindowID: editorSecond.id
        )
        model.persistWindowAssignments()

        displays.displays = [builtIn]
        model.refreshDisplays()

        XCTAssertEqual(
            model.sections[fallbackOnlySection]?.windows.map(\.id),
            [editorFirst.id, editorSecond.id, browser.id]
        )
    }

    func testLaptopTopologyOrderSurvivesRelaunchAfterReconnectCycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let builtInSection = UUID()
        let externalSection = UUID()
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtInFingerprint, root: .leaf(id: builtInSection)),
            DisplayLayout(fingerprint: externalFingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let handles = [
            AXWindowHandle(element: AXUIElementCreateSystemWide()),
            AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)),
            AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier + 1))
        ]
        let snapshots = zip(handles, ["First", "Second", "Third"]).map {
            snapshot(handle: $0.0, title: $0.1)
        }
        mock.windowSnapshots = snapshots
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.attach(window: snapshots[0], to: builtInSection)
        model.attach(window: snapshots[1], to: externalSection)
        model.attach(window: snapshots[2], to: externalSection)

        displays.displays = [builtIn]
        model.refreshDisplays()
        let collapsed = try XCTUnwrap(model.sections[builtInSection]?.windows)
        let laptopOrder = [collapsed[2].id, collapsed[0].id, collapsed[1].id]
        model.reorderWindows(in: builtInSection, to: laptopOrder)

        displays.displays = [builtIn, external]
        model.refreshDisplays()
        displays.displays = [builtIn]
        model.refreshDisplays()
        XCTAssertEqual(model.sections[builtInSection]?.windows.map(\.id), laptopOrder)

        let relaunched = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )

        XCTAssertEqual(relaunched.sections[builtInSection]?.windows.map(\.id), laptopOrder)
    }

    func testDormantWindowSlotsCannotReorderLiveApplicationsAcrossDisplayCycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let builtInSection = UUID()
        let externalSection = UUID()
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(fingerprint: builtInFingerprint, root: .leaf(id: builtInSection)),
            DisplayLayout(fingerprint: externalFingerprint, root: .leaf(id: externalSection))
        ])
        let displays = MockDisplayProvider([builtIn])
        let mock = MockAccessibility()
        let first = managedWindow(bundleIdentifier: "com.example.First", ordinal: 0)
        let second = managedWindow(bundleIdentifier: "com.example.Second", ordinal: 1)
        let movedLast = managedWindow(bundleIdentifier: "com.example.MovedLast", ordinal: 2)
        let snapshots = [first, second, movedLast].map {
            snapshot(handle: $0.handle, title: $0.title, pid: $0.pid)
        }
        mock.windowSnapshots = snapshots
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.sections[builtInSection] = LayoutSectionState(
            id: builtInSection,
            windows: [movedLast, first, second],
            activeWindowID: first.id
        )
        model.persistWindowAssignments()

        // This closed window belonged to MovedLast when that application was
        // first. Moving its remaining live window to the end must move the
        // visible application group while the dormant record retains its
        // durable position inside that application.
        model.orphanedAssignments = [PersistedWindowAssignment(
            id: UUID(),
            sectionID: builtInSection,
            additionalSectionIDs: [],
            bundleIdentifier: movedLast.bundleIdentifier,
            processIdentifier: movedLast.pid,
            accessibilityIdentifier: nil,
            title: "Closed MovedLast window",
            windowOrdinal: 3,
            order: 0,
            isActive: false,
            orphanedAt: Date(),
            awaitsWindowReopen: true,
            displayTopology: [builtInFingerprint]
        )]
        let userOrder = [first.id, second.id, movedLast.id]
        model.reorderWindows(in: builtInSection, to: userOrder)

        displays.displays = [builtIn, external]
        model.refreshDisplays()
        displays.displays = [builtIn]
        model.refreshDisplays()

        XCTAssertEqual(model.sections[builtInSection]?.windows.map(\.id), userOrder)
        let persistedLiveOrder = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
            .filter {
                $0.displayTopology == [builtInFingerprint]
                    && userOrder.contains($0.id)
            }
            .sorted { $0.order < $1.order }
            .map(\.id)
        XCTAssertEqual(persistedLiveOrder, userOrder)

        let relaunched = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        let relaunchedLiveOrder = relaunched.savedWindowAssignments
            .filter {
                $0.displayTopology == [builtInFingerprint]
                    && userOrder.contains($0.id)
            }
            .sorted { $0.order < $1.order }
            .map(\.id)
        XCTAssertEqual(relaunchedLiveOrder, userOrder)
    }

    func testReattachingReplacementAXElementDoesNotDuplicateManagedWindow() throws {
        let first = UUID()
        let second = UUID()
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: first),
                second: .leaf(id: second)
            )
        )
        let oldHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let old = snapshot(handle: oldHandle, title: "Document")
        mock.windowSnapshots = [old]
        mock.windowSnapshotsByHandle[oldHandle] = old
        model.attach(window: old, to: first)
        let stableWindowID = try XCTUnwrap(model.sections[first]?.windows.first?.id)

        let replacementHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let replacement = snapshot(handle: replacementHandle, title: "Document")
        mock.windowSnapshots = [replacement]
        mock.windowSnapshotsByHandle[replacementHandle] = replacement
        model.attach(window: replacement, to: second)

        XCTAssertNil(model.sections[first])
        XCTAssertEqual(model.sections[second]?.windows.map(\.id), [stableWindowID])
        XCTAssertEqual(model.sections.values.flatMap(\.windows).count, 1)
    }

    func testDistinctLiveWindowsWithTheSameTitleAndIdentifierDoNotCollapse() throws {
        let mock = MockAccessibility()
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let first = AXWindowSnapshot(
            handle: firstHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "shared-window-identifier",
            title: "Untitled",
            frame: CGRect(x: 50, y: 50, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        let second = AXWindowSnapshot(
            handle: secondHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            accessibilityIdentifier: "shared-window-identifier",
            title: "Untitled",
            frame: CGRect(x: 100, y: 100, width: 500, height: 400),
            isMinimized: false,
            isFullScreen: false,
            isResizable: true
        )
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]

        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [firstHandle, secondHandle])
        XCTAssertEqual(Set(model.sections[sectionID]?.windows.map(\.id) ?? []).count, 2)
    }

    func testUnchangedDisplayRefreshDefersReflowUntilWakeSettlesWithoutAXSweeps() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        let originalID = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)
        let topology = model.currentDisplayTopology
        let frameRequests = mock.setFrameRequests.count
        let focusRequests = mock.focusCallCount
        mock.resetSnapshotCallCount()
        mock.resetWindowsCallCount()

        model.beginSystemTransition(.screenSleep)
        model.refreshDisplays()
        for _ in 0..<3 {
            clock.advance(30)
            model.refreshRuntime(reportedFrontmostPID: nil)
            XCTAssertFalse(model.reflowManagedWindows())
        }
        XCTAssertEqual(model.currentDisplayTopology, topology)
        XCTAssertTrue(model.needsDisplayTopologyReflow)
        XCTAssertEqual(mock.snapshotCallCount, 0)
        XCTAssertEqual(mock.windowsCallCount, 0)
        XCTAssertEqual(mock.setFrameRequests.count, frameRequests)

        model.endSystemTransition(.screenSleep)
        model.refreshDisplays()
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertTrue(model.needsDisplayTopologyReflow)
        XCTAssertEqual(mock.snapshotCallCount, 0)
        clock.advance(PanoptosModel.transitionSettleInterval + 1)
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertFalse(model.needsDisplayTopologyReflow)
        XCTAssertGreaterThan(mock.setFrameRequests.count, frameRequests)
        XCTAssertEqual(mock.windowsCallCount, 0, "Surviving handles need no full AX window enumeration")
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [originalID])
        XCTAssertEqual(model.windowAssignmentPersistence.load().first?.sectionID, sectionID)
        XCTAssertEqual(mock.focusCallCount, focusRequests)
    }

    func testUnchangedDisplayRefreshRetriesAnImmediateFrameFailure() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        mock.frameError = AccessibilityClientError.frameRejected

        model.refreshDisplays()
        XCTAssertTrue(model.needsDisplayTopologyReflow)
        mock.frameError = nil
        model.retryDisplayTopologyReflowIfNeeded()

        XCTAssertFalse(model.needsDisplayTopologyReflow)
        XCTAssertEqual(mock.lastSetFrame, model.contentFrame(forSection: sectionID).map {
            PanoptosModel.accessibilityFrame(fromAppKitFrame: $0)
        })
    }

    func testReflowRestorationKeepsLiveHandlesWhenIdenticalTitlesChangeAXOrder() throws {
        let mock = MockAccessibility()
        let left = UUID()
        let right = UUID()
        let root = LayoutNode.split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .leaf(id: left), second: .leaf(id: right)
        )
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(123))
        let first = snapshot(handle: firstHandle, title: "Untitled")
        let second = snapshot(handle: secondHandle, title: "Untitled")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(mock: mock, root: root)
        model.attach(window: first, to: left)
        model.attach(window: second, to: right)
        let leftID = try XCTUnwrap(model.sections[left]?.windows.first?.id)
        let rightID = try XCTUnwrap(model.sections[right]?.windows.first?.id)
        mock.windowSnapshots = [second, first]

        let restored = model.restore(
            assignments: model.savedWindowAssignments, excluding: [], allowingOrdinalFallback: false
        )

        XCTAssertEqual(restored, [leftID, rightID])
        XCTAssertEqual(model.sections[left]?.windows.map(\.handle), [firstHandle])
        XCTAssertEqual(model.sections[right]?.windows.map(\.handle), [secondHandle])
        XCTAssertEqual(Set(model.sections.values.flatMap(\.windows).map(\.handle)).count, 2)
    }

    func testReflowRestorationDoesNotGiveAnUnavailableWindowAnotherManagedHandle() throws {
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(123))
        let first = snapshot(handle: firstHandle, title: "Untitled")
        let second = snapshot(handle: secondHandle, title: "Untitled")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)
        let originalIDs = try XCTUnwrap(model.sections[sectionID]?.windows.map(\.id))
        let survivingID = try XCTUnwrap(originalIDs.last)
        mock.windowSnapshots = [second]

        let restored = model.restore(
            assignments: model.savedWindowAssignments, excluding: [], allowingOrdinalFallback: false
        )

        XCTAssertEqual(restored, [survivingID])
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), originalIDs)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [firstHandle, secondHandle])
    }

    func testDisplayTopologyReflowRetryIsPacedAndEventuallyStops() throws {
        let clock = MockClock()
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        mock.frameError = AccessibilityClientError.frameRejected
        mock.resetWindowsCallCount()
        model.needsDisplayTopologyReflow = true
        model.displayTopologyReflowDeadline = clock.now.addingTimeInterval(
            PanoptosModel.displayTopologyReflowRetryDuration
        )

        model.retryDisplayTopologyReflowIfNeeded()
        let callsAfterFirstAttempt = mock.windowsCallCount
        model.retryDisplayTopologyReflowIfNeeded()

        XCTAssertEqual(callsAfterFirstAttempt, 1)
        XCTAssertEqual(mock.windowsCallCount, callsAfterFirstAttempt)
        XCTAssertTrue(model.needsDisplayTopologyReflow)

        clock.advance(PanoptosModel.displayTopologyReflowRetryInterval + 1)
        model.retryDisplayTopologyReflowIfNeeded()
        XCTAssertEqual(mock.windowsCallCount, callsAfterFirstAttempt + 1)

        clock.advance(PanoptosModel.displayTopologyReflowRetryDuration)
        model.retryDisplayTopologyReflowIfNeeded()
        XCTAssertFalse(model.needsDisplayTopologyReflow)
        XCTAssertNil(model.nextDisplayTopologyReflowAttempt)
        XCTAssertNil(model.displayTopologyReflowDeadline)
    }

    func testFallbackMapsUnavailableZonesInTheirConfiguredOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builtInFingerprint = DisplayFingerprint(vendor: 1, model: 1, serial: 1, name: "Built-in")
        let externalFingerprint = DisplayFingerprint(vendor: 2, model: 2, serial: 2, name: "External")
        let builtInFirst = UUID()
        let builtInSecond = UUID()
        // Deliberately reverse UUID sort order relative to layout order. The
        // fallback must follow the split tree, not these UUID strings.
        let externalFirst = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let externalSecond = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let builtIn = currentDisplay(
            fingerprint: builtInFingerprint,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let external = currentDisplay(
            fingerprint: externalFingerprint,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        try LayoutPersistence(url: directory.appendingPathComponent("layouts.json")).save([
            DisplayLayout(
                fingerprint: builtInFingerprint,
                root: .split(
                    id: UUID(),
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(id: builtInFirst),
                    second: .leaf(id: builtInSecond)
                )
            ),
            DisplayLayout(
                fingerprint: externalFingerprint,
                root: .split(
                    id: UUID(),
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(id: externalFirst),
                    second: .leaf(id: externalSecond)
                )
            )
        ])
        let displays = MockDisplayProvider([builtIn, external])
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        )
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let model = makeModel(
            mock: mock,
            directory: directory,
            displayProvider: { displays.displays }
        )
        model.attach(window: first, to: externalFirst)
        model.attach(window: second, to: externalSecond)

        displays.displays = [builtIn]
        model.refreshDisplays()

        XCTAssertEqual(model.sections[builtInFirst]?.windows.map(\.handle), [firstHandle])
        XCTAssertEqual(model.sections[builtInSecond]?.windows.map(\.handle), [secondHandle])
    }

    func testApplicationTerminationPreservesInactiveProfilesForRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let window = snapshot(handle: handle, title: "Managed")
        mock.windowSnapshots = [window]
        mock.windowSnapshotsByHandle[handle] = window
        let model = makeModel(mock: mock, directory: directory)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        let managed = try XCTUnwrap(model.sections[sectionID]?.windows.first)
        let active = try XCTUnwrap(model.savedWindowAssignments.first)
        let staleProfile = PersistedWindowAssignment(
            id: active.id,
            sectionID: active.sectionID,
            additionalSectionIDs: active.additionalSectionIDs,
            bundleIdentifier: active.bundleIdentifier,
            processIdentifier: active.processIdentifier - 1,
            accessibilityIdentifier: active.accessibilityIdentifier,
            title: active.title,
            windowOrdinal: active.windowOrdinal,
            order: active.order,
            isActive: active.isActive,
            displayTopology: [
                DisplayFingerprint(vendor: 9, model: 9, serial: 9, name: "Old setup")
            ]
        )
        model.savedWindowAssignments.append(staleProfile)

        model.confirmApplicationTerminated(
            pid: managed.pid,
            bundleIdentifier: managed.bundleIdentifier
        )

        let stored = WindowAssignmentPersistence(
            url: directory.appendingPathComponent("window-assignments.json")
        ).load()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.awaitsApplicationRelaunch == true })
    }

    func testReorderingRefusesAListThatIsNotAPermutationOfTheSection() throws {
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        let first = snapshot(handle: firstHandle, title: "First")
        let second = snapshot(handle: secondHandle, title: "Second")
        mock.windowSnapshots = [first, second]
        mock.windowSnapshotsByHandle = [firstHandle: first, secondHandle: second]
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        model.attach(window: first, to: sectionID)
        model.attach(window: second, to: sectionID)
        let attached = try XCTUnwrap(model.sections[sectionID]?.windows)

        model.reorderWindows(in: sectionID, to: [attached[1].id])
        model.reorderWindows(in: sectionID, to: [attached[1].id, UUID()])
        model.reorderWindows(in: UUID(), to: [attached[1].id, attached[0].id])

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.title), ["First", "Second"])
    }

    func testShortcutCyclesWindowsWithinAttachedSection() throws {
        let mock = MockAccessibility()
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: firstHandle, title: "First")
        let model = makeModel(mock: mock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: sectionID)

        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        mock.windowSnapshot = snapshot(handle: secondHandle, title: "Second")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: sectionID)
        XCTAssertEqual(mock.focusedHandle, secondHandle)

        model.performShortcut(.cyclePreviousWindow)

        XCTAssertEqual(mock.focusedHandle, firstHandle)
        XCTAssertEqual(model.sections[sectionID]?.activeWindow?.title, "First")
    }

    func testWindowShortcutsFollowGroupedSwitcherOrderInBothDirections() {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let editorOne = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 1)
        let browser = managedWindow(bundleIdentifier: "com.example.Browser", ordinal: 2)
        let editorTwo = managedWindow(bundleIdentifier: "com.example.Editor", ordinal: 3)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [editorOne, browser, editorTwo],
            activeWindowID: browser.id
        )
        model.applicationSplitPairs[sectionID] = [
            ApplicationSplitPair(
                firstBundleIdentifier: editorOne.bundleIdentifier,
                secondBundleIdentifier: browser.bundleIdentifier
            )
        ]
        mock.focusedHandle = browser.handle

        model.performShortcut(.cyclePreviousWindow)
        XCTAssertEqual(mock.focusedHandle, editorTwo.handle)
        model.performShortcut(.cyclePreviousWindow)
        XCTAssertEqual(mock.focusedHandle, editorOne.handle)
        model.performShortcut(.cyclePreviousWindow)
        XCTAssertEqual(mock.focusedHandle, browser.handle)

        model.performShortcut(.cycleNextWindow)
        XCTAssertEqual(mock.focusedHandle, editorOne.handle)
        model.performShortcut(.cycleNextWindow)
        XCTAssertEqual(mock.focusedHandle, editorTwo.handle)
        model.performShortcut(.cycleNextWindow)
        XCTAssertEqual(mock.focusedHandle, browser.handle)
    }

    func testSwitcherMovementShortcutsReorderTheFocusedApplicationGroup() throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let icon = NSImage()
        func window(_ title: String, bundleIdentifier: String, ordinal: Int) -> ManagedWindow {
            ManagedWindow(
                id: UUID(),
                handle: AXWindowHandle(element: AXUIElementCreateApplication(pid_t(ordinal + 1))),
                pid: pid_t(ordinal + 1),
                bundleIdentifier: bundleIdentifier,
                accessibilityIdentifier: nil,
                windowOrdinal: ordinal,
                applicationName: bundleIdentifier,
                icon: icon,
                title: title,
                isMinimized: false
            )
        }
        let editorOne = window("Editor 1", bundleIdentifier: "com.example.Editor", ordinal: 0)
        let browser = window("Browser", bundleIdentifier: "com.example.Browser", ordinal: 1)
        let editorTwo = window("Editor 2", bundleIdentifier: "com.example.Editor", ordinal: 2)
        let terminal = window("Terminal", bundleIdentifier: "com.example.Terminal", ordinal: 3)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID,
            windows: [editorOne, browser, editorTwo, terminal],
            activeWindowID: editorOne.id
        )
        mock.focusedHandle = editorOne.handle
        var repaintCount = 0
        model.onOverlayPresentationChanged = { repaintCount += 1 }

        model.performShortcut(.moveApplicationLater)

        XCTAssertEqual(
            model.sections[sectionID]?.windows.map(\.title),
            ["Browser", "Editor 1", "Editor 2", "Terminal"]
        )
        XCTAssertEqual(mock.focusedHandle, editorOne.handle)
        XCTAssertEqual(repaintCount, 1)

        model.performShortcut(.moveApplicationEarlier)
        model.performShortcut(.moveApplicationEarlier)

        XCTAssertEqual(
            model.sections[sectionID]?.windows.map(\.title),
            ["Browser", "Terminal", "Editor 1", "Editor 2"]
        )
        XCTAssertEqual(mock.focusedHandle, editorOne.handle)
        XCTAssertEqual(repaintCount, 3)
    }

    func testCustomSwitcherMovementShortcutSurvivesModelRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let customShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_F8),
            keyLabel: "F8",
            modifiers: [.control, .option, .command]
        )
        let firstModel = makeModel(mock: MockAccessibility(), directory: directory)

        firstModel.setShortcut(customShortcut, for: .moveApplicationLater)

        let relaunchedModel = makeModel(mock: MockAccessibility(), directory: directory)
        XCTAssertEqual(relaunchedModel.shortcut(for: .moveApplicationLater), customShortcut)
        XCTAssertEqual(
            relaunchedModel.shortcut(for: .moveApplicationEarlier),
            ShortcutCommand.moveApplicationEarlier.defaultShortcut
        )
    }

    func testSectionShortcutsCycleWindowsWhenOnlyOneSwitcherIsVisible() throws {
        let emptyLeading = UUID()
        let occupied = UUID()
        let emptyTrailing = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 1.0 / 3.0,
            first: .leaf(id: emptyLeading),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: occupied),
                second: .leaf(id: emptyTrailing)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstHandle = try attachWindow(
            titled: "First", pid: pid, to: occupied, in: model, mock: mock
        )
        let middleHandle = try attachWindow(
            titled: "Middle", pid: pid, to: occupied, in: model, mock: mock
        )
        let lastHandle = try attachWindow(
            titled: "Last", pid: pid, to: occupied, in: model, mock: mock
        )
        let middleWindowID = try XCTUnwrap(
            model.sections[occupied]?.windows.first { $0.handle == middleHandle }?.id
        )

        model.focus(windowID: middleWindowID)
        model.performShortcut(.focusPreviousSection)
        XCTAssertEqual(mock.focusedHandle, firstHandle)

        model.focus(windowID: middleWindowID)
        model.performShortcut(.focusNextSection)
        XCTAssertEqual(mock.focusedHandle, lastHandle)
    }

    func testSectionShortcutsExitFocusModeAndNavigateToAnotherSwitcher() throws {
        let focusedSection = UUID()
        let otherSection = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: focusedSection),
            second: .leaf(id: otherSection)
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstHandle = try attachWindow(
            titled: "First", pid: pid, to: focusedSection, in: model, mock: mock
        )
        let secondHandle = try attachWindow(
            titled: "Second", pid: pid, to: focusedSection, in: model, mock: mock
        )
        let otherHandle = try attachWindow(
            titled: "Other section", pid: pid, to: otherSection, in: model, mock: mock
        )
        let firstWindowID = try XCTUnwrap(
            model.sections[focusedSection]?.windows.first { $0.handle == firstHandle }?.id
        )

        model.toggleFocusMode(for: focusedSection)
        model.focus(windowID: firstWindowID)
        var focusModeAtEachRepaint: [UUID?] = []
        model.onOverlayPresentationChanged = { focusModeAtEachRepaint.append(model.focusedSectionID) }
        model.performShortcut(.focusNextSection)

        XCTAssertEqual(mock.focusedHandle, otherHandle)
        XCTAssertNotEqual(mock.focusedHandle, secondHandle)
        XCTAssertNil(model.focusedSectionID)
        XCTAssertEqual(focusModeAtEachRepaint.first, .some(nil))
    }

    func testPreviousSectionShortcutExitsFocusModeWhenFocusedSwitcherHasOneWindow() throws {
        let focusedSection = UUID()
        let otherSection = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: focusedSection),
            second: .leaf(id: otherSection)
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let pid = ProcessInfo.processInfo.processIdentifier
        let focusedHandle = try attachWindow(
            titled: "Only focused window", pid: pid, to: focusedSection, in: model, mock: mock
        )
        let otherHandle = try attachWindow(
            titled: "Other section", pid: pid, to: otherSection, in: model, mock: mock
        )

        model.toggleFocusMode(for: focusedSection)
        model.performShortcut(.focusPreviousSection)

        XCTAssertEqual(mock.focusedHandle, otherHandle)
        XCTAssertNotEqual(mock.focusedHandle, focusedHandle)
        XCTAssertNil(model.focusedSectionID)
    }

    func testShortcutFocusesActiveWindowInPreviousAndNextOccupiedSection() throws {
        let first = UUID()
        let emptyMiddle = UUID()
        let last = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 1.0 / 3.0,
            first: .leaf(id: first),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: emptyMiddle),
                second: .leaf(id: last)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let firstHandle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: firstHandle, title: "First section")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: first)

        let lastHandle = AXWindowHandle(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        mock.windowSnapshot = snapshot(handle: lastHandle, title: "Last section")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: last)
        let frameChangeCount = mock.setFrameHandles.count

        model.performShortcut(.focusPreviousSection)
        XCTAssertEqual(mock.focusedHandle, firstHandle)

        model.performShortcut(.focusNextSection)
        XCTAssertEqual(mock.focusedHandle, lastHandle)
        XCTAssertEqual(mock.setFrameHandles.count, frameChangeCount)
    }

    func testDisabledSectionFocusShortcutSurvivesModelRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstModel = makeModel(mock: MockAccessibility(), directory: directory)

        firstModel.setShortcut(nil, for: .focusNextSection)

        let relaunchedModel = makeModel(mock: MockAccessibility(), directory: directory)
        XCTAssertNil(relaunchedModel.shortcut(for: .focusNextSection))
        XCTAssertEqual(
            relaunchedModel.shortcut(for: .focusPreviousSection),
            ShortcutCommand.focusPreviousSection.defaultShortcut
        )
    }

    func testCustomSectionFocusShortcutSurvivesModelRelaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let customShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_F8),
            keyLabel: "F8",
            modifiers: [.control, .option, .command]
        )
        let firstModel = makeModel(mock: MockAccessibility(), directory: directory)

        firstModel.setShortcut(customShortcut, for: .focusNextSection)

        let relaunchedModel = makeModel(mock: MockAccessibility(), directory: directory)
        XCTAssertEqual(relaunchedModel.shortcut(for: .focusNextSection), customShortcut)
    }

    func testCycleLeftAttachesUnmanagedWindowToFirstSectionOnItsDisplay() throws {
        let first = UUID()
        let last = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: first),
            second: .leaf(id: last)
        ))
        let display = try XCTUnwrap(model.currentDisplays.first { model.layout(for: $0).root.leafIDs == [first, last] })
        let appKitFrame = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(
            handle: handle,
            title: "Unmanaged Left",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: appKitFrame)
        )

        model.performShortcut(.cycleWindowLeft)

        XCTAssertEqual(model.sections[first]?.activeWindow?.handle, handle)
        XCTAssertNil(model.sections[last])
    }

    func testCycleRightAttachesUnmanagedWindowToLastSectionOnItsDisplay() throws {
        let first = UUID()
        let last = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: first),
            second: .leaf(id: last)
        ))
        let display = try XCTUnwrap(model.currentDisplays.first { model.layout(for: $0).root.leafIDs == [first, last] })
        let appKitFrame = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(
            handle: handle,
            title: "Unmanaged Right",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: appKitFrame)
        )

        model.performShortcut(.cycleWindowRight)

        XCTAssertNil(model.sections[first])
        XCTAssertEqual(model.sections[last]?.activeWindow?.handle, handle)
    }

    func testRepeatedCycleRightDoesNotRollbackWhenFocusedWindowCannotBeRaisedAgain() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 1.0 / 3.0,
            first: .leaf(id: first),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: second),
                second: .leaf(id: third)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: handle, title: "Cross-display")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: first)
        mock.focusError = AccessibilityClientError.frameRejected

        model.performShortcut(.cycleWindowRight)
        model.performShortcut(.cycleWindowRight)

        XCTAssertNil(model.sections[first])
        XCTAssertNil(model.sections[second])
        XCTAssertEqual(model.sections[third]?.activeWindow?.handle, handle)
        XCTAssertEqual(mock.focusCallCount, 3)
    }

    func testMoveSkipsZonesTheWindowDoesNotFitAndNoticesThem() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: first),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.2,
                first: .leaf(id: second),
                second: .leaf(id: third)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: handle, title: "Wide")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: first)

        let frames = model.sectionFrames()
        let secondWidth = try XCTUnwrap(frames[second]?.width)
        let thirdWidth = try XCTUnwrap(frames[third]?.width)
        XCTAssertLessThan(secondWidth, thirdWidth)
        mock.minimumFitWidth = secondWidth + 1

        model.performShortcut(.cycleWindowRight)

        XCTAssertNil(model.sections[first])
        XCTAssertNil(model.sections[second])
        XCTAssertEqual(model.sections[third]?.activeWindow?.handle, handle)
        XCTAssertEqual(model.sectionNotices.keys.sorted(by: { $0.uuidString < $1.uuidString }), [second])
        XCTAssertTrue(try XCTUnwrap(model.sectionNotices[second]).hasSuffix("doesn't fit here"))
    }

    func testMoveStaysPutAndNoticesEveryZoneWhenNothingFits() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.6,
            first: .leaf(id: first),
            second: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: second),
                second: .leaf(id: third)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let originalFrame = CGRect(x: 50, y: 50, width: 500, height: 400)
        mock.windowSnapshot = snapshot(handle: handle, title: "Wide", frame: originalFrame)
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: first)

        let frames = model.sectionFrames()
        mock.minimumFitWidth = try XCTUnwrap(frames.values.map(\.width).max()) + 1

        model.performShortcut(.cycleWindowRight)

        XCTAssertEqual(model.sections[first]?.activeWindow?.handle, handle)
        XCTAssertNil(model.sections[second])
        XCTAssertNil(model.sections[third])
        XCTAssertTrue(Set(model.sectionNotices.keys).isSuperset(of: [second, third]))
    }

    func testMoveReachesStackedZoneThatDoesNotOverlapItsRejectedSibling() throws {
        // T-shaped layout: full-height zone beside two vertically stacked
        // zones. When the first stacked zone rejects the window, the move must
        // still reach the sibling even though the two stacked zones do not
        // vertically overlap each other.
        let full = UUID()
        let top = UUID()
        let bottom = UUID()
        let root = LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: full),
            second: .split(
                id: UUID(),
                axis: .vertical,
                // Asymmetric so `bottom` is deterministically closer to the
                // source's vertical center and is therefore attempted first.
                ratio: 0.25,
                first: .leaf(id: top),
                second: .leaf(id: bottom)
            )
        )
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: root)
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        mock.windowSnapshot = snapshot(handle: handle, title: "Wide")
        model.attach(window: try XCTUnwrap(mock.windowSnapshot), to: full)

        // Reject every zone except `top`, so the move must traverse past a
        // rejected stacked sibling to land in the other one.
        let topContent = try XCTUnwrap(model.contentFrame(forSection: top))
        let acceptedFrame = PanoptosModel.accessibilityFrame(fromAppKitFrame: topContent)
        mock.frameRejector = { $0.integral != acceptedFrame.integral }

        model.performShortcut(.cycleWindowRight)

        XCTAssertNil(model.sections[full])
        XCTAssertNil(model.sections[bottom])
        XCTAssertEqual(model.sections[top]?.activeWindow?.handle, handle)
        XCTAssertNotNil(model.sectionNotices[bottom])
    }

    // MARK: - Section focus mode

    func testFocusModeHidesTheApplicationsOfEveryOtherSection() throws {
        let fixture = try makeFocusModeFixture()

        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertEqual(fixture.mock.hideRequests.map(\.pid), [fixture.otherPID])
        XCTAssertEqual(fixture.mock.hideRequests.map(\.hidden), [true])
        XCTAssertTrue(fixture.model.isSectionVisible(fixture.focusedSection))
        XCTAssertFalse(fixture.model.isSectionVisible(fixture.otherSection))
    }

    /// Both transitions change which sections belong on screen, so both have to
    /// repaint. Exit publishes once after its focus and ordering state is final.
    func testEnteringAndLeavingFocusModeRepaintsTheOverlay() throws {
        let fixture = try makeFocusModeFixture()
        var repaintsSawFocusMode: [UUID?] = []
        fixture.model.onOverlayPresentationChanged = {
            repaintsSawFocusMode.append(fixture.model.focusedSectionID)
        }

        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        XCTAssertEqual(repaintsSawFocusMode.last, fixture.focusedSection)

        repaintsSawFocusMode.removeAll()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        // The last repaint must see the mode already ended, or it would leave
        // the other sections' bars ordered out until the idle pass.
        XCTAssertEqual(repaintsSawFocusMode.count, 1)
        XCTAssertEqual(repaintsSawFocusMode.last, .some(nil))
        XCTAssertTrue(fixture.model.isSectionVisible(fixture.otherSection))
    }

    func testLeavingFocusModeByFocusingAnotherSectionEndsWithARepaintThatSeesEverySectionVisible() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        let otherWindowID = try XCTUnwrap(fixture.model.sections[fixture.otherSection]?.windows.first?.id)

        var visibilityAtEachRepaint: [Bool] = []
        fixture.model.onOverlayPresentationChanged = {
            visibilityAtEachRepaint.append(fixture.model.isSectionVisible(fixture.otherSection))
        }
        fixture.model.focus(windowID: otherWindowID)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertEqual(visibilityAtEachRepaint.last, true)
    }

    func testSectionFocusShortcutTogglesTheSectionOfTheFocusedWindow() throws {
        let fixture = try makeFocusModeFixture()
        // The keyboard can only mean the section the user is working in.
        fixture.mock.focusedHandle = fixture.focusedHandle

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testSectionFocusShortcutHidesAndRestoresAVisibleUnattachedApplication() throws {
        let fixture = try makeFocusModeFixture()
        let unattachedPID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        try addUnattachedWindow(
            pid: unattachedPID,
            overlappingSection: fixture.focusedSection,
            in: fixture.model
        )
        fixture.mock.focusedHandle = fixture.focusedHandle

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertEqual(
            fixture.mock.hideRequests.filter { $0.pid == unattachedPID }.map(\.hidden),
            [true]
        )

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertEqual(
            fixture.mock.hideRequests.filter { $0.pid == unattachedPID }.map(\.hidden),
            [true, false]
        )
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(unattachedPID))
    }

    func testFocusModeControlPathHidesAndRestoresAVisibleUnattachedApplication() throws {
        let fixture = try makeFocusModeFixture()
        let unattachedPID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        try addUnattachedWindow(
            pid: unattachedPID,
            overlappingSection: fixture.focusedSection,
            in: fixture.model
        )

        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertEqual(
            fixture.mock.hideRequests.filter { $0.pid == unattachedPID }.map(\.hidden),
            [true, false]
        )
        XCTAssertEqual(
            fixture.model.pendingHiddenApplicationWindowOrderRestoration?.sectionIDs,
            Set([fixture.focusedSection, fixture.otherSection])
        )
        fixture.mock.resetRaiseRequests()
        fixture.model.applicationDidUnhide(pid: unattachedPID)
        XCTAssertEqual(Set(fixture.mock.raisedHandles), Set([fixture.focusedHandle, fixture.otherHandle]))
    }

    func testUnattachedOnlyRevealRestoresOrderWithoutDiscoveryCacheOrUnhideNotification() async throws {
        let sectionID = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let active = managedWindow(bundleIdentifier: "attached", ordinal: 0, pid: 101)
        model.sections[sectionID] = LayoutSectionState(
            id: sectionID, windows: [active], activeWindowID: active.id
        )
        // The discovery toggle may have cleared the cache while focus mode
        // hid this unattached-only process. It still needs a settle correction.
        model.beginRestoringActiveWindowOrder(for: [303])
        XCTAssertEqual(mock.raisedHandles, [active.handle])
        XCTAssertEqual(model.pendingHiddenApplicationWindowOrderRestoration?.awaitingPIDs, [303])
        mock.resetRaiseRequests()
        let settled = expectation(description: "Unattached-only reveal settles without a workspace notification")
        mock.onRaise = { _ in settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertEqual(mock.raisedHandles, [active.handle])
        XCTAssertNil(model.pendingHiddenApplicationWindowOrderRestoration)
    }

    func testFocusModeLeavesUnattachedOnlyApplicationsVisibleWhenDiscoveryIsDisabled() throws {
        let fixture = try makeFocusModeFixture()
        let unattachedPID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        try addUnattachedWindow(pid: unattachedPID, overlappingSection: fixture.focusedSection, in: fixture.model)
        fixture.model.showUnattachedWindowIcons = false

        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertFalse(fixture.mock.hideRequests.contains { $0.pid == unattachedPID })
        XCTAssertTrue(fixture.mock.hideRequests.contains { $0.pid == fixture.otherPID && $0.hidden })
    }

    func testSectionFocusShortcutExitRestoresFocusedSelection() throws {
        let fixture = try makeFocusModeFixture()
        fixture.mock.focusedHandle = fixture.focusedHandle
        fixture.model.performShortcut(.toggleSectionFocus)
        let focusedWindowID = try XCTUnwrap(
            fixture.model.sections[fixture.focusedSection]?.windows.first { $0.handle == fixture.focusedHandle }?.id
        )

        // A transient workspace update during application hiding/restoration
        // can clear Panoptos' optimistic selection while the real AX focus
        // remains on this window.
        let unmanagedPID = fixture.otherPID + 100_000
        fixture.model.refreshFocusedWindow(reportedFrontmostPID: unmanagedPID)
        XCTAssertNil(fixture.model.focusedManagedWindowID)

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertEqual(fixture.model.focusedManagedWindowID, focusedWindowID)
    }

    func testLeavingFocusModeRestoresAffectedSectionOrderAfterFocusAndAsUnhideSettles() throws {
        let fixture = try makeFocusModeFixture()
        // This application also occupies the focused section, so focus mode
        // leaves it visible. Restoring the other application must still put
        // this section's recorded active window back above the revealed sibling.
        let expectedTopWindow = try attachWindow(
            titled: "Other active window",
            pid: fixture.focusedPID,
            to: fixture.otherSection,
            in: fixture.model,
            mock: fixture.mock
        )
        fixture.mock.focusedHandle = fixture.focusedHandle
        fixture.model.performShortcut(.toggleSectionFocus)
        fixture.mock.resetRaiseRequests()
        var focusedHandleAtRaise: AXWindowHandle?
        fixture.mock.onRaise = { _ in focusedHandleAtRaise = fixture.mock.focusedHandle }

        fixture.model.performShortcut(.toggleSectionFocus)

        XCTAssertEqual(fixture.mock.raisedHandles, [expectedTopWindow])
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.focusedHandle)
        XCTAssertEqual(focusedHandleAtRaise, fixture.focusedHandle)

        // AXHidden can return before the workspace has completed application
        // restoration. Its did-unhide notification must repeat the ordering
        // correction after that later transition.
        fixture.mock.resetRaiseRequests()
        fixture.model.applicationDidUnhide(pid: fixture.otherPID)

        XCTAssertEqual(fixture.mock.raisedHandles, [expectedTopWindow])
        XCTAssertEqual(fixture.mock.focusedHandle, fixture.focusedHandle)
    }

    func testReenteringFocusModeCancelsThePendingUnhideOrderRestoration() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.mock.resetRaiseRequests()
        fixture.model.applicationDidUnhide(pid: fixture.otherPID)

        XCTAssertTrue(fixture.mock.raisedHandles.isEmpty)
        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testOverlappingApplicationRevealsMergeTheirPendingWindowOrderRestoration() {
        let firstSection = UUID()
        let secondSection = UUID()
        let mock = MockAccessibility()
        let model = makeModel(mock: mock, root: .split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstSection),
            second: .leaf(id: secondSection)
        ))
        let first = managedWindow(bundleIdentifier: "first", ordinal: 0, pid: 101)
        let second = managedWindow(bundleIdentifier: "second", ordinal: 1, pid: 202)
        model.sections[firstSection] = LayoutSectionState(
            id: firstSection,
            windows: [first],
            activeWindowID: first.id
        )
        model.sections[secondSection] = LayoutSectionState(
            id: secondSection,
            windows: [second],
            activeWindowID: second.id
        )

        model.beginRestoringActiveWindowOrder(for: [first.pid])
        model.beginRestoringActiveWindowOrder(for: [second.pid])
        mock.resetRaiseRequests()

        // The second reveal must not replace the first reveal's pending pid or
        // section. Either later workspace notification reasserts both sections.
        model.applicationDidUnhide(pid: first.pid)

        XCTAssertEqual(Set(mock.raisedHandles), Set([first.handle, second.handle]))
    }

    func testFocusModeKeepsAnApplicationThatAlsoOwnsAWindowInTheFocusedSection() throws {
        let fixture = try makeFocusModeFixture()
        // Hiding is per application, so the focused section's application keeps
        // every window it owns, including attached and unattached siblings.
        try attachWindow(
            titled: "Same Application, Other Section",
            pid: fixture.focusedPID,
            to: fixture.otherSection,
            in: fixture.model,
            mock: fixture.mock
        )
        try addUnattachedWindow(
            pid: fixture.focusedPID,
            overlappingSection: fixture.focusedSection,
            in: fixture.model
        )

        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertEqual(fixture.mock.hideRequests.map(\.pid), [fixture.otherPID])
    }

    func testFocusModeIgnoresMinimizedAndOtherSpaceUnattachedWindows() throws {
        for (isMinimized, isOnActiveSpace) in [(true, true), (false, false)] {
            let fixture = try makeFocusModeFixture()
            let unattachedPID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
            try addUnattachedWindow(
                pid: unattachedPID,
                overlappingSection: fixture.focusedSection,
                isMinimized: isMinimized,
                isOnActiveSpace: isOnActiveSpace,
                in: fixture.model
            )

            fixture.model.toggleFocusMode(for: fixture.focusedSection)

            XCTAssertFalse(
                fixture.mock.hideRequests.contains { $0.pid == unattachedPID },
                "isMinimized=\(isMinimized), isOnActiveSpace=\(isOnActiveSpace)"
            )
        }
    }

    func testFocusModeLeavesAPreviouslyHiddenUnattachedApplicationHidden() throws {
        let fixture = try makeFocusModeFixture()
        let unattachedPID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        try addUnattachedWindow(
            pid: unattachedPID,
            overlappingSection: fixture.focusedSection,
            in: fixture.model
        )
        fixture.mock.hiddenPIDs.insert(unattachedPID)

        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertFalse(fixture.mock.hideRequests.contains { $0.pid == unattachedPID })
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(unattachedPID))
    }

    func testFocusModeLeavesAnApplicationTheUserHadAlreadyHidden() throws {
        let fixture = try makeFocusModeFixture()
        fixture.mock.hiddenPIDs.insert(fixture.otherPID)

        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertTrue(fixture.mock.hideRequests.isEmpty)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testLeavingFocusModeShowsTheApplicationsItHid() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertEqual(fixture.mock.hideRequests.map(\.hidden), [true, false])
        XCTAssertEqual(fixture.mock.hideRequests.last?.pid, fixture.otherPID)
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testFocusingAWindowInAnotherSectionLeavesFocusMode() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        let otherWindowID = try XCTUnwrap(fixture.model.sections[fixture.otherSection]?.windows.first?.id)
        var observedTargetFocus = false
        var focusModeAtTargetFocus: UUID?
        var targetWasHiddenAtFocus: Bool?
        var targetWasFocusedAtFinalOrderRestore = false
        fixture.mock.onFocus = { _, pid in
            guard pid == fixture.otherPID else { return }
            observedTargetFocus = true
            focusModeAtTargetFocus = fixture.model.focusedSectionID
            targetWasHiddenAtFocus = fixture.mock.hiddenPIDs.contains(pid)
        }
        fixture.mock.onRaise = { _ in
            targetWasFocusedAtFinalOrderRestore = fixture.mock.focusedHandle == fixture.otherHandle
        }

        fixture.model.focus(windowID: otherWindowID)

        XCTAssertTrue(observedTargetFocus)
        XCTAssertNil(focusModeAtTargetFocus)
        XCTAssertEqual(targetWasHiddenAtFocus, false)
        XCTAssertTrue(targetWasFocusedAtFinalOrderRestore)
        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertEqual(fixture.mock.hideRequests.last?.hidden, false)
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testSwitchingWindowsInsideTheFocusedSectionKeepsFocusMode() throws {
        let fixture = try makeFocusModeFixture()
        let sibling = try attachWindow(
            titled: "Sibling",
            pid: fixture.focusedPID,
            to: fixture.focusedSection,
            in: fixture.model,
            mock: fixture.mock
        )
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        let siblingID = try XCTUnwrap(
            fixture.model.sections[fixture.focusedSection]?.windows.first { $0.handle == sibling }?.id
        )

        fixture.model.focus(windowID: siblingID)
        fixture.clock.advance(PanoptosModel.focusModeSettleInterval + 1)
        fixture.model.refreshRuntime(reportedFrontmostPID: fixture.focusedPID)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testFocusModeEndsWhenFocusLandsOutsideItsSection() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        let focusCallsAfterEntry = fixture.mock.focusCallCount

        // Activation is asynchronous, so a foreign frontmost application right
        // after entering says nothing yet.
        fixture.model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)

        fixture.clock.advance(PanoptosModel.focusModeSettleInterval + 1)
        fixture.model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
        XCTAssertEqual(fixture.mock.focusCallCount, focusCallsAfterEntry)
    }

    func testFocusModeIgnoresPanoptosItselfComingForward() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.clock.advance(PanoptosModel.focusModeSettleInterval + 1)

        // Panoptos' own settings window and its overlay menus are not the user
        // switching to another window.
        fixture.model.refreshRuntime(reportedFrontmostPID: fixture.model.ownProcessIdentifier)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testFocusModeStaysThroughASystemTransition() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        fixture.clock.advance(PanoptosModel.focusModeSettleInterval + 1)
        fixture.model.beginSystemTransition(.systemSleep)

        fixture.model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertTrue(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testFocusModeHidesAnApplicationAttachedElsewhereWhileItIsActive() throws {
        let fixture = try makeFocusModeFixture()
        let latePID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        try attachWindow(
            titled: "Late Arrival",
            pid: latePID,
            to: fixture.otherSection,
            in: fixture.model,
            mock: fixture.mock
        )
        // Attaching focuses the new window; the user comes back to the focused
        // section, which is what keeps focus mode running.
        let focusedWindowID = try XCTUnwrap(fixture.model.sections[fixture.focusedSection]?.windows.first?.id)
        fixture.model.focus(windowID: focusedWindowID)
        fixture.clock.advance(PanoptosModel.focusModeSettleInterval + 1)

        fixture.model.refreshRuntime(reportedFrontmostPID: fixture.focusedPID)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertEqual(fixture.mock.hideRequests.filter { $0.pid == latePID }.map(\.hidden), [true])
    }

    func testFocusModeHidesAVisibleUnattachedApplicationDiscoveredWhileItIsActive() throws {
        let fixture = try makeFocusModeFixture()
        let latePID = try XCTUnwrap(foreignApplicationPIDs(2).first { $0 != fixture.otherPID })
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        try addUnattachedWindow(
            pid: latePID,
            overlappingSection: fixture.focusedSection,
            in: fixture.model
        )

        fixture.model.refreshRuntime(reportedFrontmostPID: fixture.focusedPID)

        XCTAssertEqual(fixture.model.focusedSectionID, fixture.focusedSection)
        XCTAssertEqual(fixture.mock.hideRequests.filter { $0.pid == latePID }.map(\.hidden), [true])
    }

    func testFocusModeEndsWhenItsSectionLosesItsLastWindow() throws {
        let fixture = try makeFocusModeFixture()
        fixture.model.toggleFocusMode(for: fixture.focusedSection)
        let focusedWindowID = try XCTUnwrap(fixture.model.sections[fixture.focusedSection]?.windows.first?.id)

        fixture.model.detach(windowID: focusedWindowID)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertFalse(fixture.mock.hiddenPIDs.contains(fixture.otherPID))
    }

    func testUnattachedWindowsGroupOncePerApplicationAndNearestOccupiedSection() throws {
        let leftSection = UUID()
        let rightSection = UUID()
        let fingerprint = DisplayFingerprint(vendor: 91, model: 92, serial: 93, name: "Unattached")
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(fingerprint: fingerprint, frame: displayFrame)
        let pid: pid_t = 45_001
        let icon = NSImage()
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.unattached",
            applicationName: "Unattached",
            icon: icon,
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: leftSection),
                second: .leaf(id: rightSection)
            ),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed left", pid: ProcessInfo.processInfo.processIdentifier, to: leftSection, in: model, mock: mock)
        try attachWindow(titled: "Managed right", pid: ProcessInfo.processInfo.processIdentifier, to: rightSection, in: model, mock: mock)

        let sectionFrames = model.sectionFrames()
        let leftFrame = try XCTUnwrap(sectionFrames[leftSection])
        let rightFrame = try XCTUnwrap(sectionFrames[rightSection])
        let firstHandle = AXWindowHandle(element: AXUIElementCreateApplication(501))
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(502))
        let thirdHandle = AXWindowHandle(element: AXUIElementCreateApplication(503))
        let snapshots = [
            snapshot(
                handle: firstHandle,
                title: "Left one",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: leftFrame.insetBy(dx: 20, dy: 60)),
                pid: pid
            ),
            snapshot(
                handle: secondHandle,
                title: "Left two",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: leftFrame.insetBy(dx: 40, dy: 80)),
                pid: pid
            ),
            snapshot(
                handle: thirdHandle,
                title: "Right",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: rightFrame.insetBy(dx: 20, dy: 60)),
                pid: pid
            )
        ]
        mock.windowSnapshotsByPID[pid] = snapshots
        mock.windowSnapshotsByHandle.merge(
            Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        ) { _, replacement in replacement }

        model.refreshUnattachedWindows(pid: pid)

        let groups = model.unattachedWindowGroupsBySection()
        let leftGroup = try XCTUnwrap(groups[leftSection]?.first)
        let rightGroup = try XCTUnwrap(groups[rightSection]?.first)
        XCTAssertEqual(groups[leftSection]?.count, 1)
        XCTAssertEqual(groups[rightSection]?.count, 1)
        XCTAssertTrue(leftGroup.icon === icon)
        XCTAssertEqual(leftGroup.windows.map(\.handle), [firstHandle, secondHandle])
        XCTAssertEqual(rightGroup.windows.map(\.handle), [thirdHandle])
    }

    func testUnattachedWindowOnAnotherSpaceGetsNoIcon() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 97, model: 98, serial: 99, name: "Spaces")
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(fingerprint: fingerprint, frame: displayFrame)
        let pid: pid_t = 45_030
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.unattached-spaces",
            applicationName: "Spaces",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let hereHandle = AXWindowHandle(element: AXUIElementCreateApplication(45_130))
        let elsewhereHandle = AXWindowHandle(element: AXUIElementCreateApplication(45_131))
        let hereFrame = PanoptosModel.accessibilityFrame(
            fromAppKitFrame: displayFrame.insetBy(dx: 60, dy: 100)
        )
        let elsewhereFrame = PanoptosModel.accessibilityFrame(
            fromAppKitFrame: displayFrame.insetBy(dx: 40, dy: 80)
        )
        let here = snapshot(handle: hereHandle, title: "This Space", frame: hereFrame, pid: pid)
        let elsewhere = snapshot(
            handle: elsewhereHandle,
            title: "Another Space",
            frame: elsewhereFrame,
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [here, elsewhere]
        mock.windowSnapshotsByHandle = [hereHandle: here, elsewhereHandle: elsewhere]
        // The window server lists only the window on the active Space. The one
        // parked elsewhere still reports a frame inside the display.
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] },
            onScreenWindowFramesProvider: { [pid: [hereFrame]] }
        )
        try attachWindow(
            titled: "Managed",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )

        model.refreshUnattachedWindows(pid: pid)

        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [hereHandle]
        )
        XCTAssertEqual(model.unattachedWindowsByHandle[elsewhereHandle]?.isOnActiveSpace, false)
    }

    /// A menu bar application such as Ollama hides its window on close
    /// instead of destroying it, so no removal signal ever arrives and the
    /// Accessibility API keeps reporting an ordinary open window. The window
    /// server is the one public source that knows it left the screen: the
    /// switcher stops drawing it, the assignment stays, and the icon returns
    /// with the window.
    func testManagedWindowOffScreenLeavesSwitcherWithoutDetaching() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        let window = snapshot(handle: handle, title: "Ollama", frame: frame)
        mock.windowSnapshotsByHandle[handle] = window
        let onScreen = OnScreenFrames(frames: [ProcessInfo.processInfo.processIdentifier: [frame]])
        let model = makeModel(mock: mock, onScreenWindowFramesProvider: { onScreen.frames })
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])

        onScreen.frames = [:]
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [])
        XCTAssertEqual(model.sections[sectionID]?.hasVisibleWindows, false)
        XCTAssertTrue(model.orphanedAssignments.isEmpty)

        onScreen.frames = [ProcessInfo.processInfo.processIdentifier: [frame.offsetBy(dx: 1, dy: -1)]]
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])
    }

    /// Locking the screen puts the display to sleep about half a second
    /// later, and the window server can stop listing the desktop's windows
    /// in that gap. The settle period after the wake protects assignments
    /// and must never hide a switcher, but a window the server lists again is
    /// on screen regardless: the bars return on the first pass after unlock
    /// instead of waiting out the whole settle period.
    func testSettlePeriodRestoresSwitcherVisibilityWithoutHiding() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        let window = snapshot(handle: handle, title: "Ollama", frame: frame)
        mock.windowSnapshotsByHandle[handle] = window
        let pid = ProcessInfo.processInfo.processIdentifier
        let onScreen = OnScreenFrames(frames: [pid: [frame]])
        let clock = MockClock()
        let model = makeModel(mock: mock, onScreenWindowFramesProvider: { onScreen.frames }, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: nil)
        var repaints = 0
        model.onOverlayPresentationChanged = { repaints += 1 }

        // The lock shield empties the list before the sleep notification lands.
        onScreen.frames = [:]
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.hasVisibleWindows, false)
        XCTAssertEqual(repaints, 1)

        model.beginSystemTransition(.screenSleep)
        model.endSystemTransition(.screenSleep)
        XCTAssertTrue(model.isInSystemTransition)
        XCTAssertEqual(model.sections[sectionID]?.hasVisibleWindows, false)
        XCTAssertEqual(repaints, 1)

        // Unlocked, with the settle period still running.
        onScreen.frames = [pid: [frame]]
        clock.advance(1)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertTrue(model.isInSystemTransition)
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])
        XCTAssertEqual(repaints, 2)

        // A window the server drops during the settle period keeps its icon.
        onScreen.frames = [:]
        clock.advance(1)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])
        XCTAssertEqual(repaints, 2)

        // Ending the transition itself restores a window the server lists.
        onScreen.frames = [pid: [frame]]
        model.sections[sectionID]?.windows[0].isOnActiveSpace = false
        model.beginSystemTransition(.sessionInactive)
        model.endSystemTransition(.sessionInactive)
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])
        XCTAssertEqual(repaints, 3)

        clock.advance(PanoptosModel.transitionSettleInterval + 1)
        onScreen.frames = [:]
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertFalse(model.isInSystemTransition)
        XCTAssertEqual(model.sections[sectionID]?.hasVisibleWindows, false)
        XCTAssertEqual(repaints, 4)
    }

    /// Once hidden, the same window stops reporting the standard subrole, so
    /// its snapshot fails outright. The last frame the window did report is
    /// enough to answer the window-server check, and the failure remains a
    /// preserved window rather than a detachment.
    func testManagedWindowWithFailingSnapshotUsesLastKnownFrameForVisibility() throws {
        let mock = MockAccessibility()
        let handle = AXWindowHandle(element: AXUIElementCreateSystemWide())
        let frame = CGRect(x: 120, y: 80, width: 640, height: 480)
        let window = snapshot(handle: handle, title: "Ollama", frame: frame)
        mock.windowSnapshotsByHandle[handle] = window
        let onScreen = OnScreenFrames(frames: [ProcessInfo.processInfo.processIdentifier: [frame]])
        let clock = MockClock()
        let model = makeModel(mock: mock, onScreenWindowFramesProvider: { onScreen.frames }, clock: clock)
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: window, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: nil)

        mock.snapshotErrorsByHandle[handle] = AccessibilityClientError.unsupportedWindow(
            "only standard application windows are supported"
        )
        onScreen.frames = [:]
        for _ in 0..<3 {
            clock.advance(30)
            model.refreshRuntime(reportedFrontmostPID: nil)
        }

        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [handle])
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [])
        XCTAssertTrue(model.orphanedAssignments.isEmpty)

        mock.snapshotErrorsByHandle.removeValue(forKey: handle)
        onScreen.frames = [ProcessInfo.processInfo.processIdentifier: [frame]]
        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [handle])
    }

    /// The window server lists neither minimized windows nor a hidden
    /// application's windows as on screen, yet both are reachable from the
    /// switcher and must keep their icons. A window that never reported a
    /// frame, and an unavailable window server, keep every icon as well.
    func testMinimizedAndUnknownFrameManagedWindowsKeepSwitcherIcons() throws {
        let mock = MockAccessibility()
        let minimizedHandle = AXWindowHandle(element: AXUIElementCreateApplication(1))
        let minimized = AXWindowSnapshot(
            handle: minimizedHandle,
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "Minimized",
            frame: CGRect(x: 10, y: 10, width: 300, height: 200),
            isMinimized: true,
            isFullScreen: false,
            isResizable: true
        )
        mock.windowSnapshotsByHandle[minimizedHandle] = minimized
        let onScreen = OnScreenFrames(frames: [:])
        let model = makeModel(mock: mock, onScreenWindowFramesProvider: { onScreen.frames })
        let sectionID = try XCTUnwrap(model.sectionFrames().keys.first)
        model.attach(window: minimized, to: sectionID)
        model.refreshRuntime(reportedFrontmostPID: nil)
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [minimizedHandle])

        // A window whose frame is unknown cannot be matched, so it is not judged.
        model.sections[sectionID]?.windows[0].lastKnownFrame = .zero
        mock.snapshotErrorsByHandle[minimizedHandle] = AccessibilityClientError.unsupportedWindow("no frame")
        XCTAssertFalse(model.refreshManagedWindowSpaceVisibility())
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [minimizedHandle])

        // An unavailable window server never hides anything.
        model.sections[sectionID]?.windows[0].lastKnownFrame = minimized.frame
        model.sections[sectionID]?.windows[0].isMinimized = false
        onScreen.frames = nil
        XCTAssertFalse(model.refreshManagedWindowSpaceVisibility())
        XCTAssertEqual(model.sections[sectionID]?.visibleWindows.map(\.handle), [minimizedHandle])
    }

    func testEmptySeedReadKeepsTheSeedWithoutRepeatingThePacedPass() {
        let pid: pid_t = 45_031
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.seed.empty-read",
            applicationName: "Slow",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { [application] }
        )

        // The application is running but has published no AX window yet.
        XCTAssertTrue(model.refreshNextUnattachedApplicationAwaitingSeed())
        XCTAssertEqual(model.unattachedApplicationPIDsAwaitingSeed, [pid])
        // The empty read neither spends the one-time seed nor lets the paced
        // pass choose this application again.
        XCTAssertFalse(model.refreshNextUnattachedApplicationAwaitingSeed())
        XCTAssertFalse(model.hasVisibleUnattachedApplicationAwaitingSeed)

        let handle = AXWindowHandle(element: AXUIElementCreateApplication(45_132))
        let launched = snapshot(handle: handle, title: "Ready", pid: pid)
        mock.windowSnapshotsByPID[pid] = [launched]
        mock.windowSnapshotsByHandle[handle] = launched
        model.refreshUnattachedWindows(pid: pid)

        XCTAssertEqual(model.unattachedWindowsByHandle[handle]?.title, "Ready")
        XCTAssertTrue(model.unattachedApplicationPIDsAwaitingSeed.isEmpty)
    }

    func testUnattachedWindowIconsSettingStopsDiscoveryAndRestartsIt() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 94, model: 95, serial: 96, name: "Toggle")
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(fingerprint: fingerprint, frame: displayFrame)
        let pid: pid_t = 45_009
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.unattached-toggle",
            applicationName: "Toggle",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(
            titled: "Managed",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )
        let managedIDs = model.sections[sectionID]?.windows.map(\.id)
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(509))
        let candidate = snapshot(
            handle: handle,
            title: "Unattached",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: displayFrame.insetBy(dx: 60, dy: 100)),
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [candidate]
        mock.windowSnapshotsByHandle[handle] = candidate
        model.refreshUnattachedWindows(pid: pid)
        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [handle]
        )

        model.showUnattachedWindowIcons = false
        model.refreshUnattachedApplicationRoster()
        model.refreshUnattachedWindows(pid: pid)

        XCTAssertTrue(model.unattachedApplicationsByPID.isEmpty)
        XCTAssertTrue(model.unattachedWindowsByHandle.isEmpty)
        XCTAssertTrue(model.unattachedWindowGroupsBySection().isEmpty)
        XCTAssertFalse(model.windowObservationPIDs.contains(pid))
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), managedIDs)

        model.showUnattachedWindowIcons = true
        // Re-enabling queues every application for the paced seed; the overlay
        // drains it one process per runloop turn.
        XCTAssertTrue(model.hasVisibleUnattachedApplicationAwaitingSeed)
        while model.refreshNextUnattachedApplicationAwaitingSeed() { }

        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [handle]
        )
        XCTAssertTrue(model.windowObservationPIDs.contains(pid))
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), managedIDs)
    }

    func testUnattachedWindowUsesAnOccupiedSwitcherOnAnotherDisplay() throws {
        let occupiedSection = UUID()
        let firstDisplay = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 101, model: 102, serial: 103, name: "Occupied"),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let secondDisplay = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 104, model: 105, serial: 106, name: "Unoccupied"),
            frame: CGRect(x: 800, y: 0, width: 800, height: 600)
        )
        let pid: pid_t = 45_004
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.cross-display",
            applicationName: "Cross Display",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: occupiedSection),
            displayProvider: { [firstDisplay, secondDisplay] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(
            titled: "Managed",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: occupiedSection,
            in: model,
            mock: mock
        )
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(504))
        let candidate = snapshot(
            handle: handle,
            title: "Other display",
            frame: PanoptosModel.accessibilityFrame(
                fromAppKitFrame: secondDisplay.frame.insetBy(dx: 80, dy: 80)
            ),
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [candidate]
        mock.windowSnapshotsByHandle[handle] = candidate

        model.refreshUnattachedWindows(pid: pid)

        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[occupiedSection]?.first?.windows.map(\.handle),
            [handle]
        )
    }

    func testUnattachedWindowsStayHiddenWithoutAnOccupiedSwitcher() throws {
        let sectionID = UUID()
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 107, model: 108, serial: 109, name: "Empty"),
            frame: displayFrame
        )
        let pid: pid_t = 45_005
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.no-switcher",
            applicationName: "No Switcher",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(505))
        let candidate = snapshot(
            handle: handle,
            title: "Unattached",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: displayFrame.insetBy(dx: 40, dy: 80)),
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [candidate]
        mock.windowSnapshotsByHandle[handle] = candidate

        model.refreshUnattachedWindows(pid: pid)

        XCTAssertTrue(model.unattachedWindowGroupsBySection().isEmpty)
        XCTAssertNotNil(model.unattachedWindowsByHandle[handle])
    }

    func testUnattachedWindowSurvivesTransientAccessibilityFailuresAndWorkspaceHiding() throws {
        let sectionID = UUID()
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 110, model: 111, serial: 112, name: "Transient"),
            frame: displayFrame
        )
        let pid: pid_t = 45_006
        var application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.transient",
            applicationName: "Transient",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed", pid: ProcessInfo.processInfo.processIdentifier, to: sectionID, in: model, mock: mock)
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(506))
        let candidate = snapshot(
            handle: handle,
            title: "Retained",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: displayFrame.insetBy(dx: 50, dy: 90)),
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [candidate]
        mock.windowSnapshotsByHandle[handle] = candidate
        model.refreshUnattachedWindows(pid: pid)

        mock.windowHandlesError = AccessibilityClientError.attribute(
            kAXWindowsAttribute as String,
            .cannotComplete
        )
        model.refreshUnattachedWindows(pid: pid)
        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [handle]
        )

        application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            icon: application.icon,
            isHidden: true
        )
        model.refreshUnattachedApplicationRoster()
        XCTAssertTrue(model.unattachedWindowGroupsBySection()[sectionID]?.isEmpty ?? true)

        application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            icon: application.icon,
            isHidden: false
        )
        model.refreshUnattachedApplicationRoster()
        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [handle]
        )
    }

    func testUnattachedVisibilityIncludesSelectableFullscreenAndFixedWindows() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 94, model: 95, serial: 96, name: "Visibility")
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(fingerprint: fingerprint, frame: displayFrame)
        let pid: pid_t = 45_002
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.visibility",
            applicationName: "Visibility",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed", pid: ProcessInfo.processInfo.processIdentifier, to: sectionID, in: model, mock: mock)

        func candidate(
            _ id: pid_t,
            title: String,
            appKitFrame: CGRect,
            minimized: Bool = false,
            fullScreen: Bool = false,
            resizable: Bool = true
        ) -> AXWindowSnapshot {
            AXWindowSnapshot(
                handle: AXWindowHandle(element: AXUIElementCreateApplication(id)),
                pid: pid,
                title: title,
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: appKitFrame),
                isMinimized: minimized,
                isFullScreen: fullScreen,
                isResizable: resizable
            )
        }
        let visibleFrame = displayFrame.insetBy(dx: 30, dy: 70)
        let snapshots = [
            candidate(511, title: "Regular", appKitFrame: visibleFrame),
            candidate(512, title: "Minimized", appKitFrame: visibleFrame, minimized: true),
            candidate(
                513,
                title: "Offscreen",
                appKitFrame: CGRect(x: displayFrame.maxX + 100, y: displayFrame.maxY + 100, width: 300, height: 200)
            ),
            candidate(514, title: "Fullscreen", appKitFrame: visibleFrame, fullScreen: true),
            candidate(515, title: "Fixed", appKitFrame: visibleFrame, resizable: false)
        ]
        mock.windowSnapshotsByPID[pid] = snapshots
        mock.windowSnapshotsByHandle.merge(
            Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        ) { _, replacement in replacement }

        model.refreshUnattachedWindows(pid: pid)

        let titles = try XCTUnwrap(model.unattachedWindowGroupsBySection()[sectionID]?.first)
            .windows.map(\.title)
        XCTAssertEqual(Set(titles), Set(["Regular", "Fullscreen", "Fixed"]))
    }

    func testUnattachedApplicationIconCyclesWindowsWithoutChangingManagedState() throws {
        let sectionID = UUID()
        let fingerprint = DisplayFingerprint(vendor: 97, model: 98, serial: 99, name: "Cycling")
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(fingerprint: fingerprint, frame: displayFrame)
        let pid: pid_t = 45_003
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.cycling",
            applicationName: "Cycling",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed", pid: ProcessInfo.processInfo.processIdentifier, to: sectionID, in: model, mock: mock)
        let firstHandle = AXWindowHandle(element: AXUIElementCreateApplication(521))
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(522))
        let candidateFrame = displayFrame.insetBy(dx: 40, dy: 80)
        let snapshots = [
            snapshot(
                handle: firstHandle,
                title: "First",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: candidateFrame),
                pid: pid
            ),
            snapshot(
                handle: secondHandle,
                title: "Second",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: candidateFrame),
                pid: pid
            )
        ]
        mock.windowSnapshotsByPID[pid] = snapshots
        mock.windowSnapshotsByHandle.merge(
            Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        ) { _, replacement in replacement }
        model.refreshUnattachedWindows(pid: pid)
        let managedState = model.sections
        let key = try XCTUnwrap(model.unattachedWindowGroupsBySection()[sectionID]?.first?.id)
        model.focusedSectionID = sectionID

        model.cycleUnattachedWindows(in: key)
        model.cycleUnattachedWindows(in: key)
        model.cycleUnattachedWindows(in: key)

        XCTAssertNil(model.focusedSectionID)
        XCTAssertEqual(mock.focusRequests.suffix(3).map(\.handle), [firstHandle, secondHandle, firstHandle])
        XCTAssertEqual(model.sections, managedState)
        XCTAssertNil(model.focusedManagedWindowID)
        XCTAssertEqual(model.focusedUnattachedWindowHandle, firstHandle)
    }

    func testExternalUnattachedFocusUpdatesCursorAndFocusFailureDoesNotAdvanceIt() throws {
        let sectionID = UUID()
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 113, model: 114, serial: 115, name: "External Focus"),
            frame: displayFrame
        )
        let pid: pid_t = 45_007
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.external-focus",
            applicationName: "External Focus",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed", pid: ProcessInfo.processInfo.processIdentifier, to: sectionID, in: model, mock: mock)
        let firstHandle = AXWindowHandle(element: AXUIElementCreateApplication(507))
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(508))
        let candidateFrame = displayFrame.insetBy(dx: 50, dy: 90)
        let snapshots = [
            snapshot(
                handle: firstHandle,
                title: "First",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: candidateFrame),
                pid: pid
            ),
            snapshot(
                handle: secondHandle,
                title: "Second",
                frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: candidateFrame),
                pid: pid
            )
        ]
        mock.windowSnapshotsByPID[pid] = snapshots
        mock.windowSnapshotsByHandle.merge(
            Dictionary(uniqueKeysWithValues: snapshots.map { ($0.handle, $0) })
        ) { _, replacement in replacement }
        model.refreshUnattachedWindows(pid: pid)
        mock.focusedHandle = secondHandle

        XCTAssertTrue(model.refreshFocusedWindow(reportedFrontmostPID: pid))
        let group = try XCTUnwrap(model.unattachedWindowGroupsBySection()[sectionID]?.first)
        XCTAssertEqual(group.nextWindowTitle, "First")

        mock.focusError = AccessibilityClientError.attribute(kAXFocusedWindowAttribute as String, .cannotComplete)
        model.cycleUnattachedWindows(in: group.id)
        XCTAssertEqual(model.focusedUnattachedWindowHandle, secondHandle)

        mock.focusError = nil
        model.cycleUnattachedWindows(in: group.id)
        XCTAssertEqual(mock.focusRequests.last?.handle, firstHandle)
    }

    func testUnattachedDiscoveryKeepsAdvancingAcrossRosterRefreshes() {
        let icon = NSImage()
        let applications = [pid_t(45_012), 45_010, 45_011].map { pid in
            RunningApplicationSnapshot(
                pid: pid,
                bundleIdentifier: "test.discovery.\(pid)",
                applicationName: "Discovery \(pid)",
                icon: icon,
                isHidden: false
            )
        }
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { applications }
        )

        model.refreshNextUnattachedApplication()
        model.refreshUnattachedApplicationRoster()
        model.refreshNextUnattachedApplication()
        model.refreshUnattachedApplicationRoster()
        model.refreshNextUnattachedApplication()

        XCTAssertEqual(mock.windowHandlePIDs, [45_010, 45_011, 45_012])
    }

    func testInitialUnattachedSeedDiscoversEveryVisibleApplicationWithoutActivation() {
        let icon = NSImage()
        let firstPID: pid_t = 45_020
        let secondPID: pid_t = 45_021
        let hiddenPID: pid_t = 45_022
        let applications = [
            RunningApplicationSnapshot(
                pid: firstPID,
                bundleIdentifier: "test.seed.first",
                applicationName: "First",
                icon: icon,
                isHidden: false
            ),
            RunningApplicationSnapshot(
                pid: secondPID,
                bundleIdentifier: "test.seed.second",
                applicationName: "Second",
                icon: icon,
                isHidden: false
            ),
            RunningApplicationSnapshot(
                pid: hiddenPID,
                bundleIdentifier: "test.seed.hidden",
                applicationName: "Hidden",
                icon: icon,
                isHidden: true
            )
        ]
        let firstHandle = AXWindowHandle(element: AXUIElementCreateApplication(45_120))
        let secondHandle = AXWindowHandle(element: AXUIElementCreateApplication(45_121))
        let mock = MockAccessibility()
        mock.windowSnapshotsByPID = [
            firstPID: [snapshot(handle: firstHandle, title: "First free", pid: firstPID)],
            secondPID: [snapshot(handle: secondHandle, title: "Second free", pid: secondPID)]
        ]
        mock.windowSnapshotsByHandle = Dictionary(uniqueKeysWithValues:
            mock.windowSnapshotsByPID.values.flatMap { $0 }.map { ($0.handle, $0) }
        )
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { applications }
        )

        while model.refreshNextUnattachedApplicationAwaitingSeed() { }

        XCTAssertEqual(mock.windowHandlePIDs, [firstPID, secondPID])
        XCTAssertEqual(Set(model.unattachedWindowsByHandle.values.map(\.pid)), [firstPID, secondPID])
        XCTAssertTrue(mock.focusRequests.isEmpty)
        XCTAssertEqual(model.unattachedApplicationPIDsAwaitingSeed, [hiddenPID])
    }

    func testEmptyLaunchRefreshDoesNotConsumeSeedBeforeFirstWindowAppears() {
        let pid: pid_t = 45_023
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.seed.launch-race",
            applicationName: "Launching",
            icon: NSImage(),
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { [application] }
        )

        // NSWorkspace reports the process before its first window has entered
        // the application's AXWindows collection.
        model.refreshUnattachedWindows(pid: pid)
        XCTAssertEqual(model.unattachedApplicationPIDsAwaitingSeed, [pid])

        let handle = AXWindowHandle(element: AXUIElementCreateApplication(45_123))
        let launchedWindow = snapshot(handle: handle, title: "Ready", pid: pid)
        mock.windowSnapshotsByPID[pid] = [launchedWindow]
        mock.windowSnapshotsByHandle[handle] = launchedWindow

        XCTAssertTrue(model.refreshNextUnattachedApplicationAwaitingSeed())
        XCTAssertEqual(model.unattachedWindowsByHandle[handle]?.title, "Ready")
        XCTAssertTrue(model.unattachedApplicationPIDsAwaitingSeed.isEmpty)
        XCTAssertEqual(mock.windowHandlePIDs, [pid, pid])
    }

    func testNewApplicationRosterPublishesObservationTargetBeforeLaunchWindowRead() {
        let pid: pid_t = 45_024
        let application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.seed.observer-race",
            applicationName: "Observed Launch",
            icon: NSImage(),
            isHidden: false
        )
        var applications: [RunningApplicationSnapshot] = []
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            runningApplicationSnapshotsProvider: { applications }
        )
        var observedTargets: [Set<pid_t>] = []
        var windowReadCountsAtObservation: [Int] = []
        model.onUnattachedApplicationRosterChanged = {
            observedTargets.append(model.windowObservationPIDs)
            windowReadCountsAtObservation.append(mock.windowHandlesCallCount)
        }

        applications = [application]
        model.refreshUnattachedApplicationRoster()
        // Mirrors the launch handler's possibly-premature AXWindows read. The
        // coordinator has already had its synchronous opportunity to subscribe
        // to AXWindowCreated for this pid before the read occurs.
        model.refreshUnattachedWindows(pid: pid)

        XCTAssertEqual(observedTargets, [Set([pid])])
        XCTAssertEqual(windowReadCountsAtObservation, [0])
        XCTAssertEqual(mock.windowHandlePIDs, [pid])
    }

    func testUnattachedRosterToleratesDuplicatePIDsAndUsesLatestSnapshot() {
        let pid: pid_t = 45_014
        let snapshots = ["Earlier", "Latest"].map { name in
            RunningApplicationSnapshot(
                pid: pid,
                bundleIdentifier: "test.duplicate-pid",
                applicationName: name,
                icon: NSImage(),
                isHidden: false
            )
        }

        let model = makeModel(
            mock: MockAccessibility(),
            runningApplicationSnapshotsProvider: { snapshots }
        )

        XCTAssertEqual(model.unattachedApplicationsByPID[pid]?.applicationName, "Latest")
    }

    func testRuntimeClearsStaleUnattachedFocusWithoutAFrontmostSelectableApplication() {
        let model = makeModel(mock: MockAccessibility())
        model.focusedUnattachedWindowHandle = AXWindowHandle(
            element: AXUIElementCreateApplication(45_015)
        )

        model.refreshRuntime(reportedFrontmostPID: nil)

        XCTAssertNil(model.focusedUnattachedWindowHandle)
    }

    func testUnattachedApplicationKeepsOneResolvedIconForItsSessionIdentity() throws {
        let sectionID = UUID()
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 116, model: 117, serial: 118, name: "Stable Icon"),
            frame: displayFrame
        )
        let pid: pid_t = 45_013
        let firstIcon = NSImage()
        let replacementIcon = NSImage()
        var application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: "test.stable-icon",
            applicationName: "Stable Icon",
            icon: firstIcon,
            isHidden: false
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(
            titled: "Managed",
            pid: ProcessInfo.processInfo.processIdentifier,
            to: sectionID,
            in: model,
            mock: mock
        )
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(509))
        let candidate = snapshot(
            handle: handle,
            title: "Free",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: displayFrame.insetBy(dx: 50, dy: 90)),
            pid: pid
        )
        mock.windowSnapshotsByPID[pid] = [candidate]
        mock.windowSnapshotsByHandle[handle] = candidate
        model.refreshUnattachedWindows(pid: pid)

        application = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            icon: replacementIcon,
            isHidden: false
        )
        model.refreshUnattachedApplicationRoster()
        model.refreshUnattachedWindows(pid: pid)

        let group = try XCTUnwrap(model.unattachedWindowGroupsBySection()[sectionID]?.first)
        XCTAssertTrue(group.icon === firstIcon)
        XCTAssertFalse(group.icon === replacementIcon)
    }

    func testUnattachedFocusSurvivesFocusModeUnhideOrderingCorrections() throws {
        let fixture = try makeFocusModeFixture()
        let sectionFrame = try XCTUnwrap(fixture.model.sectionFrames()[fixture.focusedSection])
        let freeHandle = AXWindowHandle(element: AXUIElementCreateApplication(510))
        let freeWindow = snapshot(
            handle: freeHandle,
            title: "Free focused-app window",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: sectionFrame.insetBy(dx: 40, dy: 80)),
            pid: fixture.focusedPID
        )
        fixture.mock.windowSnapshotsByHandle[freeHandle] = freeWindow
        fixture.mock.windowSnapshots = Array(fixture.mock.windowSnapshotsByHandle.values)
        fixture.model.refreshUnattachedWindows(pid: fixture.focusedPID)
        let key = try XCTUnwrap(
            fixture.model.unattachedWindowGroupsBySection()[fixture.focusedSection]?.first?.id
        )
        fixture.model.toggleFocusMode(for: fixture.focusedSection)

        fixture.model.cycleUnattachedWindows(in: key)

        XCTAssertNil(fixture.model.focusedSectionID)
        XCTAssertEqual(fixture.mock.focusRequests.last?.handle, freeHandle)
        XCTAssertTrue(fixture.mock.raisedHandles.contains(fixture.otherHandle))

        let focusRequestCount = fixture.mock.focusRequests.count
        fixture.mock.resetRaiseRequests()
        fixture.model.applicationDidUnhide(pid: fixture.otherPID)

        XCTAssertEqual(fixture.mock.raisedHandles, [fixture.otherHandle])
        XCTAssertEqual(fixture.mock.focusRequests.count, focusRequestCount + 1)
        XCTAssertEqual(fixture.mock.focusRequests.last?.handle, freeHandle)
    }

    func testDoubleClickAttachesSelectedUnattachedWindowToIconsSection() throws {
        let leftSection = UUID()
        let rightSection = UUID()
        let displayFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let display = currentDisplay(
            fingerprint: DisplayFingerprint(vendor: 119, model: 120, serial: 121, name: "Double Click"),
            frame: displayFrame
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        let application = RunningApplicationSnapshot(
            application: try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
        )
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: leftSection),
                second: .leaf(id: rightSection)
            ),
            displayProvider: { [display] },
            runningApplicationSnapshotsProvider: { [application] }
        )
        try attachWindow(titled: "Managed left", pid: pid, to: leftSection, in: model, mock: mock)
        try attachWindow(titled: "Managed right", pid: pid, to: rightSection, in: model, mock: mock)
        let rightFrame = try XCTUnwrap(model.sectionFrames()[rightSection])
        let freeHandle = AXWindowHandle(element: AXUIElementCreateApplication(523))
        let freeWindow = snapshot(
            handle: freeHandle,
            title: "Attach me right",
            frame: PanoptosModel.accessibilityFrame(fromAppKitFrame: rightFrame.insetBy(dx: 40, dy: 80)),
            pid: pid
        )
        mock.windowSnapshotsByHandle[freeHandle] = freeWindow
        mock.windowSnapshotsByPID[pid] = Array(mock.windowSnapshotsByHandle.values)
        mock.listedWindowHandlesByPID[pid] = mock.windowSnapshotsByPID[pid]?.map(\.handle) ?? []
        model.refreshUnattachedWindows(pid: pid)
        let key = try XCTUnwrap(model.unattachedWindowGroupsBySection()[rightSection]?.first?.id)

        // The first click selects/focuses the group window; the second click's
        // separate action attaches that same selection instead of advancing.
        model.cycleUnattachedWindows(in: key)
        model.attachUnattachedWindow(in: key)

        XCTAssertTrue(model.sections[rightSection]?.windows.contains(where: { $0.handle == freeHandle }) == true)
        XCTAssertFalse(model.sections[leftSection]?.windows.contains(where: { $0.handle == freeHandle }) == true)
        XCTAssertNil(model.unattachedWindowsByHandle[freeHandle])
        XCTAssertEqual(mock.focusRequests.suffix(2).map(\.handle), [freeHandle, freeHandle])
    }

    func testDetachingAndReattachingMovesWindowInAndOutOfUnattachedGroups() throws {
        let sectionID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = try XCTUnwrap(NSRunningApplication(processIdentifier: pid))
        let application = RunningApplicationSnapshot(application: app)
        let mock = MockAccessibility()
        let model = makeModel(
            mock: mock,
            root: .leaf(id: sectionID),
            runningApplicationSnapshotsProvider: { [application] }
        )
        let firstHandle = try attachWindow(titled: "First", pid: pid, to: sectionID, in: model, mock: mock)
        _ = try attachWindow(titled: "Second", pid: pid, to: sectionID, in: model, mock: mock)
        let windows = try XCTUnwrap(mock.windowSnapshotsByHandle.isEmpty ? nil : Array(mock.windowSnapshotsByHandle.values))
        mock.windowSnapshotsByPID[pid] = windows
        mock.listedWindowHandlesByPID[pid] = windows.map(\.handle)
        let firstSnapshot = try XCTUnwrap(mock.windowSnapshotsByHandle[firstHandle])
        let firstID = try XCTUnwrap(model.managedWindow(matching: firstHandle)?.id)

        model.detach(windowID: firstID)

        XCTAssertEqual(
            model.unattachedWindowGroupsBySection()[sectionID]?.first?.windows.map(\.handle),
            [firstHandle]
        )

        model.attach(window: firstSnapshot, to: sectionID)

        XCTAssertTrue(model.unattachedWindowGroupsBySection()[sectionID]?.isEmpty ?? true)
    }

    func testUnattachedIconsShareSwitcherScrollerWithoutReducingItsViewport() throws {
        let model = makeModel(mock: MockAccessibility())
        model.windowSwitcherTitleMode = .always
        let managedWindows = (0..<5).map {
            managedWindow(bundleIdentifier: "com.example.Managed\($0)", ordinal: $0)
        }
        let sectionID = UUID()
        let section = LayoutSectionState(
            id: sectionID,
            windows: managedWindows,
            activeWindowID: managedWindows[0].id
        )
        let presentation = SectionPresentation(sectionID: sectionID, section: section)
        let width: CGFloat = 320
        let height = WindowSwitcherSize.barHeight(for: model.windowSwitcherUIScale)
        let hosting = FirstMouseHostingView(rootView: AnyView(
            SectionWindowBar(presentation: presentation)
                .environmentObject(model)
                .frame(width: width, height: height)
        ))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        settleHostedSwitcher(hosting)

        let scrollView = try XCTUnwrap(descendantScrollViews(in: hosting).first)
        let viewportWidth = scrollView.contentView.bounds.width
        let managedContentWidth = try XCTUnwrap(scrollView.documentView).frame.width
        XCTAssertEqual(viewportWidth, width, accuracy: 1)
        XCTAssertGreaterThan(managedContentWidth, viewportWidth)

        presentation.unattachedGroups = (0..<3).map { ordinal in
            let bundleIdentifier = "com.example.Unattached\(ordinal)"
            let pid = pid_t(8000 + ordinal)
            let handle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
            let unattachedWindow = UnattachedWindow(
                handle: handle,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                applicationName: "Unattached \(ordinal)",
                icon: NSImage(size: NSSize(width: 32, height: 32)),
                title: "Free window \(ordinal)",
                frame: CGRect(x: 0, y: 0, width: 500, height: 400),
                isMinimized: false,
                isOnActiveSpace: true,
                discoveryOrder: ordinal
            )
            return UnattachedWindowApplicationGroup(
                id: UnattachedWindowGroupKey(
                    sectionID: sectionID,
                    bundleIdentifier: bundleIdentifier
                ),
                applicationName: unattachedWindow.applicationName,
                icon: unattachedWindow.icon,
                windows: [unattachedWindow],
                nextWindowTitle: unattachedWindow.title
            )
        }
        settleHostedSwitcher(hosting)

        let combinedContentWidth = try XCTUnwrap(scrollView.documentView).frame.width
        XCTAssertEqual(scrollView.contentView.bounds.width, viewportWidth, accuracy: 1)
        XCTAssertGreaterThan(combinedContentWidth, managedContentWidth)

        let buttons = descendantFirstMouseButtons(in: hosting)
        let firstManagedButton = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel()?.hasPrefix(managedWindows[0].applicationName) == true
        })
        let lastUnattachedButton = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel()?.contains("Unattached 2: 1 unattached window") == true
        })
        let documentView = try XCTUnwrap(scrollView.documentView)
        let managedFrame = firstManagedButton.convert(firstManagedButton.bounds, to: documentView)
        let unattachedFrame = lastUnattachedButton.convert(lastUnattachedButton.bounds, to: documentView)
        let attachedChrome = try XCTUnwrap(descendantVisualEffectViews(in: hosting).first)
        let chromeFrame = attachedChrome.convert(attachedChrome.bounds, to: documentView)
        XCTAssertTrue(chromeFrame.contains(managedFrame))
        XCTAssertFalse(
            chromeFrame.intersects(unattachedFrame),
            "Unattached icons must remain over the panel's transparent region"
        )

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertTrue(managedFrame.intersects(scrollView.documentVisibleRect))
        XCTAssertFalse(unattachedFrame.intersects(scrollView.documentVisibleRect))

        let maximumOffset = max(0, combinedContentWidth - viewportWidth)
        scrollView.contentView.scroll(to: NSPoint(x: maximumOffset, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertFalse(managedFrame.intersects(scrollView.documentVisibleRect))
        XCTAssertTrue(unattachedFrame.intersects(scrollView.documentVisibleRect))
        _ = window
    }

    private struct FocusModeFixture {
        let model: PanoptosModel
        let mock: MockAccessibility
        let clock: MockClock
        let focusedSection: UUID
        let otherSection: UUID
        let focusedPID: pid_t
        let otherPID: pid_t
        let focusedHandle: AXWindowHandle
        let otherHandle: AXWindowHandle
    }

    /// Two sections on one display, each holding one window, owned by two
    /// different applications.
    private func makeFocusModeFixture() throws -> FocusModeFixture {
        let focusedSection = UUID()
        let otherSection = UUID()
        let focusedPID = ProcessInfo.processInfo.processIdentifier
        let otherPID = try foreignApplicationPIDs(1)[0]
        let mock = MockAccessibility()
        let clock = MockClock()
        let model = makeModel(
            mock: mock,
            root: .split(
                id: UUID(),
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(id: focusedSection),
                second: .leaf(id: otherSection)
            ),
            clock: clock
        )
        let focusedHandle = try attachWindow(
            titled: "Focused",
            pid: focusedPID,
            to: focusedSection,
            in: model,
            mock: mock
        )
        let otherHandle = try attachWindow(
            titled: "Other",
            pid: otherPID,
            to: otherSection,
            in: model,
            mock: mock
        )
        return FocusModeFixture(
            model: model,
            mock: mock,
            clock: clock,
            focusedSection: focusedSection,
            otherSection: otherSection,
            focusedPID: focusedPID,
            otherPID: otherPID,
            focusedHandle: focusedHandle,
            otherHandle: otherHandle
        )
    }

    /// Focus mode hides whole applications, so its tests need windows owned by
    /// more than one process, and `attach` only accepts pids that resolve to a
    /// running application.
    private func foreignApplicationPIDs(_ count: Int) throws -> [pid_t] {
        let own = ProcessInfo.processInfo.processIdentifier
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier).filter { $0 != own }
        try XCTSkipUnless(pids.count >= count, "Needs \(count) running application(s) besides the test process")
        return Array(pids.prefix(count))
    }

    @discardableResult
    private func attachWindow(
        titled title: String,
        pid: pid_t,
        to sectionID: UUID,
        in model: PanoptosModel,
        mock: MockAccessibility
    ) throws -> AXWindowHandle {
        // Distinct AXUIElement instances: two systemwide elements compare equal.
        let handle = AXWindowHandle(
            element: AXUIElementCreateApplication(pid_t(mock.windowSnapshotsByHandle.count + 1))
        )
        let window = snapshot(handle: handle, title: title, pid: pid)
        mock.windowSnapshotsByHandle[handle] = window
        mock.windowSnapshots = Array(mock.windowSnapshotsByHandle.values)
        model.attach(window: window, to: sectionID)
        XCTAssertNotNil(model.sections[sectionID]?.windows.first { $0.handle == handle })
        return handle
    }

    @discardableResult
    private func addUnattachedWindow(
        pid: pid_t,
        overlappingSection sectionID: UUID,
        isMinimized: Bool = false,
        isOnActiveSpace: Bool = true,
        in model: PanoptosModel
    ) throws -> AXWindowHandle {
        let application = try XCTUnwrap(model.runningApplication(pid: pid))
        let bundleIdentifier = application.bundleIdentifier ?? "pid.\(pid)"
        model.unattachedApplicationsByPID[pid] = RunningApplicationSnapshot(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? bundleIdentifier,
            icon: NSImage(),
            isHidden: false
        )
        let handle = AXWindowHandle(element: AXUIElementCreateApplication(pid))
        let frame = try XCTUnwrap(model.sectionFrames()[sectionID]).insetBy(dx: 40, dy: 80)
        model.unattachedWindowsByHandle[handle] = UnattachedWindow(
            handle: handle,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? bundleIdentifier,
            icon: NSImage(),
            title: "Unattached",
            frame: frame,
            isMinimized: isMinimized,
            isOnActiveSpace: isOnActiveSpace,
            discoveryOrder: 0
        )
        return handle
    }

    @MainActor
    func testFinderTabSwitchKeepsOneEntryIdentityOrderAndAssignment() throws {
        let mock = MockAccessibility()
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = AXWindowHandle(element: AXUIElementCreateApplication(101))
        let second = AXWindowHandle(element: AXUIElementCreateApplication(102))
        let separate = AXWindowHandle(element: AXUIElementCreateApplication(103))
        let group = AXWindowHandle(element: AXUIElementCreateApplication(104))
        let firstSnapshot = snapshot(handle: first, title: "Documents", finderTabGroup: group)
        let separateSnapshot = snapshot(handle: separate, title: "Documents")
        mock.windowSnapshots = [firstSnapshot, separateSnapshot]
        mock.windowSnapshotsByHandle = [first: firstSnapshot, separate: separateSnapshot]
        model.attach(window: firstSnapshot, to: sectionID)
        model.attach(window: separateSnapshot, to: sectionID)
        let originalOrder = try XCTUnwrap(model.sections[sectionID]?.windows.map(\.id))
        let selected = snapshot(handle: second, title: "Downloads", finderTabGroup: group)
        mock.windowSnapshotsByHandle[second] = selected
        // Inactive Finder tabs remain readable but leave the raw window list.
        mock.listedWindowHandles = [second, separate]
        mock.selectedFinderTabs[group] = second
        mock.focusedHandle = second
        model.compatibilityError = "Existing compatibility notice"

        XCTAssertTrue(model.refreshFocusedWindow(reportedFrontmostPID: pid))
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), originalOrder)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [second, separate])
        XCTAssertEqual(model.sections[sectionID]?.windows.first?.title, "Downloads")
        XCTAssertEqual(model.focusedManagedWindowID, originalOrder.first)
        XCTAssertEqual(model.compatibilityError, "Existing compatibility notice")
        XCTAssertEqual(model.attachNewlyCreatedWindow(second, pid: pid), .ignored)
        XCTAssertEqual(model.windowAssignmentPersistence.load().filter { $0.orphanedAt == nil }.count, 2)

        mock.listedWindowHandles = [first, separate]
        mock.selectedFinderTabs[group] = first
        mock.focusedHandle = first
        model.refreshRuntime(reportedFrontmostPID: pid)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), originalOrder)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.handle), [first, separate])
    }

    @MainActor
    func testFinderTabReconciliationPreservesWindowsDuringFailuresAndTabTearOff() throws {
        let mock = MockAccessibility()
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = AXWindowHandle(element: AXUIElementCreateApplication(111))
        let second = AXWindowHandle(element: AXUIElementCreateApplication(112))
        let group = AXWindowHandle(element: AXUIElementCreateApplication(113))
        let original = snapshot(handle: first, title: "Documents", finderTabGroup: group)
        mock.windowSnapshots = [original]
        mock.windowSnapshotsByHandle[first] = original
        model.attach(window: original, to: sectionID)
        let id = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)
        XCTAssertFalse(model.reconcileFinderTabs()) // The tab bar cannot answer.
        mock.selectedFinderTabs[group] = second
        mock.windowSnapshotsByHandle[second] = snapshot(handle: second, title: "Downloads", finderTabGroup: group)
        mock.listedWindowHandles = [second]
        model.transitionSettleDeadline = .distantFuture
        XCTAssertFalse(model.reconcileFinderTabs())
        XCTAssertEqual(model.managedWindow(id: id)?.handle, first)
        model.transitionSettleDeadline = nil
        mock.windowHandlesError = AccessibilityClientError.attribute(kAXWindowsAttribute as String, .cannotComplete)
        XCTAssertFalse(model.reconcileFinderTabs())
        XCTAssertEqual(model.managedWindow(id: id)?.handle, first)
        mock.windowHandlesError = nil
        // A torn-off tab remains a separately listed real window, even though
        // its old tab bar moved to the remaining tab. Do not merge them.
        mock.listedWindowHandles = [first, second]
        mock.windowSnapshotsByHandle[first] = snapshot(handle: first, title: "Documents")
        XCTAssertFalse(model.reconcileFinderTabs())
        XCTAssertEqual(model.managedWindow(id: id)?.handle, first)
        XCTAssertNil(model.managedWindow(id: id)?.finderTabGroup)
    }

    @MainActor
    func testClosingSelectedFinderTabRetainsSurvivingWindow() throws {
        let mock = MockAccessibility()
        let sectionID = UUID()
        let model = makeModel(mock: mock, root: .leaf(id: sectionID))
        let first = AXWindowHandle(element: AXUIElementCreateApplication(121))
        let second = AXWindowHandle(element: AXUIElementCreateApplication(122))
        let group = AXWindowHandle(element: AXUIElementCreateApplication(123))
        let original = snapshot(handle: first, title: "Documents", finderTabGroup: group)
        mock.windowSnapshots = [original]
        mock.windowSnapshotsByHandle[first] = original
        model.attach(window: original, to: sectionID)
        let id = try XCTUnwrap(model.sections[sectionID]?.windows.first?.id)
        mock.selectedFinderTabs[group] = second
        mock.windowSnapshotsByHandle[second] = snapshot(handle: second, title: "Downloads", finderTabGroup: group)
        mock.listedWindowHandles = [second]
        model.confirmWindowDestroyed(first)
        XCTAssertEqual(model.sections[sectionID]?.windows.map(\.id), [id])
        XCTAssertEqual(model.managedWindow(id: id)?.handle, second)
        XCTAssertTrue(model.orphanedAssignments.isEmpty)
    }

    private func snapshot(
        handle: AXWindowHandle,
        title: String,
        frame: CGRect = CGRect(x: 50, y: 50, width: 500, height: 400),
        pid: pid_t = ProcessInfo.processInfo.processIdentifier,
        finderTabGroup: AXWindowHandle? = nil
    ) -> AXWindowSnapshot {
        AXWindowSnapshot(
            handle: handle,
            pid: pid,
            title: title,
            frame: frame,
            isMinimized: false,
            isFullScreen: false,
            isResizable: true,
            finderTabGroup: finderTabGroup
        )
    }

    private func managedWindow(
        bundleIdentifier: String,
        ordinal: Int,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> ManagedWindow {
        ManagedWindow(
            id: UUID(),
            handle: AXWindowHandle(element: AXUIElementCreateApplication(pid_t(ordinal + 100))),
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            accessibilityIdentifier: nil,
            windowOrdinal: ordinal,
            applicationName: bundleIdentifier,
            icon: NSImage(),
            title: "Window \(ordinal)",
            isMinimized: false
        )
    }

    private func currentDisplay(
        fingerprint: DisplayFingerprint,
        frame: CGRect
    ) -> CurrentDisplay {
        CurrentDisplay(
            fingerprint: fingerprint,
            frame: frame,
            visibleFrame: frame,
            scale: 2
        )
    }

    private func menu(titled title: String) -> MenuNode {
        MenuNode(
            indexPath: [0],
            title: title,
            role: kAXMenuBarItemRole as String,
            isEnabled: true,
            mark: nil,
            shortcut: nil,
            availableActions: [],
            children: []
        )
    }

    private func makeModel(
        mock: MockAccessibility,
        root: LayoutNode? = nil,
        gutter: CGFloat = DisplayLayout.defaultGutter,
        directory suppliedDirectory: URL? = nil,
        keepAwakeController: KeepAwakeControlling = MockKeepAwakeController(),
        shortcutRegistrar: ShortcutRegistering = MockShortcutRegistrar(),
        loginItemController: LoginItemControlling = MockLoginItemController(),
        updateController: UpdateControlling = MockUpdateController(),
        displayProvider: (() -> [CurrentDisplay])? = nil,
        runningApplicationSnapshotsProvider: (() -> [RunningApplicationSnapshot])? = nil,
        // nil means "the window server could not be asked", which keeps every
        // discovered window visible. Tests that care about Space membership
        // pass their own map.
        onScreenWindowFramesProvider: @escaping () -> [pid_t: [CGRect]]? = { nil },
        // Managed windows in these tests carry the test process' own pid, so
        // the model is told a different one for itself. Otherwise every managed
        // application would look like Panoptos to focus mode.
        ownProcessIdentifier: pid_t = -1,
        clock: MockClock = MockClock()
    ) -> PanoptosModel {
        let directory = suppliedDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let persistence = LayoutPersistence(url: directory.appendingPathComponent("layouts.json"))
        let suppliedDisplay = displayProvider?().first
        if let root,
           let fingerprint = suppliedDisplay?.fingerprint
                ?? NSScreen.screens.first.map(DisplayFingerprint.current(for:)) {
            try? persistence.save([
                DisplayLayout(
                    fingerprint: fingerprint,
                    root: root,
                    gutter: gutter
                )
            ])
        }
        return PanoptosModel(
            accessibility: mock,
            persistence: persistence,
            windowAssignmentPersistence: WindowAssignmentPersistence(
                url: directory.appendingPathComponent("window-assignments.json")
            ),
            settingsPersistence: SettingsPersistence(url: directory.appendingPathComponent("settings.json")),
            shortcutPersistence: ShortcutPersistence(url: directory.appendingPathComponent("shortcuts.json")),
            shortcutRegistrar: shortcutRegistrar,
            keepAwakeController: keepAwakeController,
            loginItemController: loginItemController,
            updateController: updateController,
            displayProvider: displayProvider,
            runningApplicationSnapshotsProvider: runningApplicationSnapshotsProvider,
            onScreenWindowFramesProvider: onScreenWindowFramesProvider,
            ownProcessIdentifier: ownProcessIdentifier,
            now: { clock.now }
        )
    }
}

/// What the window server would list as on screen. Tests change it between
/// passes to take a window off screen and bring it back.
final class OnScreenFrames: @unchecked Sendable {
    var frames: [pid_t: [CGRect]]?

    init(frames: [pid_t: [CGRect]]?) {
        self.frames = frames
    }
}

/// Sleep, wake, and the invalid-element grace period are all time-based, so
/// tests drive the clock instead of waiting on it.
final class MockClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

private final class MockDisplayProvider: @unchecked Sendable {
    var displays: [CurrentDisplay]

    init(_ displays: [CurrentDisplay]) {
        self.displays = displays
    }
}

private final class MockLoginItemController: LoginItemControlling {
    var state: LoginItemState
    var failureToThrow: Error?
    private(set) var requestedValues: [Bool] = []

    init(state: LoginItemState = .disabled, failureToThrow: Error? = nil) {
        self.state = state
        self.failureToThrow = failureToThrow
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let failureToThrow { throw failureToThrow }
        state = enabled ? .enabled : .disabled
    }
}

private struct MockLoginItemFailure: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

/// Standing in for Sparkle keeps a test run from starting the updater or
/// reaching the update feed.
final class MockUpdateController: UpdateControlling {
    var automaticallyChecksForUpdates: Bool
    var lastUpdateCheckDate: Date?
    var canCheckForUpdates: Bool
    private(set) var checkCallCount = 0

    init(
        automaticallyChecksForUpdates: Bool = true,
        lastUpdateCheckDate: Date? = nil,
        canCheckForUpdates: Bool = true
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.lastUpdateCheckDate = lastUpdateCheckDate
        self.canCheckForUpdates = canCheckForUpdates
    }

    func checkForUpdates() {
        checkCallCount += 1
    }
}

private final class MockKeepAwakeController: KeepAwakeControlling {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var displayStartCallCount = 0
    private(set) var displayStopCallCount = 0
    private var isSystemSleepPrevented = false
    private var isDisplaySleepPrevented = false

    func startPreventingIdleSystemSleep() {
        guard !isSystemSleepPrevented else { return }
        isSystemSleepPrevented = true
        startCallCount += 1
    }

    func stopPreventingIdleSystemSleep() {
        guard isSystemSleepPrevented else { return }
        isSystemSleepPrevented = false
        stopCallCount += 1
    }

    func startPreventingIdleDisplaySleep() {
        guard !isDisplaySleepPrevented else { return }
        isDisplaySleepPrevented = true
        displayStartCallCount += 1
    }

    func stopPreventingIdleDisplaySleep() {
        guard isDisplaySleepPrevented else { return }
        isDisplaySleepPrevented = false
        displayStopCallCount += 1
    }
}

private final class MockShortcutRegistrar: ShortcutRegistering {
    var handler: ((ShortcutCommand) -> Void)?
    private(set) var updates: [[ShortcutCommand: GlobalShortcut]] = []
    func update(_ shortcuts: [ShortcutCommand: GlobalShortcut]) -> [ShortcutCommand: OSStatus] {
        updates.append(shortcuts)
        return [:]
    }
}

private struct StoredShortcutsFixture: Codable {
    let version: Int
    let shortcuts: [ShortcutCommand: GlobalShortcut]
}

@MainActor
private final class MockAccessibility: AccessibilityServing {
    var selectedFinderTabs: [AXWindowHandle: AXWindowHandle] = [:]

    func selectedWindow(inFinderTabGroup group: AXWindowHandle) throws -> AXWindowHandle {
        guard let selected = selectedFinderTabs[group] else {
            throw AccessibilityClientError.attribute(kAXWindowAttribute as String, .cannotComplete)
        }
        return selected
    }
    var isTrusted = true
    var windowSnapshot: AXWindowSnapshot?
    var windowSnapshots: [AXWindowSnapshot]?
    var windowSnapshotsByPID: [pid_t: [AXWindowSnapshot]] = [:]
    var windowSnapshotsByHandle: [AXWindowHandle: AXWindowSnapshot] = [:]
    private(set) var windowsCallCount = 0
    var snapshotError: Error?
    var snapshotErrorsByHandle: [AXWindowHandle: Error] = [:]
    /// The application's raw window list. Defaults to the snapshot fixtures,
    /// including handles whose elements can no longer be read.
    var listedWindowHandles: [AXWindowHandle]?
    var listedWindowHandlesByPID: [pid_t: [AXWindowHandle]] = [:]
    var windowHandlesError: Error?
    private(set) var windowHandlesCallCount = 0
    private(set) var windowHandlePIDs: [pid_t] = []

    /// Every per-window snapshot read. Each is a blocking Accessibility call in
    /// the real client, so this is how tests see the cost of a refresh.
    private(set) var snapshotCallCount = 0

    func resetWindowHandlesCallCount() { windowHandlesCallCount = 0 }
    func resetWindowsCallCount() { windowsCallCount = 0 }
    func resetSnapshotCallCount() { snapshotCallCount = 0 }
    func resetRaiseRequests() { raisedHandles = [] }
    var focusedHandle: AXWindowHandle?
    var focusedWindowError: Error?
    var lastSetFrame: CGRect?
    var frameError: Error?
    /// Per-window one-shot errors simulate an application that partially
    /// changes a frame and then rejects it. The attempted request is recorded
    /// before the error so rollback can be asserted precisely.
    var setFrameErrorsByHandle: [AXWindowHandle: [Error]] = [:]
    var minimumFitWidth: CGFloat?
    var frameRejector: ((CGRect) -> Bool)?
    var maximumFrameSizesByHandle: [AXWindowHandle: CGSize] = [:]
    private(set) var placedFramesByHandle: [AXWindowHandle: CGRect] = [:]
    var focusError: Error?
    var onFocus: ((AXWindowHandle, pid_t) -> Void)?
    var onRaise: ((AXWindowHandle) -> Void)?
    var focusCallCount = 0
    private(set) var focusRequests: [(handle: AXWindowHandle, pid: pid_t)] = []
    var raiseError: Error?
    private(set) var raisedHandles: [AXWindowHandle] = []
    var closeError: Error?
    private(set) var closedHandles: [AXWindowHandle] = []
    var quitApplicationError: Error?
    private(set) var quitApplicationPIDs: [pid_t] = []
    var setFrameHandles: [AXWindowHandle] = []
    private(set) var setFrameRequests: [(window: AXWindowHandle, frame: CGRect)] = []
    var hideError: Error?
    /// Applications that report themselves as hidden, as after a Command-H the
    /// user pressed themselves.
    var hiddenPIDs: Set<pid_t> = []
    /// Every hide and unhide Panoptos asked for, in order. Focus mode and
    /// application splits use this to record what they hid and gave back.
    private(set) var hideRequests: [(pid: pid_t, hidden: Bool)] = []

    /// The menu tree each application currently publishes. Tests change it to
    /// stand in for an application that rebuilt its menus mid-session.
    var menusByPID: [pid_t: [MenuNode]] = [:]
    private(set) var readMenuPIDs: [pid_t] = []

    func requestPermission() {}
    func readMenu(pid: pid_t) throws -> [MenuNode] {
        readMenuPIDs.append(pid)
        return menusByPID[pid] ?? []
    }
    func invoke(pid: pid_t, indexPath: [Int], focusing window: AXWindowHandle?) throws -> String { kAXPressAction as String }
    // An absent fixture means the application has no focused window, which the
    // real client reports as an AX error. Unwrapping it here instead would
    // charge a spurious failure to whichever test happens to be running when a
    // workspace notification drives a background refresh.
    func focusedWindowFrame(pid: pid_t) throws -> CGRect {
        guard let windowSnapshot else {
            throw AccessibilityClientError.attribute(kAXFocusedWindowAttribute as String, .noValue)
        }
        return windowSnapshot.frame
    }

    func focusedWindow(pid: pid_t) throws -> AXWindowHandle {
        if let focusedWindowError { throw focusedWindowError }
        guard let handle = focusedHandle ?? windowSnapshot?.handle else {
            throw AccessibilityClientError.attribute(kAXFocusedWindowAttribute as String, .noValue)
        }
        return handle
    }
    func windows(pid: pid_t) throws -> [AXWindowSnapshot] {
        windowsCallCount += 1
        // AccessibilityClient drops every window it cannot snapshot, so an
        // element that has gone invalid disappears from this list too.
        return (windowSnapshotsByPID[pid] ?? windowSnapshots ?? windowSnapshot.map { [$0] } ?? []).filter {
            snapshotError == nil && snapshotErrorsByHandle[$0.handle] == nil
        }
    }

    func windowHandles(pid: pid_t) throws -> [AXWindowHandle] {
        windowHandlesCallCount += 1
        windowHandlePIDs.append(pid)
        if let windowHandlesError { throw windowHandlesError }
        return listedWindowHandlesByPID[pid]
            ?? listedWindowHandles
            ?? windowSnapshotsByPID[pid]?.map(\.handle)
            ?? (windowSnapshots ?? windowSnapshot.map { [$0] } ?? []).map(\.handle)
    }
    func window(atAccessibilityPoint point: CGPoint) throws -> AXWindowSnapshot {
        guard let windowSnapshot else {
            throw AccessibilityClientError.unsupportedWindow("the pointer is not in a standard window")
        }
        return windowSnapshot
    }

    func snapshot(window: AXWindowHandle) throws -> AXWindowSnapshot {
        snapshotCallCount += 1
        if let error = snapshotErrorsByHandle[window] { throw error }
        if let snapshotError { throw snapshotError }
        guard let snapshot = windowSnapshotsByHandle[window] ?? windowSnapshot else {
            throw AccessibilityClientError.attribute(kAXRoleAttribute as String, .invalidUIElement)
        }
        return snapshot
    }

    func setFrame(_ frame: CGRect, of window: AXWindowHandle) throws {
        if let frameError { throw frameError }
        if var errors = setFrameErrorsByHandle[window], !errors.isEmpty {
            let error = errors.removeFirst()
            setFrameErrorsByHandle[window] = errors
            setFrameRequests.append((window, frame))
            throw error
        }
        if let minimumFitWidth, frame.width < minimumFitWidth {
            throw AccessibilityClientError.frameRejected
        }
        if frameRejector?(frame) == true {
            throw AccessibilityClientError.frameRejected
        }
        if let maximumSize = maximumFrameSizesByHandle[window] {
            let constrained = CGRect(
                origin: frame.origin,
                size: CGSize(
                    width: min(frame.width, maximumSize.width),
                    height: min(frame.height, maximumSize.height)
                )
            )
            guard let fitted = AccessibilityClient.fittedFrame(
                actualFrame: constrained,
                within: frame
            ) else { throw AccessibilityClientError.frameRejected }
            placedFramesByHandle[window] = fitted
            if let snapshot = windowSnapshotsByHandle[window] ?? windowSnapshot {
                let updated = AXWindowSnapshot(
                    handle: snapshot.handle,
                    pid: snapshot.pid,
                    accessibilityIdentifier: snapshot.accessibilityIdentifier,
                    title: snapshot.title,
                    frame: fitted,
                    isMinimized: snapshot.isMinimized,
                    isFullScreen: snapshot.isFullScreen,
                    isResizable: snapshot.isResizable
                )
                windowSnapshotsByHandle[window] = updated
                if windowSnapshot?.handle == window { windowSnapshot = updated }
                if let index = windowSnapshots?.firstIndex(where: { $0.handle == window }) {
                    windowSnapshots?[index] = updated
                }
            }
        } else {
            placedFramesByHandle[window] = frame
        }
        lastSetFrame = frame
        setFrameHandles.append(window)
        setFrameRequests.append((window, frame))
    }

    func isApplicationHidden(pid: pid_t) -> Bool { hiddenPIDs.contains(pid) }

    func setApplicationHidden(_ hidden: Bool, pid: pid_t) throws {
        if let hideError { throw hideError }
        hideRequests.append((pid, hidden))
        if hidden { hiddenPIDs.insert(pid) } else { hiddenPIDs.remove(pid) }
    }

    func close(window: AXWindowHandle) throws {
        if let closeError { throw closeError }
        closedHandles.append(window)
    }

    func quitApplication(pid: pid_t) throws {
        if let quitApplicationError { throw quitApplicationError }
        quitApplicationPIDs.append(pid)
    }

    func raise(window: AXWindowHandle) throws {
        if let raiseError { throw raiseError }
        onRaise?(window)
        raisedHandles.append(window)
    }

    func focus(window: AXWindowHandle, pid: pid_t) throws {
        focusCallCount += 1
        if let focusError { throw focusError }
        focusRequests.append((window, pid))
        onFocus?(window, pid)
        focusedHandle = window
    }
}
