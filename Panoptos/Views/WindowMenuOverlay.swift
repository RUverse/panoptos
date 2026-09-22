import AppKit
import ApplicationServices
import SwiftUI

private func managedWindowObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<ManagedWindowObserver>.fromOpaque(refcon).takeUnretainedValue().receive(
        element: element,
        notification: notification as String
    )
}

private enum ManagedWindowChange {
    case created(AXWindowHandle)
    case destroyed(AXWindowHandle)
    case geometry(AXWindowHandle)
    case visibility(AXWindowHandle)
    case focus
    case runtime(AXWindowHandle)
}

private final class ManagedWindowObserver {
    private let application: AXUIElement
    private let observer: AXObserver
    private let onChange: (ManagedWindowChange) -> Void
    private var windows: Set<AXWindowHandle> = []
    private var pendingApplicationNotifications: Set<String> = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification
    ]
    private var remainingApplicationNotificationRetries = 3
    private var nextApplicationNotificationRetry: Date?
    private var applicationNotificationRetryDelay: TimeInterval = 0.25

    init?(pid: pid_t, onChange: @escaping (ManagedWindowChange) -> Void) {
        application = AXUIElementCreateApplication(pid)
        // Observer registration is synchronous IPC too. An application waking
        // its AX server must not inherit the multi-second default timeout on
        // Panoptos's main thread, including on the backed-off retries below.
        AXUIElementSetMessagingTimeout(application, 0.2)
        self.onChange = onChange
        var value: AXObserver?
        guard AXObserverCreate(pid, managedWindowObserverCallback, &value) == .success, let value else { return nil }
        observer = value
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        attemptApplicationNotificationRegistration(now: Date())
    }

    /// Keeps successful subscriptions when one application-level notification
    /// is unsupported. Startup messaging failures get a small, backed-off retry
    /// budget instead of turning every idle reconciliation into failed IPC.
    func retryApplicationNotificationsIfNeeded(now: Date = Date()) {
        guard remainingApplicationNotificationRetries > 0,
              let nextApplicationNotificationRetry,
              now >= nextApplicationNotificationRetry else { return }
        remainingApplicationNotificationRetries -= 1
        attemptApplicationNotificationRegistration(now: now)
    }

    private func attemptApplicationNotificationRegistration(now: Date) {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for notification in Array(pendingApplicationNotifications) {
            let error = AXObserverAddNotification(
                observer,
                application,
                notification as CFString,
                pointer
            )
            switch error {
            case .success, .notificationAlreadyRegistered:
                pendingApplicationNotifications.remove(notification)
            case .cannotComplete, .failure, .invalidUIElement:
                // These can be transient while a new application's AX server
                // starts. Leave only this notification pending for a later try.
                break
            default:
                // Unsupported notifications and invalid arguments will not be
                // repaired by retrying. Preserve every subscription that did
                // succeed and allow per-window observation to continue.
                pendingApplicationNotifications.remove(notification)
            }
        }
        guard !pendingApplicationNotifications.isEmpty,
              remainingApplicationNotificationRetries > 0 else {
            pendingApplicationNotifications.removeAll()
            nextApplicationNotificationRetry = nil
            return
        }
        nextApplicationNotificationRetry = now.addingTimeInterval(applicationNotificationRetryDelay)
        applicationNotificationRetryDelay = min(applicationNotificationRetryDelay * 2, 4)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func receive(element: AXUIElement, notification: String) {
        switch notification {
        case kAXUIElementDestroyedNotification:
            onChange(.destroyed(AXWindowHandle(element: element)))
        case kAXMovedNotification, kAXResizedNotification:
            onChange(.geometry(AXWindowHandle(element: element)))
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            onChange(.visibility(AXWindowHandle(element: element)))
        case kAXFocusedWindowChangedNotification:
            // Switching between two windows of the same application never
            // activates anything, so this is the only signal that reports it.
            onChange(.focus)
        case kAXWindowCreatedNotification:
            onChange(.created(AXWindowHandle(element: element)))
        default:
            onChange(.runtime(AXWindowHandle(element: element)))
        }
    }

    func update(windows newWindows: Set<AXWindowHandle>) {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXUIElementDestroyedNotification
        ]
        for window in windows.subtracting(newWindows) {
            AXUIElementSetMessagingTimeout(window.element, 0.2)
            for notification in notifications {
                AXObserverRemoveNotification(observer, window.element, notification as CFString)
            }
        }
        for window in newWindows.subtracting(windows) {
            AXUIElementSetMessagingTimeout(window.element, 0.2)
            for notification in notifications {
                AXObserverAddNotification(observer, window.element, notification as CFString, pointer)
            }
        }
        windows = newWindows
    }
}

