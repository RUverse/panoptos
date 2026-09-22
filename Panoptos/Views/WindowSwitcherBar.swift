import AppKit
import SwiftUI

/// One draggable element of the window switcher. The strip groups windows by
/// application, so an application moves as a whole and a window only moves
/// among the windows of its own application: an interleaved order could not be
/// displayed by a grouped strip.
enum SectionBarDragItem: Hashable {
    case application(String)
    case applicationPair(ApplicationSplitPair)
    case window(UUID)
}

/// Stable identities understood by `ScrollViewReader`. A window gets its own
/// target whenever the strip renders a control for it; the application target
/// remains available for title modes that collapse a group to its icon.
enum SectionBarScrollTarget: Hashable {
    case application(String)
    case window(UUID)
}

enum SectionBarFocusedScrollTarget {
    static func resolve(
        section: LayoutSectionState,
        isSectionFocused: Bool,
        renderedWindowIDs: Set<UUID>
    ) -> SectionBarScrollTarget? {
        guard isSectionFocused,
              let activeWindowID = section.activeWindowID,
              let activeWindow = section.windows.first(where: { $0.id == activeWindowID }) else {
            return nil
        }
        if renderedWindowIDs.contains(activeWindowID) {
            return .window(activeWindowID)
        }
        return .application(activeWindow.bundleIdentifier)
    }
}

enum ApplicationSplitSeparatorState {
    static func showsIcon(isActive: Bool, isEligible: Bool, isHovered: Bool) -> Bool {
        isActive || (isEligible && isHovered)
    }

    /// A linked pair states itself with the glyph alone; the bordered button
    /// is an affordance for the click, so it belongs to the hover.
    static func showsChrome(isActive: Bool, isEligible: Bool, isHovered: Bool) -> Bool {
        isHovered && showsIcon(isActive: isActive, isEligible: isEligible, isHovered: isHovered)
    }
}

enum ApplicationSplitSeparatorLayout {
    static let collapsedWidth: CGFloat = 1
    static let hoverOutset: CGFloat = 2
    /// The gap on each side of a separator. With `collapsedWidth` this is the
    /// spacing the strip had before splits existed: the split control never
    /// widens the strip, it grows into that gap instead.
    static let applicationSpacing: CGFloat = 8
    /// Kept clear between the split button and each neighboring highlight box.
    static let buttonClearance: CGFloat = 1
    /// The glyph's margin inside the button's border.
    static let iconInset: CGFloat = 2

    /// Distance between two adjacent application buttons, which the strip's
    /// spacing fixes at every switcher size.
    static var gapWidth: CGFloat { 2 * applicationSpacing + collapsedWidth }

    static func expandedWidth(scale: Double) -> CGFloat {
        // Half a switcher button while that still fits the gap. The gap does
        // not scale, so past that the button stops growing and keeps its
        // clearance instead of running into the highlight boxes.
        min(
            WindowSwitcherMetrics(scale: scale).iconOnlyWidth / 2,
            gapWidth - 2 * buttonClearance
        )
    }

    /// How far the split control reaches past its one-point layout slot on
    /// each side. Negative padding turns this into growth inside the existing
    /// gap rather than into extra spacing.
    static func horizontalOverhang(scale: Double) -> CGFloat {
        max(0, (expandedWidth(scale: scale) - collapsedWidth) / 2)
    }

    /// A square button around the glyph, not a full-height one: the gap caps
    /// its side, and the strip's height is none of its business.
    static func buttonSide(scale: Double) -> CGFloat {
        expandedWidth(scale: scale)
    }

    static func iconPointSize(scale: Double) -> CGFloat {
        // Follows the switcher size until the button stops growing, then stays
        // inside its border.
        min(
            7.5 * WindowSwitcherMetrics(scale: scale).scale,
            buttonSide(scale: scale) - 2 * iconInset
        )
    }

    /// A third of the button's width reads as clearly rounded without rounding
    /// it into a capsule, and never out-rounds the switcher's own buttons.
    static func cornerRadius(scale: Double) -> CGFloat {
        min(WindowSwitcherMetrics(scale: scale).cornerRadius, expandedWidth(scale: scale) / 3)
    }

}

private struct SectionBarItemFramesKey: PreferenceKey {
    static var defaultValue: [SectionBarDragItem: CGRect] = [:]

