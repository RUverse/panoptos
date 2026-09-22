import AppKit
import SwiftUI

@MainActor
final class OverlayMenuHoverCoordinator: ObservableObject {
    private var controls: [ObjectIdentifier: WeakOverlayMenuControl] = [:]
    private weak var openControl: OverlayMenuControl?
    private weak var pendingControl: OverlayMenuControl?
    private var hoverTimer: Timer?

    func register(_ control: OverlayMenuControl) {
        controls[ObjectIdentifier(control)] = WeakOverlayMenuControl(control)
    }

    func unregister(_ control: OverlayMenuControl) {
        controls.removeValue(forKey: ObjectIdentifier(control))
        if pendingControl === control { pendingControl = nil }
        if openControl === control { control.popupMenu.cancelTrackingWithoutAnimation() }
    }

    func menuWillOpen(_ control: OverlayMenuControl) {
        openControl = control
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHoveredControl() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func menuDidClose(_ control: OverlayMenuControl) {
        guard openControl === control else { return }
        openControl = nil
        stopHoverTracking()
        guard let pendingControl else { return }
        self.pendingControl = nil
        DispatchQueue.main.async { [weak pendingControl] in pendingControl?.openMenu() }
    }

    private func checkHoveredControl() {
        // Runs at 60 Hz while a menu is open; drop dead references in place
        // rather than reallocating the dictionary every tick.
        for (key, value) in controls where value.control == nil {
            controls.removeValue(forKey: key)
        }
        guard let openControl else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let hovered = controls.values.compactMap(\.control).first(where: {
            $0 !== openControl && $0.isEnabled && $0.screenFrame.contains(mouseLocation)
        }) else { return }
        pendingControl = hovered
        openControl.popupMenu.cancelTrackingWithoutAnimation()
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    deinit { hoverTimer?.invalidate() }
}

private final class WeakOverlayMenuControl {
    weak var control: OverlayMenuControl?
    init(_ control: OverlayMenuControl) { self.control = control }
}

struct OverlayTopLevelMenu: NSViewRepresentable {
    let title: String
    var icon: NSImage?
    var usesBoldTitle = false
    let sourceID: UUID
    let nodes: [MenuNode]
    let parentPath: [String]
    let hoverCoordinator: OverlayMenuHoverCoordinator
    var onWillOpen: (() -> Void)?
    let invoke: (MenuNode, [String]) -> Void

    func makeNSView(context: Context) -> OverlayMenuControl {
        let control = OverlayMenuControl(hoverCoordinator: hoverCoordinator)
        hoverCoordinator.register(control)
        update(control)
        return control
    }

    func updateNSView(_ control: OverlayMenuControl, context: Context) {
        update(control)
        control.isEnabled = context.environment.isEnabled && !nodes.isEmpty
    }

    static func dismantleNSView(_ control: OverlayMenuControl, coordinator: Void) {
        control.hoverCoordinator.unregister(control)
    }

    private func update(_ control: OverlayMenuControl) {
        control.onWillOpen = onWillOpen
        control.configure(
            title: title,
            icon: icon,
            usesBoldTitle: usesBoldTitle,
            sourceID: sourceID,
            nodes: nodes,
            parentPath: parentPath,
            invoke: invoke
        )
    }
}

@MainActor
final class OverlayMenuControl: NSButton, NSMenuDelegate {
    let hoverCoordinator: OverlayMenuHoverCoordinator
    var onWillOpen: (() -> Void)?
    fileprivate let popupMenu = NSMenu()
    private var representedNodes: [MenuNode] = []
    private var representedParentPath: [String] = []
    private var representedSourceID: UUID?
    private var representedTitle: String?
    private var representedIcon: NSImage?
    private var representedUsesBoldTitle: Bool?
    private var actionHandlers: [OverlayMenuActionHandler] = []
    private var pendingConfiguration: MenuConfiguration?
    private var isMenuOpen = false
    private var isMenuOpenScheduled = false

    private struct MenuConfiguration {
        let sourceID: UUID
        let nodes: [MenuNode]
        let parentPath: [String]
        let invoke: (MenuNode, [String]) -> Void
    }

    var screenFrame: CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    // The panel is a never-key window of a usually inactive app; without this
    // the first click is treated as an activation click and never reaches us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(hoverCoordinator: OverlayMenuHoverCoordinator) {
        self.hoverCoordinator = hoverCoordinator
        super.init(frame: .zero)
        target = self
        action = #selector(openMenu)
        isBordered = false
        focusRingType = .none
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        controlSize = .small
        popupMenu.autoenablesItems = false
        popupMenu.delegate = self
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawDynamicImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawDynamicImage()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 14, height: max(26, size.height))
    }