@MainActor
final class WindowMenuOverlayCoordinator: ObservableObject {
    // AX observers provide normal updates. This timer is only a compatibility
    // fallback, so keep it genuinely low-frequency to avoid repeatedly
    // snapshotting every managed window while the desktop is idle.
    private let idleInterval: TimeInterval = 1
    private let trackingInterval: TimeInterval = 1.0 / 60.0
    private var model: PanoptosModel?
    private var idleTimer: Timer?
    private var trackingTimer: Timer?
    private var draggedWindow: AXWindowSnapshot?
    private var highlightedSectionID: UUID?
    private var eventMonitors: [Any] = []
    private var panels: [UUID: SectionPanelController] = [:]
    private var highlights: [UUID: AttachmentHighlightController] = [:]
    private var notices: [UUID: SectionNoticeController] = [:]
    private var observers: [pid_t: ManagedWindowObserver] = [:]
    private var pendingReconcileReflows = false
    private var isReconcileScheduled = false
    private var pendingUnattachedRefreshPIDs: Set<pid_t> = []
    private var pendingUnattachedRefreshHandles: [AXWindowHandle: pid_t] = [:]
    private var isUnattachedRefreshScheduled = false
    private var isUnattachedSeedScheduled = false
    private var didRefreshUnattachedSeedApplication = false
    private var isStripLayoutScheduled = false

    func start(model: PanoptosModel) {
        self.model = model
        // A focus or visibility change repaints the bars immediately instead of
        // waiting for the next reconciliation, whose Accessibility sweep is what
        // left the focused switcher selection trailing the click.
        model.onOverlayPresentationChanged = { [weak self] in
            self?.applyPresentation()
            self?.scheduleUnattachedSeed()
        }
        model.onUnattachedApplicationRosterChanged = { [weak self] in
            self?.synchronizeWindowObservers()
        }
        model.onWindowManagementRuntimeChanged = { [weak self] _ in
            self?.synchronizeAccess()
        }
        synchronizeAccess()
    }

    private func synchronizeAccess() {
        guard let model, model.hasWindowManagementAccess else {
            stopRuntime()
            return
        }
        guard idleTimer == nil else { return }
        // The model may have populated its application roster before the
        // coordinator started. Observe those processes before any blocking
        // reconciliation work can overlap their first window creation.
        synchronizeWindowObservers()
        reconcile()
        scheduleUnattachedSeed()
        let timer = Timer(timeInterval: idleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.trackingTimer == nil else { return }
                self?.reconcile()
            }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        installEventMonitors()
    }

    func stop() {
        model?.onOverlayPresentationChanged = nil
        model?.onUnattachedApplicationRosterChanged = nil
        model?.onWindowManagementRuntimeChanged = nil
        stopRuntime()
        model = nil
    }

