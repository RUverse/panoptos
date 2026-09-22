import AppKit
import SwiftUI

/// The pages of the welcome tour, in the order they are shown.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case accessibility
    case dock
    case layout
    case attach
    case bars
    case shortcuts

    var id: Int { rawValue }

    var isFirst: Bool { self == Self.allCases.first }
    var isLast: Bool { self == Self.allCases.last }
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
    var previous: OnboardingPage? { OnboardingPage(rawValue: rawValue - 1) }

    var title: String {
        switch self {
        case .welcome: "Welcome to Panoptos"
        case .accessibility: "Allow Accessibility access"
        case .dock: "Make room for your windows"
        case .layout: "Set up your layout"
        case .attach: "Attach windows to sections"
        case .bars: "Menus and switcher"
        case .shortcuts: "Switch with shortcuts"
        }
    }

    /// The page's explanation, quoting the user's current bindings where the
    /// tour tells them which keys to hold.
    func detail(_ shortcuts: OnboardingShortcutSummary) -> String {
        switch self {
        case .welcome:
            return "Panoptos splits each display into sections, fits windows into them, and can show each window's menus right above it. It lives in your menu bar: click the three-eye icon to open settings, refresh windows, or quit."
        case .accessibility:
            return "Panoptos arranges windows and reads application menus through macOS Accessibility. Turn it on for Panoptos under Privacy & Security › Accessibility in System Settings. Nothing else is needed, and Panoptos never records your screen."
        case .dock:
            return "We recommend automatically hiding the Dock to give your sections more space. In System Settings › Desktop & Dock, turn on “Automatically hide and show the Dock.” You can still reveal it by moving the pointer to its edge of the screen."
        case .layout:
            return "Open the Layout tab and click Edit Layout for a display. Select a section to split it left/right or top/bottom, drag a divider to resize, then Save. Each display keeps its own layout."
        case .attach:
            return Self.attachDetail(shortcuts)
        case .bars:
            return "Every occupied section shows a window switcher below its window and can show the active app's menus above it. Menu bars are off by default: turn on Show Menu Bars from the Panoptos menu bar item or in Appearance. Click the switcher to change windows, drag to reorder, or right-click to detach a window or focus the section."
        case .shortcuts:
            return "Cycle through a section's windows, jump to the neighboring section, move windows between sections, or give one section the whole screen without reaching for the mouse. Change any of these in the Shortcuts tab."
        }
    }

    private static func attachDetail(_ shortcuts: OnboardingShortcutSummary) -> String {
        let single = shortcuts.attachWindow.flatMap { $0.isEmpty ? nil : $0.displayText }
        let all = shortcuts.attachApplicationWindows.flatMap { $0.isEmpty ? nil : $0.displayText }
        var sentences: [String] = []
        switch (single, all) {
        case (let single?, let all?):
            sentences.append("Hold \(single) as you finish dragging a window to drop it into the highlighted section, or hold \(all) to bring every window of that app.")
        case (let single?, nil):
            sentences.append("Hold \(single) as you finish dragging a window to drop it into the highlighted section.")
        case (nil, let all?):
            sentences.append("Hold \(all) as you finish dragging a window to attach every window of that app to the highlighted section.")
        case (nil, nil):
            sentences.append("Window-drag attachment is turned off; choose modifier keys under Shortcuts › Window dragging to turn it on.")
        }
        // The move-window shortcuts double as keyboard attachment: with an
        // unattached window focused they attach it to the edge section.
        let moveKeys = shortcuts.edgeAttachKeys
        if !moveKeys.isEmpty {
            sentences.append("With an unattached window focused, \(moveKeys.joined(separator: " or ")) attaches it to the section at that edge of its display.")
        }
        return sentences.joined(separator: " ")
    }
}

/// One line of the shortcuts page: a task and the keys currently bound to it.
/// A nil key means the user disabled that command.
struct OnboardingShortcutRow: Equatable, Identifiable {
    let title: String
    let keys: [String?]

    var id: String { title }
}

/// The bindings the tour quotes, captured from the model so the pages describe
/// the user's shortcuts rather than the defaults.
struct OnboardingShortcutSummary: Equatable {
    var attachWindow: ShortcutModifiers?
    var attachApplicationWindows: ShortcutModifiers?
    var bindings: [ShortcutCommand: GlobalShortcut]

    static let defaults = OnboardingShortcutSummary(
        attachWindow: WindowDragShortcuts.defaults.attachWindow,
        attachApplicationWindows: WindowDragShortcuts.defaults.attachApplicationWindows,
        bindings: ShortcutPersistence.defaults
    )

