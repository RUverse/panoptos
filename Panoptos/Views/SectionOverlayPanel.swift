import AppKit
import SwiftUI

@MainActor
final class SectionPresentation: ObservableObject {
    let sectionID: UUID
    @Published var section: LayoutSectionState
    @Published var isFocused = true
    @Published var unattachedGroups: [UnattachedWindowApplicationGroup] = []
    @Published var topContentWidth: CGFloat = 0 {
        didSet {
            if topContentWidth != oldValue { onContentWidthChanged?() }
        }
    }
    @Published var bottomContentWidth: CGFloat = 0 {
        didSet {
            if bottomContentWidth != oldValue { onContentWidthChanged?() }
        }
    }
    var onContentWidthChanged: (() -> Void)?

    init(sectionID: UUID, section: LayoutSectionState) {
        self.sectionID = sectionID
        self.section = section
    }
}

@MainActor
final class SectionPanelController {
    private let topPanel: NSPanel
    private let bottomPanel: NSPanel
    private let presentation: SectionPresentation
    private var showsMenuBar = true
    private var placement: SectionBarPlacement?
    private var isPlacementScheduled = false
    /// Fired when either bar reports a new content width. A spanned switcher's
    /// width decides how much room the switchers beside it have, so the
    /// coordinator lays the whole strip out again.
    var onContentWidthChanged: (() -> Void)?

    var switcherContentWidth: CGFloat { presentation.bottomContentWidth }

    init(sectionID: UUID, section: LayoutSectionState, model: PanoptosModel) {
        presentation = SectionPresentation(sectionID: sectionID, section: section)
        topPanel = Self.panel()
        bottomPanel = Self.panel()
        let prepareFocusActiveWindow: () -> (() -> Void)? = { [weak presentation, weak model] in
            guard let presentation, let model, presentation.isFocused == false,
                  let intendedWindowID = presentation.section.activeWindow?.id else { return nil }
            let focusedWindowIDBeforeClick = model.focusedManagedWindowID
            return { [weak presentation, weak model] in
                guard let presentation, let model, presentation.isFocused == false,
                      model.focusedManagedWindowID == focusedWindowIDBeforeClick,
                      presentation.section.activeWindow?.id == intendedWindowID else { return }
                model.focus(windowID: intendedWindowID)
            }
        }
        let topView = FirstMouseHostingView(rootView: AnyView(SectionMenuBar(presentation: presentation).environmentObject(model).alwaysActiveAppearance()))
        let bottomView = FirstMouseHostingView(rootView: AnyView(SectionWindowBar(presentation: presentation).environmentObject(model).alwaysActiveAppearance()))
        topView.prepareBackgroundClick = prepareFocusActiveWindow
        bottomView.prepareBackgroundClick = prepareFocusActiveWindow
        topPanel.contentView = topView
        bottomPanel.contentView = bottomView
        presentation.onContentWidthChanged = { [weak self] in
            self?.schedulePlacement()
            self?.onContentWidthChanged?()
        }
    }

    func update(
        section: LayoutSectionState,
        isFocused: Bool,
        showsMenuBar: Bool,
        unattachedGroups: [UnattachedWindowApplicationGroup]
    ) {
        // Publishing an unchanged section re-renders both bars (and rebuilds
        // their menu controls) on every idle reconciliation.
        if presentation.section != section { presentation.section = section }
        if presentation.isFocused != isFocused { presentation.isFocused = isFocused }
        if presentation.unattachedGroups != unattachedGroups {
            presentation.unattachedGroups = unattachedGroups
        }
        self.showsMenuBar = showsMenuBar
    }

    func position(_ placement: SectionBarPlacement) {
        self.placement = placement
        applyPlacement()
    }

    private func applyPlacement() {
        guard let placement else { return }
        let frames = SectionBarLayout.frames(
            placement: placement,
            topContentWidth: presentation.topContentWidth,
            bottomContentWidth: presentation.bottomContentWidth
        )
        if showsMenuBar, topPanel.frame != frames.top { topPanel.setFrame(frames.top, display: true) }
        if bottomPanel.frame != frames.bottom { bottomPanel.setFrame(frames.bottom, display: true) }
    }

    private func schedulePlacement() {
        guard !isPlacementScheduled else { return }
        isPlacementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlacementScheduled = false
            self.applyPlacement()
        }
    }

    func ensureVisible() {
        if showsMenuBar {
            if !topPanel.isVisible { topPanel.orderFrontRegardless() }
        } else if topPanel.isVisible {
            topPanel.orderOut(nil)
        }
        if !bottomPanel.isVisible { bottomPanel.orderFrontRegardless() }
    }

    func orderOut() {
        topPanel.orderOut(nil)
        bottomPanel.orderOut(nil)
    }

    func close() {
        topPanel.close()
        bottomPanel.close()
    }

    private static func panel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