    static func reduce(value: inout [SectionBarDragItem: CGRect], nextValue: () -> [SectionBarDragItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A reordering in progress. Positions are the ones recorded when the drag
/// started, and the strip keeps that layout underneath the dragged button
/// while a marker shows where it would land, so the drop position cannot
/// shift around under a pointer that is still moving.
struct SectionBarDrag {
    let item: SectionBarDragItem
    /// Display order of the items the dragged one can move among, itself
    /// included, as it was when the drag started.
    let siblings: [SectionBarDragItem]
    let frames: [SectionBarDragItem: CGRect]
    var translation: CGFloat = 0

    private static let markerGap: CGFloat = 4

    var others: [SectionBarDragItem] { siblings.filter { $0 != item } }

    var insertionIndex: Int {
        let center = (frames[item]?.midX ?? 0) + translation
        return others.filter { (frames[$0]?.midX ?? 0) < center }.count
    }

    var reorderedSiblings: [SectionBarDragItem] {
        var reordered = others
        reordered.insert(item, at: min(insertionIndex, reordered.count))
        return reordered
    }

    var movesAnything: Bool { reorderedSiblings != siblings }

    /// Middle of the gap the item would drop into, in the strip's own space.
    var markerX: CGFloat? {
        let others = self.others
        guard !others.isEmpty else { return nil }
        let index = insertionIndex
        if index <= 0 { return (frames[others[0]]?.minX ?? 0) - Self.markerGap }
        if index >= others.count { return (frames[others[others.count - 1]]?.maxX ?? 0) + Self.markerGap }
        return ((frames[others[index - 1]]?.maxX ?? 0) + (frames[others[index]]?.minX ?? 0)) / 2
    }
}

/// Bare unattached-application controls appended to the managed groups in the
/// switcher's horizontal content. They add scroll extent but never consume a
/// dedicated portion of the visible switcher viewport.
struct UnattachedWindowIconStrip: View {
    static let spacing: CGFloat = 7
    static let iconSpacing: CGFloat = 4

    @EnvironmentObject private var model: PanoptosModel
    @ObservedObject var presentation: SectionPresentation

    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            ForEach(presentation.unattachedGroups) { group in
                let count = group.windows.count
                let noun = count == 1 ? "window" : "windows"
                let help = "\(group.applicationName): \(count) unattached \(noun). Click to cycle. Double-click to attach to this section. Next: \(group.nextWindowTitle)"
                SectionStackButton(
                    icon: group.icon,
                    scale: model.windowSwitcherUIScale,
                    drawsSelectionBackground: false,
                    drawsHoverBackground: false,
                    dimsUntilHovered: true,
                    accessibilityLabel: help,
                    help: help,
                    activate: { model.cycleUnattachedWindows(in: group.id) },
                    doubleActivate: { model.attachUnattachedWindow(in: group.id) }
                )
                .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private extension View {
    /// Records where the item sits so a drag can place it among its siblings,
    /// and carries it under the pointer while it is the one being dragged. The
    /// dragged item keeps reporting the position it started from: the strip
    /// does not reflow during a drag, so every recorded position stays valid
    /// for as long as the drag lasts.
    func sectionBarDragItem(_ item: SectionBarDragItem, drag: SectionBarDrag?, in space: String) -> some View {
        let isDragged = drag?.item == item
        return offset(x: isDragged ? drag?.translation ?? 0 : 0)
            .opacity(isDragged ? 0.85 : 1)
            .zIndex(isDragged ? 1 : 0)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SectionBarItemFramesKey.self,
                        value: [item: isDragged
                            ? drag?.frames[item] ?? geometry.frame(in: .named(space))
                            : geometry.frame(in: .named(space))]
                    )
                }
            }
    }
}

struct SectionWindowBar: View {
    @EnvironmentObject private var model: PanoptosModel
    @ObservedObject var presentation: SectionPresentation
    @State private var itemFrames: [SectionBarDragItem: CGRect] = [:]
    @State private var drag: SectionBarDrag?

    private static let stripSpace = "SectionWindowBarStrip"
    private static let focusModeIcon = NSImage(named: "SectionFocusIcon")

    private var metrics: WindowSwitcherMetrics {
        WindowSwitcherMetrics(scale: model.windowSwitcherUIScale)
    }

    private var groups: [(String, [ManagedWindow])] {
        SwitcherOrder.groups(
            presentation.section.visibleWindows,
            bundleIdentifier: \ManagedWindow.bundleIdentifier
        ).map { ($0.bundleIdentifier, $0.elements) }
    }

    /// Every window the strip draws, in strip order. A window arriving,
    /// leaving, or going off screen changes it.
    private var renderedWindowOrder: [UUID] {
        groups.flatMap { $0.1.map(\.id) }
    }

    private var windowsByApplication: [String: [ManagedWindow]] {
        Dictionary(uniqueKeysWithValues: groups)
    }

    private var applicationUnits: [SwitcherApplicationUnit] {
        SwitcherApplicationUnit.make(
            bundleOrder: groups.map(\.0),
            pairs: model.applicationSplitPairs[presentation.sectionID] ?? []
        )
    }

    private var focusedScrollTarget: SectionBarScrollTarget? {
        SectionBarFocusedScrollTarget.resolve(
            section: presentation.section,
            isSectionFocused: presentation.isFocused,
            renderedWindowIDs: renderedWindowIDs
        )
    }

    /// Observe the presentation focus itself rather than the rendered target.
    /// A collapsed same-application group has one scroll target for several
    /// windows, but every real focus transition must still request a reveal.
    private var focusedWindowIDForReveal: UUID? {
        guard presentation.isFocused else { return nil }
        return presentation.section.activeWindowID
    }

    private var renderedWindowIDs: Set<UUID> {
        Set(groups.flatMap { _, windows -> [UUID] in
            let rendersIndividualWindows = windows.count == 1
                || model.windowSwitcherTitleMode.showsTitles(applicationWindowCount: windows.count)
            return rendersIndividualWindows ? windows.map(\.id) : []
        })
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: UnattachedWindowIconStrip.spacing) {
                        strip
                            .padding(.horizontal, metrics.outerBarPadding)
                            .frame(
                                // A spanned section's switcher sits between
                                // the switchers of the sections it covers and
                                // keeps its content width; filling would push
                                // them off the strip.
                                minWidth: model.sectionBarsFillAvailableWidth
                                    && !presentation.section.isSpanned
                                    ? geometry.size.width
                                    : nil,
                                minHeight: geometry.size.height,
                                alignment: model.sectionBarsCentered ? .center : .leading
                            )
                            .sectionChrome()
                        if !presentation.unattachedGroups.isEmpty {
                            UnattachedWindowIconStrip(presentation: presentation)
                                .padding(.trailing, metrics.outerBarPadding)
                        }
                        if model.isFocusModeActive(for: presentation.sectionID) {
                            leaveFocusModeButton
                                .padding(.trailing, metrics.outerBarPadding)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .reportSectionBarContentWidth { width in
                        if presentation.bottomContentWidth != width { presentation.bottomContentWidth = width }
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: model.sectionBarsCentered ? .center : .leading
                    )
                }
                .onAppear { revealFocusedTarget(using: proxy) }
                .onChange(of: focusedWindowIDForReveal) { _, focusedWindowID in
                    guard focusedWindowID != nil else { return }
                    revealFocusedTarget(using: proxy)
                }
            }
        }
    }

