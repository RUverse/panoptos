# Panoptos Agent Guide

## Mission and hard boundaries

Panoptos is a local macOS window manager. Through the public macOS Accessibility API, it fits windows into user-configured monitor sections and renders each section's active application's menus in Panoptos-owned floating SwiftUI/AppKit UI.

- Use Accessibility permission only. Do not add Screen Recording, Input Monitoring, private APIs, event injection, or global shortcuts without explicit approval.
- Never replace, cover, split, modify, or automate the system menu bar unless the user explicitly changes that constraint.
- The app is intentionally unsandboxed and is not intended for the Mac App Store.
- Target macOS 14 or later.
- Debug and Release use their default certificate-derived designated requirements. Configure Debug's stable local signing identity through `PANOPTOS_DEBUG_CODE_SIGN_IDENTITY` in untracked `Signing.local.xcconfig` so rebuilds retain Accessibility approval. The ad-hoc fallback can build without a certificate but may prompt again after rebuilds. Do not add a bundle-identifier-only requirement through `OTHER_CODE_SIGN_FLAGS`: Xcode also applies it to nested libraries and Sparkle, and another signer could inherit the app's Accessibility grant. Release must remain team-anchored.
- Keep the Apple team in untracked `Signing.local.xcconfig`, included by `Signing.xcconfig` with `#include?`. Do not put the team ID in `project.pbxproj` or a tracked plist. It is public signature metadata, but tracking it forces contributors to edit a shared file.
- Panoptos is free software under GPL-3.0-or-later. All builds have the same unrestricted features; optional Gumroad support never grants access or changes the software license. Preserve copyright, bundled GPL/Sparkle notices, and matching corresponding-source access. Do not change licenses attached to older distributions.
- Never open a native menu merely to populate dynamic content. Treat an incomplete Accessibility menu tree as a compatibility result.
- Other applications' menu trees are volatile. Store child-index paths, then resolve a fresh AX element immediately before invocation.

## Product contract

### Layouts and windows

- The main window is settings-only. Do not add menu previews, diagnostic trees, application cards, or an invocation log unless requested.
- Users split each monitor into sections and attach resizable standard windows by holding Shift at the end of a drag. Control-Shift attaches every eligible window from the dragged application.
- A newly created eligible window automatically joins its application's section once that application has an attached window. If the application occupies several sections, use the last section where one of its managed windows was confirmed focused.
- Give early, incomplete AX window creation one deferred retry. Automatic-placement success or failure must not clear or replace the user-facing compatibility error.
- Persist monitor layouts, window assignments, switcher order, shortcuts, and user-selected settings across a normal quit and relaunch.
- The switcher groups windows by application. Dragging an application icon moves its group; dragging a window moves it only within its application. Preserve layout during the drag, mark the drop gap, keep clicks as activation until the drag threshold is crossed, and use the persisted order for cycling shortcuts. When exactly one occupied switcher exists across all displays, the previous/next-section shortcuts cycle its windows instead; with only one window they do nothing. A switcher ordered out by focus mode still counts as a navigation destination.

### Spanned windows

