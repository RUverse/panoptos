import AppKit
import SwiftUI

// Transient toast centered in a zone, e.g. "Xcode doesn't fit here".
@MainActor
final class SectionNoticeController {
    private let panel: NSPanel
    private var text = ""

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
    }

    func show(text: String, centeredIn frame: CGRect) {
        if text != self.text || panel.contentView == nil {
            self.text = text
            panel.contentView = NSHostingView(rootView: AnyView(
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .fixedSize()
                    .sectionChrome()
                    .alwaysActiveAppearance()
            ))
        }
        let size = panel.contentView?.fittingSize ?? .zero
        let target = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() { panel.close() }
}
@MainActor
final class AttachmentHighlightController {
    private let panel: NSPanel
    private var isSelected: Bool?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .stationary]
    }

    func show(frame: CGRect, selected: Bool) {
        // This runs at 60 Hz during a drag; only rebuild the hosting view when
        // the selection state actually changes.
        if isSelected != selected {
            isSelected = selected
            panel.contentView = NSHostingView(rootView:
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(selected ? 0.22 : 0.06))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(selected ? 0.95 : 0.35), lineWidth: selected ? 3 : 1) }
                    .padding(4)
                    .alwaysActiveAppearance()
            )
        }
        if panel.frame != frame.integral { panel.setFrame(frame.integral, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() { panel.close() }
}