    private var leaveFocusModeButton: some View {
        let shortcut = model.shortcut(for: .toggleSectionFocus).map { " (\($0.displayText))" } ?? ""
        return SectionStackButton(
            icon: Self.focusModeIcon,
            scale: model.windowSwitcherUIScale,
            drawsSelectionBackground: false,
            drawsHoverBackground: false,
            dimsUntilHovered: true,
            accessibilityLabel: "Leave Section Focus",
            help: "Focus mode is on. Leave Section Focus" + shortcut,
            activate: {
                guard model.isFocusModeActive(for: presentation.sectionID) else { return }
                model.toggleFocusMode(for: presentation.sectionID)
            }
        )
        .fixedSize()
    }

    private func revealFocusedTarget(using proxy: ScrollViewProxy) {
        guard let target = focusedScrollTarget else { return }
        // Presentation updates arrive in the same turn as the SwiftUI layout
        // change. Waiting one turn gives the reader the target's current
        // frame. With no explicit anchor, SwiftUI performs only the movement
        // needed to make an off-screen target visible and leaves an
        // already-visible control exactly where it is. Unrelated later layout
        // changes intentionally do not issue another request, preserving the
        // user's manual scroll position.
        DispatchQueue.main.async {
            proxy.scrollTo(target)
        }
    }