- Spanning (Control-Option-Command-Left/Right by default) grows the focused window over the adjacent layout section and moves it into a spanned section: a `LayoutSectionState` whose `coveredSectionIDs` names the layout sections it covers and whose ID is `SpannedSectionIdentity.id(covering:)`, derived from that set. Two windows spanning the same sections share one spanned section. Its menu bar and switcher sit above and below the whole spanned area; the covered sections keep only their unspanned windows.
- Persistence keeps naming layout sections: a spanned record stores the first covered section in reading order as `sectionID` and the rest as `additionalSectionIDs`, so older files decode unchanged and display migration keeps working. `liveSectionID` recovers the spanned section. Switcher order is kept per live section, never mixed with the home section's.
- A span and the sections beneath it are layers over one area. Focusing a window puts its layer on top (`isSectionOnTop`): a spanned window raises its section; a window in a covered section lowers every span over it and nonactivatingly raises the recorded active window of each other section that span covered, so the spanned window is never left showing through beside the focused one. This runs from `focus(windowID:)`, `refreshFocusedWindow()`, and `refreshRuntime()`, so Dock and app-switcher focus changes switch layers too. Raised state is session-only; the first focus after launch decides it.
- Every switcher stays on screen so the mouse can always switch. `SwitcherStripLayout` centers a spanned section's switcher on the boundary between two covered sections nearest the middle of the span; spans sharing a boundary line up side by side. The covered sections' switchers give way, keeping the widest stretch of their strip the spanned switcher does not sit over, filling only that when bars fill; a stretch narrower than `minimumWidth` keeps the whole strip instead. The spanned switcher keeps its content width, never fills, and takes no room until measured. Only the menu bar belongs to the layer on top: a covered section shows its menu bar while the span is lowered, the spanned section while it is raised.
- The previous/next-section shortcuts sweep by left edge, then right edge, so every layer is a stop: a section, the span starting there, the next covered section. Moving a spanned window collapses it into the covered section at that edge; that is the way out of a span. Application splits are unavailable in spanned sections, and a paired application must be unpaired before spanning.
- Layout edits re-key a span to whatever it still covers, fold it back into its one remaining section, or follow the editor's migration when every covered section is gone. Drag attachment targets only layout sections (`layoutSectionFrames()`); `sectionFrames()` also includes spanned sections. Automatic attachment of a new window may target a live spanned section when that is where the application lives.
- Restoring window order after an unhide (`restoreActiveWindowOrder`) treats a span and the sections it covers as one stack: it raises every layer over that area, lowest first, so the layer on top ends on top again, and raises a split's partner beside each active window. The sibling correction when a span is lowered raises split partners too.

### Menu and overlay behavior

- Floating nonactivating panels show the active attached window's application menus above its section and its window switcher below. Menu bars are off by default (`showWindowMenuBars`): the Panoptos menu bar item's Show Menu Bars toggle and the Appearance tab turn them on, and the switcher is always shown.
- Visible unattached windows appear as one bare application icon per nearby occupied switcher, in a separate transparent panel outside the switcher. A single click cycles that application's local unattached windows without changing managed state or loading their menus; a double click attaches the selected window to the icon's section. The icon has no capsule, divider, badge, shadow, or selection tile. A default-on Layout setting controls this transient discovery and presentation.
- "Visible" excludes windows on another Space. Accessibility reports their frames as though they were on screen, so `CGWindowListCopyWindowInfo` supplies that one fact. It is a public call that needs no permission beyond Accessibility — only window titles and images sit behind Screen Recording — and it must stay the only use of the window server. An unavailable answer keeps every window visible rather than making icons disappear.
- A readable window with an empty or failed menu tree still gets an icon/title-only overlay shell.
- An attached window the window server does not list on screen keeps its assignment but leaves the switcher until it is back; a section whose every window is off screen orders its bars out. This covers windows on another Space and windows a menu bar application such as Ollama orders out on close instead of destroying, which Accessibility keeps reporting as open. Minimized windows and hidden applications' windows keep their icons. The check reuses the one permitted window-server read, once per reconcile pass from the last snapshot frames, and never detaches.
- Keep the leading Apple menu in diagnostics but omit it from displayed strips. Merge the application's own menu into the bold icon/title control; the remaining strip begins with menus such as File and Edit.
- Invoke an enabled leaf directly without a Panoptos confirmation. Destructive commands rely on the target application's confirmation.
- Invocation activates the target by default and prefers `AXPick`, falling back to advertised `AXPress`. Keep the experimental no-activation setting.

### Section focus mode

