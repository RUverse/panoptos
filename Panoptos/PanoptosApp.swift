import AppKit
import SwiftUI

enum PanoptosLinks {
    static let source = URL(string: "https://github.com/RUverse/panoptos")!
    static let feedback = source.appending(path: "issues")

    static func releaseSource(version: String) -> URL {
        source.appending(path: "releases/tag/v\(version)")
    }
}

struct LoginLaunchWindowState {
    private(set) var isLoginLaunch = false
    private var didHandleInitialSettingsAppearance = false

    mutating func recordLaunch(isDefaultLaunch: Bool) {
        isLoginLaunch = !isDefaultLaunch
    }

    /// A user-initiated request must win over the pending suppression of the
    /// settings window that SwiftUI normally creates for a login-item launch.
    mutating func userRequestedSettingsWindow() {
        didHandleInitialSettingsAppearance = true
    }

    mutating func shouldDismissSettingsWindow() -> Bool {
        guard isLoginLaunch, !didHandleInitialSettingsAppearance else { return false }
        didHandleInitialSettingsAppearance = true
        return true
    }
}

/// macOS launches the full application for a login item, and the settings
/// window is this app's default scene. Detecting the login launch lets Panoptos
/// start in the menu bar instead of opening settings and taking focus.
final class PanoptosLaunchContext: NSObject, NSApplicationDelegate {
    private var windowState: LoginLaunchWindowState

    override init() {
        windowState = LoginLaunchWindowState()
        super.init()
    }

    init(windowState: LoginLaunchWindowState) {
        self.windowState = windowState
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // false means the system launched us (login item, resume, opening a
        // file) rather than the user launching Panoptos directly.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        windowState.recordLaunch(isDefaultLaunch: isDefaultLaunch)
        if windowState.isLoginLaunch { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Finder and Spotlight can reopen an already-running accessory app
        // without going through the menu-bar command.
        windowState.userRequestedSettingsWindow()
        return true
    }

    /// True only for the first settings-window appearance of a login launch, so
    /// the user can open settings normally afterwards.
    func shouldDismissSettingsWindow() -> Bool {
        windowState.shouldDismissSettingsWindow()
    }

    func userRequestedSettingsWindow() {
        windowState.userRequestedSettingsWindow()
    }
}

@main
enum PanoptosEntryPoint {
    static func main() {
#if DEBUG
        // App-hosted XCTest needs the AppKit launch lifecycle, but must never
        // construct the real Sparkle scheduler
        // or window manager before its injected test fixtures take over.
        if NSClassFromString("XCTestCase") != nil {
            NSApplication.shared.run()
            return
        }
#endif
        PanoptosApp.main()
    }
}

struct PanoptosApp: App {
    @StateObject private var model: PanoptosModel
    @StateObject private var overlayCoordinator = WindowMenuOverlayCoordinator()
    @NSApplicationDelegateAdaptor(PanoptosLaunchContext.self) private var launchContext
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        _model = StateObject(wrappedValue: PanoptosModel())
    }

    var body: some Scene {
        Window("Panoptos", id: "settings") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 500)
                .onAppear {
                    let shouldDismiss = launchContext.shouldDismissSettingsWindow()
                    if shouldDismiss {
                        NSApp.setActivationPolicy(.accessory)
                        dismissWindow(id: "settings")
                    } else {
                        NSApp.setActivationPolicy(.regular)
                    }
                    overlayCoordinator.start(model: model)
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 820, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Panoptos") {
                Button("Refresh Windows and Menus") {
                    model.refreshWindowsAndMenus()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            PanoptosMenuBarContent(
                model: model,
                onOpenSettings: { launchContext.userRequestedSettingsWindow() }
            )
        } label: {
            PanoptosMenuBarLabel(model: model) {
                overlayCoordinator.start(model: model)
            }
        }
    }
}

/// The menu bar item exists for every launch, including a login launch that
/// never opens settings, so overlay startup hangs off it rather than off the
/// settings window. `start(model:)` is idempotent.
private struct PanoptosMenuBarLabel: View {
    @ObservedObject var model: PanoptosModel
    let onAppear: () -> Void

    var body: some View {
        Image(model.keepMacAwake ? "MenuBarAwakeIcon" : "MenuBarIcon")
            .accessibilityLabel("Panoptos")
            .onAppear(perform: onAppear)
    }
}

private struct PanoptosMenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: PanoptosModel
    let onOpenSettings: () -> Void

    var body: some View {
        Button("Open Panoptos Settings") {
            // Keep this before openWindow: presenting the scene can drive its
            // onAppear synchronously, where a pending login suppression closes it.
            onOpenSettings()
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Refresh Windows and Menus") {
            model.refreshWindowsAndMenus()
        }

        Toggle("Show Menu Bars", isOn: $model.showWindowMenuBars)
            .disabled(!model.isAccessibilityTrusted)

        Toggle("Keep Mac Awake", isOn: $model.keepMacAwake)
        Toggle("Keep Screen On", isOn: $model.keepScreenOn)

        Divider()

        Link("Feedback & Bug Reports…", destination: PanoptosLinks.feedback)

        Divider()

        Button("Quit Panoptos") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