    private var strip: some View {
        HStack(spacing: ApplicationSplitSeparatorLayout.applicationSpacing) {
            ForEach(Array(applicationUnits.enumerated()), id: \.element) { index, unit in
                applicationUnit(unit)
                if index < applicationUnits.count - 1 {
                    separator(between: unit, and: applicationUnits[index + 1])
                }
            }
        }
        .coordinateSpace(name: Self.stripSpace)
        .onPreferenceChange(SectionBarItemFramesKey.self) { frames in
            itemFrames = frames
        }
        // The positions a drag recorded describe a strip that no longer exists
        // once a window arrives or leaves, so a drag still in flight is
        // abandoned rather than dropped somewhere arbitrary.
        .onChange(of: renderedWindowOrder) { _, _ in drag = nil }
        .overlay(alignment: .topLeading) { insertionMarker }
    }

    @ViewBuilder
    private func applicationUnit(_ unit: SwitcherApplicationUnit) -> some View {
        switch unit {
        case .application(let bundleIdentifier):
            let item = SectionBarDragItem.application(bundleIdentifier)
            if let windows = windowsByApplication[bundleIdentifier] {
                applicationGroup(
                    bundleIdentifier: bundleIdentifier,
                    windows: windows,
                    applicationDragItem: item
                )
                .id(SectionBarScrollTarget.application(bundleIdentifier))
                .sectionBarDragItem(item, drag: drag, in: Self.stripSpace)
            }
        case .pair(let pair):
            let item = SectionBarDragItem.applicationPair(pair)
            HStack(spacing: ApplicationSplitSeparatorLayout.applicationSpacing) {
                if let windows = windowsByApplication[pair.firstBundleIdentifier] {
                    applicationGroup(
                        bundleIdentifier: pair.firstBundleIdentifier,
                        windows: windows,
                        applicationDragItem: item
                    )
                    .id(SectionBarScrollTarget.application(pair.firstBundleIdentifier))
                }
                ApplicationSplitSeparator(
                    axis: model.applicationSplitAxis(inSection: presentation.sectionID) ?? .horizontal,
                    scale: model.windowSwitcherUIScale,
                    isActive: true,
                    isEligible: true,
                    firstApplicationName: applicationName(for: pair.firstBundleIdentifier),
                    secondApplicationName: applicationName(for: pair.secondBundleIdentifier),
                    activate: {
                        model.toggleApplicationSplit(
                            first: pair.firstBundleIdentifier,
                            second: pair.secondBundleIdentifier,
                            inSection: presentation.sectionID
                        )
                    }
                )
                if let windows = windowsByApplication[pair.secondBundleIdentifier] {
                    applicationGroup(
                        bundleIdentifier: pair.secondBundleIdentifier,
                        windows: windows,
                        applicationDragItem: item
                    )
                    .id(SectionBarScrollTarget.application(pair.secondBundleIdentifier))
                }
            }
            .sectionBarDragItem(item, drag: drag, in: Self.stripSpace)
        }
    }

    @ViewBuilder
    private func separator(
        between first: SwitcherApplicationUnit,
        and second: SwitcherApplicationUnit
    ) -> some View {
        if case .application(let firstBundleIdentifier) = first,
           case .application(let secondBundleIdentifier) = second {
            ApplicationSplitSeparator(
                axis: model.applicationSplitAxis(inSection: presentation.sectionID) ?? .horizontal,
                scale: model.windowSwitcherUIScale,
                isActive: false,
                isEligible: model.canPairApplications(
                    firstBundleIdentifier,
                    secondBundleIdentifier,
                    inSection: presentation.sectionID
                ),
                firstApplicationName: applicationName(for: firstBundleIdentifier),
                secondApplicationName: applicationName(for: secondBundleIdentifier),
                activate: {
                    model.toggleApplicationSplit(
                        first: firstBundleIdentifier,
                        second: secondBundleIdentifier,
                        inSection: presentation.sectionID
                    )
                }
            )
        } else {
            Divider().frame(height: metrics.separatorHeight)
        }
    }

    private func applicationName(for bundleIdentifier: String) -> String {
        windowsByApplication[bundleIdentifier]?.first?.applicationName ?? bundleIdentifier
    }

