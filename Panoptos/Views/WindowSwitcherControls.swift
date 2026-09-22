import AppKit
import SwiftUI

/// Controls embedded in a nonactivating SwiftUI bar can narrow the geometric
/// first-click area used when the hosting view receives the event itself.
protocol FirstMouseInteractionRegion: AnyObject {
    func containsInteractionPoint(_ point: NSPoint) -> Bool
}

// Lets SwiftUI controls and gestures in the bars receive the first click even
// though the hosting panel is never key; see OverlayMenuControl.
final class FirstMouseHostingView: NSHostingView<AnyView> {
    var prepareBackgroundClick: (() -> (() -> Void)?)?
    private var pendingBackgroundClick: (() -> Void)?
    private var press: ReorderPress?
    private var scrollMonitor: Any?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // NSHostingView.hitTest claims points inside SwiftUI ScrollView content for
    // itself, so AppKit delivers those clicks here instead of to the embedded
    // AppKit controls, and SwiftUI does not reliably re-dispatch them while the
    // panel is never key. Resolve the control geometrically and activate it
    // directly. Calling control.mouseDown(with:) here can route the event back
    // through this hosting view and recurse until the process crashes.
    override func mouseDown(with event: NSEvent) {
        // A press on a reorderable button outlives its mouse-down, and a tool
        // tip hanging over the bar while it is dragged is just in the way.
        OverlayTooltipController.shared.cancel()
        if let control = interactiveControl(at: event.locationInWindow, in: self) {
            pendingBackgroundClick = nil
            if let button = control as? FirstMouseButton, button.reorder != nil {
                // Whether this is a drag or a click is only settled at the
                // mouse-up; see mouseDragged and mouseUp.
                press = ReorderPress(button: button, origin: event.locationInWindow)
            } else if let button = control as? NSButton {
                button.performClick(nil)
            } else {
                control.sendAction(control.action, to: control.target)
            }
            return
        }
        press = nil
        pendingBackgroundClick = prepareBackgroundClick?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard press != nil else {
            super.mouseDragged(with: event)
            return
        }
        press?.dragged(to: event.locationInWindow)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let control = interactiveControl(at: event.locationInWindow, in: self),
           let menu = control.menu {
            NSMenu.popUpContextMenu(menu, with: event, for: control)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let press {
            self.press = nil
            press.finish()
            return
        }
        super.mouseUp(with: event)
        let action = pendingBackgroundClick
        pendingBackgroundClick = nil
        DispatchQueue.main.async { action?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeScrollMonitor()
        } else if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.scheduleHoverReconciliation(after: event)
                return event
            }
        }
    }

    deinit {
        removeScrollMonitor()
    }

    private func scheduleHoverReconciliation(after event: NSEvent) {
        guard event.window === window else { return }
        let windowPoint = event.locationInWindow
        let localPoint = convert(windowPoint, from: nil)
        guard visibleRect.contains(localPoint) else { return }
        // Scrolling moves controls beneath a stationary pointer. AppKit can
        // deliver an enter to the newly exposed control without delivering an
        // exit to the one that moved away, leaving every traversed button with
        // stale hover chrome. Reconcile after the clip view has consumed this
        // event so the geometry describes the new scroll position.
        DispatchQueue.main.async { [weak self] in
            self?.reconcileButtonHover(at: windowPoint)
        }
    }

    private func removeScrollMonitor() {
        guard let scrollMonitor else { return }
        NSEvent.removeMonitor(scrollMonitor)
        self.scrollMonitor = nil
    }

    func reconcileButtonHover(at windowPoint: NSPoint) {
        let buttons = descendantSwitcherButtons(in: self)
        let hovered = buttons.first { button in
            guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor else { return false }
            let point = button.convert(windowPoint, from: nil)
            return button.bounds.contains(point) && button.visibleRect.contains(point)
        }
        for button in buttons {
            button.setPointerHovered(button === hovered)
        }
    }

    private func descendantSwitcherButtons(in view: NSView) -> [FirstMouseButton] {
        if let button = view as? FirstMouseButton { return [button] }
        return view.subviews.reversed().flatMap(descendantSwitcherButtons(in:))
    }

    // Outermost enabled NSControl whose visible (unclipped) bounds contain the
    // point. Deliberately avoids hitTest, which stops at this hosting view.
    private func interactiveControl(at windowPoint: NSPoint, in view: NSView) -> NSControl? {
        let candidates = interactiveControls(at: windowPoint, in: view)
        // A control that narrows its own interaction region overlaps its
        // neighbors on purpose, so it wins over a plain button that merely
        // happens to contain the same point.
        return candidates.first { $0 is FirstMouseInteractionRegion } ?? candidates.first
    }

    private func interactiveControls(at windowPoint: NSPoint, in view: NSView) -> [NSControl] {
        guard !view.isHidden else { return [] }
        let point = view.convert(windowPoint, from: nil)
        guard view.visibleRect.contains(point) else { return [] }
        if let control = view as? NSControl {
            guard control.isEnabled else { return [] }
            if let region = control as? FirstMouseInteractionRegion,
               !region.containsInteractionPoint(point) {
                return []
            }
            return [control]
        }
        return view.subviews.reversed().flatMap { subview in
            interactiveControls(at: windowPoint, in: subview)
        }
    }
}