    var rows: [OnboardingShortcutRow] {
        [
            OnboardingShortcutRow(title: "Cycle windows", keys: keys(.cyclePreviousWindow, .cycleNextWindow)),
            OnboardingShortcutRow(title: "Switch section", keys: keys(.focusPreviousSection, .focusNextSection)),
            OnboardingShortcutRow(title: "Move window", keys: keys(.cycleWindowLeft, .cycleWindowRight)),
            OnboardingShortcutRow(title: "Focus section", keys: keys(.toggleSectionFocus))
        ]
    }

    func displayText(for command: ShortcutCommand) -> String? {
        bindings[command]?.displayText
    }

    /// The move-window bindings, left then right, that also attach an
    /// unattached focused window to the section at that edge of its display.
    var edgeAttachKeys: [String] {
        [displayText(for: .cycleWindowLeft), displayText(for: .cycleWindowRight)].compactMap { $0 }
    }

    private func keys(_ commands: ShortcutCommand...) -> [String?] {
        commands.map(displayText(for:))
    }
}

@MainActor
extension OnboardingShortcutSummary {
    init(model: PanoptosModel) {
        self.init(
            attachWindow: model.windowDragShortcut(for: .attachWindow),
            attachApplicationWindows: model.windowDragShortcut(for: .attachApplicationWindows),
            bindings: Dictionary(uniqueKeysWithValues: ShortcutCommand.allCases.compactMap { command in
                model.shortcut(for: command).map { (command, $0) }
            })
        )
    }
}

enum OnboardingCompletion {
    case skipped
    case finished
}

/// The welcome tour sheet: page dots, title, and explanation on the left, an
/// illustration on the right. Only Skip and Done dismiss it, so a closed sheet
/// always means the completion was recorded.
struct OnboardingView: View {
    @EnvironmentObject private var model: PanoptosModel
    @State private var page: OnboardingPage
    let onComplete: (OnboardingCompletion) -> Void

    init(initialPage: OnboardingPage = .welcome, onComplete: @escaping (OnboardingCompletion) -> Void) {
        _page = State(initialValue: initialPage)
        self.onComplete = onComplete
    }