    @ViewBuilder
    private func applicationGroup(
        bundleIdentifier: String,
        windows: [ManagedWindow],
        applicationDragItem: SectionBarDragItem
    ) -> some View {
        let applicationWindowCount = model.managedWindowCount(bundleIdentifier: bundleIdentifier)
        if windows.count == 1, let window = windows.first {
            let showsTitle = model.windowSwitcherTitleMode.showsTitles(
                applicationWindowCount: applicationWindowCount
            )
            let displayedTitle = showsTitle
                ? WindowTitleFormatter.display(
                    window.title,
                    limitCharacters: model.limitWindowSwitcherTitleCharacters
                )
                : nil
            SectionStackButton(
                title: displayedTitle,
                icon: window.icon,
                scale: model.windowSwitcherUIScale,
                selection: WindowSwitcherSelection.resolve(
                    windowID: window.id,
                    section: presentation.section,
                    isSectionFocused: presentation.isFocused
                ),
                accessibilityLabel: window.title.isEmpty
                    ? window.applicationName
                    : "\(window.applicationName), \(window.title)",
                help: window.title.isEmpty ? window.applicationName : window.title,
                activate: { model.focus(windowID: window.id) },
                detach: { model.detach(windowID: window.id) },
                sectionFocusTitle: sectionFocusTitle,
                sectionFocusShortcut: model.shortcut(for: .toggleSectionFocus),
                toggleSectionFocus: { model.toggleFocusMode(for: presentation.sectionID) },
                close: { model.close(windowID: window.id) },
                quitApplicationTitle: quitApplicationTitle(for: window),
                quitApplication: quitApplicationAction(for: window),
                reorder: reorderHandlers(for: applicationDragItem, siblings: { applicationItems })
            )
            .fixedSize()
            .id(SectionBarScrollTarget.window(window.id))
        } else {
            HStack(spacing: 3) {
                // The application's icon drags its whole group; each of its
                // window buttons drags only within the group.
                SectionStackButton(
                    icon: windows[0].icon,
                    scale: model.windowSwitcherUIScale,
                    accessibilityLabel: windows[0].applicationName,
                    help: windows[0].applicationName,
                    activate: {
                        model.focusMostRecentWindow(bundleIdentifier: bundleIdentifier, in: presentation.sectionID)
                    },
                    sectionFocusTitle: sectionFocusTitle,
                    sectionFocusShortcut: model.shortcut(for: .toggleSectionFocus),
                    toggleSectionFocus: { model.toggleFocusMode(for: presentation.sectionID) },
                    quitApplicationTitle: quitApplicationTitle(for: windows[0]),
                    quitApplication: quitApplicationAction(for: windows[0]),
                    reorder: reorderHandlers(for: applicationDragItem, siblings: { applicationItems })
                )
                .fixedSize()
                if model.windowSwitcherTitleMode.showsTitles(applicationWindowCount: windows.count) {
                    ForEach(windows) { window in
                        SectionStackButton(
                            title: WindowTitleFormatter.display(
                                window.title,
                                limitCharacters: model.limitWindowSwitcherTitleCharacters
                            ),
                            scale: model.windowSwitcherUIScale,
                            selection: WindowSwitcherSelection.resolve(
                                windowID: window.id,
                                section: presentation.section,
                                isSectionFocused: presentation.isFocused
                            ),
                            accessibilityLabel: window.title,
                            help: window.title,
                            activate: { model.focus(windowID: window.id) },
                            detach: { model.detach(windowID: window.id) },
                            sectionFocusTitle: sectionFocusTitle,
                            sectionFocusShortcut: model.shortcut(for: .toggleSectionFocus),
                            toggleSectionFocus: { model.toggleFocusMode(for: presentation.sectionID) },
                            close: { model.close(windowID: window.id) },
                            quitApplicationTitle: quitApplicationTitle(for: window),
                            quitApplication: quitApplicationAction(for: window),
                            reorder: reorderHandlers(
                                for: .window(window.id),
                                siblings: { windowItems(ofApplication: bundleIdentifier) }
                            )
                        )
                        .fixedSize()
                        .id(SectionBarScrollTarget.window(window.id))
                        .sectionBarDragItem(.window(window.id), drag: drag, in: Self.stripSpace)
                    }
                }
            }
        }
    }

    private var sectionFocusTitle: String {
        model.isFocusModeActive(for: presentation.sectionID) ? "Leave Section Focus" : "Focus Section"
    }

    private func quitApplicationTitle(for window: ManagedWindow) -> String? {
        model.canQuitApplication(pid: window.pid) ? "Quit \(window.applicationName)" : nil
    }

    private func quitApplicationAction(for window: ManagedWindow) -> (() -> Void)? {
        guard model.canQuitApplication(pid: window.pid) else { return nil }
        return { model.quitApplication(windowID: window.id) }
    }

