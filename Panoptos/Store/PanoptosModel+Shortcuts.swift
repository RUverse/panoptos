import AppKit
import Foundation

// Shortcut configuration, registration, and dispatch.
@MainActor
extension PanoptosModel {
    func shortcut(for command: ShortcutCommand) -> GlobalShortcut? {
        shortcuts[command]
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for command: ShortcutCommand) {
        if let shortcut {
            guard shortcut.modifiers.hasNonShiftModifier else {
                shortcutError = "Shortcuts need Control, Option, or Command so ordinary typing remains available."
                return
            }
            if let duplicate = shortcuts.first(where: { $0.key != command && $0.value.conflicts(with: shortcut) })?.key {
                shortcutError = "That shortcut is already assigned to \(duplicate.title)."
                return
            }
            shortcuts[command] = shortcut
            disabledShortcutCommands.remove(command)
        } else {
            shortcuts.removeValue(forKey: command)
            disabledShortcutCommands.insert(command)
        }

        saveShortcuts()
        refreshShortcutRegistration()
    }

    private func saveShortcuts() {
        do {
            try shortcutPersistence.save(ShortcutState(
                bindings: shortcuts,
                disabledCommands: disabledShortcutCommands
            ))
            shortcutError = nil
        } catch {
            shortcutError = "Could not save shortcuts: \(error.localizedDescription)"
        }
    }

    func windowDragShortcut(for action: WindowDragShortcutAction) -> ShortcutModifiers? {
        windowDragShortcuts[action]
    }

    var attachAllApplicationWindowsWithControlShift: Bool {
        windowDragShortcuts.attachApplicationWindows != nil
    }

    func setWindowDragShortcut(_ modifiers: ShortcutModifiers?, for action: WindowDragShortcutAction) {
        let modifiers = modifiers.flatMap { $0.isEmpty ? nil : $0 }
        if let modifiers,
           let duplicate = WindowDragShortcutAction.allCases.first(where: {
               $0 != action && windowDragShortcuts[$0] == modifiers
           }) {
            let message = "Those keys are already assigned to \(duplicate.title.lowercased())."
            windowDragShortcutValidationError = message
            shortcutError = message
            return
        }
        windowDragShortcuts[action] = modifiers
        if shortcutError == windowDragShortcutValidationError {
            shortcutError = nil
        }
        windowDragShortcutValidationError = nil
    }

    func windowDragAction(for modifierFlags: NSEvent.ModifierFlags) -> WindowDragShortcutAction? {
        windowDragShortcuts.action(for: ShortcutModifiers(eventFlags: modifierFlags))
    }

    func resetShortcuts() {
        shortcuts = ShortcutPersistence.defaults
        disabledShortcutCommands = []
        windowDragShortcuts = .defaults
        saveShortcuts()
        refreshShortcutRegistration()
    }

    func performShortcut(_ command: ShortcutCommand) {
        guard hasWindowManagementAccess, isAccessibilityTrusted else { return }
        switch command {
        case .cycleNextWindow:
            cycleWindow(step: 1)
        case .cyclePreviousWindow:
            cycleWindow(step: -1)
        case .focusPreviousSection:
            focusWindowInSection(.left)
        case .focusNextSection:
            focusWindowInSection(.right)
        case .cycleWindowLeft:
            moveFocusedWindow(.left)
        case .cycleWindowRight:
            moveFocusedWindow(.right)
        case .moveApplicationEarlier:
            moveFocusedApplicationInSwitcher(step: -1)
        case .moveApplicationLater:
            moveFocusedApplicationInSwitcher(step: 1)
        case .spanWindowLeft:
            spanFocusedWindow(.left)
        case .spanWindowRight:
            spanFocusedWindow(.right)
        case .toggleSectionFocus:
            toggleFocusModeForFocusedWindow()
        }
    }
    private func reportShortcutRegistrationFailures(_ failures: [ShortcutCommand: OSStatus]) {
        guard let failure = failures.first else { return }
        shortcutError = "macOS could not register \(failure.key.title) (error \(failure.value)). Choose a different shortcut."
    }

    func refreshShortcutRegistration() {
        let activeShortcuts = hasWindowManagementAccess && isAccessibilityTrusted ? shortcuts : [:]
        reportShortcutRegistrationFailures(shortcutRegistrar.update(activeShortcuts))
    }
}