private enum WindowSwitcherSelectionStyle {
    static let appKitHoverBackground = NSColor.labelColor.withAlphaComponent(0.08)
}

enum WindowSwitcherSelection: Equatable {
    case none
    case inactiveSectionActiveWindow
    case focusedSectionActiveWindow

    var backgroundOpacity: CGFloat {
        switch self {
        case .none: 0
        case .inactiveSectionActiveWindow: 0.07
        case .focusedSectionActiveWindow: 0.14
        }
    }

    var isSelected: Bool { self != .none }

    static func resolve(
        windowID: UUID,
        section: LayoutSectionState,
        isSectionFocused: Bool
    ) -> Self {
        guard section.activeWindow?.id == windowID else { return .none }
        return isSectionFocused ? .focusedSectionActiveWindow : .inactiveSectionActiveWindow
    }
}

enum WindowSwitcherTitleFont {
    static func display(size: CGFloat, isSelected: Bool) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: isSelected ? .semibold : .regular)
    }

    static func measurement(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }
}

struct WindowSwitcherMetrics: Equatable {
    let scale: CGFloat

    init(scale: Double) {
        self.scale = CGFloat(WindowSwitcherSize.normalized(scale))
    }

    var buttonHeight: CGFloat { WindowSwitcherSize.baseButtonHeight * scale }
    var iconHeight: CGFloat { 19 * scale }
    var titleFontSize: CGFloat { 11 }
    /// Square: the same two-point inset the button height gives the icon.
    var iconOnlyWidth: CGFloat { WindowSwitcherSize.baseButtonHeight * scale }
    /// Four points on each side. Titles need more breathing room than an icon,
    /// so this stays wider than the inset around an icon-only button.
    var horizontalContentPadding: CGFloat { 8 * scale }
    var iconTitleSpacing: CGFloat { 4 * scale }
    var iconAndTitlePadding: CGFloat { iconHeight + iconTitleSpacing + horizontalContentPadding }
    var titleOnlyHorizontalPadding: CGFloat { horizontalContentPadding }
    var titleOnlyMinimumHeight: CGFloat { 20 * scale }
    var titleVerticalPadding: CGFloat { 8 * scale }
    var cornerRadius: CGFloat { 5 * scale }
    /// Shorter than the 19-point icon it stands between, so the rule reads as
    /// a light divider rather than a second piece of chrome.
    var separatorHeight: CGFloat { 12 * scale }
    /// Matches the fixed clearance above and below the scaled buttons.
    var outerBarPadding: CGFloat { WindowSwitcherSize.outerVerticalAllowance / 2 }
}

/// Gives AppKit a point-sized drawing recipe instead of changing the logical
/// size of an application's multi-representation icon. In particular, the
/// system-provided app icons on macOS 26 contain scale- and appearance-aware
/// representations. Their 1× small representation can fall back to the
/// application's default light icon even when the 2× representation follows
/// the user's icon appearance. Always select the 2× source and let the
/// destination context downsample it on a 1× display.
enum ApplicationIconImage {
    static func make(from source: NSImage, height: CGFloat) -> NSImage {
        let size = drawnSize(for: source, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let sourceTransform = NSAffineTransform()
            sourceTransform.scale(by: 2)
            source.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.ctm: sourceTransform]
            )
            return true
        }
        // Each control owns its wrapper and invalidates this small cache when
        // its appearance or backing scale changes. This avoids repeatedly
        // downsampling icons while a crowded switcher is being reordered.
        image.cacheMode = .bySize
        image.isTemplate = source.isTemplate
        return image
    }

    /// Keeps the icon's own proportions. Application icons are square, but a
    /// symbol is not, and forcing one into a square box stretches the glyph.
    static func drawnSize(for icon: NSImage, height: CGFloat) -> NSSize {
        let size = icon.size
        guard size.width > 0, size.height > 0 else { return NSSize(width: height, height: height) }
        return NSSize(width: (height * size.width / size.height).rounded(), height: height)
    }
}

