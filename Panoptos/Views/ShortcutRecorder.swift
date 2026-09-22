import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Both recorders present the same fixed-size pill.
private let shortcutRecorderSize = CGSize(width: 154, height: 28)

/// Distance from the pill's leading edge to its text, and from its trailing
/// edge to the text when the clear control is showing.
private let shortcutTextInset: CGFloat = 10
private let shortcutClearedTextInset: CGFloat = 30

/// Trailing room reserved inside the shortcut label so the last glyph is never
/// clipped. Arrow and modifier glyphs paint out to their full advance width, so
/// right-aligned text laid out in a frame fitted to its own measured width
/// loses the tip of its final character.
private let shortcutLabelSlack: CGFloat = 4

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut?
    let onChange: (GlobalShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        if view.shortcut != shortcut {
            view.shortcut = shortcut
        }
        view.onChange = onChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderNSView, context: Context) -> CGSize? {
        shortcutRecorderSize
    }
}

/// Shared pill: chrome, shortcut text, clear control, and click routing. The
/// subclasses only own what they record and how they capture it.
///
/// The chrome goes in a dedicated sublayer because neither `draw(_:)` nor the
/// view's own backing layer draws it correctly inside an `NSViewRepresentable`
/// on macOS 26: drawRect content is composited at the wrong horizontal scale,
/// and a rounded border set on the backing layer is composited from a wider
/// rect than `bounds`, so the right corners and right edge fall outside the
/// pill. A plain sublayer is composited from its own geometry.
class ShortcutPillView: NSView {
    private let chromeLayer = CALayer()
    private let shortcutLabel = NSTextField(labelWithString: "None")
    private let clearView = NSImageView()
    private var showsActiveBorder = false
    /// Drives the clear control, the trailing text inset, and clear clicks.
    private(set) var showsClearControl = false

    var displayedShortcutText: String { shortcutLabel.stringValue }
    var isClearControlVisible: Bool { !clearView.isHidden }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { shortcutRecorderSize }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chromeLayer.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byClipping
        shortcutLabel.maximumNumberOfLines = 1
        shortcutLabel.setAccessibilityElement(false)
        addSubview(shortcutLabel)

