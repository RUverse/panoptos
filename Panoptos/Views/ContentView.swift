import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PanoptosModel
    @State private var editingDisplay: CurrentDisplay?
    @State private var selectedTab = SettingsTab.general
    @State private var isShowingOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            settingsTabBar
            Divider()
            if !model.isAccessibilityTrusted {
                permissionBanner
                Divider()
            }
            if let error = model.compatibilityError {
                errorBanner(error)
                Divider()
            }
            settingsScrollView {
                switch selectedTab {
                case .general:
                    VStack(alignment: .leading, spacing: 20) {
                        startupSettings
                        updateSettings
                        if model.isAccessibilityTrusted {
                            grantedAccessibilityRow
                        }
                        keepAwakeSettings
                        invocationSettings
                        recommendedMacOSSettings
                        supportSettings
                    }
                case .appearance:
                    sectionBarSettings
                case .layout:
                    layoutSettings
                case .shortcuts:
                    shortcutsSettings
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.activateShortcuts()
            model.refreshLaunchAtLoginState()
        }
        // The tour waits for the window to be on screen rather than presenting
        // from onAppear: that runs before the window is ordered in, and for a
        // login launch on a window dismissed in the same turn, and a sheet
        // begun then never shows while the flag stays set.
        .background(SettingsWindowVisibilityObserver { presentOnboardingIfNeeded() })
        // Changing the login item in System Settings does not recreate this
        // view, so re-read the system state whenever Panoptos comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLaunchAtLoginState()
        }
        .sheet(item: $editingDisplay) { display in
            LayoutEditorView(display: display, initialLayout: model.layout(for: display))
                .environmentObject(model)
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView { completion in
                // The first run ends on the tab the tour just pointed at; a
                // replay from General leaves the user where they were.
                let isFirstRun = !model.hasCompletedOnboarding
                model.completeOnboarding()
                isShowingOnboarding = false
                if completion == .finished, isFirstRun {
                    selectedTab = .layout
                }
            }
            .environmentObject(model)
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !model.hasCompletedOnboarding, !isShowingOnboarding, editingDisplay == nil else { return }
        isShowingOnboarding = true
    }

    private var settingsTabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                    selectedTab = tab
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func settingsScrollView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 760)
                .padding(28)
                .frame(maxWidth: .infinity)
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isAccessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(model.isAccessibilityTrusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isAccessibilityTrusted ? "Accessibility access granted" : "Accessibility access required")
                    .font(.headline)
                Text(model.isAccessibilityTrusted
                     ? "Panoptos can arrange windows and read their application menus."
                     : "Grant access in System Settings, then relaunch this exact build if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.permissionRelaunchError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if !model.isAccessibilityTrusted {
                Button("Request Access") { model.requestAccessibilityPermission() }
                Button("Relaunch Panoptos") { model.relaunchForAccessibilityPermission() }
            }
            Button(model.isAccessibilityTrusted ? "Refresh" : "Check Again") { model.checkAccessibilityPermission() }
        }
        .padding(12)
        .background(model.isAccessibilityTrusted ? Color.green.opacity(0.06) : Color.orange.opacity(0.08))
    }

    private var grantedAccessibilityRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility access").fontWeight(.medium)
                Text("Panoptos can arrange windows and read their application menus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Granted")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)) }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.callout)
            Spacer()
            Button("Dismiss") { model.compatibilityError = nil }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var layoutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(
                title: "Monitor layouts",
                description: "Split each monitor into sections, then use your window-drag shortcut to attach a window."
            ) {
                VStack(spacing: 10) {
                    ForEach(model.currentDisplays) { display in
                        let layout = model.layout(for: display)
                        let count = layout.root.leafIDs.count
                        HStack(spacing: 14) {
                            LayoutMiniature(
                                layout: layout,
                                displaySize: display.visibleFrame.size,
                                height: 46
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name).fontWeight(.semibold)
                                Text("\(count) \(count == 1 ? "section" : "sections") · \(Int(layout.gutter)) pt gutter · \(LayoutGeometry.sizeLabel(display.visibleFrame)) usable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(sectionSizeSummary(for: layout, in: display))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit Layout") { editingDisplay = display }
                                .disabled(!model.isAccessibilityTrusted)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            SettingsSection(
                title: "Unattached windows",
                description: "Choose whether visible windows outside your layouts appear beside section switchers."
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show unattached window icons").fontWeight(.medium)
                        Text("Discover visible unattached windows and display their app icons beside the nearest occupied switcher. Section focus mode also hides these apps unless they have an attached window in the focused section. When off, unattached-only apps remain visible in focus mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.showUnattachedWindowIcons)
                        .labelsHidden()
                        .disabled(!model.isAccessibilityTrusted)
                }
            }
        }
    }

    /// Compact "1912 × 1041" list so section sizes are visible without opening
    /// the editor. Long lists are truncated because this is a summary row.
    private func sectionSizeSummary(for layout: DisplayLayout, in display: CurrentDisplay) -> String {
        let frames = layout.frames(in: display.visibleFrame)
        let ordered = LayoutGeometry.readingOrder(leafIDs: layout.root.leafIDs, frames: frames)
        let limit = 4
        let sizes = ordered.prefix(limit).map { LayoutGeometry.sizeLabel(frames[$0] ?? .zero) }
        let remainder = ordered.count - sizes.count
        return sizes.joined(separator: "  ·  ") + (remainder > 0 ? "  ·  +\(remainder) more" : "")
    }

    private var startupSettings: some View {
        SettingsSection(
            title: "Startup",
            description: "macOS keeps this setting, so it also appears in System Settings › General › Login Items."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Launch at login").fontWeight(.medium)
                        Text("Starts Panoptos automatically after you log in, so your sections are ready without opening it yourself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.launchAtLogin).labelsHidden()
                }
                if let notice = model.launchAtLoginNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(notice).font(.caption)
                        Spacer()
                        if model.launchAtLoginNeedsSystemSettings {
                            Button("Open Login Items") {
                                openSystemSettingsPane("com.apple.LoginItems-Settings.extension")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var updateSettings: some View {
        SettingsSection(
            title: "Updates",
            description: "Panoptos checks panoptos.ruverse.ai for a newer version. It sends nothing else, and it never installs an update without asking."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check for updates automatically").fontWeight(.medium)
                        Text("Looks for a new version about once a day. Turn this off to check only when you ask.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.automaticallyChecksForUpdates).labelsHidden()
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current version \(currentAppVersion).")
                        Text(lastUpdateCheckLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { model.checkForUpdatesNow() }
                        .controlSize(.small)
                        .disabled(!model.canCheckForUpdates)
                }
            }
        }
    }

    private var supportSettings: some View {
        SettingsSection(
            title: "Support",
            description: "Get help, inspect the source, and read the software notices."
        ) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Feedback and bug reports").fontWeight(.medium)
                        Text("Opens the Panoptos GitHub issue tracker in your default browser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Feedback & Bug Reports…", destination: PanoptosLinks.feedback)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Free and open source").fontWeight(.medium)
                        Text("Panoptos is licensed under GPL-3.0-or-later. Third-party notices are included with the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("License…") { openBundledLegalFile(named: "LICENSE") }
                    Button("Notices…") { openBundledLegalFile(named: "NOTICE") }
                    Link("Source Code…", destination: PanoptosLinks.releaseSource(version: currentAppVersion))
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Welcome tour").fontWeight(.medium)
                        Text("Replays the first-launch introduction to layouts, attaching windows, section bars, and shortcuts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Tour") { isShowingOnboarding = true }
                }
            }
        }
    }

    private func openBundledLegalFile(named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    /// Sparkle records the date of the last completed check, including automatic
    /// ones, so this reads as history rather than as the result of pressing the
    /// button.
    private var lastUpdateCheckLabel: String {
        guard let date = model.lastUpdateCheckDate else {
            return "No update check yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    private var keepAwakeSettings: some View {
        SettingsSection(
            title: "Keep awake",
            description: "Optional sleep prevention, also available from the Panoptos menu bar item. Its icon changes while the Mac is being kept awake."
        ) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep Mac awake").fontWeight(.medium)
                        Text("Prevents the Mac from going to idle sleep while Panoptos is running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.keepMacAwake).labelsHidden()
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep screen on").fontWeight(.medium)
                        Text("Also prevents the display from sleeping. Turning this on keeps the Mac awake.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.keepScreenOn).labelsHidden()
                }
            }
        }
    }

    private var sectionBarSettings: some View {
        SettingsSection(
            title: "Section bars",
            description: "Each occupied section reserves a menu bar above the window and a switcher below it."
        ) {
            VStack(spacing: 12) {
                SectionBarStyleSelector(
                    fillsAvailableWidth: $model.sectionBarsFillAvailableWidth,
                    centersBars: $model.sectionBarsCentered
                )
                .disabled(!model.isAccessibilityTrusted)
                .opacity(model.isAccessibilityTrusted ? 1 : 0.55)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Display window menubars").fontWeight(.medium)
                        Text("Show each section's application menus above its window. When off, the window uses that space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.showWindowMenuBars)
                        .labelsHidden()
                        .disabled(!model.isAccessibilityTrusted)
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Window titles in switcher").fontWeight(.medium)
                        Text(model.windowSwitcherTitleMode == .always
                             ? "Always show each window's full title."
                             : "Show titles only when an app has multiple windows.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Window titles in switcher", selection: $model.windowSwitcherTitleMode) {
                        ForEach(WindowSwitcherTitleMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!model.isAccessibilityTrusted)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Limit window titles to \(WindowTitleFormatter.characterLimit) characters")
                            .fontWeight(.medium)
                        Text("Applies whenever window titles are shown in the switcher.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.limitWindowSwitcherTitleCharacters)
                        .labelsHidden()
                        .disabled(!model.isAccessibilityTrusted)
                }

                Divider()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Switcher size").fontWeight(.medium)
                        Text("Changes icon and target size; window-label text stays at its default size. Attached windows resize to leave room when applied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    WindowSwitcherSizeControl(scale: model.windowSwitcherUIScale) {
                        model.setWindowSwitcherUIScale($0)
                    }
                }
            }
        }
    }

    private var invocationSettings: some View {
        SettingsSection(
            title: "Command invocation",
            description: "Controls how commands selected from a section menu are delivered."
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Invoke without activating the window").fontWeight(.medium)
                    Text("Experimental. First-responder commands may fail or reach a different window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $model.invokeWithoutActivation).labelsHidden()
            }
        }
    }

    private var recommendedMacOSSettings: some View {
        SettingsSection(
            title: "Recommended macOS settings",
            description: "These system options keep the macOS menu bar and Dock from competing for space with Panoptos sections."
        ) {
            VStack(spacing: 12) {
                recommendedSystemSetting(
                    icon: "menubar.rectangle",
                    title: "Automatically hide and show the menu bar",
                    recommendation: "Set this to Always.",
                    buttonTitle: "Open Menu Bar Settings",
                    paneIdentifier: "com.apple.ControlCenter-Settings.extension"
                )

                Divider()

                recommendedSystemSetting(
                    icon: "dock.rectangle",
                    title: "Automatically hide and show the Dock",
                    recommendation: "Turn this option on.",
                    buttonTitle: "Open Desktop & Dock Settings",
                    paneIdentifier: "com.apple.Desktop-Settings.extension"
                )
            }
        }
    }

    private func recommendedSystemSetting(
        icon: String,
        title: String,
        recommendation: String,
        buttonTitle: String,
        paneIdentifier: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(recommendation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle) {
                openSystemSettingsPane(paneIdentifier)
            }
        }
    }

    private func openSystemSettingsPane(_ paneIdentifier: String) {
        let workspace = NSWorkspace.shared
        if let paneURL = URL(string: "x-apple.systempreferences:\(paneIdentifier)"),
           workspace.open(paneURL) {
            return
        }

        if let settingsURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.open(settingsURL)
        }
    }

    private var shortcutsSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shortcuts").font(.title2.weight(.semibold))
                    Text("Click a shortcut, then press a new key combination. Delete or × disables it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults") { model.resetShortcuts() }
            }

            if let error = model.shortcutError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout)
                    Spacer()
                    Button("Dismiss") { model.shortcutError = nil }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window dragging").font(.headline)
                    Text("Click a key field, hold the modifier keys you want, then release them. The window drag itself does not change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(WindowDragShortcutAction.allCases.enumerated()), id: \.element.id) { index, action in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).fontWeight(.medium)
                                Text(action.description).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ModifierShortcutRecorder(modifiers: model.windowDragShortcut(for: action)) { modifiers in
                                model.setWindowDragShortcut(modifiers, for: action)
                            }
                            .frame(width: 154, height: 28)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if index < WindowDragShortcutAction.allCases.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)) }
            }

            ForEach(ShortcutGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.headline)
                        Text(group.description).font(.caption).foregroundStyle(.secondary)
                    }
                    shortcutControls(for: group)
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutControls(for group: ShortcutGroup) -> some View {
        switch group {
        case .windowSwitching:
            directionalShortcutCluster(
                top: (.cyclePreviousWindow, "Cycle previous window"),
                left: (.focusPreviousSection, "Previous section"),
                right: (.focusNextSection, "Next section"),
                bottom: (.cycleNextWindow, "Cycle next window")
            )
        case .windowMovement:
            VStack(alignment: .leading, spacing: 14) {
                directionalShortcutCluster(
                    top: (.moveApplicationEarlier, "Move application earlier"),
                    left: (.cycleWindowLeft, "Move window left"),
                    right: (.cycleWindowRight, "Move window right"),
                    bottom: (.moveApplicationLater, "Move application later")
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("Extend across sections")
                        .font(.subheadline.weight(.medium))
                    HStack(spacing: 10) {
                        shortcutCard(.spanWindowLeft)
                        shortcutCard(.spanWindowRight)
                    }
                }
            }
        case .sectionFocus:
            VStack(spacing: 0) {
                ForEach(Array(group.commands.enumerated()), id: \.element.id) { index, command in
                    shortcutRow(command)
                    if index < group.commands.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)) }
        }
    }

    private func directionalShortcutCluster(
        top: (command: ShortcutCommand, title: String),
        left: (command: ShortcutCommand, title: String),
        right: (command: ShortcutCommand, title: String),
        bottom: (command: ShortcutCommand, title: String)
    ) -> some View {
        VStack(spacing: 10) {
            shortcutCard(top.command, title: top.title)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                shortcutCard(left.command, title: left.title)
                shortcutCard(right.command, title: right.title)
            }
            shortcutCard(bottom.command, title: bottom.title)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcutCard(_ command: ShortcutCommand, title: String? = nil) -> some View {
        shortcutRow(command, title: title)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)) }
    }

    private func shortcutRow(_ command: ShortcutCommand, title: String? = nil) -> some View {
        HStack(spacing: 12) {
            Text(title ?? command.title)
                .fontWeight(.medium)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 0)
            ShortcutRecorder(shortcut: model.shortcut(for: command)) { shortcut in
                model.setShortcut(shortcut, for: command)
            }
            .frame(width: 154, height: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }
}