    @ViewBuilder
    private var insertionMarker: some View {
        if let drag, drag.movesAnything, let x = drag.markerX {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 5)
                .offset(x: x - 1)
        }
    }

    private var applicationItems: [SectionBarDragItem] {
        applicationUnits.map { unit in
            switch unit {
            case .application(let bundleIdentifier): .application(bundleIdentifier)
            case .pair(let pair): .applicationPair(pair)
            }
        }
    }

    private func windowItems(ofApplication bundleIdentifier: String) -> [SectionBarDragItem] {
        guard let group = groups.first(where: { $0.0 == bundleIdentifier }) else { return [] }
        return group.1.map { SectionBarDragItem.window($0.id) }
    }

    /// The siblings are read when the drag starts rather than captured here, so
    /// a strip that changed since the button was rendered still reorders the
    /// windows it currently shows.
    private func reorderHandlers(
        for item: SectionBarDragItem,
        siblings: @escaping () -> [SectionBarDragItem]
    ) -> SectionBarReorderHandlers {
        SectionBarReorderHandlers(
            began: {
                let frames = itemFrames
                // Without a recorded position for the button there is nothing
                // to measure a drop against, and a drag computed from a
                // missing frame would land somewhere arbitrary.
                guard frames[item] != nil else { return }
                drag = SectionBarDrag(item: item, siblings: siblings(), frames: frames)
            },
            changed: { translation in drag?.translation = translation },
            ended: {
                commitDrag()
            }
        )
    }

    private func commitDrag() {
        guard let drag else { return }
        self.drag = nil
        guard drag.movesAnything else { return }
        let groups = self.groups
        var ordered: [UUID] = []
        switch drag.item {
        case .application, .applicationPair:
            let windowsByApplication = self.windowsByApplication
            for sibling in drag.reorderedSiblings {
                let bundleIdentifiers: [String]
                switch sibling {
                case .application(let bundleIdentifier):
                    bundleIdentifiers = [bundleIdentifier]
                case .applicationPair(let pair):
                    bundleIdentifiers = pair.bundleIdentifiers
                case .window:
                    return
                }
                for bundleIdentifier in bundleIdentifiers {
                    guard let windows = windowsByApplication[bundleIdentifier] else { return }
                    ordered.append(contentsOf: windows.map(\.id))
                }
            }
        case let .window(windowID):
            guard let group = groups.first(where: { $0.1.contains { $0.id == windowID } }) else { return }
            let reordered = drag.reorderedSiblings.compactMap { sibling -> UUID? in
                guard case let .window(id) = sibling else { return nil }
                return id
            }
            guard reordered.count == group.1.count else { return }
            for (bundleIdentifier, windows) in groups {
                ordered.append(contentsOf: bundleIdentifier == group.0 ? reordered : windows.map(\.id))
            }
        }
        // The strip only drew the on-screen windows; the rest stay attached
        // beside their application. A window that came or went mid-drag
        // leaves a list the model refuses, rather than one that would drop it
        // from the section.
        model.reorderWindows(
            in: presentation.sectionID,
            to: SwitcherOrder.completing(
                ordered,
                with: presentation.section.windows,
                bundleIdentifier: \.bundleIdentifier
            )
        )
        // The strip renders the section the panel controller last published,
        // and that only happens on the coordinator's next reconciliation. Take
        // the committed order from the model now so the buttons land where
        // they were dropped instead of a beat later.
        if let committed = model.sections[presentation.sectionID], presentation.section != committed {
            presentation.section = committed
        }
    }
}

private struct ApplicationSplitSeparator: View {
    let axis: SplitAxis
    let scale: Double
    let isActive: Bool
    let isEligible: Bool
    let firstApplicationName: String
    let secondApplicationName: String
    let activate: () -> Void
    @State private var isHovered = false

    var body: some View {
        ApplicationSplitSeparatorControl(
            axis: axis,
            scale: scale,
            isActive: isActive,
            isEligible: isEligible,
            firstApplicationName: firstApplicationName,
            secondApplicationName: secondApplicationName,
            isHovered: $isHovered,
            activate: activate
        )
        .frame(
            width: ApplicationSplitSeparatorLayout.buttonSide(scale: scale),
            height: WindowSwitcherMetrics(scale: scale).buttonHeight
        )
        // The control draws at its full width but only claims a divider's
        // worth of layout, so a revealed split button fills the gap that was
        // already between the two applications instead of pushing the strip
        // apart. The slot itself never changes width, so revealing the action
        // cannot reflow the strip or move a centered switcher under the
        // pointer.
        .padding(.horizontal, -ApplicationSplitSeparatorLayout.horizontalOverhang(scale: scale))
        .zIndex(1)
    }
}

