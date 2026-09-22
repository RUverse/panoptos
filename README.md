# Panoptos

Create snap zones. Stack apps. Switch windows naturally. Keep every workspace predictable.

Panoptos is a local macOS window manager that divides each monitor into a persistent layout of user-defined zones. Each zone can hold a stack of windows and keeps the active window's application menus close at hand.

## Features

- **Snap zones made for your screen.** Split each monitor horizontally or vertically, nest those splits, and resize them into a layout that matches how you work.
- **Apps stack inside zones.** Put multiple windows—even windows from different apps—in the same zone instead of giving each one permanent screen space.
- **Two apps can share one zone.** Use the divider between neighboring application groups in the window switcher to place them side by side, or top and bottom in a tall zone. Panoptos keeps the pair together while switching and restores it after relaunch.
- **Switch with the keyboard or mouse.** Use customizable global shortcuts for fast navigation, or click the window switcher below a zone when the mouse is more convenient.
- **Menus appear where you need them.** Turn on **Show Menu Bars** from the menu-bar menu or the Appearance tab and the active window's application menus are shown directly above its zone, so a window on the right side of the screen does not require a trip to the far-left system menu bar. Menu bars are off by default; the window switcher is always shown.
- **Stay awake when you need to.** Turn on **Keep Mac Awake** from the Panoptos menu-bar menu to prevent idle system sleep while still allowing display sleep. Turn on **Keep Screen On** to prevent display sleep as well; it automatically enables **Keep Mac Awake**. The three-eye menu-bar icon changes to one enlarged open eye while either option is active, and both settings survive relaunches.
- **Restrictions create stability.** Attached windows stay fitted to their assigned zones, and Panoptos will not move a window into a zone that the app cannot fit. This helps prevent accidental resizing and broken layouts.
- **Your workspace comes back.** Monitor layouts, window assignments, shortcuts, and preferences survive a normal quit and relaunch.

Panoptos is built entirely on the public Accessibility API. It does not modify or cover the system menu bar and does not use Screen Recording, Input Monitoring, event injection, or private APIs. User-editable global shortcuts are registered through macOS's public hot-key API.

## Install

[Download from Gumroad](https://1391562068503.gumroad.com/l/yqqmi) to support development, or [download free from GitHub](https://github.com/RUverse/panoptos/releases/latest). Each official GitHub release provides exactly two uploaded assets: the signed and notarized DMG and its matching complete source archive. Their SHA-256 checksums appear in the release description.

To install with [Homebrew](https://github.com/RUverse/homebrew-tap):

```sh
brew install --cask ruverse/tap/panoptos
```

Requires macOS 14 or later. No account, license key, or trial period is required.

Upgrading preserves your layouts, attached windows, switcher order, shortcuts, onboarding completion, and preferences. Old activation and trial records are no longer read or used; they remain untouched in Keychain. Previously distributed versions retain the terms accompanying those versions.

## Run

1. Open `Panoptos.xcodeproj` in Xcode and run the `Panoptos` scheme. The first launch opens a short welcome tour over the settings window; replay it any time from **General → Support → Show Tour**.
2. Click **Request Access** and enable Panoptos in **System Settings → Privacy & Security → Accessibility**.
3. Relaunch the exact app build if the permission banner remains orange.
4. Open **Edit Layout** for a monitor. Select a section to split it left/right or top/bottom, drag dividers, then Save.
5. Hold **Shift** while dragging a standard resizable window. Release it over a highlighted section to attach it.
6. Hold **Control-Shift** instead to attach every eligible window from the dragged application.
7. Use the bottom bar or your configured shortcuts to switch stacked windows. Right-click a window title in the bottom bar to detach it.
8. To share a section between two applications, hover over the divider between their groups in the bottom bar and click the split button.
9. Use the top bar to invoke the active window's application menus without moving the pointer to the system menu bar.
10. Open the **Shortcuts** tab to edit, disable, or restore window switching and section movement shortcuts.
11. Open the Panoptos menu-bar menu to toggle **Show Menu Bars**, **Keep Mac Awake**, or **Keep Screen On**. The menu-bar icon becomes a single open eye while either keep-awake option is active.

Layouts are persisted per physical display. Panoptos restores matching window assignments after a normal relaunch.

## Expected limitations

- Version 1 manages normal windows on one desktop Space per monitor. Mission Control Spaces and native full-screen windows are unsupported.
- Dialogs, sheets, and windows that reject Accessibility resizing remain floating.
- Applications may expose incomplete menu trees until their native menus open. Panoptos never opens native menus merely to populate them.
- Some non-AppKit applications expose incomplete Accessibility metadata or no invokable menu action.
- First-responder menu commands normally require the target window to become active.

## Build and test

The app runs on macOS 14 or later. Building requires Xcode 26 or later for its Icon Composer asset. Sparkle is the only third-party app dependency and is pinned in `Package.resolved`.

A contributor build needs no owner's Apple account, payment credentials, or local signing file:

```sh
xcodebuild -project Panoptos.xcodeproj -scheme Panoptos -configuration Debug -derivedDataPath /tmp/PanoptosDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Panoptos.xcodeproj -scheme Panoptos -configuration Debug -derivedDataPath /tmp/PanoptosDerivedData CODE_SIGNING_ALLOWED=NO
```

Tests inject update and system-service fakes; they must not contact the Sparkle feed. The full suite needs Xcode's macOS test-runner service and a graphical desktop session.

For manual Accessibility testing, use Xcode Stop and Run with a normally signed Debug product. Configure a stable local signing identity to preserve Accessibility approval across rebuilds:

```sh
cp Signing.local.xcconfig.example Signing.local.xcconfig
```

Set `PANOPTOS_DEBUG_CODE_SIGN_IDENTITY` to an installed code-signing certificate and, where needed, `PANOPTOS_DEVELOPMENT_TEAM` to your own team. The local file is ignored by Git. Without a certificate, Debug supports ad-hoc signing; changing the signature can require Accessibility approval again. Never add local signing material to source control. Keep Xcode's default certificate-derived designated requirements.

All source builds are unrestricted. Sparkle uses the official update feed; accepting an official update replaces a locally modified app with the official release. You can disable scheduled checks in General settings.

## Updates and releases

Sparkle checks `https://panoptos.ruverse.ai/appcast.xml` on the user's chosen schedule and always asks before downloading or installing. Profiling and automatic installation remain disabled. Updates never depend on payment.

GitHub Actions prepares reviewable candidates; it does not publish releases or deploy the website. Production signing and notarization remain local. Unsigned CI artifacts, logs, appcast drafts, metadata, notes files, and checksum files are not public release assets. See [the release guide](docs/releasing.md) for candidate preparation, matching source, verification, and publication ordering.

Version/build values come from Xcode's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Each published build must exceed all previous builds. Published binaries and version tags are immutable; corrections require a new release.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidance and [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## License and notices

Copyright © 2026 Alireza Ektefaie.

Panoptos is licensed under **GPL-3.0-or-later**. See the unmodified [GNU GPL version 3 text](LICENSE). GPL and third-party notices are bundled with the application and accessible in General settings.

Sparkle is the only third-party app code dependency, distributed under its own [license and bundled notices](Panoptos/Resources/Legal/Sparkle-LICENSE.txt). Matching release source archives include the pinned dependency source and build instructions.