    private var summary: OnboardingShortcutSummary { OnboardingShortcutSummary(model: model) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                pageIndicator
                Group {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                        .padding(.top, 20)
                    Text(page.detail(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .fixedSize(horizontal: false, vertical: true)
                .id(page)
                .transition(.opacity)
                Spacer(minLength: 12)
                if page == .accessibility {
                    accessibilityStatus
                        .padding(.bottom, 12)
                }
                if page == .dock {
                    Button("Open Desktop & Dock Settings") { openDockSettings() }
                        .padding(.bottom, 12)
                }
                buttons
            }
            .frame(width: 252)
            .padding(22)

            ZStack {
                OnboardingIllustration(page: page, summary: summary, showsMenuBars: model.showWindowMenuBars)
                    .id(page)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .padding(.trailing, 12)
        }
        .frame(width: 640, height: 372)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: page)
        .interactiveDismissDisabled()
        .onExitCommand { onComplete(.skipped) }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { candidate in
                Button { page = candidate } label: {
                    Circle()
                        .fill(candidate == page ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 8, height: 8)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(candidate.rawValue + 1) of \(OnboardingPage.allCases.count)")
                .accessibilityAddTraits(candidate == page ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        if model.isAccessibilityTrusted {
            Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                Label("Not allowed yet", systemImage: "exclamationmark.shield.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button("Request Access") { model.requestAccessibilityPermission() }
                    .controlSize(.small)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if page.isFirst {
                Button("Skip") { onComplete(.skipped) }
                Button("Show Me Around") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Previous") {
                    if let previous = page.previous { page = previous }
                }
                if page.isLast {
                    Button("Done") { onComplete(.finished) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Next") { advance() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
    }

    private func advance() {
        if let next = page.next { page = next }
    }

    private func openDockSettings() {
        let workspace = NSWorkspace.shared
        if let paneURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"),
           workspace.open(paneURL) {
            return
        }
        if let settingsURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            workspace.open(settingsURL)
        }
    }
}

// MARK: - Illustrations

/// Schematic drawings of the app, laid out in a fixed 300 × 300 canvas so each
/// page composes the same way regardless of the sheet's exact size.
private struct OnboardingIllustration: View {
    let page: OnboardingPage
    let summary: OnboardingShortcutSummary
    let showsMenuBars: Bool

    static let canvas = CGSize(width: 300, height: 300)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .underPageBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08))
            content
                .frame(width: Self.canvas.width, height: Self.canvas.height)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: WelcomeIllustration(showsMenuBars: showsMenuBars)
        case .accessibility: AccessibilityIllustration()
        case .dock: DockIllustration()
        case .layout: LayoutIllustration()
        case .attach: AttachIllustration(summary: summary)
        case .bars: BarsIllustration(summary: summary)
        case .shortcuts: ShortcutsIllustration(rows: summary.rows)
        }
    }
}

private struct WelcomeIllustration: View {
    let showsMenuBars: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            MockMenuBar()
                .frame(width: 300, height: 26)
            MockMenuBarMenu(showsMenuBars: showsMenuBars)
                .frame(width: 176)
                .offset(x: 122, y: 30)
            HStack(spacing: 8) {
                MockSection(appTitle: "Editor", switcherIcons: [.blue, .orange])
                MockSection(appTitle: "Mail", switcherIcons: [.green])
            }
            .frame(width: 300, height: 128)
            .offset(y: 172)
        }
        .frame(width: 300, height: 300, alignment: .topLeading)
        .overlayPreferenceValue(WelcomeMenuIconAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let icon = geometry[anchor]
                    CurvedArrow(
                        from: CGPoint(x: 44, y: 150),
                        to: CGPoint(x: icon.minX - 5, y: icon.midY),
                        control: CGPoint(x: 40, y: icon.midY)
                    )
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct WelcomeMenuIconAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct DockIllustration: View {
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 8) {
                MockSection(appTitle: "Editor", switcherIcons: [.blue, .orange])
                MockSection(appTitle: "Mail", switcherIcons: [.green])
            }
            .frame(height: 160)

            VStack(alignment: .leading, spacing: 12) {
                Label("Desktop & Dock", systemImage: "dock.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                HStack(spacing: 12) {
                    Text("Automatically hide and show the Dock")
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                    // An illustration of the recommended setting, not a control.
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 28, height: 16)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                        }
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)) }
        }
        .frame(width: 300, height: 300)
    }
}

private struct AccessibilityIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                    Text("Privacy & Security › Accessibility")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Allow the applications below to control your computer.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    MockPermissionRow(name: nil, tint: .gray, isOn: false)
                    Divider().padding(.leading, 40)
                    MockPermissionRow(name: "Panoptos", tint: .accentColor, isOn: true)
                    Divider().padding(.leading, 40)
                    MockPermissionRow(name: nil, tint: .gray, isOn: false)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)) }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)) }
            .offset(y: 36)

            CurvedArrow(
                from: CGPoint(x: 150, y: 262),
                to: CGPoint(x: 262, y: 164),
                control: CGPoint(x: 262, y: 262)
            )
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 300, height: 300, alignment: .topLeading)
    }
}

private struct LayoutIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MockTabStrip(selected: "Layout")
                .frame(width: 300, height: 36)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.12))
                MockLayoutSection(isSelected: true)
                    .frame(width: 126, height: 150)
                    .offset(x: 8, y: 8)
                MockLayoutSection(isSelected: false)
                    .frame(width: 146, height: 71)
                    .offset(x: 146, y: 8)
                MockLayoutSection(isSelected: false)
                    .frame(width: 146, height: 71)
                    .offset(x: 146, y: 87)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: 6, height: 150)
                    .offset(x: 137, y: 8)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Color.accentColor, in: Circle())
                    .offset(x: 129, y: 72)
            }
            .frame(width: 300, height: 166)
            .offset(y: 44)

            HStack(spacing: 6) {
                MockButton(title: "Split Left / Right", systemImage: SplitAxis.horizontal.systemImage)
                MockButton(title: "Split Top / Bottom", systemImage: SplitAxis.vertical.systemImage)
                Spacer(minLength: 0)
                MockButton(title: "Save", systemImage: nil, isProminent: true)
            }
            .frame(width: 300, height: 26)
            .offset(y: 222)

            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 12))
                Text("Select a section, then split it or drag a divider.")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
            .frame(width: 300, alignment: .leading)
            .offset(y: 262)
        }
        .frame(width: 300, height: 300, alignment: .topLeading)
    }
}

private struct AttachIllustration: View {
    let summary: OnboardingShortcutSummary

