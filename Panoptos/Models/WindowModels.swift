import AppKit
import CryptoKit
import Foundation

struct ManagedWindow: Identifiable {
    let id: UUID
    var handle: AXWindowHandle
    let pid: pid_t
    let bundleIdentifier: String
    let accessibilityIdentifier: String?
    let windowOrdinal: Int
    let applicationName: String
    let icon: NSImage
    var title: String
    var isMinimized: Bool
    var finderTabGroup: AXWindowHandle? = nil
    /// False when the window server lists no on-screen window at this frame
    /// while the window is neither minimized nor in a hidden application: it
    /// is parked on another Space, or its application ordered it out without
    /// closing it, as menu bar applications do. Session-only; the assignment
    /// stays attached so the window returns to its section when it reappears.
    var isOnActiveSpace = true
    /// The last frame a snapshot reported, in Accessibility coordinates. It
    /// lets the window-server check still answer for a window whose snapshot
    /// is currently failing. Session-only and excluded from equality: a move
    /// must not repaint the switcher.
    var lastKnownFrame: CGRect = .zero

    var target: TargetApplication {
        TargetApplication(pid: pid, bundleIdentifier: bundleIdentifier, name: applicationName, icon: icon)
    }
}

extension ManagedWindow: Equatable {
    // Icon compares by object identity: NSImage equality is expensive and the
    // instance is stable for a window's lifetime.
    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.handle == rhs.handle
            && lhs.pid == rhs.pid
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.accessibilityIdentifier == rhs.accessibilityIdentifier
            && lhs.windowOrdinal == rhs.windowOrdinal
            && lhs.applicationName == rhs.applicationName
            && lhs.icon === rhs.icon
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.finderTabGroup == rhs.finderTabGroup
            && lhs.isOnActiveSpace == rhs.isOnActiveSpace
    }
}

struct LayoutSectionState: Identifiable, Equatable {
    let id: UUID
    var windows: [ManagedWindow] = []
    var activeWindowID: UUID?
    /// The layout sections a spanned section covers; empty for a layout
    /// section. A window spanned across several sections leaves its layout
    /// section for the spanned section derived from exactly this set, so it
    /// gets a switcher and menu bar of its own that sit above and below the
    /// whole spanned area instead of staying inside one of the old sections.
    var coveredSectionIDs: Set<UUID> = []

    var isSpanned: Bool { !coveredSectionIDs.isEmpty }

    var activeWindow: ManagedWindow? {
        windows.first { $0.id == activeWindowID } ?? windows.last
    }

    /// The windows the switcher renders. Attached windows that are off screen
    /// keep their assignment but not their icon.
    var visibleWindows: [ManagedWindow] {
        windows.filter(\.isOnActiveSpace)
    }

    var hasVisibleWindows: Bool {
        windows.contains(where: \.isOnActiveSpace)
    }
}

