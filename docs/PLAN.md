# Panoptos Linux implementation plan

Status: proposed plan; no implementation milestones completed.
Updated: 2026-10-04.

## 1. Delivery assumptions

Implement the [specification](SPEC.md) as a Panoptos desktop layer on Omarchy.
Reuse the base's hardware setup, installation, system services, portals, updates,
and recovery. Work on those areas is limited to integration changes and regression
checks needed by the desktop layer.

Estimates assume one experienced full-time developer, an available graphical
x86_64 test machine, and occasional design/user-testing help. They are planning
ranges, not measured implementation commitments. Re-estimate after the feasibility
prototype. Learning the desktop stack, part-time availability, or a compositor
plugin requirement extends the schedule.

The first deliverable is installable on an existing supported Omarchy system.
A branded ISO is a subsequent packaging milestone with its own estimate.

## 2. Milestones and timing

| Milestone | Target elapsed time from start | Evidence |
| --- | --- | --- |
| Technical feasibility and baseline | Weeks 1-2 | Persistent zones and stacks demonstrated on the selected compositor build |
| Visual shell prototype | Weeks 2-4 | Consistent launcher, dock/taskbar, and control-center prototype |
| Common graphical settings and onboarding | Weeks 4-8 | Newcomers complete the core desktop tasks through visible controls |
| Integrated window-management alpha | Weeks 6-12 | Editor, stacks, assignment, persistence, and display events work together |
| Polished desktop-layer release | Months 3-5 | Acceptance evidence, packaging, recovery, and compatibility documentation |

These ranges are cumulative and overlap. The UI and window model share early
work; one developer may interleave them after their prerequisites are complete.
Hardware ports, universal app menu parity, and a separately maintained distro
infrastructure are outside these estimates.

## 3. Phase 0: baseline and feasibility

### Tasks

- [ ] Record the selected Omarchy release/commit and the actual Hyprland,
      Quickshell, portal, and relevant system package versions.
- [ ] Choose a non-destructive source import strategy that preserves this
      repository's documentation and any existing tags/releases. Record upstream
      provenance and a repeatable way to compare and incorporate upstream changes.
- [ ] Prepare a graphical test installation; capture the unmodified base's
      suspend/resume, locking, display reconnection, and screen-sharing behavior.
- [ ] Verify the documented Lua layout API in the selected package. Test custom
      geometry, empty zones, native groups, focus, and switcher reservations.
- [ ] Prototype three persistent zones and mixed-app stacks using browser,
      terminal, editor, and office windows.
- [ ] Prototype modifier-drag highlighting and drop detection. Verify that the
      overlay does not intercept an application's ordinary input or steal focus.
- [ ] Demonstrate a shell restart and a display reconnect with all windows still
      reachable.
- [ ] Record the chosen adapter/layout approach and any gaps against SPEC A2-A6.

### Exit criteria

The prototype demonstrates stable geometry and usable switching on the pinned
build. Native capabilities are identified separately from behavior implemented
by Panoptos. An unsupported API triggers a compatibility decision and revised
estimate before the main window-management work starts.

If native groups cannot meet the stack contract, compare a bounded alternative
against a C++ plugin. A floating-window simulation may help test interactions,
but does not establish production feasibility by itself.

## 4. Phase 1: shell and visual foundation

Dependency: a documented Omarchy integration point; the window engine can remain
experimental during this phase.

- [ ] Define shared typography, spacing, iconography, colors, focus indicators,
      light/dark appearance, and motion settings.
- [ ] Implement a Panoptos bar/dock and visible application launcher using the
      existing shell/plugin architecture.
- [ ] Present existing audio, network, Bluetooth, power, and notification controls
      through a consistent control center.
- [ ] Build reusable controls and empty/error/loading states for later settings.
- [ ] Provide a repeatable enable/disable path with access to the upstream shell.

Exit: a usable shell prototype at tested scales. Existing lock, authentication,
notifications, and portal services continue to function. A full-bar replacement
must be tested against the service/facade limitations documented by upstream.

## 5. Phase 2: settings and newcomer workflows

Dependency: the shell controls and a validated settings/configuration adapter.

- [ ] Add graphical appearance, shortcuts, display arrangement/scaling, and
      desktop settings; reuse reliable existing service controls.
- [ ] Validate configuration writes and preserve unrelated settings. Implement
      preview, timed confirmation, and automatic revert for display changes.
- [ ] Add a short optional welcome tour explaining launch, zones, stacks,
      floating windows, and recovery; allow replay from settings.