/// What the hosting view reports while the pointer drags a switcher button.
/// The translation is horizontal only, because the strip is a single row.
struct SectionBarReorderHandlers {
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let ended: () -> Void
}

struct SectionStackButton: NSViewRepresentable {
    var title: String? = nil
    var icon: NSImage? = nil
    /// Height the icon is drawn at. Application icons are square and fill the
    /// default; a symbol wants a smaller box so it sits inside the button
    /// rather than against its edges.
    var iconHeight: CGFloat = 19
    var scale: Double = WindowSwitcherSize.minimumScale
    var selection: WindowSwitcherSelection = .none
    var drawsSelectionBackground = true
    var drawsHoverBackground = true
    /// Bare external application icons use opacity alone for hover feedback.
    var dimsUntilHovered = false
    let accessibilityLabel: String
    let help: String
    let activate: () -> Void
    /// External unattached-window icons use a double click to attach the
    /// window selected by the first click. Other switcher controls leave this
    /// nil and preserve their existing repeated-click behavior.
    var doubleActivate: (() -> Void)? = nil
    var detach: (() -> Void)?
    var sectionFocusTitle: String? = nil
    var sectionFocusShortcut: GlobalShortcut? = nil
    var toggleSectionFocus: (() -> Void)? = nil
    var close: (() -> Void)?
    var quitApplicationTitle: String?
    var quitApplication: (() -> Void)?
    /// Supplied by the window switcher, whose buttons can be dragged into a
    /// different order. Buttons without it are click-only.
    var reorder: SectionBarReorderHandlers?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            activate: activate,
            doubleActivate: doubleActivate,
            detach: detach,
            sectionFocusTitle: sectionFocusTitle,
            sectionFocusShortcut: sectionFocusShortcut,
            toggleSectionFocus: toggleSectionFocus,
            close: close,
            quitApplicationTitle: quitApplicationTitle,
            quitApplication: quitApplication
        )
    }

    func makeNSView(context: Context) -> FirstMouseButton {
        let button = FirstMouseButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.activateButton)
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: FirstMouseButton, context: Context) {
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: FirstMouseButton, coordinator: Coordinator) {
        coordinator.activate = activate
        coordinator.doubleActivate = doubleActivate
        coordinator.detach = detach
        coordinator.sectionFocusTitle = sectionFocusTitle
        coordinator.sectionFocusShortcut = sectionFocusShortcut
        coordinator.toggleSectionFocus = toggleSectionFocus
        coordinator.close = close
        coordinator.quitApplicationTitle = quitApplicationTitle
        coordinator.quitApplication = quitApplication
        button.reorder = reorder
        button.drawsHoverBackground = drawsHoverBackground
        button.dimsUntilHovered = dimsUntilHovered
        let metrics = WindowSwitcherMetrics(scale: scale)

        // Dragging a button re-renders the whole strip on every pointer event,
        // and rebuilding an image, a title, and a context menu for each button
        // that often is enough to make the drag stutter. Nothing below this
        // point changes between those renders.
        let appearance = Coordinator.Appearance(
            title: title,
            icon: icon.map(ObjectIdentifier.init),
            iconHeight: iconHeight,
            scale: metrics.scale,
            selection: selection,
            drawsSelectionBackground: drawsSelectionBackground,
            dimsUntilHovered: dimsUntilHovered,
            accessibilityLabel: accessibilityLabel,
            help: help,
            canDetach: detach != nil,
            sectionFocusTitle: sectionFocusTitle,
            sectionFocusShortcut: sectionFocusShortcut,
            canToggleSectionFocus: toggleSectionFocus != nil,
            canClose: close != nil,
            quitApplicationTitle: quitApplicationTitle,
            canQuitApplication: quitApplication != nil
        )
        guard coordinator.appearance != appearance else { return }
        coordinator.appearance = appearance

        button.tooltipText = help
        button.setAccessibilityLabel(accessibilityLabel)
        button.alignment = .center
        button.layer?.cornerRadius = metrics.cornerRadius

        let displayTitle = title ?? ""
        let font = WindowSwitcherTitleFont.display(
            size: metrics.titleFontSize,
            isSelected: selection.isSelected
        )
        let attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        // Reserve the selected weight even while this button is unselected, so
        // moving focus cannot resize compact switcher bars as titles change
        // between regular and semibold.
        let measuredTitle = NSAttributedString(
            string: displayTitle,
            attributes: [.font: WindowSwitcherTitleFont.measurement(size: metrics.titleFontSize)]
        )

        if let icon {
            button.image = ApplicationIconImage.make(
                from: icon,
                height: iconHeight * metrics.scale
            )
            if displayTitle.isEmpty {
                button.imagePosition = .imageOnly
                button.attributedTitle = NSAttributedString(string: "")
                button.preferredSize = NSSize(width: metrics.iconOnlyWidth, height: metrics.buttonHeight)
            } else {
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
                button.attributedTitle = attributedTitle
                let measured = measuredTitle.size()
                button.preferredSize = NSSize(
                    width: ceil(measured.width) + metrics.iconAndTitlePadding,
                    height: metrics.buttonHeight
                )
            }
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = attributedTitle
            let measured = measuredTitle.size()
            button.preferredSize = NSSize(
                width: ceil(measured.width) + metrics.titleOnlyHorizontalPadding,
                height: max(metrics.titleOnlyMinimumHeight, ceil(measured.height) + metrics.titleVerticalPadding)
            )
        }
        button.selectedBackgroundOpacity = drawsSelectionBackground ? selection.backgroundOpacity : 0

        button.menu = Self.contextMenu(for: coordinator)
        button.invalidateIntrinsicContentSize()
    }

    static func contextMenu(for coordinator: Coordinator) -> NSMenu? {
        let hasQuitApplication = coordinator.quitApplicationTitle != nil
            && coordinator.quitApplication != nil
        guard coordinator.detach != nil
                || coordinator.toggleSectionFocus != nil
                || coordinator.close != nil
                || hasQuitApplication else { return nil }
        let menu = NSMenu()
        // Right-click delivery varies between the hosting view and the
        // embedded button. The menu delegate is the one path both share, so
        // dismiss Panoptos' pop-up-level tooltip immediately before AppKit
        // presents the context menu.
        menu.delegate = coordinator
        if coordinator.detach != nil {
            let item = NSMenuItem(title: "Detach Window", action: #selector(Coordinator.detachWindow), keyEquivalent: "")
            item.target = coordinator
            menu.addItem(item)
        }
        if let title = coordinator.sectionFocusTitle, coordinator.toggleSectionFocus != nil {
            let item = NSMenuItem(title: title, action: #selector(Coordinator.toggleSectionFocusAction), keyEquivalent: "")
            item.target = coordinator
            if let shortcut = coordinator.sectionFocusShortcut {
                item.keyEquivalent = MenuVirtualKeyEquivalent.character(for: Int(shortcut.keyCode))
                    ?? shortcut.keyLabel.lowercased()
                var modifiers: NSEvent.ModifierFlags = []
                if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
                if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
                if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
                if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
                item.keyEquivalentModifierMask = modifiers
            }
            menu.addItem(item)
        }
        if coordinator.close != nil {
            let item = NSMenuItem(title: "Close Window", action: #selector(Coordinator.closeWindow), keyEquivalent: "")
            item.target = coordinator
            menu.addItem(item)
        }
        if let title = coordinator.quitApplicationTitle, coordinator.quitApplication != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(
                title: title,
                action: #selector(Coordinator.quitApplicationAction),
                keyEquivalent: ""
            )
            item.target = coordinator
            menu.addItem(item)
        }
        return menu
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        /// Everything the button draws. Icons compare by object identity, the
        /// way `ManagedWindow` compares them: NSImage equality is expensive and
        /// the instance is stable for a window's lifetime.
        struct Appearance: Equatable {
            let title: String?
            let icon: ObjectIdentifier?
            let iconHeight: CGFloat
            let scale: CGFloat
            let selection: WindowSwitcherSelection
            let drawsSelectionBackground: Bool
            let dimsUntilHovered: Bool
            let accessibilityLabel: String
            let help: String
            let canDetach: Bool
            let sectionFocusTitle: String?
            let sectionFocusShortcut: GlobalShortcut?
            let canToggleSectionFocus: Bool
            let canClose: Bool
            let quitApplicationTitle: String?
            let canQuitApplication: Bool
        }

        var activate: () -> Void
        var doubleActivate: (() -> Void)?
        var detach: (() -> Void)?
        var sectionFocusTitle: String?
        var sectionFocusShortcut: GlobalShortcut?
        var toggleSectionFocus: (() -> Void)?
        var close: (() -> Void)?
        var quitApplicationTitle: String?
        var quitApplication: (() -> Void)?
        var appearance: Appearance?

        init(
            activate: @escaping () -> Void,
            doubleActivate: (() -> Void)? = nil,
            detach: (() -> Void)?,
            sectionFocusTitle: String? = nil,
            sectionFocusShortcut: GlobalShortcut? = nil,
            toggleSectionFocus: (() -> Void)? = nil,
            close: (() -> Void)?,
            quitApplicationTitle: String?,
            quitApplication: (() -> Void)?
        ) {
            self.activate = activate
            self.doubleActivate = doubleActivate
            self.detach = detach
            self.sectionFocusTitle = sectionFocusTitle
            self.sectionFocusShortcut = sectionFocusShortcut
            self.toggleSectionFocus = toggleSectionFocus
            self.close = close
            self.quitApplicationTitle = quitApplicationTitle
            self.quitApplication = quitApplication
        }

        @objc func activateButton() {
            performActivation(clickCount: NSApp.currentEvent?.clickCount ?? 1)
        }

        func performActivation(clickCount: Int) {
            if clickCount >= 2, let doubleActivate {
                doubleActivate()
            } else {
                activate()
            }
        }
        @objc func detachWindow() { detach?() }
        @objc func toggleSectionFocusAction() { toggleSectionFocus?() }
        @objc func closeWindow() { close?() }
        @objc func quitApplicationAction() { quitApplication?() }

        func menuWillOpen(_ menu: NSMenu) {
            OverlayTooltipController.shared.cancel()
        }
    }
}

/// Panoptos draws its own tool tips. AppKit shows the built-in ones only for
/// the active application's windows, and these panels belong to an application
/// that is almost never active and to windows that never become key, so
/// `NSView.toolTip` never appears on a section bar.
@MainActor
final class OverlayTooltipController {
    static let shared = OverlayTooltipController()

    /// Close enough to the system's own hover delay not to feel foreign.
    private let delay: TimeInterval = 0.5
    private let panel: NSPanel
    private var timer: Timer?
    private weak var owner: NSView?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
    }

    func show(_ text: String, from view: NSView) {
        guard !text.isEmpty else { return }
        cancel()
        owner = view
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, self.owner === view else { return }
                self.present(text, from: view)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Passing the view leaves another button's tool tip alone, so a pointer
    /// that has already moved on does not lose the one it just triggered.
    func cancel(from view: NSView? = nil) {
        if let view, owner !== view { return }
        timer?.invalidate()
        timer = nil
        owner = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func present(_ text: String, from view: NSView) {
        guard let window = view.window, window.isVisible else { return }
        panel.contentView = NSHostingView(rootView: AnyView(
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .fixedSize()
                .sectionChrome()
                .alwaysActiveAppearance()
        ))
        let size = panel.contentView?.fittingSize ?? .zero
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        panel.setFrame(
            OverlayTooltipLayout.frame(size: size, anchor: anchor, screen: screen?.visibleFrame ?? anchor),
            display: true
        )
        panel.orderFrontRegardless()
    }
}

/// Carries a press on a switcher button from its mouse-down to its mouse-up and
/// resolves it into either a reorder drag or a click.
///
/// AppKit can deliver that press either to the embedded button or its hosting
/// view depending on SwiftUI's compositing and hit-testing. Both views
/// therefore own a tracker and drive this.
///
/// Events are handled as AppKit delivers them rather than pulled from the queue
/// in a tracking loop: the overlay coordinator's event monitors have to keep
/// seeing the mouse-up, or its window-drag tracking never stops and panel
/// reconciliation stays suppressed behind it.
@MainActor
private struct ReorderPress {
    /// Far enough that a click with an unsteady hand still activates a window.
    private static let threshold: CGFloat = 4

    private let button: FirstMouseButton
    private let origin: NSPoint
    private var isReordering = false

    init(button: FirstMouseButton, origin: NSPoint) {
        self.button = button
        self.origin = origin
    }

    mutating func dragged(to location: NSPoint) {
        let horizontal = location.x - origin.x
        let vertical = location.y - origin.y
        if !isReordering, max(abs(horizontal), abs(vertical)) >= Self.threshold {
            isReordering = true
            button.reorder?.began()
        }
        if isReordering { button.reorder?.changed(horizontal) }
    }

    func finish() {
        if isReordering {
            button.reorder?.ended()
        } else {
            button.performClick(nil)
        }
    }
}

final class FirstMouseButton: NSButton {
    var preferredSize = NSSize(width: 24, height: 24)
    /// Set while this button may be dragged into a different position. Both this
    /// button and the hosting view read it on every press; see ReorderPress.
    var reorder: SectionBarReorderHandlers?
    /// Shown by Panoptos' own tool tip; see OverlayTooltipController.
    var tooltipText: String?
    /// Opacity of the active window's selection background. The focused
    /// section is stronger than the remembered active window in other
    /// sections.
    var selectedBackgroundOpacity: CGFloat = 0 {
        didSet {
            guard selectedBackgroundOpacity != oldValue else { return }
            applySelectionBackground()
        }
    }
    /// Switcher buttons show their exact clickable bounds under the pointer.
    var drawsHoverBackground = false {
        didSet {
            guard drawsHoverBackground != oldValue else { return }
            applySelectionBackground()
        }
    }
    /// Leaves a bare icon slightly subdued at rest and restores full opacity
    /// under the pointer without drawing any background chrome.
    var dimsUntilHovered = false {
        didSet {
            guard dimsUntilHovered != oldValue else { return }
            applyHoverOpacity()
        }
    }
    private(set) var isPointerHovered = false
    private var hoverArea: NSTrackingArea?
    private var press: ReorderPress?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { preferredSize }

    // Resolving a dynamic NSColor into a layer's CGColor freezes it in the
    // appearance that was current at the time, so a switch between light and
    // dark mode has to resolve it again. The button owns the color for that
    // reason: SectionStackButton reapplies it only when what it draws changes,
    // and the appearance changing is not one of those times.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySelectionBackground()
        redrawDynamicImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawDynamicImage()
    }

    private func applySelectionBackground() {
        let color: NSColor
        if selectedBackgroundOpacity > 0 {
            color = NSColor.labelColor.withAlphaComponent(selectedBackgroundOpacity)
        } else if drawsHoverBackground && isPointerHovered {
            color = WindowSwitcherSelectionStyle.appKitHoverBackground
        } else {
            color = .clear
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }

    private func applyHoverOpacity() {
        alphaValue = dimsUntilHovered && !isPointerHovered ? 0.82 : 1
    }

    private func redrawDynamicImage() {
        image?.recache()
        needsDisplay = true
    }

    // Presses that AppKit hands straight to this button. Without these the
    // button's own tracking would swallow the drag and only ever report a
    // click.
    override func mouseDown(with event: NSEvent) {
        guard reorder != nil else {
            super.mouseDown(with: event)
            return
        }
        OverlayTooltipController.shared.cancel()
        press = ReorderPress(button: self, origin: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard press != nil else {
            super.mouseDragged(with: event)
            return
        }
        press?.dragged(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else {
            super.mouseUp(with: event)
            return
        }
        self.press = nil
        press.finish()
    }

    // `.activeAlways`: the pointer has to be tracked while another application
    // is the active one, which is the normal case for a section bar.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setPointerHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setPointerHovered(false)
    }

    func setPointerHovered(_ hovered: Bool) {
        guard isPointerHovered != hovered else { return }
        isPointerHovered = hovered
        applySelectionBackground()
        applyHoverOpacity()
        if hovered, let tooltipText {
            OverlayTooltipController.shared.show(tooltipText, from: self)
        } else {
            OverlayTooltipController.shared.cancel(from: self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            setPointerHovered(false)
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        layer?.cornerRadius = 5
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyHoverOpacity()
    }

    required init?(coder: NSCoder) { nil }
}