    private func stopRuntime() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopTracking(action: nil)
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        observers.removeAll()
        pendingUnattachedRefreshPIDs.removeAll()
        pendingUnattachedRefreshHandles.removeAll()
        isUnattachedRefreshScheduled = false
        isUnattachedSeedScheduled = false
        didRefreshUnattachedSeedApplication = false
        isStripLayoutScheduled = false
        panels.values.forEach { $0.close() }
        panels.removeAll()
        notices.values.forEach { $0.close() }
        notices.removeAll()
        hideHighlights()
    }

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let model,
                  model.hasWindowManagementAccess,
                  model.isAccessibilityTrusted else { return }
            // A press inside one of Panoptos' own panels is never a window
            // drag: the element under the pointer is the panel itself, and
            // tracking it would suspend panel reconciliation for the length of
            // a switcher reorder. Only the global monitor, whose events carry
            // no window of ours, reports a real window being dragged.
            guard event.window == nil else { return }
            do {
                let snapshot = try model.window(atAppKitPoint: NSEvent.mouseLocation)
                let frame = model.appKitFrame(for: snapshot)
                let titleRegion = CGRect(x: frame.minX, y: frame.maxY - min(64, frame.height), width: frame.width, height: min(64, frame.height))
                guard titleRegion.contains(NSEvent.mouseLocation) else { return }
                startTracking(snapshot)
            } catch {
                break
            }
        case .leftMouseUp:
            // Without a tracked drag nothing was moved and nothing is waiting to
            // be placed, so reflowing and reconciling here would spend a
            // blocking Accessibility read per managed window — twice — on every
            // click anywhere, including clicks on Panoptos' own switcher. The
            // activation notification and the AX observers cover those.
            guard draggedWindow != nil else { break }
            stopTracking(action: model?.windowDragAction(for: NSEvent.modifierFlags))
        default:
            break
        }
    }

    private func startTracking(_ snapshot: AXWindowSnapshot) {
        guard trackingTimer == nil else { return }
        draggedWindow = snapshot
        let timer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateDragTarget() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
        updateDragTarget()
    }

    private func updateDragTarget() {
        guard let model, model.hasWindowManagementAccess, draggedWindow != nil else { return }
        guard model.windowDragAction(for: NSEvent.modifierFlags) != nil else {
            highlightedSectionID = nil
            hideHighlights()
            return
        }
        let point = NSEvent.mouseLocation
        // Windows are dropped into the layout's sections; a span over them is
        // not a drop target.
        let frames = model.layoutSectionFrames()
        highlightedSectionID = frames.first(where: { $0.value.contains(point) })?.key
        showHighlights(frames: frames, selected: highlightedSectionID)
    }

    private func stopTracking(action: WindowDragShortcutAction?) {
        trackingTimer?.invalidate()
        trackingTimer = nil
        let snapshot = draggedWindow
        draggedWindow = nil
        // The user is allowed to press the modifier at the end of the drag.
        // Recompute synchronously instead of depending on whether the 60 Hz
        // highlight timer happened to run between that key press and mouse-up.
        let sectionID = action == nil ? nil : model?.layoutSectionFrames()
            .first(where: { $0.value.contains(NSEvent.mouseLocation) })?.key
        highlightedSectionID = nil
        hideHighlights()
        if let action, let snapshot, let sectionID {
            switch action {
            case .attachApplicationWindows:
                model?.attachApplicationWindows(containing: snapshot, to: sectionID)
            case .attachWindow:
                model?.attach(window: snapshot, to: sectionID)
            }
        } else {
            model?.reflowManagedWindows()
        }
        reconcile()
    }

    // One managed-window change (e.g. a reflow) can fire moved/resized
    // notifications for every window in the section. Coalesce the resulting AX
    // callbacks into a single reconciliation per runloop turn instead of
    // running a full runtime refresh for each notification.
    private func scheduleReconcile(reflowWindows: Bool) {
        pendingReconcileReflows = pendingReconcileReflows || reflowWindows
        guard !isReconcileScheduled else { return }
        isReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let reflow = self.pendingReconcileReflows
            self.isReconcileScheduled = false
            self.pendingReconcileReflows = false
            // Do not mutate panel structure during live drag. The mouse-up
            // reconciliation will apply the change.
            guard self.model?.hasWindowManagementAccess == true,
                  self.trackingTimer == nil else { return }
            self.reconcile(reflowWindows: reflow)
        }
    }

    /// Window servers often deliver moved, resized, and title notifications in
    /// bursts. Refresh each affected free-window application at most once per
    /// runloop turn, and defer all such reads while a live drag is being polled.
    private func scheduleUnattachedRefresh(pid: pid_t) {
        pendingUnattachedRefreshPIDs.insert(pid)
        scheduleUnattachedRefreshFlush()
    }

    /// The narrow form: the notification named its own window, so re-read that
    /// one element instead of every window the application owns. Applications
    /// that rewrite their titles continuously would otherwise keep a blocking
    /// read per sibling window running while the desktop is idle.
    private func scheduleUnattachedRefresh(handle: AXWindowHandle, pid: pid_t) {
        pendingUnattachedRefreshHandles[handle] = pid
        scheduleUnattachedRefreshFlush()
    }

    private func scheduleUnattachedRefreshFlush() {
        guard trackingTimer == nil, !isUnattachedRefreshScheduled else { return }
        isUnattachedRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUnattachedRefreshScheduled = false
            guard self.model?.hasWindowManagementAccess == true,
                  self.trackingTimer == nil else { return }
            self.flushPendingUnattachedRefreshes()
        }
    }

    private func flushPendingUnattachedRefreshes() {
        guard let model, model.hasWindowManagementAccess, trackingTimer == nil else { return }
        let pids = pendingUnattachedRefreshPIDs.sorted()
        let handles = pendingUnattachedRefreshHandles
        pendingUnattachedRefreshPIDs.removeAll()
        pendingUnattachedRefreshHandles.removeAll()
        for pid in pids { model.refreshUnattachedWindows(pid: pid) }
        // An application-wide refresh already re-read every one of its
        // windows, so its per-window requests have nothing left to do.
        for (handle, pid) in handles where !pids.contains(pid) {
            model.refreshUnattachedWindow(handle: handle, pid: pid)
        }
    }

    /// Enumerate already-running applications promptly at startup without
    /// putting every blocking AX read into one main-thread turn. Each pass
    /// handles one process and immediately yields back to the runloop.
    private func scheduleUnattachedSeed() {
        guard let model,
              model.hasWindowManagementAccess,
              model.hasVisibleUnattachedApplicationAwaitingSeed,
              !isUnattachedSeedScheduled else { return }
        isUnattachedSeedScheduled = true
        didRefreshUnattachedSeedApplication = false
        DispatchQueue.main.async { [weak self] in self?.continueUnattachedSeed() }
    }

    private func continueUnattachedSeed() {
        guard let model, model.hasWindowManagementAccess else {
            isUnattachedSeedScheduled = false
            didRefreshUnattachedSeedApplication = false
            return
        }
        guard trackingTimer == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.continueUnattachedSeed()
            }
            return
        }
        if model.refreshNextUnattachedApplicationAwaitingSeed() {
            didRefreshUnattachedSeedApplication = true
            DispatchQueue.main.async { [weak self] in self?.continueUnattachedSeed() }
            return
        }

        let needsObserverRefresh = didRefreshUnattachedSeedApplication
        isUnattachedSeedScheduled = false
        didRefreshUnattachedSeedApplication = false
        if needsObserverRefresh { scheduleReconcile(reflowWindows: false) }
    }

    private func reconcile(reflowWindows: Bool = false) {
        guard let model,
              model.hasWindowManagementAccess,
              model.isAccessibilityTrusted else {
            panels.values.forEach { $0.orderOut() }
            notices.values.forEach { $0.close() }
            notices.removeAll()
            return
        }
        flushPendingUnattachedRefreshes()
        // `applyPresentation()` below is this pass's repaint; letting
        // `refreshRuntime` publish one as well would run the whole
        // presentation pass twice in the same runloop turn.
        model.refreshRuntime(publishesPresentationChanges: false)
        model.refreshNextUnattachedApplication()
        if reflowWindows { model.reflowManagedWindows() }
        applyPresentation()

        let frames = model.sectionFrames()
        let sectionNotices = model.sectionNotices
        for id in Array(notices.keys) where sectionNotices[id] == nil {
            notices.removeValue(forKey: id)?.close()
        }
        for (id, text) in sectionNotices {
            guard let frame = frames[id], model.isSectionVisible(id) else { continue }
            let controller = notices[id] ?? {
                let value = SectionNoticeController()
                notices[id] = value
                return value
            }()
            controller.show(text: text, centeredIn: frame)
        }

        synchronizeWindowObservers()
    }

    /// Keeps application-level creation/focus observation synchronized with
    /// the cheap NSWorkspace roster, and per-window observation synchronized
    /// with the latest discovered handles. This intentionally runs separately
    /// from presentation and may be called before a full AX reconciliation.
    private func synchronizeWindowObservers() {
        guard let model,
              model.hasWindowManagementAccess,
              model.isAccessibilityTrusted,
              !model.isInSystemTransition,
              trackingTimer == nil else { return }
        var handlesByPID: [pid_t: Set<AXWindowHandle>] = [:]
        for window in model.sections.values.flatMap(\.windows) {
            handlesByPID[window.pid, default: []].insert(window.handle)
        }
        for window in model.unattachedWindowsByHandle.values {
            handlesByPID[window.pid, default: []].insert(window.handle)
        }
        let pids = model.windowObservationPIDs
        for pid in Array(observers.keys) where !pids.contains(pid) { observers.removeValue(forKey: pid) }
        for pid in pids where observers[pid] == nil {
            observers[pid] = ManagedWindowObserver(pid: pid) { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    switch change {
                    case .destroyed(let handle):
                        self.model?.confirmWindowDestroyed(handle)
                        self.scheduleReconcile(reflowWindows: false)
                    case .created(let handle):
                        let result = self.model?.attachNewlyCreatedWindow(handle, pid: pid)
                        self.scheduleUnattachedRefresh(pid: pid)
                        if result == .retry {
                            // Some applications publish a window-created event
                            // before its standard attributes and resize actions
                            // are ready. Retry attachment and free-window
                            // discovery once after the event burst settles.
                            DispatchQueue.main.asyncAfter(deadline: .now() + PanoptosModel.windowCreationRetryInterval) { [weak self] in
                                guard let self else { return }
                                _ = self.model?.attachNewlyCreatedWindow(
                                          handle,
                                          pid: pid,
                                          isDeferredRetry: true
                                      )
                                self.scheduleUnattachedRefresh(pid: pid)
                                self.scheduleReconcile(reflowWindows: false)
                            }
                        }
                        self.scheduleReconcile(reflowWindows: false)
                    case .focus:
                        // Resolve and repaint the new focus from one read before
                        // scheduling the pass that costs a blocking read per
                        // managed window. Same-app switches have no activation
                        // notification.
                        self.model?.refreshFocusedWindow()
                        // Free-window discovery observes every running
                        // application, so this fires for applications the user
                        // never attached. Only one that owns managed windows
                        // can change what the sweep would find; for the rest
                        // the idle pass is soon enough.
                        if self.model?.hasManagedWindows(pid: pid) == true {
                            self.scheduleReconcile(reflowWindows: false)
                        }
                    case .geometry(let handle), .visibility(let handle), .runtime(let handle):
                        if self.model?.managedWindow(matching: handle) != nil {
                            self.scheduleReconcile(reflowWindows: change.requiresManagedReflow)
                        } else if self.model?.unattachedWindowsByHandle[handle] != nil {
                            self.scheduleUnattachedRefresh(handle: handle, pid: pid)
                        } else {
                            // An element discovery has not seen yet: only the
                            // application-wide list can introduce it.
                            self.scheduleUnattachedRefresh(pid: pid)
                        }
                    }
                }
            }
        }
        for pid in pids {
            observers[pid]?.retryApplicationNotificationsIfNeeded()
            observers[pid]?.update(windows: handlesByPID[pid] ?? [])
        }
    }

    /// Pushes the model's current state into the section panels, and nothing
    /// else.
    ///
    /// Deliberately free of Accessibility traffic, so a focus change can repaint
    /// the bars in the runloop turn that delivered it. `reconcile()` ends up at
    /// these same panels, but only behind a blocking read per managed window —
    /// long enough for the user to watch the focused switcher selection lag
    /// their click.
    private func applyPresentation() {
        // Panel structure must not change under a live drag, exactly as in
        // `scheduleReconcile`.
        guard let model,
              model.hasWindowManagementAccess,
              model.isAccessibilityTrusted,
              trackingTimer == nil else { return }
        let frames = model.sectionFrames()
        let desired = Set(model.sections.keys.filter { model.sections[$0]?.windows.isEmpty == false && frames[$0] != nil })
        for id in Array(panels.keys) where !desired.contains(id) {
            panels.removeValue(forKey: id)?.close()
        }
        let focusedWindowID = model.focusedManagedWindowID
        let unattachedGroupsBySection = model.unattachedWindowGroupsBySection()
        var onScreen: [UUID: LayoutSectionState] = [:]
        for id in desired {
            guard let section = model.sections[id] else { continue }
            let controller = panels[id] ?? {
                let value = SectionPanelController(sectionID: id, section: section, model: model)
                value.onContentWidthChanged = { [weak self] in self?.scheduleStripLayout() }
                panels[id] = value
                return value
            }()
            // Focus mode leaves the panels of the other sections built but off
            // screen, so leaving it puts them straight back. A section whose
            // every window is off screen has nothing to draw either; the
            // windows stay attached and the bars return with them.
            guard model.isSectionVisible(id), section.hasVisibleWindows else {
                controller.orderOut()
                continue
            }
            let isFocused = focusedWindowID != nil && section.activeWindow?.id == focusedWindowID
            // Every switcher stays on screen so the mouse can always switch.
            // The menu bar is the one bar that belongs to the layer on top: a
            // spanned window's menus and the menus of the windows beneath it
            // would otherwise sit on the same strip.
            controller.update(
                section: section,
                isFocused: isFocused,
                showsMenuBar: model.showWindowMenuBars && model.isSectionOnTop(id),
                unattachedGroups: unattachedGroupsBySection[id] ?? []
            )
            onScreen[id] = section
        }
        // A spanned section's switcher sits between the switchers of the
        // sections it covers, which give way to it. Its measured width decides
        // how much; until measured it takes no room.
        let bottomHeight = WindowSwitcherSize.barHeight(for: model.windowSwitcherUIScale)
        let strips = SwitcherStripLayout.placements(
            frames: frames,
            coveredSectionIDs: onScreen.compactMapValues { $0.isSpanned ? $0.coveredSectionIDs : nil },
            contentWidths: onScreen.keys.reduce(into: [UUID: CGFloat]()) {
                $0[$1] = panels[$1]?.switcherContentWidth ?? 0
            },
            spacing: model.sectionBarSpacing(forSectionIDs: Set(frames.keys)),
            height: bottomHeight
        )
        for id in onScreen.keys {
            guard let controller = panels[id], let frame = frames[id] else { continue }
            let strip = strips[id] ?? SwitcherStripLayout.Placement(
                strip: SwitcherStripLayout.strip(of: frame, height: bottomHeight),
                anchorX: nil
            )
            controller.position(SectionBarPlacement(
                frame: frame,
                switcherStrip: strip.strip,
                switcherAnchorX: strip.anchorX,
                fillsAvailableWidth: model.sectionBarsFillAvailableWidth,
                centersBars: model.sectionBarsCentered,
                bottomHeight: bottomHeight
            ))
            controller.ensureVisible()
        }
    }

    /// A switcher reported a new content width. A spanned switcher's width
    /// moves the switchers beside it, so the strip is laid out again — from
    /// model state alone, with no Accessibility traffic, once per turn.
    private func scheduleStripLayout() {
        guard !isStripLayoutScheduled else { return }
        isStripLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStripLayoutScheduled = false
            self.applyPresentation()
        }
    }

    private func showHighlights(frames: [UUID: CGRect], selected: UUID?) {
        for (id, frame) in frames {
            let controller = highlights[id] ?? {
                let value = AttachmentHighlightController()
                highlights[id] = value
                return value
            }()
            controller.show(frame: frame, selected: id == selected)
        }
        for id in Array(highlights.keys) where frames[id] == nil {
            highlights.removeValue(forKey: id)?.close()
        }
    }

    private func hideHighlights() {
        highlights.values.forEach { $0.close() }
        highlights.removeAll()
    }
}

private extension ManagedWindowChange {
    var requiresManagedReflow: Bool {
        switch self {
        case .geometry, .visibility: true
        case .created, .destroyed, .focus, .runtime: false
        }
    }

}