/// A spanned section is identified by the layout sections it covers, not by
/// a stored identifier: the same span is the same section in every session,
/// and the assignment file keeps recording a home layout section plus the
/// additional ones it already knew about.
enum SpannedSectionIdentity {
    static func id(covering sectionIDs: Set<UUID>) -> UUID {
        let joined = sectionIDs.map(\.uuidString).sorted().joined(separator: "+")
        let digest = Array(SHA256.hash(data: Data(joined.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// The stable metadata Panoptos needs while discovering windows that
/// have not been attached to a section. Keeping this separate from
/// `NSRunningApplication` makes discovery deterministic in model tests and
/// prevents a transient UI feature from owning an application object.
struct RunningApplicationSnapshot: Equatable {
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    /// Supplied by tests or an already-resolved caller. Live roster snapshots
    /// deliberately leave this nil so merely activating an application does
    /// not synchronously ask IconServices for every running app's icon.
    let icon: NSImage?
    let isHidden: Bool
    let activationPolicy: NSApplication.ActivationPolicy

    init(application: NSRunningApplication) {
        pid = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        applicationName = application.localizedName
            ?? application.bundleIdentifier
            ?? "PID \(application.processIdentifier)"
        icon = nil
        isHidden = application.isHidden
        activationPolicy = application.activationPolicy
    }

    init(
        pid: pid_t,
        bundleIdentifier: String,
        applicationName: String,
        icon: NSImage?,
        isHidden: Bool,
        activationPolicy: NSApplication.ActivationPolicy = .regular
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.icon = icon
        self.isHidden = isHidden
        self.activationPolicy = activationPolicy
    }

    /// Lets the roster tell an unchanged rebuild apart from a real change, so
    /// activating an already-running application does not publish an overlay
    /// repaint that renders exactly what is already on screen.
    static func == (lhs: RunningApplicationSnapshot, rhs: RunningApplicationSnapshot) -> Bool {
        lhs.pid == rhs.pid
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.applicationName == rhs.applicationName
            && lhs.icon === rhs.icon
            && lhs.isHidden == rhs.isHidden
            && lhs.activationPolicy == rhs.activationPolicy
    }
}

/// Resolves an application's icon without making the common case more
/// expensive. `NSRunningApplication.icon` remains the first and normally only
/// image the answer is built from.
///
/// Two Steam-shaped problems sit behind that. Chromium-derived clients draw
/// their windows from a helper process whose nested bundle carries no icon, and
/// AppKit answers that helper's `icon` with the generic application placeholder
/// rather than nil, so the enclosing host bundle has to supply the image. And a
/// self-updating client runs from an extension-less bundle LaunchServices never
/// registered, which IconServices answers with the legacy `CFBundleIconFile`
/// instead of the asset-catalog icon the Dock shows, so that one layout defers
/// to the registered copy of the same bundle identifier.
enum ApplicationIconResolver {
    static func icon(for application: NSRunningApplication) -> NSImage {
        resolve(
            processIcon: application.icon,
            bundleURL: application.bundleURL,
            isGenericIcon: isGenericApplicationIcon(_:),
            hostBundleURL: { hostBundleURL(for: $0) },
            registeredBundleURL: registeredBundleURL(for:),
            bundleIconLoader: { NSWorkspace.shared.icon(forFile: $0.path) },
            genericIconLoader: {
                NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            }
        )
    }

    /// An application in an `.app` bundle has no registered copy to redirect to
    /// and an icon of its own, so it settles on the process icon after one
    /// comparison. Only the extension-less updater layout or a helper pays for
    /// the lookups below it. The generic host icon is rejected too, otherwise a
    /// nested bundle whose own icon happens to be usable would be downgraded.
    static func resolve(
        processIcon: NSImage?,
        bundleURL: URL?,
        isGenericIcon: (NSImage) -> Bool,
        hostBundleURL: (URL) -> URL?,
        registeredBundleURL: (URL) -> URL?,
        bundleIconLoader: (URL) -> NSImage?,
        genericIconLoader: () -> NSImage
    ) -> NSImage {
        func registeredIcon(forBundleAt url: URL) -> NSImage? {
            guard let registered = registeredBundleURL(url),
                  let icon = bundleIconLoader(registered),
                  !isGenericIcon(icon) else { return nil }
            return icon
        }

        if let bundleURL, let registered = registeredIcon(forBundleAt: bundleURL) { return registered }
        if let processIcon, !isGenericIcon(processIcon) { return processIcon }
        if let bundleURL, let hostURL = hostBundleURL(bundleURL) {
            if let registered = registeredIcon(forBundleAt: hostURL) { return registered }
            if let hostIcon = bundleIconLoader(hostURL), !isGenericIcon(hostIcon) { return hostIcon }
        }
        if let processIcon { return processIcon }
        if let bundleURL, let bundleIcon = bundleIconLoader(bundleURL) { return bundleIcon }
        return genericIconLoader()
    }

    /// The installed copy LaunchServices resolves this bundle's identifier to.
    ///
    /// Deliberately restricted to a bundle that is not an `.app`, which is the
    /// updater layout Steam runs its client from. LaunchServices registers
    /// `.app` bundles, so an extension-less one is never the registered copy and
    /// is exactly the case IconServices answers with the legacy
    /// `CFBundleIconFile` fallback. An ordinary duplicate — a portable, preview,
    /// developer, or external-volume copy sharing an installed application's
    /// bundle identifier — is an `.app` and keeps its own process icon rather
    /// than borrowing the installed copy's.
    static func registeredBundleURL(for bundleURL: URL) -> URL? {
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") != .orderedSame,
              let identifier = Bundle(url: bundleURL)?.bundleIdentifier,
              let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
              registered.path != bundleURL.resolvingSymlinksInPath().path else { return nil }
        return registered
    }

    /// AppKit answers a bundle that carries no icon with the generic
    /// application placeholder rather than nil, so the only reliable test is
    /// the image itself. A 16-point rasterization keeps the comparison to about
    /// a kilobyte, and the model caches the outcome per process identity.
    static func isGenericApplicationIcon(_ icon: NSImage) -> Bool {
        guard let genericThumbnail, let thumbnail = thumbnail(for: icon) else { return false }
        return thumbnail == genericThumbnail
    }

    private static let genericThumbnail: Data? =
        thumbnail(for: NSWorkspace.shared.icon(for: .applicationBundle))

    static func thumbnail(for icon: NSImage) -> Data? {
        let size = NSSize(width: 16, height: 16)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = representation.bitmapData else { return nil }
        return Data(bytes: bytes, count: representation.bytesPerRow * representation.pixelsHigh)
    }

    /// Walks out of a nested helper to the application bundle that contains it.
    /// The walk is bounded, runs only for a process whose own icon is the
    /// generic placeholder, and is cached per process identity by the model, so
    /// it costs a handful of `stat` calls once per helper.
    static func hostBundleURL(
        for bundleURL: URL,
        containsBundle: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }
    ) -> URL? {
        var candidate = bundleURL.resolvingSymlinksInPath()
        for _ in 0..<8 {
            guard candidate.pathComponents.count > 2 else { return nil }
            candidate.deleteLastPathComponent()
            if containsBundle(candidate) { return candidate }
        }
        return nil
    }
}

/// One resolved icon per live process identity. Besides avoiding repeated
/// IconServices and bundle reads for multi-window applications, retaining the
/// same image instance prevents unnecessary overlay view updates.
struct CachedApplicationIcon {
    let bundleIdentifier: String
    let icon: NSImage
}

/// A live, selectable window that remains outside Panoptos' managed layout.
/// Its frame is stored in AppKit coordinates so grouping does not perform AX
/// work or coordinate conversion while repainting the overlay.
struct UnattachedWindow: Equatable {
    let handle: AXWindowHandle
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let icon: NSImage
    var title: String
    var frame: CGRect
    var isMinimized: Bool
    /// False while the window sits on another Space, including a native
    /// full-screen Space. Such a window still reports a frame inside a
    /// display, so nothing in the Accessibility API distinguishes it.
    var isOnActiveSpace: Bool
    let discoveryOrder: Int

    static func == (lhs: UnattachedWindow, rhs: UnattachedWindow) -> Bool {
        lhs.handle == rhs.handle
            && lhs.pid == rhs.pid
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.applicationName == rhs.applicationName
            && lhs.icon === rhs.icon
            && lhs.title == rhs.title
            && lhs.frame == rhs.frame
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isOnActiveSpace == rhs.isOnActiveSpace
            && lhs.discoveryOrder == rhs.discoveryOrder
    }
}

struct UnattachedWindowGroupKey: Hashable {
    let sectionID: UUID
    let bundleIdentifier: String
}

/// One bare application icon at the end of a section switcher's scrollable
/// content. A group is local to that section so the same application may have
/// an icon on several displays, each cycling only the nearby unattached windows.
struct UnattachedWindowApplicationGroup: Identifiable, Equatable {
    let id: UnattachedWindowGroupKey
    let applicationName: String
    let icon: NSImage
    let windows: [UnattachedWindow]
    let nextWindowTitle: String

    static func == (lhs: UnattachedWindowApplicationGroup, rhs: UnattachedWindowApplicationGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.applicationName == rhs.applicationName
            && lhs.icon === rhs.icon
            && lhs.windows == rhs.windows
            && lhs.nextWindowTitle == rhs.nextWindowTitle
    }
}