- [ ] Expose updates and recovery through the existing Omarchy workflows.
- [ ] Verify keyboard focus order, text scaling, contrast, reduced motion, and
      screen-reader behavior; record unresolved accessibility limitations.
- [ ] Observe at least three Mac/Windows users new to Linux completing the SPEC A1
      tasks without instructions beyond the product's own labels and tour.

Exit: core tasks are discoverable without configuration-file editing or memorized
shortcuts. Any failed task receives a concrete UI change and another observation.

## 6. Phase 3: complete the zone model

Dependency: phase 0 establishes the layout approach; shell surfaces are available
from phase 1. This work can be interleaved with phase 2.

- [ ] Implement split-tree geometry, stable zone IDs, presets, merge/split
      assignment handling, and minimum-size constraints.
- [ ] Build the layout editor with live preview, divider dragging, undo, cancel,
      and save.
- [ ] Implement assign/detach, explicit app rules, stable mixed-app stacks,
      per-zone switchers, and keyboard navigation.
- [ ] Handle dialogs, popup surfaces, fullscreen, normal workspaces, and special
      workspace exclusions according to the specification.
- [ ] Implement versioned persistence, atomic writes, last-known-good recovery,
      and conservative matching of running windows.
- [ ] Handle display disconnect/reconnect, identity fallback, scaling, rotation,
      and recovery of displaced windows.
- [ ] Test actual edge cases: duplicate window titles, application relaunch,
      empty zones, unavailable displays, small fixed-size windows, and corrupt
      saved state.

Exit: an integrated alpha meets SPEC A2-A7 on the selected test environment.
Pairing two applications inside one zone and menu replication remain later work.

## 7. Phase 4: packaging and release

Dependency: the integrated alpha and common settings workflows are complete.

- [ ] Package Panoptos components and their integration points without replacing
      the base's package-management or update workflow.
- [ ] Document install, update, disable, uninstall, and return-to-upstream paths.
      Back up touched configuration and remove only project-owned artifacts.
- [ ] Test a supported upstream update and snapshot rollback with Panoptos
      installed, including state-schema compatibility and user overrides.
- [ ] Test inherited functionality against the phase 0 baseline and document
      base failures separately from regressions introduced by Panoptos.
- [ ] Complete the acceptance matrix, licensing/notices, compatibility record,
      known limitations, and release instructions.
- [ ] Run a short daily-use beta and resolve window-loss, focus, state corruption,
      unusable display configuration, and broken recovery issues before release.

Exit: SPEC A1-A10 have recorded results. Any limitation is documented precisely;
core data-loss or window-reachability failures block the release.

## 8. Validation approach

Use focused automated tests for split-tree geometry, assignment transitions,
serialization/migrations, and conservative window matching. These verify behavior
that can lose organization or produce incorrect placement. Avoid tests that only
mirror UI implementation details.

Use graphical integration checks for focus, groups, drag interaction, layer-shell
surfaces, dialogs, portals, and shell restarts. A browser-rendered mockup cannot
validate Wayland compositor behavior.

The initial runtime matrix includes one display, an ultrawide layout, two displays
with different scales, display reconnect, suspend/resume, and a workspace change.
Expand machine/GPU coverage only when the release intends to claim that support.
If a required setup is unavailable, record the check as untested rather than passed.

Keep validation evidence versioned with the implementation: base commit, packages,
display arrangement, applications, expected behavior, observed result, and logs
with private content removed. Set responsiveness targets after measuring phase 0;
avoid continuous process spawning or unnecessary polling for normal shell updates.

## 9. Upstream maintenance and later delivery

Keep Panoptos additions distinguishable from upstream source and configurations.
Review incoming Omarchy changes for affected integration points, run the focused
acceptance checks, and update the compatibility record. Budget roughly one day per
week for maintenance during an active beta, adjusting to observed update frequency
and failures; this is an allowance, not a known recurring workload.

After the desktop-layer release, estimate a branded ISO separately. Reuse upstream
image tooling where appropriate and prove that installation, package sources,
updates, recovery, and source provenance work with the branding. The current plan
does not publish an ISO or promise additional hardware coverage.

Future scope is ordered by user evidence: application pairs within zones,
compatible application menus, previews, richer workspace profiles, and additional
platforms. Each receives its own requirements and compatibility checks.

## 10. First implementation checkpoint

The immediate next task is phase 0. Deliver its prototype, selected baseline,
recorded runtime results, architecture decision, and revised estimate. Only then
turn the remaining checklist into implementation-sized issues and set release dates.