- The switcher's right-click “Focus Section” action, placed after “Detach Window” with its configured shortcut displayed, and the “Toggle section focus” shortcut (Control-Option-F by default) make one section keep the screen to itself. The action becomes “Leave Section Focus” while active. Hide other sections' applications with application hiding, like Command-H, and order out their bars. Do not minimize, move, or resize their windows.
- Window switching inside the focused section remains available through the window-cycling shortcuts and switcher. When another occupied section exists, the previous/next-section shortcuts leave focus mode immediately and focus the directional destination; focus mode ordering other switchers out never turns those shortcuts into local window cycling.
- Focus mode is session-only and ends on the next foreign focus. Never restore it after launch; doing so would hide applications the user did not ask to hide.
- Hiding is per application. Never hide an application that also owns a window in the focused section; its other-section windows remaining visible is the accepted tradeoff.
- When unattached-window discovery is enabled, also hide applications with visible unattached windows, even when those windows overlap the focused section. Retain any application with an attached window in the focused section. Minimized, other-Space, and already-hidden unattached windows are not hiding candidates. Disabling discovery leaves unattached-only applications visible in focus mode; explain this coupling in the Layout setting.
- Revealing applications with unattached windows must also register asynchronous window-order restoration for occupied sections, including the section that kept focus. An unattached-only application has no managed section from which to infer this correction; clearing the discovery cache while hidden must not lose it.
- Restore exactly the applications Panoptos hid. `focusModeHiddenApplications` includes bundle identifiers because macOS reuses pids; never “unhide everything.”
- After unhiding, a manual exit reasserts the window that remained focused; an automatic exit caused by foreign focus must never reclaim that focus. Then nonactivatingly raise each restored section's recorded active window so reactivating the focused application cannot put one of its other-section windows on top. Repeat that ordering correction as asynchronous application-unhide transitions settle.
- Only `exitFocusMode()` may end the mode. Call it on every path that could strand hidden applications, including a section emptying and `NSApplication.willTerminateNotification`. Termination cleanup must run inline because a main-queue hop will not run.
- The context-menu action targets its section. The shortcut targets the focused window's section and can end focus mode from anywhere.
- While section focus is active, show the closed-eye SVG button outside the right end of that section's switcher capsule, styled as a bare icon like unattached windows. Clicking it leaves focus mode; omit the button outside focus mode.
- A new shortcut command must reach existing users through a `ShortcutPersistence` version bump and must not claim an existing user binding.
- `reconcileFocusMode(frontmostPID:)` runs from `refreshRuntime()`. Keep it out of the way during system transitions, the short entry settle window, and while Panoptos is frontmost so browsing an overlay menu does not end focus mode.

### Onboarding