private struct ApplicationSplitSeparatorControl: NSViewRepresentable {
    let axis: SplitAxis
    let scale: Double
    let isActive: Bool
    let isEligible: Bool
    let firstApplicationName: String
    let secondApplicationName: String
    @Binding var isHovered: Bool
    let activate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(activate: activate, isHovered: $isHovered)
    }

    func makeNSView(context: Context) -> ApplicationSplitSeparatorButton {
        let button = ApplicationSplitSeparatorButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.activateButton)
        button.onHoverChanged = { [weak coordinator = context.coordinator] hovered in
            coordinator?.isHovered.wrappedValue = hovered
        }
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ApplicationSplitSeparatorButton, context: Context) {
        context.coordinator.activate = activate
        context.coordinator.isHovered = $isHovered
        let metrics = WindowSwitcherMetrics(scale: scale)
        let description = isActive
            ? "Unpair \(firstApplicationName) and \(secondApplicationName)"
            : splitDescription
        button.preferredSize = NSSize(
            width: ApplicationSplitSeparatorLayout.buttonSide(scale: scale),
            height: metrics.buttonHeight
        )
        button.hoverOutset = ApplicationSplitSeparatorLayout.hoverOutset
        button.chromeCornerRadius = ApplicationSplitSeparatorLayout.cornerRadius(scale: scale)
        button.separatorHeight = metrics.separatorHeight
        button.splitIsActive = isActive
        button.splitIsEligible = isEligible
        button.isEnabled = isActive || isEligible
        button.tooltipText = description
        button.setAccessibilityElement(isActive || isEligible)
        button.setAccessibilityLabel(description)
        button.splitImage = NSImage(systemSymbolName: axis.systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: ApplicationSplitSeparatorLayout.iconPointSize(scale: scale),
                weight: .regular
            ))
        button.invalidateIntrinsicContentSize()
        button.needsLayout = true
    }

    private var splitDescription: String {
        axis == .vertical
            ? "Split \(firstApplicationName) and \(secondApplicationName) top and bottom"
            : "Split \(firstApplicationName) and \(secondApplicationName) side by side"
    }

    @MainActor
    final class Coordinator: NSObject {
        var activate: () -> Void
        var isHovered: Binding<Bool>

        init(activate: @escaping () -> Void, isHovered: Binding<Bool>) {
            self.activate = activate
            self.isHovered = isHovered
        }

        @objc func activateButton() {
            OverlayTooltipController.shared.cancel()
            activate()
        }
    }
}

/// The bars remain nonactivating while another application is frontmost, so a
/// SwiftUI hover callback is not strong enough here. This control owns an
/// `.activeAlways` tracking area and is also found by FirstMouseHostingView's
/// geometric first-click routing.
private final class ApplicationSplitSeparatorButton: NSButton, FirstMouseInteractionRegion {
    var preferredSize = NSSize(width: 27, height: 27)
    var separatorHeight: CGFloat = 12 {
        didSet {
            guard separatorHeight != oldValue else { return }
            needsLayout = true
        }
    }
    var hoverOutset: CGFloat = 2
    var chromeCornerRadius: CGFloat = 5 {
        didSet { chromeView.cornerRadius = chromeCornerRadius }
    }
    var splitIsActive = false {
        didSet { updateVisualState() }
    }
    var splitIsEligible = false {
        didSet { updateVisualState() }
    }
    var splitImage: NSImage? {
        didSet { splitImageView.image = splitImage }
    }
    var tooltipText = ""
    var onHoverChanged: ((Bool) -> Void)?
    private let splitImageView = NSImageView(frame: .zero)
    private let chromeView = ApplicationSplitChromeView()
    private let dividerView = ApplicationSplitDividerView()
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    private var showsIcon: Bool {
        ApplicationSplitSeparatorState.showsIcon(
            isActive: splitIsActive,
            isEligible: splitIsEligible,
            isHovered: isHovered
        )
    }

    private var showsChrome: Bool {
        ApplicationSplitSeparatorState.showsChrome(
            isActive: splitIsActive,
            isEligible: splitIsEligible,
            isHovered: isHovered
        )
    }

    override var intrinsicContentSize: NSSize { preferredSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, containsInteractionPoint(point) else { return nil }
        return self
    }