/// Reports each time the window hosting the settings view becomes visible on
/// screen, and once on attachment if it already is. Occlusion state comes from
/// the window server, so unlike key status it does not depend on the app being
/// active. The welcome tour presents from this signal because it is the first
/// moment a sheet on that window is guaranteed to show, whichever way the
/// window was opened.
private struct SettingsWindowVisibilityObserver: NSViewRepresentable {
    let onBecomeVisible: () -> Void

    func makeNSView(context: Context) -> VisibilityObservingView {
        let view = VisibilityObservingView()
        view.onBecomeVisible = onBecomeVisible
        return view
    }

    func updateNSView(_ nsView: VisibilityObservingView, context: Context) {
        nsView.onBecomeVisible = onBecomeVisible
    }

    final class VisibilityObservingView: NSView {
        var onBecomeVisible: () -> Void = {}
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window.occlusionState.contains(.visible) else { return }
                self?.onBecomeVisible()
            }
            if window.occlusionState.contains(.visible) {
                DispatchQueue.main.async { [weak self] in self?.onBecomeVisible() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Scaled-down, non-interactive drawing of a display's sections. Section
/// proportions come from the real layout tree, but the gutter is drawn at a
/// legible minimum: a scaled 10 pt gutter would be a sub-pixel gap here and the
/// separations would disappear.
private struct LayoutMiniature: View {
    let layout: DisplayLayout
    let displaySize: CGSize
    let height: CGFloat

    private static let minimumGap: CGFloat = 2

    var body: some View {
        let width = max(height * (displaySize.width / max(displaySize.height, 1)), 12)
        let gap = layout.gutter > 0 ? Self.minimumGap : 0
        let bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height)).insetBy(dx: gap, dy: gap)
        let frames = layout.root.frames(in: bounds, dividerWidth: gap)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(0.07))
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.primary.opacity(0.12))
            ForEach(layout.root.leafIDs, id: \.self) { id in
                if let frame = frames[id] {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                        .offset(x: frame.minX, y: height - frame.maxY)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

private struct SectionBarStyleSelector: View {
    @Binding var fillsAvailableWidth: Bool
    @Binding var centersBars: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Section bars").font(.subheadline.weight(.semibold))
                Text("Choose how the menu and window bars sit inside each section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Width").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SectionBarStyleCard(
                            title: "Full width",
                            fillsAvailableWidth: true,
                            centersBars: false,
                            isSelected: fillsAvailableWidth
                        ) { fillsAvailableWidth = true }
                        SectionBarStyleCard(
                            title: "Fit content",
                            fillsAvailableWidth: false,
                            centersBars: false,
                            isSelected: !fillsAvailableWidth
                        ) { fillsAvailableWidth = false }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 82)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Alignment").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        SectionBarStyleCard(
                            title: "Left",
                            fillsAvailableWidth: fillsAvailableWidth,
                            centersBars: false,
                            isSelected: !centersBars
                        ) { centersBars = false }
                        SectionBarStyleCard(
                            title: "Center",
                            fillsAvailableWidth: fillsAvailableWidth,
                            centersBars: true,
                            isSelected: centersBars
                        ) { centersBars = true }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)) }
    }
}