- The first settings window after a launch opens the welcome tour as a sheet when `hasCompletedOnboarding` is false: welcome and menu bar icon, Accessibility access with its live status and a Request Access button, layouts, attaching windows by drag or with the move-window shortcuts, section bars and how to turn menu bars on, and shortcuts. The attach and shortcut pages quote the user's current bindings, never the defaults.
- Only Skip and Done dismiss the sheet, and both persist completion; Escape counts as Skip. Done on the first run switches to the Layout tab when window management is available. The field defaults to false when missing, so an existing installation sees the tour once after updating.
- Present the tour when the settings window is on screen (`SettingsWindowVisibilityObserver`, driven by the window's occlusion state), never from `onAppear`: that runs before the window is ordered in, and for a login launch on a window dismissed in the same turn, so a sheet begun there never shows while the flag stays set. Do not switch this to key-window status; it depends on the app being active, which the test host and a background launch are not. `OnboardingPresentationTests` hosts the real settings view in an on-screen window to check the sheet attaches.
- General › Support has a “Show Tour” button that replays the tour without clearing completion. The tour is still a sheet over the settings-only window, not a new window or tab.

### Updates

- The General tab contains Updates. When allowed, Sparkle checks the appcast on its daily schedule; otherwise it checks only from Check Now. It always asks before downloading or installing an update.
- Sparkle is the only third-party code dependency and is pinned through SPM in `Package.resolved`; do not introduce another app dependency. App network requests are limited to Sparkle updates. Support, feedback, and source links open in the user's browser; never add payment validation.
- Keep `SUEnableSystemProfiling` and `SUAutomaticallyUpdate` false. Panoptos does not send OS/hardware details and never replaces itself without asking.
- Sparkle owns and persists its update preference. `UpdateController` mirrors it instead of copying it into `settings.json`, following the `LoginItemController` precedent for system-owned state.
- Constructing `SparkleUpdateController` starts scheduled checks. Tests must inject `UpdateControlling` and must never contact the feed.
- The private EdDSA key is stored in the developer's login keychain and is not recoverable. `SUPublicEDKey` pins it in the shipped app; losing it ends updates for all installed copies.
- Every published build needs a `CURRENT_PROJECT_VERSION` greater than every earlier published build because Sparkle uses it to select updates.
- `scripts/release.sh` audits the hardened runtime and secure timestamp on the app and every nested Sparkle framework, helper, app, and XPC service before notarization.
- `scripts/release.sh` dresses the disk image itself: `scripts/dmg-assets.swift` renders the folder-style volume icon and the drag-arrow background from the app icon glyph, and `scripts/dmg-layout.py` writes the Finder window layout straight into `.DS_Store`. Do not switch this back to Finder AppleScript; current Finder neither persists scripted view options nor leaves the volume icon in place.

### Free distribution and upgrades

- No trials, activation, accounts, device limits, payment gates, or licensing network requests. Accessibility trust and the user's window-management preference remain real operational prerequisites.
- Leave old licensing Keychain items untouched and unread. Never deactivate a remote license or migrate payment credentials into preferences.
- Preserve bundle identity, storage paths, layouts, assignments, switcher order, shortcuts, onboarding completion, and settings across upgrades from every former licensing state.
- Runtime startup, restoration, observer registration, shortcuts, focus-mode exit, and keep-awake cleanup belong to the lifecycle implementation. Start once and stop cleanly.
- Keep legal notices and corresponding-source links in General support UI; do not recreate a License settings tab.
- Feedback opens the canonical GitHub repository's Issues page directly. Optional support opens the website's /buy page.
- Sparkle remains available without payment and retains the existing feed URL and public EdDSA key.
- No license-only Keychain entitlement or provisioning profile is required. Preserve certificate-derived signing, Developer ID, hardened runtime, secure timestamps, nested Sparkle audits, notarization, and stapling.
- Public source and distribution preparation follows the workflow below; implementing changes does not authorize publication.

## State and reliability

### Persistence

Persistence is part of every durable feature, not optional follow-up work.

- Persist every user-editable preference and useful organizational state by default, including toggles, selectors, sizing/alignment choices, shortcuts, layouts, and window assignments.
- Session-only state is limited to inherently transient values such as focus mode, hover/open-menu/drag state, notices, caches, live pids, and AX handles, or behavior the user explicitly requests to be temporary.
- If a setting is intentionally temporary, say so in the UI and obtain product direction instead of silently resetting it.
- If a durable runtime object cannot be serialized, persist a stable public descriptor and reconstruct it on launch. Never serialize AX elements or rely on private window identifiers.
- Decide relaunch semantics whenever adding `@Published`, `@State`, or a binding. Load durable values before presenting UI and save them atomically when they change.
- Persistence formats must decode older files and default missing fields individually. A newly added field must not invalidate the whole settings file.
- Add a storage round-trip test and a model-level relaunch test for new durable state. The relaunch test must construct a new model with the same store and verify user-visible values.
- Before handoff, manually change every new durable UI option, quit normally, relaunch, and verify both the control and behavior are restored.

### Window lifetime

Detaching a window is a last resort. Sleep, screen sleep, session locking, and display changes can invalidate AX elements for seconds without closing windows.

- Only user detachment, application termination, and observed `kAXUIElementDestroyedNotification` are authoritative removal signals.
- `NSRunningApplication(processIdentifier:)` can fail for a live pid. Use `runningApplication(pid:)`, which corroborates with `NSWorkspace.runningApplications`; never let one unresolved lookup detach every window owned by an application.
- A failed attribute read is not proof of destruction. `kAXErrorInvalidUIElement` permits detachment only after `invalidWindowFailureDuration` and after the owning application no longer lists the element in `AXWindows`. If the application cannot answer at all, keep the window.
- `PanoptosModel.isInSystemTransition` suppresses removal heuristics during sleep, lock, wake settling, and screen-parameter changes. Every new lifecycle heuristic must respect it.
- A heuristic removal creates an orphan instead of deleting the assignment. Keep orphans in persistence and recover them through `recoverOrphanedWindows()`. Orphan matching deliberately excludes the window-ordinal fallback used for launch restoration.
- Never allow a heuristic removal to be the final writer of `window-assignments.json`; losing the record makes detachment permanent across relaunches.

### Overlay and Accessibility performance

The overlay implementation across `Panoptos/Views/WindowMenuOverlay.swift`,
`SectionOverlayPanel.swift`, `OverlayMenuControls.swift`,
`WindowSwitcherControls.swift`, `WindowSwitcherBar.swift`, and
`SectionOverlayFeedback.swift` is sensitive performance code.

- Use AX observer notifications for focused-window changes, moves, and resizes. Keep the tolerant low-frequency timer only as a compatibility fallback.
- During a real pointer drag beginning in a tracked window's title region, poll position at 60 Hz for that pid only. Prefer event-driven tracking plus narrowly scoped live-drag polling over continuous system-wide polling.
- Live tracking changes position only. It must not rebuild menus, close panels, or mutate panel structure while a menu is being browsed.
- AX frame reads need a short messaging timeout. Round panel frames before comparison to prevent AppKit coordinate noise from causing repeated `setFrame` calls.
- The idle reconciliation pass may reassert floating z-order. Never call `orderFrontRegardless()` on every live frame.
- Keep repaint and reconciliation separate. `applyPresentation()` performs no Accessibility calls and immediately pushes model state into panels; `reconcile()` performs the blocking managed-window reads.
- User-visible click and shortcut feedback, especially focused appearance, must use the presentation path through `PanoptosModel.onOverlayPresentationChanged`. `refreshFocusedWindow()` resolves focus with one read.
- Same-application window switches have no activation notification. Route `kAXFocusedWindowChangedNotification` through its own `.focus` fast path.
- Entering or leaving focus mode changes every section's visibility, so repaint all sections. `focus(windowID:)` relies on the repaint inside the single `exitFocusMode()` path to correct presentation in the same turn.
- Reflow and reconcile on left mouse-up only when a drag was tracked. Doing it for ordinary clicks causes two unnecessary full AX sweeps.
- `stop()` must invalidate timers, remove event monitors and AX observers, clear panels, and nil the model so queued callbacks cannot recreate orphan overlays.
- AppKit may deliver a switcher press to either `FirstMouseHostingView` or `FirstMouseButton` depending on SwiftUI compositing and hit-testing. Use `ReorderPress` from both paths for switcher reordering.
- `NSView.toolTip` does not work on these nonactivating bars. Use `OverlayTooltipController` with `.activeAlways` tracking areas; do not try to fix tooltips by assigning `toolTip` again.

## Code map

- `Panoptos/Accessibility/AccessibilityClient.swift`: trust, menu traversal, fresh-path invocation, focused-window frames, and AX conversion.
- `Panoptos/Models/MenuModels.swift`: targets, menu trees, shortcuts, invocation, and presentation filtering.
- `Panoptos/Models/LayoutModels.swift`: split layouts, display identity, layout persistence, and persisted assignments.
- `Panoptos/Models/SettingsModels.swift`: durable preferences and backward-compatible storage.
- `Panoptos/Models/ShortcutModels.swift`: shortcut definitions, persistence, and Carbon registration.
- `Panoptos/Models/WindowModels.swift`: `ManagedWindow` and `LayoutSectionState`.
- `Panoptos/Models/SystemTransition.swift`: paired sleep, screen-sleep, and session-lock notifications.
- `Panoptos/System/LoginItemController.swift` and `KeepAwakeController.swift`: injected wrappers around system-owned state.
- `Panoptos/Store/PanoptosModel.swift` and its `+Layout`, `+Lifecycle`, `+Persistence`, `+Navigation`, `+Shortcuts`, `+Settings`, and `+FocusMode` extensions: app state and behavior.
- `Panoptos/Views/ContentView.swift`: settings-only UI.
- `Panoptos/Views/OnboardingView.swift`: welcome tour pages, the bindings they quote, the sheet, and its schematic illustrations.
- `Panoptos/Views/WindowMenuOverlay.swift`: AX observation, target tracking, reconciliation, and presentation coordination.
- `Panoptos/Views/SectionOverlayPanel.swift`: section panel lifecycle, placement, top menu-bar presentation, and shared bar layout.
- `Panoptos/Views/OverlayMenuControls.swift`: native menu controls, menu construction, invocation handlers, and hover switching.
- `Panoptos/Views/WindowSwitcherControls.swift`: first-click routing, switcher buttons, reorder presses, icons, and overlay tooltips.
- `Panoptos/Views/WindowSwitcherBar.swift`: grouped window-switcher layout, drag ordering, and shared overlay chrome.
- `Panoptos/Views/SectionOverlayFeedback.swift`: transient compatibility notices and attachment highlights.
- `PanoptosTests/LayoutManagerTests.swift`: layouts, navigation, persistence, restoration, shortcuts, and window management.
- `PanoptosTests/MenuParsingTests.swift`: parsing, action selection, errors, shortcut formatting, and menu filtering.

## Development workflow

### Editing

- Preserve unrelated user changes and inspect `git status` before editing or committing.
- Use `apply_patch` for source edits.
- Add new Swift files to the correct Xcode group and target sources in `Panoptos.xcodeproj/project.pbxproj`.
- Keep raw Accessibility data separate from display filtering so diagnostics remain trustworthy.
- `PanoptosModel` state has no access modifier because Swift scopes `private` to a file across its extensions. Views still must mutate it only through model methods.
- Avoid synchronous, high-frequency AX work across all target pids. AX calls are IPC and can block on slow applications.
- Add focused unit coverage for pure parsing, filtering, coordinates, persistence, and action selection. Validate Accessibility and window-server behavior manually.

### Automated checks

From the repository root:

```sh
xcodebuild -project Panoptos.xcodeproj -scheme Panoptos -configuration Debug -derivedDataPath /tmp/PanoptosDerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild test -project Panoptos.xcodeproj -scheme Panoptos -configuration Debug -derivedDataPath /tmp/PanoptosDerivedData CODE_SIGNING_ALLOWED=NO
```

The tests require Xcode's macOS test-runner service. A sandboxed failure to reach `testmanagerd` is an environment failure, not necessarily a product failure. Before handoff, run `git diff --check`, the build, and the full test suite.

### Manual Accessibility checks

Use the normally signed Xcode Debug product, never an unsigned `/tmp` build.

- Always stop and start Panoptos with Xcode's Stop and Run controls for manual testing. Never launch any built Panoptos `.app` directly while an Xcode run may be active.
- Before and after restarting, verify exactly one Panoptos process is running and that its executable is Xcode's Debug product.
- Never target Panoptos itself by app name, bundle identifier, or built-app path with UI inspection tools; app resolution can launch another registered copy. Inspect Xcode and the target applications instead.

Verify at minimum:

- Restoration reattaches matching windows without targeting Panoptos, activating every target, or stealing focus.
- Several conventional applications can occupy sections without a slow application's AX calls blocking interaction.
- Overlays follow pointer dragging and keyboard snapping without disrupting an open overlay menu.
- Same- and cross-application switching updates menus and raises the intended target.
- New eligible windows follow the application's correct section without unsupported/background windows taking over active state.
- Switcher drag reorders without activation, click still activates, and order survives relaunch.
- A harmless command reaches the correct target without a Panoptos confirmation.
- Disabled Accessibility, terminated apps, dynamic menus, and unavailable windows fail gracefully.
- Layouts, assignments, bar preferences, window-manager and invocation behavior, and shortcuts survive relaunch.
- Focus mode hides other applications instantly, restores exactly what it hid, ends through every supported path, and never leaves an application hidden after Panoptos quits.

## Release workflow

Preparation is local or in GitHub Actions; publishing requires a later explicit instruction. Do not push source, create a public release, deploy the website, or publish a cask merely because preparation was requested.

### Repository and candidate

- Use the verified cleaned GitHub application repository. Preserve the original private checkout/archive; never push its legacy history, checkpoint refs, or private operations documents. Never migrate with `git push --mirror` or `git push --all`.
- If no cleaned repository exists, export an audited tree to a separate directory and create new local history there. Scan the exact proposed tree/history/artifacts before publication; exclude local signing configuration, credentials, certificates, provisioning material, and build output.
- The website retains its existing hosting and deployment. Inspect both worktrees and remote refs before preparing a release; preserve unrelated work.
- Use a stable semantic version explicitly chosen for the release and a build number greater than all prior published builds and project configurations. Do not reuse historical release numbers.
- GitHub Actions prepares and tests a candidate from an exact source commit. Workflow permissions are read-only, actions are pinned to immutable revisions, and no untrusted pull request receives signing secrets or write credentials.
- Signing stays on the owner's Mac unless a secure Actions arrangement is separately configured. Unsigned CI artifacts are review material, never official downloads.
- Run `git diff --check`, the Debug build/full tests, a clean contributor build without `Signing.local.xcconfig`, applicable Release validation and release dry run, and website/cask checks. Record unavailable manual checks.

### Packaging and review

- Keep version/build values in Xcode settings, with `Info.plist` reading them.
- Keep Developer ID/hardened-runtime/timestamp/nested-code audits, app and DMG notarization, stapling, and Gatekeeper validation. Do not weaken unrelated checks when removing obsolete license entitlements.
- Build matching corresponding-source archives beside the binary, including project/resources, packaging scripts, notices, and pinned Sparkle source and required non-system dependency source. GitHub's automatic repository archive alone is insufficient.
- Prepare release notes, SHA-256 checksums, exact commit/version/build metadata, and the candidate Sparkle appcast. Generate signed enclosure data from final DMG bytes with Sparkle tooling; never hand-edit it.
- Preserve `https://panoptos.ruverse.ai/appcast.xml`, its signing key, older entries, and old download paths.
- The new official DMG is an immutable GitHub release asset associated with an immutable version tag and exact source commit. Do not overwrite released bytes.
- Review source/app/website/cask changes, exact notes, hashes, source completeness, tests, signing/notarization results, and all intended publication actions together. Confirm outstanding GPL suffix, repository, version, Gumroad, and Homebrew inputs before first publication.

### Publication after explicit authorization

1. Publish/verify sanitized GPL source and its matching immutable tag.
2. Publish the verified signed/notarized GitHub DMG, matching source package, checksums, and approved notes. Verify anonymous downloads and bytes.
3. Publish the generated appcast and website only after the asset is available; verify live version, build, URL, length, signature, notes, and links.
4. Publish the Homebrew cask using that same DMG and verified checksum. Advertise its exact install command only after the tap/cask resolves.
5. Enable the verified optional Gumroad product link. Do not modify a listing, deliver files, or contact customers without authorization.
6. Retire legacy payment infrastructure only after checking existing customer needs and obtaining authorization for the live changes.

Report exactly what is local, draft, or public. A failed partial rollout must not be described as a completed release.

## Out of scope unless requested

- Automatic layout policies beyond user-created sections and explicit movement/spanning commands.
- Replacing or splitting the system menu bar or hiding status items such as the clock or Control Center.
- Production signing, notarization, distribution, or App Store packaging outside the explicit release workflow.
- New global-shortcut categories or event injection without explicit approval.