    func containsInteractionPoint(_ point: NSPoint) -> Bool {
        showsIcon && chromeRect.contains(point)
    }

    override func layout() {
        super.layout()
        chromeView.frame = chromeRect
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = 1 / max(1, scale)
        dividerView.frame = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - separatorHeight / 2,
            width: width,
            height: separatorHeight
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }

    private func replaceHoverTrackingArea() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            // An inactive separator only reveals its button when the pointer
            // is on the divider itself, plus a two-point allowance on either
            // side. Once visible, the square button remains hoverable.
            rect: showsIcon ? chromeRect : dividerHoverRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area

        // Replacing a tracking area during layout does not guarantee an exit
        // callback for the old area. Verify an existing hover on the next turn
        // so stale split controls cannot remain visible.
        if isHovered {
            DispatchQueue.main.async { [weak self] in
                self?.clearHoverIfPointerIsOutside()
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard splitIsActive || splitIsEligible else { return }
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setHovered(false)
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        imagePosition = .noImage
        // The cell draws for real now that this view has no draw(_:) override,
        // and NSButton's stock title would appear between the applications.
        title = ""
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        // Both pieces of chrome are layer-backed subviews rather than draw(_:)
        // content: on macOS 26 a drawRect-backed layer inside a SwiftUI-hosted
        // view composites horizontally squeezed. See ShortcutPillView.
        chromeView.isHidden = true
        addSubview(chromeView)
        addSubview(dividerView)

        // NSButtonCell gives tiny borderless symbols a leading bias. A
        // centered image view keeps the split glyph geometrically centered in
        // the space between its neighboring application buttons.
        splitImageView.translatesAutoresizingMaskIntoConstraints = false
        splitImageView.imageAlignment = .alignCenter
        splitImageView.imageScaling = .scaleProportionallyDown
        splitImageView.contentTintColor = .secondaryLabelColor
        splitImageView.isHidden = true
        addSubview(splitImageView)
        NSLayoutConstraint.activate([
            splitImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            splitImageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func updateVisualState() {
        splitImageView.isHidden = !showsIcon
        chromeView.isHidden = !showsChrome
        dividerView.isHidden = showsIcon
        needsLayout = true
        replaceHoverTrackingArea()
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        onHoverChanged?(hovered)
        updateVisualState()
        if hovered {
            OverlayTooltipController.shared.show(tooltipText, from: self)
        } else {
            OverlayTooltipController.shared.cancel(from: self)
        }
    }

    /// The visible button: a square around the glyph, centered in a control
    /// that is as tall as the strip's buttons.
    private var chromeRect: NSRect {
        let side = min(bounds.width, bounds.height)
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private var dividerHoverRect: NSRect {
        NSRect(
            x: bounds.midX - ApplicationSplitSeparatorLayout.collapsedWidth / 2 - hoverOutset,
            y: bounds.minY,
            width: ApplicationSplitSeparatorLayout.collapsedWidth + 2 * hoverOutset,
            height: bounds.height
        )
    }

    private func clearHoverIfPointerIsOutside() {
        guard isHovered, let window else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let trackingRect = showsIcon ? chromeRect : dividerHoverRect
        if !trackingRect.contains(pointer) {
            setHovered(false)
        }
    }
}

/// Never takes the click: the button owns the whole interaction, and its
/// geometric first-click routing looks for the enclosing NSControl.
private class ApplicationSplitChromeLayerView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
}

private final class ApplicationSplitChromeView: ApplicationSplitChromeLayerView {
    var cornerRadius: CGFloat = 5 {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsDisplay = true
        }
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer.borderColor = NSColor.separatorColor.cgColor
    }
}

private final class ApplicationSplitDividerView: ApplicationSplitChromeLayerView {
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

extension View {
    func sectionChrome() -> some View {
        background(ActiveMaterialBackground())
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 0.5) }
    }

    // Panels are nonactivating, so AppKit would otherwise render materials,
    // vibrant text, and accent colors in the inactive-window style except on
    // whichever panel last became key, making the bars look inconsistent.
    @ViewBuilder
    func alwaysActiveAppearance() -> some View {
        if #available(macOS 15.0, *) {
            environment(\.appearsActive, true)
        } else {
            environment(\.controlActiveState, .key)
        }
    }
}

private struct ActiveMaterialBackground: NSViewRepresentable {
    private static let cornerMask: NSImage = {
        let radius: CGFloat = 8
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.cornerMask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