private struct SectionBarStyleCard: View {
    let title: String
    let fillsAvailableWidth: Bool
    let centersBars: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                SectionBarMiniature(
                    fillsAvailableWidth: fillsAvailableWidth,
                    centersBars: centersBars,
                    isSelected: isSelected
                )
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SectionBarMiniature: View {
    let fillsAvailableWidth: Bool
    let centersBars: Bool
    let isSelected: Bool

    var body: some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 4
            let availableWidth = max(0, geometry.size.width - horizontalInset * 2)
            let barWidth = fillsAvailableWidth ? availableWidth : availableWidth * 0.56
            let barX = !fillsAvailableWidth && centersBars
                ? (geometry.size.width - barWidth) / 2
                : horizontalInset
            let contentWidth = max(8, barWidth * 0.48)
            let contentX = centersBars
                ? barX + (barWidth - contentWidth) / 2
                : barX + 3
            let backgroundColor = isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.13)
            let contentColor = isSelected ? Color.accentColor : Color.secondary.opacity(0.72)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.11))
                    .frame(width: availableWidth - 8, height: 17)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                RoundedRectangle(cornerRadius: 2)
                    .fill(backgroundColor)
                    .frame(width: barWidth, height: 7)
                    .offset(x: barX, y: 5)
                HStack(spacing: 2) {
                    Circle().frame(width: 3, height: 3)
                    Capsule().frame(width: max(3, contentWidth * 0.32), height: 2.5)
                    Capsule().frame(width: max(3, contentWidth * 0.42), height: 2.5)
                }
                .foregroundStyle(contentColor)
                .frame(width: contentWidth, height: 7, alignment: .leading)
                .offset(x: contentX, y: 5)
                RoundedRectangle(cornerRadius: 2)
                    .fill(backgroundColor)
                    .frame(width: barWidth, height: 7)
                    .offset(x: barX, y: geometry.size.height - 12)
                HStack(spacing: 2) {
                    Circle().frame(width: 3, height: 3)
                    Capsule().frame(width: max(3, contentWidth * 0.27), height: 2.5)
                    Capsule().frame(width: max(3, contentWidth * 0.37), height: 2.5)
                }
                .foregroundStyle(contentColor)
                .frame(width: contentWidth, height: 7, alignment: .leading)
                .offset(x: contentX, y: geometry.size.height - 12)
            }
        }
        .frame(height: 40)
    }
}