    private var singleKeys: String? {
        summary.attachWindow.flatMap { $0.isEmpty ? nil : $0.displayText }
    }

    private var allKeys: String? {
        summary.attachApplicationWindows.flatMap { $0.isEmpty ? nil : $0.displayText }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 138, height: 178)
                    .offset(x: 8, y: 8)
                MockWindow()
                    .frame(width: 118, height: 128)
                    .offset(x: 18, y: 32)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 138, height: 178)
                    .offset(x: 154, y: 8)
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: 138, height: 178)
                    .offset(x: 154, y: 8)
            }
            .frame(width: 300, height: 194)
            .offset(y: 20)

            CurvedArrow(
                from: CGPoint(x: 96, y: 96),
                to: CGPoint(x: 188, y: 78),
                control: CGPoint(x: 140, y: 52)
            )
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            MockWindow()
                .frame(width: 118, height: 96)
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
                .offset(x: 150, y: 96)
            Image(systemName: "cursorarrow")
                .font(.system(size: 15))
                .offset(x: 206, y: 100)
            KeyCap(text: singleKeys ?? "⇧", isEnabled: singleKeys != nil)
                .offset(x: 222, y: 114)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        KeyCap(text: singleKeys ?? "Off", isEnabled: singleKeys != nil)
                        Text("Attach window")
                    }
                    HStack(spacing: 6) {
                        KeyCap(text: allKeys ?? "Off", isEnabled: allKeys != nil)
                        Text("Attach all app windows")
                    }
                }
                HStack(spacing: 6) {
                    if summary.edgeAttachKeys.isEmpty {
                        KeyCap(text: "Off", isEnabled: false)
                    } else {
                        ForEach(summary.edgeAttachKeys, id: \.self) { keys in
                            KeyCap(text: keys)
                        }
                    }
                    Text("Attach focused window to that edge")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 300, alignment: .leading)
            .offset(y: 228)
        }
        .frame(width: 300, height: 300, alignment: .topLeading)
    }
}

private struct BarsIllustration: View {
    let summary: OnboardingShortcutSummary

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.blue).frame(width: 9, height: 9)
                        Text("Editor").font(.system(size: 11, weight: .bold))
                    }
                    .padding(.trailing, 10)
                    ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { title in
                        Text(title)
                            .font(.system(size: 11))
                            .padding(.horizontal, 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Color.primary.opacity(0.09), in: Capsule())

                MockWindow()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MockSwitcher(icons: [.blue, .orange, .green], selectedIndex: 0, title: "Draft", height: 30)
            }
            .padding(10)
            .frame(width: 300, height: 232)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)) }
            .offset(y: 12)

            Image(systemName: "cursorarrow")
                .font(.system(size: 15))
                .offset(x: 158, y: 222)
            VStack(alignment: .leading, spacing: 0) {
                MockMenuRow(title: "Detach Window", shortcut: nil)
                MockMenuRow(title: "Focus Section", shortcut: summary.displayText(for: .toggleSectionFocus))
            }
            .frame(width: 150)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.14)) }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .offset(x: 146, y: 236)
        }
        .frame(width: 300, height: 300, alignment: .topLeading)
    }
}

private struct ShortcutsIllustration: View {
    let rows: [OnboardingShortcutRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, keys in
                        KeyCap(text: keys ?? "Off", isEnabled: keys != nil)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .frame(width: 272)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)) }
        .frame(width: 300, height: 300)
    }
}

// MARK: - Illustration parts

private struct MockMenuBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 13, height: 13)
                .foregroundStyle(.white)
                .frame(width: 22, height: 18)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                .anchorPreference(key: WelcomeMenuIconAnchor.self, value: .bounds) { $0 }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("4:20 PM").monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.09))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }
}

private struct MockMenuBarMenu: View {
    let showsMenuBars: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockMenuRow(title: "Open Panoptos Settings", shortcut: nil, isHighlighted: true)
            MockMenuRow(title: "Refresh Windows", shortcut: nil)
            MockMenuRow(title: "Show Menu Bars", shortcut: nil, isChecked: showsMenuBars)
            Divider().padding(.horizontal, 6)
            MockMenuRow(title: "Quit Panoptos", shortcut: "⌘Q")
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.14)) }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}

private struct MockMenuRow: View {
    let title: String
    let shortcut: String?
    var isHighlighted = false
    var isChecked = false

