import AppKit
import ApplicationServices
import Foundation

enum AccessibilityClientError: LocalizedError, Equatable {
    case permissionRequired
    case applicationUnavailable(pid_t)
    case attribute(String, AXError)
    case stalePath([Int])
    case unsupportedAction
    case limitExceeded
    case unsupportedWindow(String)
    case frameRejected
    case applicationQuitRejected

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Accessibility permission is required."
        case .applicationUnavailable(let pid):
            "Application with PID \(pid) is no longer running."
        case .attribute(let attribute, let error):
            "Could not read \(attribute) (AX error \(error.rawValue))."
        case .stalePath(let path):
            "The menu changed and path \(path.map(String.init).joined(separator: ".")) is stale. Refresh and try again."
        case .unsupportedAction:
            "The menu item does not expose AXPick or AXPress."
        case .limitExceeded:
            "The menu hierarchy exceeded Panoptos's safety limit."
        case .unsupportedWindow(let reason):
            "This window cannot be managed: \(reason)."
        case .frameRejected:
            "The application did not accept the requested window size."
        case .applicationQuitRejected:
            "The application did not accept the quit request."
        }
    }
}

struct AXWindowHandle: Hashable {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: AXWindowHandle, rhs: AXWindowHandle) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

struct AXWindowSnapshot {
    let handle: AXWindowHandle
    let pid: pid_t
    let accessibilityIdentifier: String?
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFullScreen: Bool
    let isResizable: Bool
    /// Finder moves this same public AXTabGroup between its per-tab windows.
    /// It is a session identity only; never serialize the Accessibility handle.
    let finderTabGroup: AXWindowHandle?

    init(
        handle: AXWindowHandle,
        pid: pid_t,
        accessibilityIdentifier: String? = nil,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        isFullScreen: Bool,
        isResizable: Bool,
        finderTabGroup: AXWindowHandle? = nil
    ) {
        self.handle = handle
        self.pid = pid
        self.accessibilityIdentifier = accessibilityIdentifier
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.isResizable = isResizable
        self.finderTabGroup = finderTabGroup
    }
}

@MainActor
protocol AccessibilityServing {
    var isTrusted: Bool { get }
    func requestPermission()
    func readMenu(pid: pid_t) throws -> [MenuNode]
    func invoke(pid: pid_t, indexPath: [Int], focusing window: AXWindowHandle?) throws -> String
    func focusedWindowFrame(pid: pid_t) throws -> CGRect
    func focusedWindow(pid: pid_t) throws -> AXWindowHandle
    func windows(pid: pid_t) throws -> [AXWindowSnapshot]
    func windowHandles(pid: pid_t) throws -> [AXWindowHandle]
    func window(atAccessibilityPoint point: CGPoint) throws -> AXWindowSnapshot
    func snapshot(window: AXWindowHandle) throws -> AXWindowSnapshot
    func selectedWindow(inFinderTabGroup group: AXWindowHandle) throws -> AXWindowHandle
    func setFrame(_ frame: CGRect, of window: AXWindowHandle) throws
    func isApplicationHidden(pid: pid_t) -> Bool
    func setApplicationHidden(_ hidden: Bool, pid: pid_t) throws
    func close(window: AXWindowHandle) throws
    func quitApplication(pid: pid_t) throws
    func raise(window: AXWindowHandle) throws
    func focus(window: AXWindowHandle, pid: pid_t) throws
}

extension AccessibilityServing {
    func selectedWindow(inFinderTabGroup group: AXWindowHandle) throws -> AXWindowHandle {
        throw AccessibilityClientError.unsupportedWindow("no Finder tab group is available")
    }
}

@MainActor
final class AccessibilityClient: AccessibilityServing {
    private let maximumDepth = 16
    private let maximumNodes = 4_000
    private static let framePositionTolerance: CGFloat = 2
    private static let frameSizeTolerance: CGFloat = 8

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func readMenu(pid: pid_t) throws -> [MenuNode] {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        let menuBar = try elementAttribute(application, kAXMenuBarAttribute as String)
        var nodeCount = 0
        let snapshots = try children(of: menuBar).map {
            try snapshot(element: $0, depth: 0, nodeCount: &nodeCount)
        }
        return MenuTreeParser.parse(snapshots)
    }