    func configure(
        title: String,
        icon: NSImage?,
        usesBoldTitle: Bool,
        sourceID: UUID,
        nodes: [MenuNode],
        parentPath: [String],
        invoke: @escaping (MenuNode, [String]) -> Void
    ) {
        // SwiftUI calls updateNSView liberally; rebuilding attributed titles
        // and copying icons on every pass is wasted work when nothing changed.
        // The icon compares by identity because the instance is stable for a
        // window's lifetime.
        if title != representedTitle || icon !== representedIcon || usesBoldTitle != representedUsesBoldTitle {
            representedTitle = title
            representedIcon = icon
            representedUsesBoldTitle = usesBoldTitle
            self.title = title
            self.image = icon.map { ApplicationIconImage.make(from: $0, height: 18) }
            let font = NSFont.systemFont(ofSize: 12, weight: usesBoldTitle ? .semibold : .regular)
            self.font = font
            let attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            self.attributedTitle = attributedTitle
            attributedAlternateTitle = attributedTitle
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
        }
        guard nodes != representedNodes || parentPath != representedParentPath || sourceID != representedSourceID else {
            pendingConfiguration = nil
            return
        }
        let configuration = MenuConfiguration(sourceID: sourceID, nodes: nodes, parentPath: parentPath, invoke: invoke)
        if isMenuOpen {
            pendingConfiguration = configuration
        } else {
            rebuildMenu(with: configuration)
        }
    }

    @objc func openMenu() {
        guard isEnabled, !popupMenu.items.isEmpty, !isMenuOpen, !isMenuOpenScheduled else { return }
        isMenuOpenScheduled = true
        onWillOpen?()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMenuOpenScheduled = false
            guard self.isEnabled, !self.popupMenu.items.isEmpty, !self.isMenuOpen else { return }
            let frame = self.screenFrame
            self.popupMenu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY), in: nil)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        highlight(true)
        hoverCoordinator.menuWillOpen(self)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        highlight(false)
        if let pendingConfiguration {
            self.pendingConfiguration = nil
            rebuildMenu(with: pendingConfiguration)
        }
        hoverCoordinator.menuDidClose(self)
    }

    private func redrawDynamicImage() {
        image?.recache()
        needsDisplay = true
    }

    private func rebuildMenu(with configuration: MenuConfiguration) {
        representedNodes = configuration.nodes
        representedParentPath = configuration.parentPath
        representedSourceID = configuration.sourceID
        actionHandlers.removeAll()
        popupMenu.removeAllItems()
        add(nodes: configuration.nodes, to: popupMenu, path: configuration.parentPath, invoke: configuration.invoke)
    }

    private func add(
        nodes: [MenuNode],
        to menu: NSMenu,
        path: [String],
        invoke: @escaping (MenuNode, [String]) -> Void
    ) {
        for node in nodes {
            if node.isSeparator {
                menu.addItem(.separator())
                continue
            }

            let title = node.title.isEmpty ? "(untitled)" : node.title
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = !node.presentedChildren.isEmpty ? node.isEnabled : node.isInvokable
            apply(mark: node.mark, to: item)
            apply(shortcut: node.shortcut, to: item)

            if node.presentedChildren.isEmpty {
                let itemPath = path + (node.title.isEmpty ? [] : [node.title])
                let handler = OverlayMenuActionHandler { invoke(node, itemPath) }
                actionHandlers.append(handler)
                item.target = handler
                item.action = #selector(OverlayMenuActionHandler.performAction)
            } else {
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                add(
                    nodes: node.presentedChildren,
                    to: submenu,
                    path: path + (node.title.isEmpty ? [] : [node.title]),
                    invoke: invoke
                )
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    private func apply(mark: String?, to item: NSMenuItem) {
        guard let mark, !mark.isEmpty else { return }
        item.state = mark == "-" ? .mixed : .on
        guard mark != "-", mark != "✓", mark != "✔" else { return }

        let value = NSAttributedString(
            string: mark,
            attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.black]
        )
        let measured = value.size()
        let size = NSSize(width: max(12, ceil(measured.width)), height: max(14, ceil(measured.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            value.draw(at: NSPoint(x: (rect.width - measured.width) / 2, y: (rect.height - measured.height) / 2))
            return true
        }
        image.isTemplate = true
        item.onStateImage = image
    }

    private func apply(shortcut: String?, to item: NSMenuItem) {
        guard var shortcut else { return }
        var modifiers: NSEvent.ModifierFlags = []
        for (symbol, modifier): (Character, NSEvent.ModifierFlags) in [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)] {
            if shortcut.first == symbol {
                modifiers.insert(modifier)
                shortcut.removeFirst()
            }
        }
        if shortcut.hasPrefix("key:") {
            if let keyCode = Int(shortcut.dropFirst(4)),
               let keyEquivalent = MenuVirtualKeyEquivalent.character(for: keyCode) {
                item.keyEquivalent = keyEquivalent
                item.keyEquivalentModifierMask = modifiers
            }
            return
        }
        guard !shortcut.isEmpty else { return }
        item.keyEquivalent = shortcut.lowercased()
        item.keyEquivalentModifierMask = modifiers
    }

}

@MainActor
private final class OverlayMenuActionHandler: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func performAction() { action() }
}
