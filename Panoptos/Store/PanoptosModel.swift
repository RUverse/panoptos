import AppKit
import Combine
import Foundation
import OSLog
import ServiceManagement

enum AutomaticWindowAttachmentResult: Equatable {
    case attached
    case retry
    case ignored
}

/// The store is split across `PanoptosModel+*.swift`, and Swift scopes
/// `private` to a single file, so this type's state is declared without access
/// modifiers rather than as `private(set)`. That is a consequence of the file
/// layout, not an invitation: **views must treat every property here as
/// read-only** and go through the model's methods to change anything.
///
/// - `PanoptosModel+Layout`: displays, section geometry, coordinate spaces.
/// - `PanoptosModel+Lifecycle`: runtime reconciliation, system transitions,
///   and the only paths that may detach a window.
/// - `PanoptosModel+Persistence`: window assignments and their restoration.
/// - `PanoptosModel+Navigation`: shortcut-driven focus and window movement.
/// - `PanoptosModel+Shortcuts`: shortcut configuration and registration.
/// - `PanoptosModel+Settings`: preferences, keep awake, login item.
@MainActor
final class PanoptosModel: ObservableObject {
    nonisolated static let chromeHeight: CGFloat = 38

    @Published var layouts: [DisplayLayout]
    @Published var currentDisplays: [CurrentDisplay] = []
    @Published var sections: [UUID: LayoutSectionState] = [:]
    /// Durable application-level pairs within each section. Views read this
    /// state, but mutations go through the split methods in the layout store.
    @Published var applicationSplitPairs: [UUID: [ApplicationSplitPair]] = [:]
    @Published var menusByPID: [pid_t: [MenuNode]] = [:]
    /// Transient per-zone messages (e.g. "Xcode doesn't fit here") shown
    /// centered in the zone by the overlay and cleared automatically.
    @Published var sectionNotices: [UUID: String] = [:]
    /// The managed window that is focused system-wide (frontmost application's
    /// focused window), or nil when focus is outside every managed window.
    var focusedManagedWindowID: UUID?
    /// A focused selectable window outside the managed layout. This is kept
    /// separate from `focusedManagedWindowID`: free windows never become a
    /// section's active window merely because their icon was clicked.
    var focusedUnattachedWindowHandle: AXWindowHandle?
    /// Called when what the overlay renders has changed — which window is
    /// focused, or which sections are on screen. The overlay repaints its bars
    /// from this rather than waiting for the next reconciliation pass:
    /// reconciliation costs a blocking Accessibility read per managed window,
    /// which is long enough for the change to visibly trail the click or
    /// shortcut that caused it.
    var onOverlayPresentationChanged: (() -> Void)?
    /// Called after the running-application roster changes which processes need
    /// application-level AX observation. The overlay synchronizes those
    /// observers immediately, before a launch-era AXWindows read can miss the
    /// application's first window-created notification.
    var onUnattachedApplicationRosterChanged: (() -> Void)?
    /// The section that currently has the screen to itself, or nil when every
    /// section is visible. Deliberately session-only: focus mode ends the
    /// moment focus leaves the section, so there is no state left to restore at
    /// the next launch, and restoring one would hide windows unprompted.
    @Published var focusedSectionID: UUID?
    @Published var shortcuts: [ShortcutCommand: GlobalShortcut]
    /// Commands the user cleared on purpose. Saved beside the bindings so a
    /// later default for one of them is not installed over that choice.
    var disabledShortcutCommands: Set<ShortcutCommand> = []
    @Published private(set) var isAccessibilityTrusted = false
    @Published var permissionRelaunchError: String?
    @Published var compatibilityError: String?
    @Published var shortcutError: String?
    @Published var windowDragShortcuts: WindowDragShortcuts { didSet { persistSettings() } }
    @Published var sectionBarsFillAvailableWidth: Bool { didSet { persistSettings() } }
    @Published var sectionBarsCentered: Bool { didSet { persistSettings() } }
    /// Hiding the menu bars also returns their reserved strip to the window, so
    /// every managed window has to be reflowed when this changes.
    @Published var showWindowMenuBars: Bool {
        didSet {
            guard showWindowMenuBars != oldValue else { return }
            persistSettings()
            reflowManagedWindows()
        }
    }
    @Published var showUnattachedWindowIcons: Bool {
        didSet {
            guard showUnattachedWindowIcons != oldValue else { return }
            persistSettings()
            if showUnattachedWindowIcons {
                // The roster rebuild queues every application for the paced
                // seed and publishes the change that starts it, so there is
                // nothing left to enumerate synchronously here.
                refreshUnattachedApplicationRoster()
            } else {
                clearUnattachedWindowState()
            }
            onOverlayPresentationChanged?()
        }
    }
    @Published var windowSwitcherUIScale: Double
    @Published var windowSwitcherTitleMode: WindowSwitcherTitleMode { didSet { persistSettings() } }
    @Published var limitWindowSwitcherTitleCharacters: Bool { didSet { persistSettings() } }
    @Published var invokeWithoutActivation: Bool { didSet { persistSettings() } }
    /// Mirrors the system login-item state. Writes go straight to
    /// ServiceManagement; nothing is stored in Panoptos' own settings file.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    @Published var launchAtLoginNotice: String?
    /// True when only the user can resolve the state, in System Settings.
    @Published var launchAtLoginNeedsSystemSettings = false
    @Published var keepMacAwake: Bool {
        didSet {
            if !keepMacAwake, keepScreenOn {
                keepScreenOn = false
            }
            persistSettings()
            updateKeepAwakeActivity()
        }
    }
    @Published var keepScreenOn: Bool {
        didSet {
            if keepScreenOn, !keepMacAwake {
                keepMacAwake = true
            }
            persistSettings()
            updateKeepAwakeActivity()
        }
    }
    /// Whether the welcome tour has been dismissed. Durable so the tour opens
    /// with the first settings window and never again on its own; the General
    /// tab can replay it without clearing this.
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            guard hasCompletedOnboarding != oldValue else { return }
            persistSettings()
        }
    }

    let accessibility: AccessibilityServing
    let persistence: LayoutPersistence
    let windowAssignmentPersistence: WindowAssignmentPersistence
    let settingsPersistence: SettingsPersistence
    let shortcutPersistence: ShortcutPersistence
    let shortcutRegistrar: ShortcutRegistering
    let keepAwakeController: KeepAwakeControlling
    let loginItemController: LoginItemControlling
    let updateController: UpdateControlling
    let displayProvider: () -> [CurrentDisplay]
    let runningApplicationSnapshotsProvider: () -> [RunningApplicationSnapshot]
    /// On-screen window frames per pid, in Accessibility coordinates, or nil
    /// when the window server could not be asked. Accessibility cannot say
    /// which Space a window sits on, and this is the only public answer.
    let onScreenWindowFramesProvider: () -> [pid_t: [CGRect]]?
    /// Panoptos' own pid. Focus mode compares the frontmost application against
    /// it so its settings window and overlay menus do not count as the user
    /// switching away from the focused section.
    let ownProcessIdentifier: pid_t
    var isSyncingLaunchAtLogin = false
    var windowDragShortcutValidationError: String?
    var workspaceObservers: [NSObjectProtocol] = []
    var permissionPoller: AnyCancellable?
    var isWindowManagementRuntimeStarted = false
    var onWindowManagementRuntimeChanged: ((Bool) -> Void)?
    var previewLayouts: [String: DisplayLayout] = [:]
    var previewSectionsBackup: [UUID: LayoutSectionState]?
    var previewApplicationSplitPairsBackup: [UUID: [ApplicationSplitPair]]?
    var previewRaisedSpannedSectionIDsBackup: Set<UUID>?
    /// The spanned sections currently on top of the sections they cover. A
    /// span and the sections beneath it are layers over the same area, and
    /// only the layer on top draws its bars; focusing a window puts its layer
    /// on top. Session-only: the next launch learns it from the first focus.
    var raisedSpannedSectionIDs: Set<UUID> = []
    var loadingMenus: Set<pid_t> = []
    var noticeGeneration = 0
    /// Session-only application presentation state. The icon cache is shared
    /// by managed and unattached windows so multi-window applications resolve
    /// IconServices at most once per process identity.
    var unattachedApplicationsByPID: [pid_t: RunningApplicationSnapshot] = [:]
    var applicationIconsByPID: [pid_t: CachedApplicationIcon] = [:]
    var unattachedWindowsByHandle: [AXWindowHandle: UnattachedWindow] = [:]
    var unattachedCycleCursors: [UnattachedWindowGroupKey: AXWindowHandle] = [:]
    /// Newly observed applications get one prompt, paced AX enumeration so
    /// their icons do not depend on the user activating them first. The idle
    /// compatibility pass continues to revisit applications after this
    /// one-time seed.
    var unattachedApplicationPIDsAwaitingSeed: Set<pid_t> = []
    /// Applications whose seed read came back empty. They keep their pending
    /// seed, so a later targeted refresh still counts as the first real
    /// enumeration, but the paced pass stops revisiting them.
    var unattachedApplicationPIDsWithEmptySeedRead: Set<pid_t> = []
    var nextUnattachedWindowDiscoveryOrder = 0
    var lastUnattachedDiscoveryPID: pid_t?
    var savedWindowAssignments: [PersistedWindowAssignment]
    var didAttemptWindowRestoration = false
    var snapshotFailures: Set<UUID> = []
    var invalidSnapshotFirstFailure: [UUID: Date] = [:]
    /// The last section in which each application was confirmed focused. A new
    /// window can become the AX focused window before its creation notification
    /// is handled, making `focusedManagedWindowID` temporarily nil; this memory
    /// preserves the intended destination through that notification race.
    var lastFocusedSectionByPID: [pid_t: UUID] = [:]
    /// Assignments whose windows are temporarily absent. This includes windows
    /// dropped by the invalid-element heuristic, explicitly closed windows
    /// awaiting a reopen, and windows whose application quit so a future
    /// instance can reclaim their sections.
    var orphanedAssignments: [PersistedWindowAssignment] = []
    var nextOrphanRecoveryAttempt: Date?
    /// AX destruction can arrive just before the workspace reports that the
    /// whole application quit. Hold those records briefly so termination can
    /// convert the record into an application-relaunch assignment; otherwise
    /// it becomes a durable window-reopen assignment for the same process.
    var pendingDestroyedWindows: [UUID: (
        pid: pid_t,
        bundleIdentifier: String,
        finalizationDeadline: Date
    )] = [:]
    /// Exact process identities already corroborated for dormant closed-window
    /// records. This avoids rescanning NSWorkspace on every overlay reconcile;
    /// persisted records are validated once when restoration is prepared.
    var windowReopenObservationIdentities: [pid_t: String] = [:]
    /// The one newly launched process currently allowed to use each bundle's
    /// relaunch-only ordinal records. Repeated activations of that same process
    /// must not keep extending stale recovery indefinitely.
    var applicationRelaunchRecoveryPIDs: [String: pid_t] = [:]
    /// Live windows the user detached in this session, by owning process. A
    /// detached window stays visible and still belongs to an application that
    /// may own other attached windows, so automatic placement, orphan recovery,
    /// and relaunch recovery could otherwise reclaim it moments later. Only an
    /// explicit attachment lifts the exemption; window destruction and
    /// application termination drop the dead handles. Session-only: AX handles
    /// cannot be persisted.
    var userDetachedWindowHandles: [pid_t: Set<AXWindowHandle>] = [:]
    /// Creation events received while AX is unsettled survive the observer's
    /// short retry. Session-only handles, in arrival order. A nil retry date
    /// means no settled attempt has run; otherwise exactly one retry remains.
    var pendingWindowCreations: [(handle: AXWindowHandle, pid: pid_t, retryAfter: Date?)] = []
    /// A display change can temporarily replace AX window elements. Keep
    /// retrying the resulting zone reflow from normal runtime refreshes until
    /// every current handle accepts its destination frame.
    var needsDisplayTopologyReflow = false
    var nextDisplayTopologyReflowAttempt: Date?
    var displayTopologyReflowDeadline: Date?
    /// Applications Panoptos hid to enter focus mode. Leaving focus mode shows
    /// exactly these again, so an application the user had already hidden stays
    /// hidden.
    var focusModeHiddenApplications: Set<HiddenApplication> = []
    /// Applications hidden behind the currently selected application split
    /// group. Kept separate from focus mode so each feature restores exactly
    /// the applications it hid and never undoes the user's own Command-H.
    var applicationSplitHiddenApplications: Set<HiddenApplication> = []
    /// A close during sleep, wake settling, or display reconfiguration cannot
    /// safely resize the surviving half immediately. Retry once AX is stable.
    var needsApplicationSplitReflow = false
    /// Window ordering can settle after the AX hidden attribute has already
    /// accepted `false`. Keep the affected sections until workspace unhide
    /// notifications (or a bounded fallback) let us reassert their active
    /// windows after that asynchronous transition.
    var pendingHiddenApplicationWindowOrderRestoration: HiddenApplicationWindowOrderRestoration?
    /// When choosing a free window exits focus mode, asynchronous unhide
    /// corrections may briefly raise managed windows afterward. Reassert this
    /// explicit target after each correction while it remains the known focus.
    var pendingUnattachedFocusReassertion: (handle: AXWindowHandle, pid: pid_t)?
    var hiddenApplicationWindowOrderRestorationGeneration = 0
    /// Activation is asynchronous, so the frontmost application can still be
    /// the previous one for a moment after focus mode focuses its section. The
    /// mode is not allowed to end on its own before this passes.
    var focusModeSettleDeadline: Date?
    /// Sleep, screen-sleep, and session-lock states that are currently active.
    /// Tracked as a set rather than a count so an unpaired notification cannot
    /// leave Panoptos permanently convinced the system is asleep.
    var activeSystemTransitions: Set<SystemTransition> = []
    /// Set when a transition ends or the displays reconfigure, so AX keeps its
    /// grace period while windows are still being moved back into place.
    var transitionSettleDeadline: Date?
    let now: () -> Date
    let lifecycleLogger = Logger(subsystem: "ai.ruverse.Panoptos", category: "WindowLifecycle")

    /// An invalid AX element is only authoritative once the owning application
    /// stops listing it. Sleep, screen lock, and display reconfiguration all
    /// invalidate live elements for seconds at a time without closing anything,
    /// so the window has to keep failing for this long before it is dropped.
    static let invalidWindowFailureDuration: TimeInterval = 10
    /// How long AX stays untrusted after a wake, unlock, or display change.
    static let transitionSettleInterval: TimeInterval = 15
    /// Bounds idle retries. Saved records survive expiry and become eligible
    /// again on recovery events or an explicit refresh, using descriptor matching.
    static let orphanRetentionInterval: TimeInterval = 600
    static let orphanRecoveryInterval: TimeInterval = 2
    static let windowDestructionTerminationGraceInterval: TimeInterval = 1
    static let windowDestructionTerminationMaxWait: TimeInterval = 10
    static let displayTopologyReflowRetryInterval: TimeInterval = 2
    static let displayTopologyReflowRetryDuration: TimeInterval = 60
    static let windowCreationRetryInterval: TimeInterval = 0.25
    /// How long focus mode ignores an apparently foreign focus right after it
    /// was entered, while the section's own application comes forward.
    static let focusModeSettleInterval: TimeInterval = 2
    static let hiddenApplicationWindowOrderSettleInterval: TimeInterval = 0.75

    init(
        accessibility: AccessibilityServing? = nil,
        persistence: LayoutPersistence = .live,
        windowAssignmentPersistence: WindowAssignmentPersistence = .live,
        settingsPersistence: SettingsPersistence = .live,
        shortcutPersistence: ShortcutPersistence = .live,
        shortcutRegistrar: ShortcutRegistering? = nil,
        keepAwakeController: KeepAwakeControlling? = nil,
        loginItemController: LoginItemControlling? = nil,
        // Constructing the live controller starts Sparkle's scheduled check
        // cycle, so tests supply their own rather than letting a test run reach
        // the update feed.
        updateController: UpdateControlling? = nil,
        displayProvider: (() -> [CurrentDisplay])? = nil,
        runningApplicationSnapshotsProvider: (() -> [RunningApplicationSnapshot])? = nil,
        onScreenWindowFramesProvider: (() -> [pid_t: [CGRect]]?)? = nil,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        now: @escaping () -> Date = Date.init
    ) {
        self.ownProcessIdentifier = ownProcessIdentifier
        self.now = now
        self.accessibility = accessibility ?? AccessibilityClient()
        self.persistence = persistence
        self.windowAssignmentPersistence = windowAssignmentPersistence
        self.settingsPersistence = settingsPersistence
        self.shortcutPersistence = shortcutPersistence
        let registrar = shortcutRegistrar ?? GlobalShortcutRegistrar()
        self.shortcutRegistrar = registrar
        self.keepAwakeController = keepAwakeController ?? ProcessInfoKeepAwakeController()
        self.updateController = updateController ?? SparkleUpdateController()
        self.displayProvider = displayProvider ?? {
            NSScreen.screens.map {
                CurrentDisplay(
                    fingerprint: DisplayFingerprint.current(for: $0),
                    frame: $0.frame,
                    visibleFrame: $0.visibleFrame,
                    scale: $0.backingScaleFactor
                )
            }
        }
        self.runningApplicationSnapshotsProvider = runningApplicationSnapshotsProvider ?? {
            NSWorkspace.shared.runningApplications.map(RunningApplicationSnapshot.init(application:))
        }
        self.onScreenWindowFramesProvider = onScreenWindowFramesProvider
            ?? Self.currentOnScreenWindowFrames
        let loginItem = loginItemController ?? SMAppServiceLoginItemController()
        self.loginItemController = loginItem
        let loginItemState = loginItem.state
        launchAtLogin = loginItemState == .enabled
        launchAtLoginNeedsSystemSettings = loginItemState == .requiresApproval
        launchAtLoginNotice = Self.launchAtLoginNotice(for: loginItemState)
        layouts = persistence.load()
        savedWindowAssignments = windowAssignmentPersistence.load()
        let shortcutState = shortcutPersistence.loadState()
        shortcuts = shortcutState.bindings
        disabledShortcutCommands = shortcutState.disabledCommands
        let settings = settingsPersistence.load()
        windowDragShortcuts = settings.windowDragShortcuts
        sectionBarsFillAvailableWidth = settings.sectionBarsFillAvailableWidth
        sectionBarsCentered = settings.sectionBarsCentered
        showWindowMenuBars = settings.showWindowMenuBars
        showUnattachedWindowIcons = settings.showUnattachedWindowIcons
        windowSwitcherUIScale = settings.windowSwitcherUIScale
        windowSwitcherTitleMode = settings.windowSwitcherTitleMode
        limitWindowSwitcherTitleCharacters = settings.limitWindowSwitcherTitleCharacters
        invokeWithoutActivation = settings.invokeWithoutActivation
        keepMacAwake = settings.keepMacAwake
        keepScreenOn = settings.keepScreenOn
        hasCompletedOnboarding = settings.hasCompletedOnboarding
        refreshDisplays()
        registrar.handler = { [weak self] command in
            Task { @MainActor in self?.performShortcut(command) }
        }
        startWindowManagementRuntime()
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let defaultCenter = NotificationCenter.default
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
            defaultCenter.removeObserver(observer)
        }
        keepAwakeController.stopPreventingIdleSystemSleep()
        keepAwakeController.stopPreventingIdleDisplaySleep()
    }

    func requestAccessibilityPermission() {
        guard hasWindowManagementAccess else { return }
        accessibility.requestPermission()
        refreshPermissionState()
    }

    func activateShortcuts() {
        refreshShortcutRegistration()
    }

    func refreshPermissionState() {
        guard hasWindowManagementAccess else { return }
        let wasTrusted = isAccessibilityTrusted
        isAccessibilityTrusted = accessibility.isTrusted
        if wasTrusted != isAccessibilityTrusted { refreshShortcutRegistration() }
        if isAccessibilityTrusted {
            permissionRelaunchError = nil
            if !wasTrusted {
                renewOrphanRecovery()
                restoreWindowAssignmentsIfNeeded()
                refreshUnattachedApplicationRoster()
                refreshRuntime()
            }
        }
    }

    func checkAccessibilityPermission() {
        guard hasWindowManagementAccess else { return }
        refreshPermissionState()
        guard isAccessibilityTrusted else {
            permissionRelaunchError = "macOS still reports this Panoptos build as untrusted. Relaunch it after granting access."
            return
        }
        refreshDisplays()
        refreshRuntime()
    }

    func relaunchForAccessibilityPermission() {
        permissionRelaunchError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApplication.shared.terminate(nil) }
        } catch {
            permissionRelaunchError = "Could not relaunch Panoptos: \(error.localizedDescription)"
        }
    }

    func attach(window snapshot: AXWindowSnapshot, to sectionID: UUID) {
        guard hasWindowManagementAccess else { return }
        attach(window: snapshot, to: sectionID, focusAfterAttachment: true)
    }

    func attachApplicationWindows(containing draggedWindow: AXWindowSnapshot, to sectionID: UUID) {
        guard hasWindowManagementAccess else { return }
        let applicationWindows = (try? accessibility.windows(pid: draggedWindow.pid)) ?? []
        let listedHandles = (try? accessibility.windowHandles(pid: draggedWindow.pid)).map(Set.init)
        let otherWindows = applicationWindows.filter { $0.handle != draggedWindow.handle }

        for snapshot in otherWindows where snapshot.isResizable && !snapshot.isFullScreen {
            attach(
                window: snapshot,
                to: sectionID,
                focusAfterAttachment: false,
                knownApplicationWindows: applicationWindows,
                knownListedHandles: listedHandles
            )
        }
        attach(
            window: draggedWindow,
            to: sectionID,
            focusAfterAttachment: true,
            knownApplicationWindows: applicationWindows,
            knownListedHandles: listedHandles
        )
    }

    /// Places a newly opened window beside the application's existing managed
    /// windows. The application's last confirmed focused section wins when it
    /// has windows in more than one section; otherwise display/layout order is
    /// the fallback. Creations during a system transition wait for runtime
    /// reconciliation after settling; incomplete AX attributes then get the
    /// same one deferred retry as an ordinary creation.
    @discardableResult
    func attachNewlyCreatedWindow(
        _ handle: AXWindowHandle,
        pid: pid_t,
        reportedFrontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        isDeferredRetry: Bool = false
    ) -> AutomaticWindowAttachmentResult {
        guard hasWindowManagementAccess else { return .ignored }
        reconcileFinderTabs(pid: pid)
        guard managedWindow(matching: handle) == nil else { return .ignored }
        // Some applications announce an existing window again, and a detached
        // window's application usually still owns attached windows. The user
        // just opted this window out; only an explicit attachment brings it back.
        guard !isUserDetached(handle, pid: pid) else { return .ignored }
        if isInSystemTransition {
            if !pendingWindowCreations.contains(where: { $0.handle == handle }) {
                pendingWindowCreations.append((handle, pid, nil))
            }
            return .retry
        }
        // The observer's 0.25-second callback may straddle the settle deadline.
        // Leave queued events to reconciliation so that callback cannot consume
        // the only retry before the first real attachment attempt has run.
        guard !pendingWindowCreations.contains(where: { $0.handle == handle }) else { return .retry }
        if let reopened = recoverReopenedWindow(handle, pid: pid) {
            return isDeferredRetry && reopened == .retry ? .ignored : reopened
        }
        if let replaced = recoverReplacedWindow(handle, pid: pid) {
            return isDeferredRetry && replaced == .retry ? .ignored : replaced
        }
        prepareApplicationRelaunchRecovery(
            pid: pid,
            bundleIdentifier: runningApplication(pid: pid)?.bundleIdentifier
        )
        if hasAwaitingApplicationRelaunch(pid: pid) {
            _ = recoverApplicationRelaunchWindows(pid: pid)
            if managedWindow(matching: handle) != nil { return .attached }
            // A relaunch record owns placement while it is pending. In
            // particular, do not let a newly created second window follow the
            // first restored window into the wrong section.
            return isDeferredRetry ? .ignored : .retry
        }
        guard let sectionID = automaticAttachmentSectionID(for: pid) else { return .ignored }
        let snapshot: AXWindowSnapshot
        do {
            snapshot = try accessibility.snapshot(window: handle)
        } catch {
            return isDeferredRetry ? .ignored : .retry
        }
        guard snapshot.pid == pid, !snapshot.isFullScreen else { return .ignored }
        // AXWindowCreated can arrive before AXPosition and AXSize become
        // writable. Give that early state one deferred chance to settle.
        guard snapshot.isResizable else { return isDeferredRetry ? .ignored : .retry }

        let applicationWindows = try? accessibility.windows(pid: pid)
        let listedHandles = (try? accessibility.windowHandles(pid: pid)).map(Set.init)
        let isSystemFocused = reportedFrontmostPID == pid
            && (try? accessibility.focusedWindow(pid: pid)) == handle
        let attached = attach(
            window: snapshot,
            to: sectionID,
            focusAfterAttachment: false,
            knownApplicationWindows: applicationWindows,
            knownListedHandles: listedHandles,
            makeActiveAfterAttachment: isSystemFocused,
            reportsCompatibilityErrors: false
        )
        if attached, isSystemFocused { lastFocusedSectionByPID[pid] = sectionID }
        return attached ? .attached : (isDeferredRetry ? .ignored : .retry)
    }

    @discardableResult
    func retryPendingWindowCreations(reportedFrontmostPID: pid_t?) -> Bool {
        guard hasWindowManagementAccess, isAccessibilityTrusted, !isInSystemTransition else { return false }
        let ready = pendingWindowCreations.filter { ($0.retryAfter ?? .distantPast) <= now() }
        var attached = false
        for pending in ready {
            pendingWindowCreations.removeAll { $0.handle == pending.handle }
            let result = attachNewlyCreatedWindow(
                pending.handle,
                pid: pending.pid,
                reportedFrontmostPID: reportedFrontmostPID,
                isDeferredRetry: pending.retryAfter != nil
            )
            if result == .retry {
                pendingWindowCreations.append((
                    pending.handle, pending.pid, now().addingTimeInterval(Self.windowCreationRetryInterval)
                ))
            }
            attached = attached || result == .attached
        }
        return attached
    }

    private func automaticAttachmentSectionID(for pid: pid_t) -> UUID? {
        if let sectionID = lastFocusedSectionByPID[pid],
           sections[sectionID]?.windows.contains(where: { $0.pid == pid }) == true,
           contentFrame(forSection: sectionID) != nil {
            return sectionID
        }
        if let focusedManagedWindowID,
           managedWindow(id: focusedManagedWindowID)?.pid == pid,
           let location = location(ofWindowID: focusedManagedWindowID) {
            return location.sectionID
        }

        // Live spanned sections are destinations too: an application whose
        // windows were all restored into a span has no other.
        let sectionIDs = currentDisplays.flatMap { layout(for: $0).root.leafIDs }
            + LayoutGeometry.readingOrder(
                leafIDs: sections.keys.filter { sections[$0]?.isSpanned == true },
                frames: sectionFrames()
            )
        return sectionIDs.first {
            sections[$0]?.activeWindow?.pid == pid
        } ?? sectionIDs.first {
            sections[$0]?.windows.contains(where: { $0.pid == pid }) == true
        }
    }

    @discardableResult
    func attach(
        window snapshot: AXWindowSnapshot,
        to sectionID: UUID,
        focusAfterAttachment: Bool,
        knownApplicationWindows: [AXWindowSnapshot]? = nil,
        knownListedHandles: Set<AXWindowHandle>? = nil,
        makeActiveAfterAttachment: Bool = true,
        reportsCompatibilityErrors: Bool = true
    ) -> Bool {
        guard hasWindowManagementAccess else { return false }
        let activeSplitsBeforeAttachment = activeApplicationSplitPairs()
        guard snapshot.isResizable else {
            if reportsCompatibilityErrors {
                compatibilityError = AccessibilityClientError.unsupportedWindow("it cannot be resized").localizedDescription
            }
            return false
        }
        guard !snapshot.isFullScreen else {
            if reportsCompatibilityErrors {
                compatibilityError = AccessibilityClientError.unsupportedWindow("native full-screen windows are not supported").localizedDescription
            }
            return false
        }
        guard let app = runningApplication(pid: snapshot.pid) else { return false }
        let bundleIdentifier = app.bundleIdentifier ?? "pid.\(snapshot.pid)"
        let prospectiveLiveBundles = Set(
            sections[sectionID]?.windows.map(\.bundleIdentifier) ?? []
        ).union([bundleIdentifier])
        guard let destination = contentFrame(
            forApplication: bundleIdentifier,
            inSection: sectionID,
            assumingLiveBundleIdentifiers: prospectiveLiveBundles
        ) else { return false }

        let originalFrame = snapshot.frame
        let applicationWindows = knownApplicationWindows
            ?? (try? accessibility.windows(pid: snapshot.pid))
        let windowOrdinal = applicationWindows?
            .firstIndex { $0.handle == snapshot.handle } ?? 0
        let listedHandles = knownListedHandles
            ?? (try? accessibility.windowHandles(pid: snapshot.pid)).map(Set.init)
        let existing = managedWindow(
            matching: snapshot,
            windowOrdinal: windowOrdinal,
            listedHandles: listedHandles
        )
        let window = ManagedWindow(
            id: existing?.id ?? UUID(),
            handle: snapshot.handle,
            pid: snapshot.pid,
            bundleIdentifier: bundleIdentifier,
            accessibilityIdentifier: snapshot.accessibilityIdentifier,
            windowOrdinal: windowOrdinal,
            applicationName: app.localizedName ?? app.bundleIdentifier ?? "PID \(snapshot.pid)",
            icon: applicationIcon(for: app),
            title: snapshot.title,
            isMinimized: snapshot.isMinimized,
            finderTabGroup: snapshot.finderTabGroup,
            lastKnownFrame: snapshot.frame
        )

        do {
            try accessibility.setFrame(Self.accessibilityFrame(fromAppKitFrame: destination), of: snapshot.handle)
        } catch {
            try? accessibility.setFrame(originalFrame, of: snapshot.handle)
            if reportsCompatibilityErrors { compatibilityError = error.localizedDescription }
            return false
        }

        if let existing {
            removeWindow(id: existing.id)
        }
        removeWindow(handle: snapshot.handle)
        // Automatic placement filters detached handles out before reaching
        // this point, so every caller left is acting on the user's explicit
        // request (drag, icon double click, edge shortcut, or an
        // application-wide attachment). The detachment exemption ends here.
        forgetUserDetachedWindow(snapshot.handle, pid: snapshot.pid)
        pendingWindowCreations.removeAll { $0.handle == snapshot.handle }
        var section = sections[sectionID] ?? LayoutSectionState(id: sectionID)
        section.windows.append(window)
        if makeActiveAfterAttachment || section.activeWindowID == nil {
            section.activeWindowID = window.id
        }
        sections[sectionID] = section
        removeUnattachedWindow(handle: snapshot.handle)
        if activeApplicationSplitPairs() != activeSplitsBeforeAttachment {
            let preservedCompatibilityError = compatibilityError
            reflowManagedWindows()
            if !reportsCompatibilityErrors {
                compatibilityError = preservedCompatibilityError
            }
        }
        if focusAfterAttachment {
            do {
                try accessibility.focus(window: snapshot.handle, pid: snapshot.pid)
                lastFocusedSectionByPID[snapshot.pid] = sectionID
            } catch {}
            // The user put this window here, so this is the layer they are
            // looking at; a span covering it would otherwise hide the bars.
            presentLayer(for: sectionID)
        }
        if reportsCompatibilityErrors { compatibilityError = nil }
        loadMenu(pid: snapshot.pid)
        persistWindowAssignments()
        return true
    }

    func detach(windowID: UUID) {
        guard hasWindowManagementAccess else { return }
        for key in Array(sections.keys) {
            guard var section = sections[key],
                  let window = section.windows.first(where: { $0.id == windowID }) else { continue }
            snapshotFailures.remove(windowID)
            invalidSnapshotFirstFailure.removeValue(forKey: windowID)
            forgetSavedWindowAssignments { $0.id == windowID }
            userDetachedWindowHandles[window.pid, default: []].insert(window.handle)
            pendingWindowCreations.removeAll { $0.handle == window.handle }
            section.windows.removeAll { $0.id == windowID }
            if section.activeWindowID == windowID { section.activeWindowID = section.windows.last?.id }
            if section.windows.isEmpty { sections.removeValue(forKey: key) } else { sections[key] = section }
            if section.windows.isEmpty { raisedSpannedSectionIDs.remove(key) }
            if !sections.values.contains(where: { section in
                section.windows.contains { $0.bundleIdentifier == window.bundleIdentifier }
            }) {
                // Detaching the last window opts the application out of
                // management, including dormant close/relaunch assignments
                // and records saved for other display configurations.
                forgetSavedWindowAssignments { $0.bundleIdentifier == window.bundleIdentifier }
                pendingDestroyedWindows = pendingDestroyedWindows.filter {
                    $0.value.bundleIdentifier != window.bundleIdentifier
                }
                windowReopenObservationIdentities = windowReopenObservationIdentities.filter {
                    $0.value != window.bundleIdentifier
                }
                applicationRelaunchRecoveryPIDs.removeValue(forKey: window.bundleIdentifier)
                lastFocusedSectionByPID.removeValue(forKey: window.pid)
            }
            if pruneApplicationSplitPairs() { reflowManagedWindows() }
            reconcileApplicationSplitVisibilityForCurrentFocus(fallbackSectionID: key)
            persistWindowAssignments()
            exitFocusModeIfSectionIsEmpty()
            refreshUnattachedWindows(pid: window.pid)
            break
        }
    }

    /// Asks the target application to close the window without activating it.
    /// The managed record remains until the application's AX destruction
    /// notification confirms the close, so a save prompt can still cancel it.
    func close(windowID: UUID) {
        guard hasWindowManagementAccess else { return }
        guard let window = managedWindow(id: windowID) else { return }
        do {
            try accessibility.close(window: window.handle)
            compatibilityError = nil
        } catch {
            compatibilityError = "Could not close window: \(error.localizedDescription)"
        }
    }

    /// Sends a normal quit request to the owning application without changing
    /// managed state. Workspace termination confirmation preserves its window
    /// assignments for a later application relaunch; a cancelled quit changes
    /// nothing.
    func quitApplication(windowID: UUID) {
        guard hasWindowManagementAccess else { return }
        guard let window = managedWindow(id: windowID), canQuitApplication(pid: window.pid) else { return }
        do {
            try accessibility.quitApplication(pid: window.pid)
            compatibilityError = nil
        } catch {
            compatibilityError = "Could not quit \(window.applicationName): \(error.localizedDescription)"
        }
    }

    func canQuitApplication(pid: pid_t) -> Bool {
        pid != ownProcessIdentifier
    }

    func focus(windowID: UUID) {
        guard hasWindowManagementAccess else { return }
        for key in Array(sections.keys) {
            guard var section = sections[key], let window = section.windows.first(where: { $0.id == windowID }) else { continue }
            // A destination outside the focused section may belong to an
            // application focus mode hid. Restore the layout before asking AX
            // to activate or raise that window. Centralizing the ordering here
            // keeps every present and future caller safe.
            let exitsFocusMode = focusedSectionID != nil && focusedSectionID != key
            if exitsFocusMode { exitFocusMode() }
            do {
                let revealedSplitApplications = prepareApplicationSplitVisibilityForFocus(
                    focusedWindow: window,
                    inSection: key
                )
                bringApplicationSplitPartnerForward(for: window, inSection: key)
                try accessibility.focus(window: window.handle, pid: window.pid)
                section.activeWindowID = window.id
                sections[key] = section
                // The window's layer comes on top: a span is raised over the
                // sections it covers, and a window in one of those sections
                // lowers the span and brings the neighbouring sections' active
                // windows up with it so the spanned window is fully covered.
                presentLayer(for: key)
                // Both split applications have now been activated as needed;
                // only now is it safe to hide the old group behind them.
                reconcileApplicationSplitVisibility(
                    focusedWindow: window,
                    inSection: key
                )
                // Optimistic: the next refreshRuntime() confirms, but callers
                // (e.g. the switcher selection) should reflect focus right
                // away.
                focusedManagedWindowID = window.id
                lastFocusedSectionByPID[window.pid] = key
                compatibilityError = nil
                if exitsFocusMode || revealedSplitApplications {
                    restorePendingHiddenApplicationWindowOrderAfterFocusChange()
                }
                // Ahead of the menu read and the assignment write below, both of
                // which can block: the selection update is what the user is
                // waiting on.
                onOverlayPresentationChanged?()
                loadMenu(pid: window.pid)
                persistWindowAssignments()
            } catch {
                compatibilityError = error.localizedDescription
            }
            return
        }
    }

    func focusMostRecentWindow(bundleIdentifier: String, in sectionID: UUID) {
        guard hasWindowManagementAccess else { return }
        guard let section = sections[sectionID] else { return }
        let candidates = section.windows.filter { $0.bundleIdentifier == bundleIdentifier }
        if let active = section.activeWindow, active.bundleIdentifier == bundleIdentifier {
            focus(windowID: active.id)
        } else if let candidate = candidates.last {
            focus(windowID: candidate.id)
        }
    }
    /// Applies a user-chosen order to a section's windows, as the window
    /// switcher does when one of its buttons is dragged. The order drives the
    /// switcher and the cycling shortcuts alike, and it is persisted, so a
    /// reordering survives a relaunch.
    ///
    /// Accepts a permutation or nothing: a list that added or dropped a window
    /// would silently detach it.
    func reorderWindows(in sectionID: UUID, to orderedIDs: [UUID]) {
        guard hasWindowManagementAccess else { return }
        guard var section = sections[sectionID],
              orderedIDs.count == section.windows.count,
              Set(orderedIDs) == Set(section.windows.map(\.id)) else { return }
        let windowsByID = Dictionary(uniqueKeysWithValues: section.windows.map { ($0.id, $0) })
        let reordered = orderedIDs.compactMap { windowsByID[$0] }
        guard reordered != section.windows else { return }
        section.windows = reordered
        sections[sectionID] = section
        persistWindowAssignments()
    }

    func invoke(window: ManagedWindow, node: MenuNode, path: [String]) {
        guard hasWindowManagementAccess else { return }
        do {
            if !invokeWithoutActivation { try accessibility.focus(window: window.handle, pid: window.pid) }
            _ = try accessibility.invoke(
                pid: window.pid,
                indexPath: node.indexPath,
                focusing: invokeWithoutActivation ? nil : window.handle
            )
            loadMenu(pid: window.pid, force: true)
        } catch {
            compatibilityError = "Could not invoke \(path.joined(separator: " › ")): \(error.localizedDescription)"
        }
    }
    func loadMenu(pid: pid_t, force: Bool = false) {
        guard hasWindowManagementAccess,
              isAccessibilityTrusted,
              !loadingMenus.contains(pid),
              force || menusByPID[pid] == nil else { return }
        loadingMenus.insert(pid)
        defer { loadingMenus.remove(pid) }
        do {
            menusByPID[pid] = try accessibility.readMenu(pid: pid)
        } catch {
            menusByPID[pid] = []
        }
    }
    func startPermissionPolling() {
        guard hasWindowManagementAccess, permissionPoller == nil else { return }
        permissionPoller = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshPermissionState() }
    }
}