/// Where a tool tip sits relative to the control it describes: under it, or
/// above it when the screen runs out underneath — the bottom bar's buttons sit
/// on the screen's lower edge.
enum OverlayTooltipLayout {
    static let spacing: CGFloat = 5

    static func frame(size: CGSize, anchor: CGRect, screen: CGRect) -> CGRect {
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - spacing - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + spacing }
        origin.y = max(screen.minY, min(origin.y, screen.maxY - size.height))
        origin.x = max(screen.minX, min(origin.x, screen.maxX - size.width))
        return CGRect(origin: origin, size: size).integral
    }
}

struct SectionBarFrames: Equatable {
    let top: CGRect
    let bottom: CGRect
}

/// Where a section's two bars may sit. The menu bar uses the section's own
/// frame. The switcher gets a strip of its own because a spanned section's
/// switcher sits between the switchers of the sections it covers, and those
/// give way to it: their strips shrink around it, while it is centered on an
/// anchor and keeps its content width.
struct SectionBarPlacement: Equatable {
    var frame: CGRect
    var switcherStrip: CGRect
    /// Set for a spanned section: its switcher is centered on this x within
    /// the strip and never fills the strip.
    var switcherAnchorX: CGFloat?
    var fillsAvailableWidth: Bool
    var centersBars: Bool
    var bottomHeight: CGFloat
}

enum SectionBarLayout {
    static func frames(
        in sectionFrame: CGRect,
        fillsAvailableWidth: Bool,
        centersBars: Bool,
        topContentWidth: CGFloat,
        bottomContentWidth: CGFloat,
        bottomHeight: CGFloat = PanoptosModel.chromeHeight
    ) -> SectionBarFrames {
        frames(
            placement: SectionBarPlacement(
                frame: sectionFrame,
                switcherStrip: SwitcherStripLayout.strip(of: sectionFrame, height: bottomHeight),
                switcherAnchorX: nil,
                fillsAvailableWidth: fillsAvailableWidth,
                centersBars: centersBars,
                bottomHeight: bottomHeight
            ),
            topContentWidth: topContentWidth,
            bottomContentWidth: bottomContentWidth
        )
    }

    static func frames(
        placement: SectionBarPlacement,
        topContentWidth: CGFloat,
        bottomContentWidth: CGFloat
    ) -> SectionBarFrames {
        let topHeight = PanoptosModel.chromeHeight
        let topWidth = width(
            available: placement.frame.width,
            content: topContentWidth,
            fillsAvailableWidth: placement.fillsAvailableWidth
        )
        let strip = placement.switcherStrip
        let bottom: CGRect
        if let anchorX = placement.switcherAnchorX {
            // A spanned switcher keeps its content width. Until that has been
            // measured it gets a sliver rather than the whole strip, so nothing
            // shows up over its neighbours before it can be placed.
            let bottomWidth = bottomContentWidth > 0 ? min(strip.width, bottomContentWidth) : 1
            let originX = min(max(anchorX - bottomWidth / 2, strip.minX), strip.maxX - bottomWidth)
            bottom = CGRect(x: originX, y: strip.minY, width: bottomWidth, height: placement.bottomHeight)
        } else {
            let bottomWidth = width(
                available: strip.width,
                content: bottomContentWidth,
                fillsAvailableWidth: placement.fillsAvailableWidth
            )
            bottom = CGRect(
                x: originX(in: strip, barWidth: bottomWidth, centersBars: placement.centersBars),
                y: strip.minY,
                width: bottomWidth,
                height: placement.bottomHeight
            )
        }
        return SectionBarFrames(
            top: CGRect(
                x: originX(in: placement.frame, barWidth: topWidth, centersBars: placement.centersBars),
                y: placement.frame.maxY - topHeight,
                width: topWidth,
                height: topHeight
            ).integral,
            bottom: bottom.integral
        )
    }

    private static func width(
        available: CGFloat,
        content: CGFloat,
        fillsAvailableWidth: Bool
    ) -> CGFloat {
        let available = max(0, available)
        guard !fillsAvailableWidth, content > 0 else { return available }
        return min(available, content)
    }