    func invoke(pid: pid_t, indexPath: [Int], focusing window: AXWindowHandle? = nil) throws -> String {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }

        if let window { try focus(window: window, pid: pid) }
        let application = AXUIElementCreateApplication(pid)
        var element = try elementAttribute(application, kAXMenuBarAttribute as String)
        for index in indexPath {
            let childElements = try children(of: element)
            guard childElements.indices.contains(index) else {
                throw AccessibilityClientError.stalePath(indexPath)
            }
            element = childElements[index]
        }

        let actions = try actionNames(of: element)
        guard let action = MenuActionSelector.preferredAction(in: actions) else {
            throw AccessibilityClientError.unsupportedAction
        }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else { throw AccessibilityClientError.attribute(action, result) }
        return action
    }

    func focusedWindowFrame(pid: pid_t) throws -> CGRect {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let window: AXUIElement
        do {
            window = try elementAttribute(application, kAXFocusedWindowAttribute as String)
        } catch {
            window = try elementAttribute(application, kAXMainWindowAttribute as String)
        }
        AXUIElementSetMessagingTimeout(window, 0.2)

        let position = try pointAttribute(window, kAXPositionAttribute as String)
        let size = try sizeAttribute(window, kAXSizeAttribute as String)
        return CGRect(origin: position, size: size)
    }

    func focusedWindow(pid: pid_t) throws -> AXWindowHandle {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        do {
            return AXWindowHandle(element: try elementAttribute(application, kAXFocusedWindowAttribute as String))
        } catch {
            return AXWindowHandle(element: try elementAttribute(application, kAXMainWindowAttribute as String))
        }
    }

    func windows(pid: pid_t) throws -> [AXWindowSnapshot] {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return try childrenAttribute(application, kAXWindowsAttribute as String)
            .compactMap { try? snapshot(window: AXWindowHandle(element: $0)) }
    }

    /// The application's own window list, without snapshotting each element.
    /// A window whose element has gone invalid is dropped by `windows(pid:)`,
    /// so only this raw list can tell a replaced element apart from a slow one.
    func windowHandles(pid: pid_t) throws -> [AXWindowHandle] {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return try childrenAttribute(application, kAXWindowsAttribute as String)
            .map { AXWindowHandle(element: $0) }
    }

    func window(atAccessibilityPoint point: CGPoint) throws -> AXWindowSnapshot {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        let system = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found)
        guard result == .success, var element = found else {
            throw AccessibilityClientError.attribute("window at pointer", result)
        }

        for _ in 0..<12 {
            // This walk runs on the main actor for every press outside Panoptos,
            // so no hop may inherit the six-second default: an application slow
            // to answer would stall the pointer while Panoptos decides whether a
            // drag started. The system-wide element is deliberately left alone —
            // a timeout set on it becomes this process's default for every
            // element, including the menu reads that ask for a longer one.
            AXUIElementSetMessagingTimeout(element, 0.2)
            let role: String? = optionalAttribute(element, kAXRoleAttribute as String)
            if role == (kAXWindowRole as String) {
                return try snapshot(window: AXWindowHandle(element: element))
            }
            guard let parent = try? elementAttribute(element, kAXParentAttribute as String) else { break }
            element = parent
        }
        throw AccessibilityClientError.unsupportedWindow("the pointer is not in a standard window")
    }

    func snapshot(window: AXWindowHandle) throws -> AXWindowSnapshot {
        let element = window.element
        AXUIElementSetMessagingTimeout(element, 0.2)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              application(pid: pid) != nil else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }

        let role: String = try requiredAttribute(element, kAXRoleAttribute as String)
        let subrole: String = try requiredAttribute(element, kAXSubroleAttribute as String)
        guard role == (kAXWindowRole as String), subrole == (kAXStandardWindowSubrole as String) else {
            throw AccessibilityClientError.unsupportedWindow("only standard application windows are supported")
        }
        let position = try pointAttribute(element, kAXPositionAttribute as String)
        let size = try sizeAttribute(element, kAXSizeAttribute as String)
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)

        let finderTabGroup: AXWindowHandle?
        if application(pid: pid)?.bundleIdentifier == "com.apple.finder" {
            // Inspect only direct window chrome, never the folder's contents.
            finderTabGroup = (try? children(of: element))?.first {
                AXUIElementSetMessagingTimeout($0, 0.2)
                let role: String? = optionalAttribute($0, kAXRoleAttribute as String)
                return role == kAXTabGroupRole as String
            }.map { AXWindowHandle(element: $0) }
        } else {
            finderTabGroup = nil
        }
        return AXWindowSnapshot(
            handle: window,
            pid: pid,
            accessibilityIdentifier: optionalAttribute(element, kAXIdentifierAttribute as String),
            title: optionalAttribute(element, kAXTitleAttribute as String) ?? "Window",
            frame: CGRect(origin: position, size: size),
            isMinimized: optionalAttribute(element, kAXMinimizedAttribute as String) ?? false,
            isFullScreen: optionalAttribute(element, "AXFullScreen") ?? false,
            isResizable: positionSettable.boolValue && sizeSettable.boolValue,
            finderTabGroup: finderTabGroup
        )
    }

    func selectedWindow(inFinderTabGroup group: AXWindowHandle) throws -> AXWindowHandle {
        AXUIElementSetMessagingTimeout(group.element, 0.2)
        return AXWindowHandle(element: try elementAttribute(group.element, kAXWindowAttribute as String))
    }

    func setFrame(_ frame: CGRect, of window: AXWindowHandle) throws {
        var size = frame.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityClientError.frameRejected
        }
        func setPosition(_ requestedPosition: CGPoint) throws {
            var position = requestedPosition
            guard let positionValue = AXValueCreate(.cgPoint, &position) else {
                throw AccessibilityClientError.frameRejected
            }
            let result = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
            guard result == .success else {
                throw AccessibilityClientError.attribute(kAXPositionAttribute as String, result)
            }
        }

        // Move onto the destination display before resizing. macOS and some apps
        // constrain size against the window's current monitor, which otherwise
        // leaves a cross-display move with the old monitor's dimensions.
        try setPosition(frame.origin)
        let sizeResult = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        guard sizeResult == .success else {
            throw AccessibilityClientError.attribute(kAXSizeAttribute as String, sizeResult)
        }
        // Resizing can adjust the origin to keep the title bar visible.
        try setPosition(frame.origin)
        let actual = try snapshot(window: window).frame
        guard let fitted = Self.fittedFrame(actualFrame: actual, within: frame) else {
            throw AccessibilityClientError.frameRejected
        }
        guard !Self.accepts(actualFrame: actual, requestedFrame: fitted) else { return }

        // Some standard windows expose a writable AXSize but clamp one or both
        // dimensions to an application-defined maximum. They are still valid
        // managed windows when the resulting size fits in the destination.
        try setPosition(fitted.origin)
        let centered = try snapshot(window: window).frame
        guard Self.accepts(actualFrame: centered, requestedFrame: fitted) else {
            throw AccessibilityClientError.frameRejected
        }
    }

    /// Returns the frame an application-constrained result should occupy in the
    /// requested destination. A meaningfully smaller result is centered;
    /// differences within the terminal-grid tolerance retain their requested
    /// origin, whether the quantized result is slightly smaller or larger.
    static func fittedFrame(actualFrame: CGRect, within requestedFrame: CGRect) -> CGRect? {
        let values = [
            actualFrame.minX, actualFrame.minY, actualFrame.width, actualFrame.height,
            requestedFrame.minX, requestedFrame.minY, requestedFrame.width, requestedFrame.height
        ]
        guard values.allSatisfy(\.isFinite),
              actualFrame.width > 0, actualFrame.height > 0,
              requestedFrame.width > 0, requestedFrame.height > 0 else { return nil }

        let isMeaningfullySmaller = requestedFrame.width - actualFrame.width > frameSizeTolerance
            || requestedFrame.height - actualFrame.height > frameSizeTolerance
        if isMeaningfullySmaller,
           actualFrame.width <= requestedFrame.width,
           actualFrame.height <= requestedFrame.height {
            return CGRect(
                x: requestedFrame.midX - actualFrame.width / 2,
                y: requestedFrame.midY - actualFrame.height / 2,
                width: actualFrame.width,
                height: actualFrame.height
            )
        }
        return accepts(actualFrame: actualFrame, requestedFrame: requestedFrame)
            ? actualFrame
            : nil
    }

    static func isSettled(actualFrame: CGRect, within requestedFrame: CGRect) -> Bool {
        guard let fitted = fittedFrame(actualFrame: actualFrame, within: requestedFrame) else {
            return false
        }
        return accepts(actualFrame: actualFrame, requestedFrame: fitted)
    }

    /// Terminal-style windows quantize their content area to whole character
    /// cells, so a successful AXSize write can legitimately land a few points
    /// from the requested dimensions. The origin remains strict so an app that
    /// keeps the window on another display or away from the section is rejected.
    static func accepts(actualFrame: CGRect, requestedFrame: CGRect) -> Bool {
        abs(actualFrame.minX - requestedFrame.minX) <= framePositionTolerance
            && abs(actualFrame.minY - requestedFrame.minY) <= framePositionTolerance
            && abs(actualFrame.width - requestedFrame.width) <= frameSizeTolerance
            && abs(actualFrame.height - requestedFrame.height) <= frameSizeTolerance
    }

    func isApplicationHidden(pid: pid_t) -> Bool {
        application(pid: pid)?.isHidden ?? false
    }

    /// Panoptos visibility modes hide applications this way: exactly what
    /// Command-H does, so windows disappear where they stand, instantly and
    /// without an animation, and come back in place.
    ///
    /// Hiding is per application, so callers must retain applications that own
    /// any window which should remain visible.
    func setApplicationHidden(_ hidden: Bool, pid: pid_t) throws {
        guard let application = application(pid: pid) else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }
        if hidden ? application.hide() : application.unhide() { return }
        // AppKit refuses for an application that is already in the requested
        // state, and occasionally for one that is mid-launch. The Accessibility
        // attribute is the same switch and answers definitively.
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let result = AXUIElementSetAttributeValue(
            element,
            kAXHiddenAttribute as CFString,
            hidden ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard result == .success else {
            throw AccessibilityClientError.attribute(kAXHiddenAttribute as String, result)
        }
    }

    /// `NSRunningApplication(processIdentifier:)` intermittently fails to
    /// resolve a live pid, so the workspace's own list corroborates it.
    private func application(pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
            ?? NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
    }

    /// Requests the same close operation as the window's native close button.
    /// The target application remains responsible for save confirmation and
    /// may cancel the close without Panoptos changing the managed window.
    func close(window: AXWindowHandle) throws {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        AXUIElementSetMessagingTimeout(window.element, 0.2)
        let closeButton = try elementAttribute(window.element, kAXCloseButtonAttribute as String)
        let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        guard result == .success else {
            throw AccessibilityClientError.attribute(kAXPressAction as String, result)
        }
    }

    /// Sends the application's normal termination request. This is not a
    /// force-quit: the application may ask to save documents or cancel.
    func quitApplication(pid: pid_t) throws {
        guard let application = application(pid: pid) else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }
        guard application.terminate() else {
            throw AccessibilityClientError.applicationQuitRejected
        }
    }

    /// Restores a section's active window to the top without activating its
    /// application or changing keyboard focus.
    func raise(window: AXWindowHandle) throws {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        AXUIElementSetMessagingTimeout(window.element, 0.2)
        let result = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        guard result == .success else {
            throw AccessibilityClientError.attribute(kAXRaiseAction as String, result)
        }
    }

    func focus(window: AXWindowHandle, pid: pid_t) throws {
        guard isTrusted else { throw AccessibilityClientError.permissionRequired }
        guard let application = application(pid: pid) else {
            throw AccessibilityClientError.applicationUnavailable(pid)
        }
        let applicationElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(applicationElement, 0.2)
        AXUIElementSetMessagingTimeout(window.element, 0.2)

        _ = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        try Self.performWindowFocus(
            isApplicationActive: application.isActive,
            selectWindow: {
                _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                return AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedWindowAttribute as CFString,
                    window.element
                )
            },
            activateApplication: { application.activate(options: []) },
            makeApplicationFrontmost: {
                AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            },
            raiseWindow: { try self.raise(window: window) }
        )
    }

    /// App activation brings its main/key windows forward. Select the requested
    /// window first so an old sibling (including an unattached one) does not
    /// come along. Already-active apps need only a window selection and raise.
    /// Closures keep the real activation sequence testable without controlling
    /// other applications from the test runner.
    static func performWindowFocus(
        isApplicationActive: Bool,
        selectWindow: () -> AXError,
        activateApplication: () -> Bool,
        makeApplicationFrontmost: () -> AXError,
        raiseWindow: () throws -> Void
    ) throws {
        if !isApplicationActive {
            // Some AX servers reject focus while inactive. Still prepare main
            // and key focus before activation, then retry the selection.
            _ = selectWindow()
            // AppKit accepting the request does not mean activation has
            // completed. Keep the AX write before retrying focus for servers
            // that reject selection while their application is inactive.
            let activationRequested = activateApplication()
            let result = makeApplicationFrontmost()
            guard activationRequested || result == .success else {
                throw AccessibilityClientError.attribute(kAXFrontmostAttribute as String, result)
            }
        }
        let focusedResult = selectWindow()
        guard focusedResult == .success else {
            throw AccessibilityClientError.attribute(kAXFocusedWindowAttribute as String, focusedResult)
        }
        try raiseWindow()
    }

    private func snapshot(
        element: AXUIElement,
        depth: Int,
        nodeCount: inout Int
    ) throws -> MenuSnapshot {
        guard depth <= maximumDepth, nodeCount < maximumNodes else {
            throw AccessibilityClientError.limitExceeded
        }
        nodeCount += 1

        return MenuSnapshot(
            title: optionalAttribute(element, kAXTitleAttribute as String),
            role: optionalAttribute(element, kAXRoleAttribute as String) ?? "AXUnknown",
            isEnabled: optionalAttribute(element, kAXEnabledAttribute as String),
            mark: optionalAttribute(element, kAXMenuItemMarkCharAttribute as String),
            commandCharacter: optionalAttribute(element, kAXMenuItemCmdCharAttribute as String),
            commandModifiers: optionalNumberAttribute(element, kAXMenuItemCmdModifiersAttribute as String),
            virtualKey: optionalNumberAttribute(element, kAXMenuItemCmdVirtualKeyAttribute as String),
            actions: (try? actionNames(of: element)) ?? [],
            children: try children(of: element).map {
                try snapshot(element: $0, depth: depth + 1, nodeCount: &nodeCount)
            }
        )
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement {
        let (error, value) = copyAttribute(element, attribute)
        guard error == .success, let value else {
            throw AccessibilityClientError.attribute(attribute, error)
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AccessibilityClientError.attribute(attribute, .illegalArgument)
        }
        return value as! AXUIElement
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        let (error, value) = copyAttribute(element, kAXChildrenAttribute as String)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else {
            throw AccessibilityClientError.attribute(kAXChildrenAttribute as String, error)
        }
        guard let values = value as? [AXUIElement] else { return [] }
        return values
    }

    private func childrenAttribute(_ element: AXUIElement, _ attribute: String) throws -> [AXUIElement] {
        let (error, value) = copyAttribute(element, attribute)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success else { throw AccessibilityClientError.attribute(attribute, error) }
        return value as? [AXUIElement] ?? []
    }

    private func optionalAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        let (error, value) = copyAttribute(element, attribute)
        guard error == .success else { return nil }
        return value as? T
    }

    private func requiredAttribute<T>(_ element: AXUIElement, _ attribute: String) throws -> T {
        let (error, value) = copyAttribute(element, attribute)
        guard error == .success, let typedValue = value as? T else {
            throw AccessibilityClientError.attribute(attribute, error == .success ? .illegalArgument : error)
        }
        return typedValue
    }

    private func optionalNumberAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        let value: NSNumber? = optionalAttribute(element, attribute)
        return value?.intValue
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        let (error, value) = copyAttribute(element, attribute)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityClientError.attribute(attribute, error)
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            throw AccessibilityClientError.attribute(attribute, .cannotComplete)
        }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) throws -> CGSize {
        let (error, value) = copyAttribute(element, attribute)
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            throw AccessibilityClientError.attribute(attribute, error)
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            throw AccessibilityClientError.attribute(attribute, .cannotComplete)
        }
        return size
    }

    private func actionNames(of element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success else { throw AccessibilityClientError.attribute("actions", error) }
        return names as? [String] ?? []
    }
}