    var body: some View {
        HStack(spacing: 4) {
            Text(isChecked ? "✓" : " ")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 8)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let shortcut {
                Text(shortcut).foregroundStyle(isHighlighted ? .white : .secondary)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
    }
}

private struct MockPermissionRow: View {
    let name: String?
    let tint: Color
    let isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if name != nil {
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(.white)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
            .background(tint.opacity(name == nil ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 5))
            if let name {
                Text(name).font(.system(size: 11, weight: .medium))
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 84, height: 7)
            }
            Spacer(minLength: 0)
            MockToggle(isOn: isOn)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

private struct MockToggle: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.18))
            Circle()
                .fill(.white)
                .padding(2)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        }
        .frame(width: 30, height: 17)
    }
}

/// The settings tab bar as `SettingsTabButton` draws it: icon above label,
/// centered, with the selected tab tinted and backed.
private struct MockTabStrip: View {
    let selected: String

    private static let tabs: [(title: String, systemImage: String)] = [
        ("General", "gearshape"),
        ("Appearance", "paintbrush"),
        ("Layout", "rectangle.split.2x1"),
        ("Shortcuts", "command")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.tabs, id: \.title) { tab in
                let isSelected = tab.title == selected
                VStack(spacing: 2) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(height: 13)
                    Text(tab.title)
                        .font(.system(size: 8))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(minWidth: 44)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(isSelected ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MockLayoutSection: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            Text("Section")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MockButton: View {
    let title: String
    let systemImage: String?
    var isProminent = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.system(size: 10, weight: isProminent ? .semibold : .regular))
        .foregroundStyle(isProminent ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            isProminent ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(isProminent ? 0 : 0.15)) }
    }
}

/// A window card: title bar with traffic lights and a few lines of content.
private struct MockWindow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.85))
                Circle().fill(Color.yellow.opacity(0.85))
                Circle().fill(Color.green.opacity(0.85))
            }
            .frame(height: 7)
            .padding(8)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.primary.opacity(0.16)).frame(width: 60, height: 5)
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 5)
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 5)
                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 40, height: 5)
            }
            .padding(10)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14)) }
    }
}

/// A section as Panoptos draws it: menu bar above the window, switcher below.
private struct MockSection: View {
    let appTitle: String
    let switcherIcons: [Color]

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(switcherIcons.first ?? .blue).frame(width: 6, height: 6)
                Text(appTitle).font(.system(size: 7, weight: .bold))
                ForEach(["File", "Edit", "View"], id: \.self) { title in
                    Text(title).font(.system(size: 7))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 13)
            .background(Color.primary.opacity(0.09), in: Capsule())
            MockWindow()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            MockSwitcher(icons: switcherIcons, selectedIndex: 0, title: nil, height: 16)
        }
        .padding(5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)) }
    }
}

/// The window switcher capsule: one icon per window, grouped by application.
/// It sizes to its content so the containing stack centers it.
private struct MockSwitcher: View {
    let icons: [Color]
    let selectedIndex: Int
    let title: String?
    let height: CGFloat

    var body: some View {
        let iconSize = max(8, height - 10)
        HStack(spacing: 4) {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, color in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: iconSize * 0.24)
                        .fill(color)
                        .frame(width: iconSize, height: iconSize)
                    if index == selectedIndex, let title {
                        Text(title).font(.system(size: 10))
                    }
                }
                .padding(.horizontal, 3)
                .frame(height: height - 6)
                .background(
                    index == selectedIndex ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                if index < icons.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 1, height: iconSize)
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(height: height)
        .background(Color.primary.opacity(0.09), in: Capsule())
    }
}

private struct KeyCap: View {
    let text: String
    var isEnabled = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.18)) }
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
    }
}

/// A quadratic curve with an arrowhead at its end, in the canvas' top-left
/// coordinate space.
private struct CurvedArrow: Shape {
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    var headLength: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)

        let direction = CGVector(dx: to.x - control.x, dy: to.y - control.y)
        let length = max(hypot(direction.dx, direction.dy), 0.001)
        let unit = CGVector(dx: direction.dx / length, dy: direction.dy / length)
        let normal = CGVector(dx: -unit.dy, dy: unit.dx)
        let base = CGPoint(x: to.x - unit.dx * headLength, y: to.y - unit.dy * headLength)
        let halfWidth = headLength * 0.6
        path.move(to: CGPoint(x: base.x + normal.dx * halfWidth, y: base.y + normal.dy * halfWidth))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: base.x - normal.dx * halfWidth, y: base.y - normal.dy * halfWidth))
        return path
    }
}