        clearView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        clearView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        clearView.contentTintColor = .secondaryLabelColor
        clearView.imageScaling = .scaleNone
        clearView.setAccessibilityElement(false)
        addSubview(clearView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The single place where a recorder's state becomes pixels.
    func present(text: String, tracked: Bool, isRecording: Bool, showsClear: Bool) {
        shortcutLabel.setShortcutText(
            text,
            color: isRecording ? .controlAccentColor : .labelColor,
            tracked: tracked
        )
        showsClearControl = showsClear
        clearView.isHidden = !showsClear
        showsActiveBorder = isRecording
        setAccessibilityValue(text)
        needsLayout = true
        needsDisplay = true
    }

    /// Overridden by subclasses to hand `nil` back through their own binding.
    func clearBinding() {}

    override func updateLayer() {
        applyChrome()
    }

    override func layout() {
        super.layout()
        applyChrome()

        let trailingInset = showsClearControl ? shortcutClearedTextInset : shortcutTextInset
        let labelHeight = shortcutLabel.intrinsicContentSize.height
        shortcutLabel.frame = NSRect(
            x: shortcutTextInset,
            y: floor((bounds.height - labelHeight) / 2),
            width: max(0, bounds.width - shortcutTextInset - trailingInset + shortcutLabelSlack),
            height: labelHeight
        )
        // An image view centers its symbol in its own bounds, so the clear
        // control lines up with the pill without any glyph-metric arithmetic.
        clearView.frame = clearButtonFrame
    }

    var clearButtonFrame: NSRect {
        NSRect(x: bounds.maxX - 26, y: 2, width: 24, height: bounds.height - 4)
    }

    func shouldClearShortcut(at point: NSPoint) -> Bool {
        showsClearControl && clearButtonFrame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if shouldClearShortcut(at: convert(event.locationInWindow, from: nil)) {
            clearBinding()
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func applyChrome() {
        guard let layer else { return }
        if chromeLayer.superlayer !== layer {
            layer.insertSublayer(chromeLayer, at: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeLayer.frame = bounds
        chromeLayer.cornerRadius = 10
        chromeLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        chromeLayer.borderWidth = showsActiveBorder ? 2 : 1
        chromeLayer.borderColor = (showsActiveBorder ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        CATransaction.commit()
    }
}

private extension NSTextField {
    /// Shortcut glyphs run together at this size, so the modifiers and the key
    /// read as one dense cluster; tracking separates them, while placeholder
    /// text such as "None" keeps normal spacing. Both get `shortcutLabelSlack`
    /// after the final glyph, which is what keeps it out of the clip edge.
    func setShortcutText(_ text: String, color: NSColor, tracked: Bool) {
        textColor = color
        guard let font else {
            stringValue = text
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        let length = (text as NSString).length
        if tracked, length > 1 {
            attributed.addAttribute(.kern, value: 2.0, range: NSRange(location: 0, length: length - 1))
        }
        if length > 0 {
            attributed.addAttribute(
                .kern,
                value: shortcutLabelSlack,
                range: NSRange(location: length - 1, length: 1)
            )
        }
        attributedStringValue = attributed
    }
}

final class ShortcutRecorderNSView: ShortcutPillView {
    var shortcut: GlobalShortcut? {
        didSet { updatePresentation() }
    }
    var onChange: ((GlobalShortcut?) -> Void)?
    private var isRecording = false {
        didSet { updatePresentation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Keyboard shortcut")
        updatePresentation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func clearBinding() {
        onChange?(nil)
    }

    override func keyDown(with event: NSEvent) {
        guard capture(event) else { super.keyDown(with: event); return }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        isRecording && capture(event)
    }

    private func updatePresentation() {
        let hasShortcut = shortcut != nil
        present(
            text: isRecording ? "Type shortcut" : shortcut?.displayText ?? "None",
            tracked: hasShortcut && !isRecording,
            isRecording: isRecording,
            showsClear: hasShortcut && !isRecording
        )
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown, !event.isARepeat else { return false }
        if Int(event.keyCode) == kVK_Escape {
            window?.makeFirstResponder(nil)
            return true
        }
        if Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete {
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return true
        }
        onChange?(GlobalShortcut(event: event))
        window?.makeFirstResponder(nil)
        return true
    }
}

struct ModifierShortcutRecorder: NSViewRepresentable {
    let modifiers: ShortcutModifiers?
    let onChange: (ShortcutModifiers?) -> Void

    func makeNSView(context: Context) -> ModifierShortcutRecorderNSView {
        let view = ModifierShortcutRecorderNSView()
        view.modifiers = modifiers
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ModifierShortcutRecorderNSView, context: Context) {
        if view.modifiers != modifiers {
            view.modifiers = modifiers
        }
        view.onChange = onChange
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ModifierShortcutRecorderNSView,
        context: Context
    ) -> CGSize? {
        shortcutRecorderSize
    }
}

final class ModifierShortcutRecorderNSView: ShortcutPillView {
    var modifiers: ShortcutModifiers? {
        didSet { updatePresentation() }
    }
    var onChange: ((ShortcutModifiers?) -> Void)?
    private var isRecording = false {
        didSet { updatePresentation() }
    }
    private var pendingModifiers: ShortcutModifiers = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Window drag modifier keys")
        updatePresentation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        pendingModifiers = []
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        pendingModifiers = []
        isRecording = false
        return true
    }

    override func clearBinding() {
        onChange?(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        let current = ShortcutModifiers(eventFlags: event.modifierFlags)
        if current.isEmpty {
            guard !pendingModifiers.isEmpty else { return }
            let captured = pendingModifiers
            onChange?(captured)
            window?.makeFirstResponder(nil)
            return
        }
        pendingModifiers.formUnion(current)
        updatePresentation()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case kVK_Escape:
            window?.makeFirstResponder(nil)
        case kVK_Delete, kVK_ForwardDelete:
            onChange?(nil)
            window?.makeFirstResponder(nil)
        default:
            NSSound.beep()
        }
    }

    private func updatePresentation() {
        let pendingText = pendingModifiers.isEmpty ? "Hold keys" : pendingModifiers.displayText
        present(
            text: isRecording ? pendingText : modifiers?.displayText ?? "None",
            tracked: isRecording ? !pendingModifiers.isEmpty : modifiers != nil,
            isRecording: isRecording,
            showsClear: modifiers != nil && !isRecording
        )
    }
}