    private static func originX(in sectionFrame: CGRect, barWidth: CGFloat, centersBars: Bool) -> CGFloat {
        centersBars ? sectionFrame.midX - barWidth / 2 : sectionFrame.minX
    }
}

/// The bottom strip a spanned section shares with the sections it covers.
/// Every switcher stays on screen — switching with the mouse must always be
/// possible — so the spanned switcher is centered on the boundary between two
/// covered sections, the boundary nearest the middle of the span, and the
/// covered sections' switchers give way to it.
enum SwitcherStripLayout {
    struct Placement: Equatable {
        var strip: CGRect
        var anchorX: CGFloat?
    }

    /// A covered section whose strip would be left narrower than this keeps
    /// the whole strip instead: a switcher under another beats a missing one.
    static let minimumWidth: CGFloat = 48

    static func strip(of frame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    }

    /// `frames` holds every section, spanned ones included. `coveredSectionIDs`
    /// names the layout sections behind each spanned switcher that is on
    /// screen, and `contentWidths` how wide those switchers measured, 0 while
    /// unknown; an unmeasured switcher reserves no room yet.
    static func placements(
        frames: [UUID: CGRect],
        coveredSectionIDs: [UUID: Set<UUID>],
        contentWidths: [UUID: CGFloat],
        spacing: CGFloat,
        height: CGFloat
    ) -> [UUID: Placement] {
        var placements: [UUID: Placement] = [:]
        for (id, frame) in frames {
            placements[id] = Placement(strip: strip(of: frame, height: height), anchorX: nil)
        }

        var anchors: [UUID: CGFloat] = [:]
        for (id, covered) in coveredSectionIDs {
            guard let frame = frames[id] else { continue }
            anchors[id] = anchor(for: covered.compactMap { frames[$0] }, in: frame)
        }
        // Spans anchored on the same boundary line up side by side around it.
        var reserved: [(x: ClosedRange<CGFloat>, y: CGFloat)] = []
        for (anchorX, members) in Dictionary(grouping: anchors.keys, by: { anchors[$0] ?? 0 }) {
            let ordered = members.sorted { $0.uuidString < $1.uuidString }
            let widths = ordered.map { min(contentWidths[$0] ?? 0, frames[$0]?.width ?? 0) }
            let measured = widths.filter { $0 > 0 }
            let total = measured.reduce(0, +) + spacing * CGFloat(max(0, measured.count - 1))
            var x = anchorX - total / 2
            for (member, width) in zip(ordered, widths) {
                guard let frame = frames[member] else { continue }
                let strip = strip(of: frame, height: height)
                guard width > 0 else {
                    placements[member] = Placement(strip: strip, anchorX: anchorX)
                    continue
                }
                let minX = min(max(x, strip.minX), strip.maxX - width)
                placements[member] = Placement(strip: strip, anchorX: minX + width / 2)
                reserved.append((minX...(minX + width), strip.minY))
                x += width + spacing
            }
        }
        guard !reserved.isEmpty else { return placements }

        // The covered sections keep the widest stretch of their strip that no
        // spanned switcher sits over.
        for (id, frame) in frames where coveredSectionIDs[id] == nil {
            let strip = strip(of: frame, height: height)
            let blocked = reserved
                .filter { abs($0.y - strip.minY) < 0.5 }
                .map { ($0.x.lowerBound - spacing)...($0.x.upperBound + spacing) }
            guard !blocked.isEmpty else { continue }
            var free = [strip.minX...strip.maxX]
            for range in blocked {
                free = free.flatMap { piece -> [ClosedRange<CGFloat>] in
                    guard piece.overlaps(range) else { return [piece] }
                    var pieces: [ClosedRange<CGFloat>] = []
                    if piece.lowerBound < range.lowerBound { pieces.append(piece.lowerBound...range.lowerBound) }
                    if range.upperBound < piece.upperBound { pieces.append(range.upperBound...piece.upperBound) }
                    return pieces
                }
            }
            guard let widest = free.max(by: { length(of: $0) < length(of: $1) }),
                  length(of: widest) >= minimumWidth else { continue }
            placements[id] = Placement(
                strip: CGRect(x: widest.lowerBound, y: strip.minY, width: length(of: widest), height: height),
                anchorX: nil
            )
        }
        return placements
    }

    private static func length(of range: ClosedRange<CGFloat>) -> CGFloat {
        range.upperBound - range.lowerBound
    }

