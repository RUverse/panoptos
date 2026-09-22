import AppKit
import ApplicationServices
import Foundation

struct TargetApplication: Identifiable, Hashable {
    let pid: pid_t
    let bundleIdentifier: String
    let name: String
    let icon: NSImage

    var id: pid_t { pid }
    var isRunning: Bool { NSRunningApplication(processIdentifier: pid) != nil }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.pid == rhs.pid }
    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
}

struct MenuNode: Identifiable, Hashable {
    let indexPath: [Int]
    let title: String
    let role: String
    let isEnabled: Bool
    let mark: String?
    let shortcut: String?
    let availableActions: [String]
    let children: [MenuNode]

    var id: String { indexPath.map(String.init).joined(separator: ".") }
    var isSeparator: Bool { role == (kAXMenuItemRole as String) && title.isEmpty && children.isEmpty }
    var isInvokable: Bool { children.isEmpty && !isSeparator && isEnabled && MenuActionSelector.preferredAction(in: availableActions) != nil }
    var presentedChildren: [MenuNode] {
        if children.count == 1, children[0].role == (kAXMenuRole as String), children[0].title.isEmpty {
            return children[0].children
        }
        return children
    }
}

extension Array where Element == MenuNode {
    var appSpecificMenus: [MenuNode] {
        guard first?.title.localizedCaseInsensitiveCompare("Apple") == .orderedSame else {
            return self
        }
        return Array(dropFirst())
    }

    var menuStripAppMenu: MenuNode? {
        guard first?.title.localizedCaseInsensitiveCompare("Apple") == .orderedSame, count > 1 else {
            return nil
        }
        return self[1]
    }

    var menuStripCommandMenus: [MenuNode] {
        guard menuStripAppMenu != nil else { return appSpecificMenus }
        return Array(dropFirst(2))
    }
}

struct MenuSnapshot: Equatable {
    var title: String?
    var role: String
    var isEnabled: Bool?
    var mark: String?
    var commandCharacter: String?
    var commandModifiers: Int?
    var virtualKey: Int?
    var actions: [String]
    var children: [MenuSnapshot]
}

enum MenuTreeParser {
    static func parse(_ snapshots: [MenuSnapshot]) -> [MenuNode] {
        snapshots.enumerated().map { parse($0.element, path: [$0.offset]) }
    }

    private static func parse(_ snapshot: MenuSnapshot, path: [Int]) -> MenuNode {
        MenuNode(
            indexPath: path,
            title: snapshot.title ?? "",
            role: snapshot.role,
            isEnabled: snapshot.isEnabled ?? true,
            mark: snapshot.mark?.nilIfEmpty,
            shortcut: ShortcutFormatter.format(
                character: snapshot.commandCharacter,
                modifiers: snapshot.commandModifiers,
                virtualKey: snapshot.virtualKey
            ),
            availableActions: snapshot.actions,
            children: snapshot.children.enumerated().map {
                parse($0.element, path: path + [$0.offset])
            }
        )
    }
}

enum MenuActionSelector {
    static func preferredAction(in actions: [String]) -> String? {
        if actions.contains(kAXPickAction as String) { return kAXPickAction as String }
        if actions.contains(kAXPressAction as String) { return kAXPressAction as String }
        return nil
    }
}

enum ShortcutFormatter {
    // Accessibility uses Carbon menu modifier bits: Shift=1, Option=2, Control=4,
    // NoCommand=8. Command is present when the NoCommand bit is absent.
    static func format(character: String?, modifiers: Int?, virtualKey: Int?) -> String? {
        guard let rawCharacter = character?.nilIfEmpty else {
            guard let virtualKey else { return nil }
            return "key:\(virtualKey)"
        }

        let flags = modifiers ?? 0
        var result = ""
        if flags & 4 != 0 { result += "⌃" }
        if flags & 2 != 0 { result += "⌥" }
        if flags & 1 != 0 { result += "⇧" }
        if flags & 8 == 0 { result += "⌘" }
        result += rawCharacter.uppercased()
        return result
    }
}

enum MenuVirtualKeyEquivalent {
    static func character(for keyCode: Int) -> String? {
        let functionKeys: [Int: UInt32] = [
            122: 0xF704, 120: 0xF705, 99: 0xF706, 118: 0xF707,
            96: 0xF708, 97: 0xF709, 98: 0xF70A, 100: 0xF70B,
            101: 0xF70C, 109: 0xF70D, 103: 0xF70E, 111: 0xF70F,
            105: 0xF710, 107: 0xF711, 113: 0xF712, 106: 0xF713,
            64: 0xF714, 79: 0xF715, 80: 0xF716, 90: 0xF717
        ]
        let specialKeys: [Int: UInt32] = [
            114: 0xF746, 115: 0xF729, 116: 0xF72C, 117: 0xF728,
            119: 0xF72B, 121: 0xF72D, 123: 0xF702, 124: 0xF703,
            125: 0xF701, 126: 0xF700
        ]
        if let scalar = functionKeys[keyCode] ?? specialKeys[keyCode] {
            return UnicodeScalar(scalar).map(String.init)
        }
        switch keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        case 71: return UnicodeScalar(0xF739).map(String.init)
        case 76: return "\u{3}"
        default: return nil
        }
    }
}

struct InvocationResult: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let targetName: String
    let menuPath: String
    let action: String?
    let previousFrontmostApp: String?
    let resultingFrontmostApp: String?
    let duration: TimeInterval
    let error: String?

    var succeeded: Bool { error == nil }
}

struct PendingInvocation: Identifiable {
    let id = UUID()
    let target: TargetApplication
    let node: MenuNode
    let menuPath: [String]
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