private struct WindowSwitcherSizeControl: View {
    let scale: Double
    let commit: (Double) -> Void
    @State private var draftScale: Double
    @State private var isEditing = false

    init(scale: Double, commit: @escaping (Double) -> Void) {
        self.scale = scale
        self.commit = commit
        _draftScale = State(initialValue: scale)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 10) {
                Slider(
                    value: $draftScale,
                    in: WindowSwitcherSize.minimumScale...WindowSwitcherSize.maximumScale,
                    step: WindowSwitcherSize.scaleStep,
                    onEditingChanged: { editing in
                        isEditing = editing
                        if !editing { commit(draftScale) }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Switcher size")
                Text(Self.displayText(for: draftScale))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            HStack {
                Text("1×")
                Spacer()
                Text("3×")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 220)
            .padding(.trailing, 52)
            .accessibilityHidden(true)
        }
        .frame(width: 272)
        .onChange(of: scale) { _, newScale in
            guard !isEditing else { return }
            draftScale = newScale
        }
    }

    private static func displayText(for scale: Double) -> String {
        let quarterSteps = Int((WindowSwitcherSize.normalized(scale) * 4).rounded())
        switch quarterSteps % 4 {
        case 0:
            return "\(quarterSteps / 4)×"
        case 2:
            return String(format: "%.1f×", Double(quarterSteps) / 4)
        default:
            return String(format: "%.2f×", Double(quarterSteps) / 4)
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case layout
    case shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .layout: "Layout"
        case .shortcuts: "Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .layout: "rectangle.split.2x1"
        case .shortcuts: "command"
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(minWidth: 64)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.primary.opacity(0.08) : isHovered ? Color.primary.opacity(0.04) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct LayoutEditorView: View {
    @EnvironmentObject private var model: PanoptosModel
    @Environment(\.dismiss) private var dismiss
    let display: CurrentDisplay
    @State private var draft: DisplayLayout
    @State private var selectedLeafID: UUID?
    @State private var didCommit = false

    /// Exact section frames in display points, recomputed from the draft so the
    /// rulers and section labels always match what Save would apply.
    private var sectionFrames: [UUID: CGRect] {
        draft.frames(in: display.visibleFrame)
    }

    init(display: CurrentDisplay, initialLayout: DisplayLayout) {
        self.display = display
        _draft = State(initialValue: initialLayout)
        _selectedLeafID = State(initialValue: initialLayout.root.leafIDs.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit \(display.name)").font(.title2.weight(.semibold))
                    Text("Select a section to split it, or drag a divider to resize.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            SplitTreeEditor(node: $draft.root, selectedLeafID: $selectedLeafID, frames: sectionFrames) {
                model.preview(draft)
            }
            .aspectRatio(max(display.visibleFrame.width / max(display.visibleFrame.height, 1), 1.2), contentMode: .fit)
            .frame(maxWidth: 760, maxHeight: 460)
            .padding(28)

            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gutter").fontWeight(.medium)
                    Text("Adds equal spacing between sections, around display edges, and between bars and windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Stepper(value: $draft.gutter, in: DisplayLayout.gutterRange, step: 1) {
                    Text("\(Int(draft.gutter)) pt")
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .onChange(of: draft.gutter) { _, _ in model.preview(draft) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            HStack {
                Button { split(.horizontal) } label: {
                    Label("Split Left / Right", systemImage: SplitAxis.horizontal.systemImage)
                }
                Button { split(.vertical) } label: {
                    Label("Split Top / Bottom", systemImage: SplitAxis.vertical.systemImage)
                }
                Button(role: .destructive) { removeSelected() } label: {
                    Label("Remove Section", systemImage: "trash")
                }
                .disabled(draft.root.leafIDs.count == 1 || selectedLeafID == nil)
                Spacer()
                Button("Cancel") {
                    model.cancelLayoutPreview(for: display)
                    dismiss()
                }
                Button("Save") {
                    didCommit = true
                    model.commit(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { model.beginLayoutPreview(for: display) }
        .onDisappear {
            if !didCommit { model.cancelLayoutPreview(for: display) }
        }
    }

    private func split(_ axis: SplitAxis) {
        guard let selectedLeafID else { return }
        draft.root = draft.root.splitting(leafID: selectedLeafID, axis: axis)
        model.preview(draft)
    }

    private func removeSelected() {
        guard let selectedLeafID, let result = draft.root.removing(leafID: selectedLeafID) else { return }
        draft.root = result.node
        self.selectedLeafID = result.survivor
        model.preview(draft, migrating: [selectedLeafID: result.survivor])
    }
}

private struct SplitTreeEditor: View {
    @Binding var node: LayoutNode
    @Binding var selectedLeafID: UUID?
    let frames: [UUID: CGRect]
    let onChange: () -> Void

    var body: some View {
        SplitTreeNodeView(node: $node, selectedLeafID: $selectedLeafID, frames: frames, onChange: onChange)
            .padding(6)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SplitTreeNodeView: View {
    @Binding var node: LayoutNode
    @Binding var selectedLeafID: UUID?
    let frames: [UUID: CGRect]
    let onChange: () -> Void

    var body: some View { rendered() }

    private func rendered() -> AnyView {
        switch node {
        case .leaf(let id):
            let isSelected = selectedLeafID == id
            return AnyView(
                Button { selectedLeafID = id } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                        VStack(spacing: 2) {
                            Text("Section")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("\(LayoutGeometry.sizeLabel(frames[id] ?? .zero)) pt")
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 6)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Section \(LayoutGeometry.sizeLabel(frames[id] ?? .zero)) points")
            )
        case .split(let id, let axis, let ratio, _, _):
            return AnyView(
                GeometryReader { geometry in
                    let length = axis == .horizontal ? geometry.size.width : geometry.size.height
                    let divider: CGFloat = 8
                    let available = max(1, length - divider)
                    let firstLength = available * ratio
                    Group {
                        if axis == .horizontal {
                            HStack(spacing: 0) {
                                childView(first: true).frame(width: firstLength)
                                dividerView(splitID: id, axis: axis, size: geometry.size)
                                    .frame(width: divider)
                                childView(first: false)
                            }
                        } else {
                            VStack(spacing: 0) {
                                childView(first: true).frame(height: firstLength)
                                dividerView(splitID: id, axis: axis, size: geometry.size)
                                    .frame(height: divider)
                                childView(first: false)
                            }
                        }
                    }
                }
            )
        }
    }

    private func childView(first: Bool) -> some View {
        SplitTreeNodeView(
            node: childBinding(first: first),
            selectedLeafID: $selectedLeafID,
            frames: frames,
            onChange: onChange
        )
    }

    private func childBinding(first useFirst: Bool) -> Binding<LayoutNode> {
        Binding(
            get: {
                guard case .split(_, _, _, let first, let second) = node else { return node }
                return useFirst ? first : second
            },
            set: { updated in
                guard case .split(let id, let axis, let ratio, let first, let second) = node else { return }
                node = .split(
                    id: id,
                    axis: axis,
                    ratio: ratio,
                    first: useFirst ? updated : first,
                    second: useFirst ? second : updated
                )
            }
        )
    }

    private func dividerView(splitID: UUID, axis: SplitAxis, size: CGSize) -> some View {
        SplitDivider(node: $node, splitID: splitID, axis: axis, size: size, onChange: onChange)
    }
}

private struct SplitDivider: View {
    @Binding var node: LayoutNode
    let splitID: UUID
    let axis: SplitAxis
    let size: CGSize
    let onChange: () -> Void
    @State private var startingRatio: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isShowingResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(isHovering || isDragging ? 0.95 : 0.65))
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                syncCursor()
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            syncCursor()
                        }
                        let current = ratio(for: splitID, in: node) ?? 0.5
                        if startingRatio == nil { startingRatio = current }
                        let length = max(axis == .horizontal ? size.width : size.height, 1)
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        let minimum = min(0.45, 160 / length)
                        let updated = min(max((startingRatio ?? current) + translation / length, minimum), 1 - minimum)
                        node = node.replacingSplit(id: splitID, ratio: updated)
                        onChange()
                    }
                    .onEnded { _ in
                        startingRatio = nil
                        isDragging = false
                        syncCursor()
                    }
            )
            // A divider can disappear mid-drag when its section is removed, so
            // never leave a pushed cursor behind.
            .onDisappear {
                isHovering = false
                isDragging = false
                syncCursor()
            }
    }

    private var resizeCursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    /// Keeps the resize cursor visible while hovering and for the whole drag,
    /// including when the pointer runs past the divider. Pushes and pops stay
    /// balanced because the cursor state is derived, not toggled per event.
    private func syncCursor() {
        let shouldShowResizeCursor = isHovering || isDragging
        guard shouldShowResizeCursor != isShowingResizeCursor else { return }
        isShowingResizeCursor = shouldShowResizeCursor
        if shouldShowResizeCursor {
            resizeCursor.push()
        } else {
            NSCursor.pop()
        }
    }

    private func ratio(for id: UUID, in node: LayoutNode) -> CGFloat? {
        switch node {
        case .leaf:
            nil
        case .split(let nodeID, _, let ratio, let first, let second):
            nodeID == id ? ratio : self.ratio(for: id, in: first) ?? self.ratio(for: id, in: second)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            content
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)) }
        }
    }
}