    /// The boundary between two neighbouring covered sections nearest the
    /// middle of the span, or the middle itself when the covered sections do
    /// not sit side by side.
    private static func anchor(for covered: [CGRect], in union: CGRect) -> CGFloat {
        var boundaries: [CGFloat] = []
        for lhs in covered {
            for rhs in covered where lhs != rhs {
                guard lhs.maxX <= rhs.minX + 0.5,
                      verticalOverlap(lhs, rhs) > 0,
                      !covered.contains(where: { between in
                          between != lhs && between != rhs
                              && verticalOverlap(between, lhs) > 0
                              && between.minX >= lhs.maxX - 0.5
                              && between.maxX <= rhs.minX + 0.5
                      }) else { continue }
                boundaries.append((lhs.maxX + rhs.minX) / 2)
            }
        }
        return boundaries.min { lhs, rhs in
            let leftDistance = abs(lhs - union.midX)
            let rightDistance = abs(rhs - union.midX)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs < rhs
        } ?? union.midX
    }

    private static func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    }
}

private struct SectionBarContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func reportSectionBarContentWidth(_ update: @escaping (CGFloat) -> Void) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SectionBarContentWidthPreferenceKey.self,
                    value: geometry.size.width
                )
            }
        }
        .onPreferenceChange(SectionBarContentWidthPreferenceKey.self, perform: update)
    }
}

private struct SectionMenuBar: View {
    @EnvironmentObject private var model: PanoptosModel
    @ObservedObject var presentation: SectionPresentation
    @StateObject private var menuHoverCoordinator = OverlayMenuHoverCoordinator()

    // Unless no-activation mode is enabled, opening a menu on an inactive bar
    // focuses its window first so commands act on the window being browsed.
    private func focusForMenuIfNeeded(_ window: ManagedWindow) {
        guard !model.invokeWithoutActivation, !presentation.isFocused else { return }
        model.focus(windowID: window.id)
    }

    var body: some View {
        let active = presentation.section.activeWindow
        let menus = active.map { model.menusByPID[$0.pid] ?? [] } ?? []
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if let active {
                        if let appMenu = menus.menuStripAppMenu {
                            OverlayTopLevelMenu(
                                title: active.applicationName,
                                icon: active.icon,
                                usesBoldTitle: true,
                                sourceID: active.id,
                                nodes: appMenu.presentedChildren,
                                parentPath: [appMenu.title],
                                hoverCoordinator: menuHoverCoordinator,
                                onWillOpen: { focusForMenuIfNeeded(active) }
                            ) { node, path in
                                model.invoke(window: active, node: node, path: path)
                            }
                            .fixedSize()
                        } else {
                            OverlayApplicationIcon(icon: active.icon)
                                .frame(width: 18, height: 18)
                            Text(active.applicationName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        Divider().frame(height: 19)
                        HStack(spacing: 0) {
                            ForEach(menus.menuStripCommandMenus) { node in
                                OverlayTopLevelMenu(
                                    title: node.title.isEmpty ? "(untitled)" : node.title,
                                    sourceID: active.id,
                                    nodes: node.presentedChildren,
                                    parentPath: [node.title],
                                    hoverCoordinator: menuHoverCoordinator,
                                    onWillOpen: { focusForMenuIfNeeded(active) }
                                ) { selected, path in
                                    model.invoke(window: active, node: selected, path: path)
                                }
                                .fixedSize()
                                .disabled(node.presentedChildren.isEmpty)
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .fixedSize(horizontal: true, vertical: false)
                .reportSectionBarContentWidth { width in
                    if presentation.topContentWidth != width { presentation.topContentWidth = width }
                }
                .frame(
                    minWidth: max(0, geometry.size.width),
                    minHeight: geometry.size.height,
                    alignment: model.sectionBarsCentered ? .center : .leading
                )
            }
        }
        .sectionChrome()
    }
}

private struct OverlayApplicationIcon: NSViewRepresentable {
    let icon: NSImage

    func makeNSView(context: Context) -> DynamicApplicationIconView {
        let view = DynamicApplicationIconView()
        view.imageScaling = .scaleProportionallyDown
        view.configure(icon: icon)
        return view
    }

    func updateNSView(_ view: DynamicApplicationIconView, context: Context) {
        view.configure(icon: icon)
    }
}

@MainActor
private final class DynamicApplicationIconView: NSImageView {
    private var representedIcon: NSImage?

    func configure(icon: NSImage) {
        guard icon !== representedIcon else { return }
        representedIcon = icon
        image = ApplicationIconImage.make(from: icon, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawDynamicImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawDynamicImage()
    }

    private func redrawDynamicImage() {
        image?.recache()
        needsDisplay = true
    }
}
