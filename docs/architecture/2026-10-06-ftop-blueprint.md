# Architecture Blueprint: ftop

Status: approved by the owner on 2026-10-06. The first implementation departs from it in the
ways listed under "Amendments after the first build" at the end; where they differ, the
amendments describe the code.

## Summary

- Product goal: a small, refined macOS status monitor shown as a floating panel that
  stays usable at any window size and is opened by typing `ftop`.
- Source decisions: docs/intent/2026-10-05-ftop-intent.md (R1–R14);
  docs/product/2026-10-06-floating-panel-decision.md (approved look and layout
  rules); design/trial/ftop-any-size.html (behavior reference).
- Architecture type: greenfield native desktop app in a repository whose previous
  code (a btop fork) was removed.
- Selected stack: Swift 6 with strict concurrency; SwiftUI views hosted in an AppKit
  `NSPanel`; Swift Package Manager as the only build definition; Swift Testing;
  `swift format`; no third-party runtime dependencies.
- Primary constraints: any-size layout (R2); refinement of type, color, motion
  (R13); per-core frequency and temperature exist only behind private Apple APIs;
  the monitor must cost almost nothing to run; one owner working with coding
  agents, so everything must build and test from the command line; no CI.
- Non-goals: history graphs, disk information, Intel Macs, Mac App Store, runtime
  plugin loading, remote or multi-machine monitoring, telemetry of any kind.

## Decisions

- Frontend/runtime: SwiftUI inside an AppKit-owned borderless `NSPanel` (floating
  level, joins all Spaces, non-activating). Why: real typography, vibrancy, light
  and dark, and continuous resize are native; AppKit owns the window behavior
  SwiftUI scenes cannot express. Rejected: Tauri or Electron (a web runtime makes
  the monitor a visible resource consumer); Rust with a custom GPU UI (no native
  material or text rendering, more code for less polish); AppKit-only views (far
  more layout code for the fit ladder). Revisit when: SwiftUI cannot hit the
  performance budget below after profiling.
- Any-size layout (consequential boundary). Selected: a custom `LadderLayout`
  (SwiftUI `Layout` protocol) that walks an ordered list of candidates produced by a
  pure `LayoutLadder` value in the core (tier, column count, process count, strip
  orientation), measures each with `sizeThatFits`, takes the first that fits, then
  the largest type scale that still fits. Compared: (a) nested `ViewThatFits` —
  least code, but cannot choose "largest scale that fits" or prefer column counts
  by aspect ratio, and its order lives in view code where it cannot be unit tested;
  (b) hard-coded size breakpoints — simplest to test, but breaks whenever a font,
  locale, or module set changes, which is exactly how the old build failed; (c) the
  selected design — order is data (unit testable), fitting is measured (cannot
  clip), one place owns the rule. Caller burden: modules only supply a view per
  tier. Test seam: ladder order in core tests, fit sweep in UI tests. Migration
  cost: low, the ladder is one type. Revisit when: measurement cost shows up while
  resizing.
- Backend/runtime: one sampler actor on a coalescing timer (default 1 s, leeway
  10%) produces an immutable `Snapshot`; no helper daemon, no subprocesses. Why:
  every reading is a cheap in-process call; a daemon adds install and lifecycle
  work for nothing. Rejected: privileged helper (would unlock all processes'
  details but needs an installer and admin approval); shelling out to `top` or
  `powermetrics` (slow, fragile parsing, `powermetrics` needs sudo). Revisit when:
  the owner wants root-owned processes' CPU and memory that the unprivileged API
  refuses.
- System-API boundary (consequential boundary). Selected: only the `FtopSensors`
  target may import IOKit, libproc, or Mach; private symbols (IOReport,
  IOHIDEventSystem) are declared in one C shim target, `CSystemPrivate`. Each
  provider returns `Reading<T>` = value or unavailable-with-reason and never
  throws into the UI. Compared: calling system APIs from views or models (no test
  seam, private API spreads) versus a provider protocol per domain with recorded
  fixtures (selected). Operational ownership: an OS update that breaks a private
  call degrades one reading to "unavailable" instead of crashing. Revisit when:
  Apple ships public per-core frequency or thermal APIs.
- Readings: CPU usage per core from `host_processor_info` (public). Frequency per
  core from IOReport group "CPU Stats", subgroup "CPU Core Performance States",
  residency weighted by the DVFS tables in IORegistry `pmgr` (`voltage-states*`).
  Core grouping from the IODeviceTree `cluster-type` letter of each CPU, ordered
  and named by `hw.perflevelN.*`; no list of known chips (amended 2026-10-06,
  issue 1: an M5 Pro reports 'M' and 'P' and calls them Performance and Super).
  Each core takes the `voltage-states*-sram` table with as many steps as its
  IOReport channel has active states. Temperature from IOHIDEventSystem thermal
  services, always labeled with its level (SoC sensor aggregate). Memory from
  `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`.
  Network from 64-bit interface counters, non-loopback, as deltas. Processes from
  libproc (`proc_listallpids`, `proc_pid_rusage`). Why usage is not taken from
  IOReport: see Pending Evidence P1. Rejected: one source for everything
  (IOReport activity looked wrong on the test machine). Revisit when: P1's
  accuracy check fails.
- Module model (R11, consequential boundary). Selected: compile-time modules. A
  `PanelModule` declares an id, the readings it needs, and a view per tier; a
  registry lists them; config enables, orders, and sets per-module options.
  Compared: runtime plugins as dylibs (ABI and code-signing burden, a security
  hole for an unsandboxed app); script-driven modules in the style of menu bar
  script runners (flexible, but untyped output cannot meet the design bar);
  compile-time modules (selected: typed, testable, designed). Leverage: a new
  module is one file plus a registry line. Revisit when: the owner wants modules
  from other people without rebuilding.
- Data/persistence: two stores, one owner each. The user owns
  `~/.config/ftop/config.json5` (modules, order, options, palette, refresh
  interval, motion); the app owns window frame and last palette in `UserDefaults`.
  Config is decoded with Foundation's JSON5 support, validated, watched for
  changes, and applied live; an invalid file keeps the last good config and shows
  the error on hover. Rejected: TOML (needs a third-party parser for one file);
  property lists (unfriendly to hand editing); a settings window as the only path
  (R11 asks for file-level control). Revisit when: a settings window is requested;
  it would write the same file.
- API/contracts: `Snapshot` and `Config` in `FtopCore` are the sources of truth.
  The CLI's `ftop probe --json` encodes `Snapshot` directly, so there is no second
  schema to drift. CLI to app control uses `DistributedNotificationCenter` with
  three verbs: show, toggle, quit. Rejected: XPC service (needs a bundle service
  and more lifecycle for three verbs); a socket (more code, no benefit). Revisit
  when: a verb needs a reply.
- Launch: the `ftop` command is a small executable that starts the app bundle
  detached and returns at once; if an instance is running it sends `show`.
  Subcommands: `quit`, `toggle`, `probe`, `doctor`, `config path`. Rejected: one
  binary that forks itself (AppKit after `fork` is unsupported). Revisit when:
  never expected.
- Build: SwiftPM only; a script assembles and ad-hoc signs the `.app` bundle
  (`LSUIElement` so there is no Dock icon). Why: text-only project definition that
  agents and reviewers can read and diff; Xcode still opens `Package.swift` for
  previews. Rejected: an Xcode project (opaque project file); XcodeGen or Tuist
  (another tool to install). Revisit when: entitlements, notarization, or a widget
  extension are needed.
- Auth/security: not sandboxed (the private APIs require it), no entitlements, no
  network client code at all, nothing written outside the config and defaults
  paths. The process list shows names only as the OS reports them. Rejected: App
  Sandbox (blocks IOReport and process inspection). Revisit when: distribution
  beyond the owner's machines is decided.
- Testing: Swift Testing. Core: metric arithmetic, rate deltas, ladder order,
  config decoding and validation, formatting. Sensors: providers run against
  recorded fixtures through protocol seams; a hardware smoke (`ftop probe`) runs
  locally only. UI: a fit sweep that renders the panel across a grid of sizes,
  both appearances, and all palettes and fails on any clipped or overlapping
  element; image snapshots for a small set of reference sizes. Rejected: UI
  automation through the Accessibility API (slow, flaky, needs permissions).
  Revisit when: the sweep misses a real regression.
- CI/CD and deploy: no CI (owner rule). `scripts/check.sh` is the single gate:
  format check, build with warnings as errors, tests. Deployment is a local
  install script that copies the bundle to `~/Applications` and links
  `~/.local/bin/ftop`. Rejected: GitHub Actions (owner declined); Homebrew cask
  (needs a public remote and signing). Revisit when: the project gets a remote.
- Observability: `os.Logger` with subsystem `dev.ftop` and categories sensors,
  layout, config, lifecycle; `ftop doctor` prints which readings are available and
  why not; `scripts/perf.sh` measures ftop's own CPU, wakeups, and memory. No
  telemetry. Rejected: file logs (the unified log already filters and rotates).
  Revisit when: users other than the owner need to send diagnostics.
- Performance budget: at 1 Hz with the panel visible, under 1% of one core on
  average and under 60 MB resident; hidden or fully occluded, sampling stops.
  Smooth column motion is on by default and turns off in Low Power Mode and under
  reduced motion. Rejected: unbounded animation (keeps the compositor awake).
  Revisit when: measurements on the owner's machine exceed the budget.
- Resilience: one failing provider never blanks the panel; a late tick is skipped,
  not queued; deltas reset after sleep; the window is pulled back on screen when
  displays change; a second launch reuses the running instance.
- Shared resources: design tokens (palettes, type scale, spacing, radii, motion
  durations) live once in `FtopUI/Theme` and are the only place colors and sizes
  are written; a theme is data, so "line" can be added without new views. Strings
  live in a String Catalog (Simplified Chinese and English).
- Documentation: ADR files under docs/architecture/adr/ created when the scaffold
  lands, from the list below. Revisit when: any listed decision changes.

## System Shape

- Runtime surfaces: `Ftop.app` (the panel); `ftop` (launcher and diagnostics CLI).
- Module boundaries (SwiftPM targets; arrows are allowed imports):
  - `CSystemPrivate` — C declarations of private symbols. Imported only by
    `FtopSensors`.
  - `FtopCore` — `Snapshot`, `Reading`, metric math, `LayoutLadder`, `Config`,
    formatting. Foundation only.
  - `FtopSensors` → `FtopCore`, `CSystemPrivate` — providers and the sampler actor.
  - `FtopUI` → `FtopCore` — modules, components, theme, `LadderLayout`. Must not
    import `FtopSensors`; previews and tests feed it fixture snapshots.
  - `FtopApp` → all — panel window, window state, config watcher, control verbs,
    context menu (palette, modules, quit).
  - `ftop` → `FtopCore`, `FtopSensors` — launcher, `probe`, `doctor`.
- Data flow: timer tick → sampler asks each enabled provider → `Snapshot` (sendable
  value) → main actor `PanelModel` (`@Observable`) → modules render their tier →
  `LadderLayout` picks tier, columns, and scale for the current window size.
- External integrations: none. No network access.
- Background jobs/events: sampler timer; config file watcher; sleep/wake, display
  change, occlusion, appearance, Low Power Mode, and reduced-motion notifications.
- Domain model source: none; terms follow the product decision record.

## Pending Evidence

- P1. Question: can per-core frequency be read without sudo on current hardware
  and OS? Status: returned for feasibility. Result: the archived build's
  `ftop --ftop-probe` printed a frequency for each of 10 performance and 4
  efficiency cores on an M4 Pro, macOS 27.0.1, unprivileged (run 2026-10-06; no
  evidence file was written). The same output showed about 99–100% activity on
  every core at the same time, which is implausible. So usage comes from
  `host_processor_info`, and the frequency arithmetic must be cross-checked against
  `sudo powermetrics` by the owner during the first slice. If it cannot be made
  accurate, frequency falls back to per-cluster values and the line across each
  column is drawn per cluster.

## Scaffold Plan

- Directory structure (all handwritten; nothing is generated):
  - `Package.swift` — targets and the allowed-import graph above.
  - `Sources/CSystemPrivate/include/` — `ioreport.h`, `hidthermal.h`, module map.
  - `Sources/FtopCore/` — `Model/`, `Metrics/`, `Layout/`, `Config/`, `Format/`.
  - `Sources/FtopSensors/` — `CPU/`, `Thermal/`, `Memory/`, `Network/`,
    `Process/`, `Sampler.swift`, `SystemSource.swift` (protocol seams).
  - `Sources/FtopUI/` — `Panel/` (`LadderLayout`, `PanelView`, `PanelModel`),
    `Modules/` (one file per module), `Components/`, `Theme/`,
    `Resources/Localizable.xcstrings`.
  - `Sources/FtopApp/` — `main.swift`, `PanelController.swift`,
    `WindowState.swift`, `ConfigWatcher.swift`, `Control.swift`, `ContextMenu.swift`.
  - `Sources/ftop/main.swift` — launcher and subcommands.
  - `Support/Info.plist`, `Support/config.example.json5`.
  - `Tests/FtopCoreTests/`, `Tests/FtopSensorsTests/Fixtures/`,
    `Tests/FtopUITests/` (fit sweep, snapshots under `__Snapshots__/`).
  - `scripts/check.sh`, `scripts/bundle.sh`, `scripts/install.sh`, `scripts/perf.sh`.
- Required config files: `Package.swift`, `.swift-format`, `.editorconfig`,
  `Support/Info.plist`.
- Core modules: CPU, Memory, Network, Processes (R4, R6, R8, R9); temperature is
  part of CPU (R5).
- Contract/generated files: none.
- Test locations: as above, mirroring targets.
- Local dev commands: `scripts/check.sh` (gate); `swift build`; `swift test`;
  `swift run ftop probe`; `scripts/bundle.sh && scripts/install.sh`;
  `scripts/perf.sh`.
- CI workflows: none.
- Deployment artifacts: `build/Ftop.app`, the `ftop` link, the example config.
- Validation per area: every target by `swift build` and `swift test`; scripts by
  `scripts/check.sh` running them in dry-run mode; the bundle by launching it and
  `ftop doctor`.

## Migration and Rollout

N/A — the btop-based code was removed before this blueprint; there is no live data,
installed user base, or contract to preserve. The old build remains in the local
archive zip and at git tag `archive/btop-fork-v1.4.7`.

## Implementation Sequence

- Foundation: package and targets, `scripts/check.sh`, format config, `Snapshot`
  and `Reading`, theme tokens ported from the trial, the empty panel window that
  moves, resizes from any edge, snaps, and remembers its frame.
- First vertical slice: the CPU module with real data across the whole size
  ladder — per-core usage, per-core frequency through the private API, temperature
  with its label, and `LadderLayout` choosing tiers from the smallest strip to the
  full-screen layout. This exercises both risky decisions (private APIs and
  any-size layout) and settles P1's accuracy check.
- Hardening: remaining modules; config file with live reload; `ftop` launcher and
  verbs; palettes and appearance; hover chip; motion rules; resilience items;
  performance measurement against the budget; fit sweep and snapshots.
- Launch gates: `scripts/check.sh` green; fit sweep clean; budget met on the
  owner's machine; `ftop doctor` shows every reading available or an honest
  reason; the owner has dragged the real panel through small, thin, and large
  sizes and compared it with the trial.

## Verification

- Unit/component tests: residency-to-frequency math including the degenerate
  inputs the old code guarded; rate deltas across counter wrap and sleep; ladder
  order; config validation and fallback; number and unit formatting.
- API/contract tests: `Snapshot` JSON round trip; `ftop probe --json` decodes into
  `Snapshot`; control verbs reach a running instance.
- Integration/E2E tests: fit sweep over the size grid in both appearances and all
  palettes; snapshots at the reference sizes in the trial.
- Build/type/lint checks: Swift 6 language mode, warnings as errors,
  `swift format lint --strict`.
- Deployment smoke: install, run `ftop`, `ftop toggle`, `ftop quit`, relaunch
  restores the frame.
- Observability checks: `ftop doctor` output; `scripts/perf.sh` numbers recorded in
  docs/evidence/.

## ADRs to Write

- ADR: Native floating panel in Swift and SwiftUI. Context/decision: refinement and
  any-size need native rendering. Rejected: web runtimes, custom GPU UI,
  AppKit-only. Revisit when: SwiftUI misses the performance budget.
- ADR: SwiftPM-only build with a bundling script. Context/decision: text project
  definition for agent-driven work. Rejected: Xcode project, generators. Revisit
  when: entitlements or extensions are needed.
- ADR: Private system APIs behind one target with typed availability.
  Context/decision: frequency and temperature have no public API. Rejected: sudo
  tools, privileged helper. Revisit when: public APIs appear or P1 fails.
- ADR: Measured ladder layout. Context/decision: order as data, fit by
  measurement. Rejected: `ViewThatFits` nesting, fixed breakpoints. Revisit when:
  resize cost is measurable.
- ADR: Compile-time modules configured by a JSON5 file. Context/decision: typed,
  designed modules; user-owned file. Rejected: runtime plugins, script modules,
  TOML. Revisit when: third-party modules or a settings window are wanted.
- ADR: No CI, single local gate. Context/decision: owner rule. Rejected: GitHub
  Actions. Revisit when: a remote exists.

## Risks And Assumptions

- Risks:
  - Private APIs can change in an OS update. Contained by the boundary and typed
    availability; `ftop doctor` reports it.
  - Unprivileged process inspection may refuse CPU or memory for processes owned
    by other users, including system ones such as WindowServer. Default: list what
    is readable and say so in `ftop doctor`; a helper is out of scope.
  - Temperature sensor names differ across chips; the label must come from what
    was actually read, or the value is unavailable.
  - Continuous column motion may exceed the budget; it is switchable and measured.
  - The fit sweep proves no clipping, not beauty; the owner's drag-through remains
    a launch gate.
- Assumptions (defaults, each reversible):
  - Apple Silicon only.
  - Minimum macOS 26, to use the system glass material directly. The owner's
    machine runs macOS 27.0.1.
  - Local install only; no signing identity, notarization, or public release yet.
  - Bundle identifier `dev.ftop.app`.
  - License undecided; nothing is published until it is.
- Revisit triggers: listed per decision above.

## Handoff

- Assumptions with stated defaults: the five above.
- Open questions (none blocking):
  - Optional large-window modules (process icons, finer memory, GPU and power,
    battery). Default: none in the first version; the module model admits them.
  - Whether the frequency line per core stays if P1's accuracy check fails.
    Default: per-cluster line.
- Non-goals: as in Summary.
- Status line: written to docs/architecture/2026-10-06-ftop-blueprint.md; stack,
  boundaries, and ADRs await the owner's approval; next step is approval, then
  `project-init` Scaffold, then `plan-tasks`.

## Amendments after the first build

Recorded 2026-10-06 after the first working version. Each item replaces the matching
decision above.

- Minimum macOS is 15, not 26. The panel uses `NSVisualEffectView` for the glass look,
  which needs nothing newer. Revisit when: a newer system material is wanted.
- Layout choice is arithmetic, not a `Layout` that measures at run time. Every candidate's
  ideal size is measured once at scale 1 with fixed sample data shaped like this machine;
  `LayoutLadder.choose` then picks a candidate and a continuous scale from those sizes.
  Resizing costs no measurement. The order is still data and the fit is still measured.
- Processes are read by a child process, `ftop-helper`, and listed every other sample.
  Unprivileged it reads the user's own processes (about 350 of 1,650 were unreadable on
  the test machine, WindowServer among them). The owner chose to grant access:
  `sudo ftop grant` installs the helper setuid root at `/usr/local/libexec/ftop/`. This
  replaces "no helper, no subprocesses". Rejected: calling `ps` (55 ms of CPU per call).
- Core columns are Core Animation layers inside one `NSView` (`CoreBars`), not SwiftUI
  shapes. Columns ease to each new reading for 0.4 s instead of gliding continuously.
  Measured cost of the alternatives on the test machine: continuous SwiftUI animation
  45–60% of a core; SwiftUI's numeric text transition another ~35%.
- Strings are two-language constants in code (`Strings`), not a String Catalog, so the
  app bundle needs no resource bundle. A `language` setting can force one language.
- The CLI gained `size`, `grant`, and `revoke`. The app executable is `FtopPanel`
  because `Ftop` and `ftop` collide on a case-insensitive disk.
- `Support/config.example.json5` does not exist; the commented template lives in
  `Config.template` and is written on first launch.
- Performance budget: not met. Measured on an M4 Pro at 1 Hz with motion on: panel 4–5%
  of one core and about 31 MB; helper about 1%. The remaining cost is SwiftUI
  re-rendering text each second. With `motion: false` the panel measured 2–3%.
- P1 result: per-core frequency reads without admin rights and varies plausibly with
  load (idle performance cores at the lowest step, busy ones higher). The archived
  build's "99% on every core" came from its own arithmetic, not the API. The comparison
  against `sudo powermetrics` has not been run.

## Amendments after the second build

Recorded 2026-10-06. Each item replaces the matching decision or amendment above.

- No SwiftUI. The panel is drawn from a `Scene`: plain geometry (text runs, shapes, the
  core columns' rectangle, hover regions) built by `SceneBuilder` from a snapshot, a
  layout choice, and `PanelStyle`. `PanelCanvasView` draws it with Core Text into its own
  bitmap, redrawing only the rectangles whose content changed, and hands the image to a
  layer. Rejected: SwiftUI with fewer invalidations (the first build spent about 60 ms of
  main-thread time per sample in graph update and layout however little changed);
  `draw(_:)` on a layer-backed view (kept about 4 MB of glyph cache per type size, 180 MB
  in total); an sRGB bitmap (the system converted it to the display's color space on
  every change, two thirds of the remaining cost). Revisit when: a control needs real
  text input or accessibility beyond what the scene's hover regions give.
- Layout is exact, not measured. A candidate's size is the size of the scene built for
  it; the window is set to that size. `FitSweepTests` checks every candidate at several
  scales for text leaving the panel, text overlapping text or the core columns, and
  numbers centered under their columns.
- `LayoutLadder.choose` picks by coverage of the dragged size (see the product
  amendments) and returns how much the layout grows; `PanelModel.choice(for:)` then
  corrects scale and growth against the real scene so it never exceeds the window.
- The chosen layout and the core counts are stored in user defaults. Layout sizes
  depend on core counts, so they are known before the window is first sized.
- `ftop-helper` protocol version 2: it keeps the previous CPU times itself and answers
  with only the sixteen busiest processes. The panel still understands a version 1
  helper left in `/usr/local/libexec/ftop/` by an earlier `sudo ftop grant`, at a higher
  cost; `ftop doctor` says when that is the case.
- While the panel is hidden or fully covered the sampler reads only the module the
  menu bar item shows (per-core usage without frequencies when that is the processor);
  with the menu bar item off it stops. Since 2026-10-08 that module is read even when
  the panel does not show it, and the panel is given the readings without it.
- Network: an interface's name is looked up once per index, not on every sample.
- Performance, measured on an M4 Pro at 1 Hz with motion on, panel at 300×420: panel
  0.9–1.3% of one core and 22 MB, with the version 1 helper still installed (the panel
  parses about 1,650 process lines every other sample in that case). Helper about 1%.
  The budget of under 1% is met only at the low end of that range. Not yet measured with
  the version 2 helper installed setuid, which needs the owner's password.
- Later the same day: the canvas draws into two `IOSurface`s in turn and gives the layer
  the finished one. An image made from a bitmap is a copy-on-write copy, and the page
  copies cost more than the drawing in a large window. The menu bar number updates
  every other sample because the system's status item machinery costs more per update
  than the panel does. Measured with the version 2 helper, motion on: about 1.0% of one
  core at 300×420, about 1.3% at 1049×500 (text is drawn at up to twice the size
  there), 0.0–0.1% while the panel is hidden or fully covered. Memory 22–38 MB.
  The budget is still not met for large windows.
- `ftop-helper` protocol version 3 adds the 32 processes holding the most memory after
  the 32 busiest. With a version 2 helper still installed the list by memory shows as
  unavailable and lists stop at 16 rows; `ftop doctor` says so.
- Capping type at 1.3 times and filling large windows with rows did not lower the cost:
  1.3–1.5% at 1049×492 against 1.2–1.3% before. The cost of a large window is a floor
  of per-sample work spread over many small items, not the size of the type. Slowing
  the small core numbers to every other sample was tried and reverted: no measurable gain.


## Amendment: updates (2026-10-06)

- Decision: ftop checks GitHub's latest release of Nongfsq/ftop once a day and, by
  default, installs it (`updates: "install" | "check" | "off"` in the settings file).
  Asked for by the owner together with the 0.1.1 release. Compared: Sparkle (a
  dependency and an appcast to host, built for Developer ID signed apps) versus a
  small updater over the releases the project already publishes (selected).
- Shape: `FtopCore/Update.swift` holds the version order and the reading of the
  release answer (tested); `FtopApp/Updater.swift` downloads, checks, swaps the
  bundle, and restarts. It is the only code in ftop that goes online.
- Trust: releases are ad-hoc signed, so authenticity rests on HTTPS to github.com and
  on the archive address being this repository's release downloads. The archive must
  match the SHA-256 the release states, hold `dev.ftop.app` at exactly the announced
  version, and pass `codesign --verify`. Only a newer version is installed.
- Root: the updater replaces the user-owned app bundle only. The setuid helper at
  `/usr/local/libexec/ftop` is never written by it; a release cannot change what runs
  as root without the owner running `sudo ftop grant` again.
- Revisit when: releases are signed with a Developer ID (then verify the signer).

## Amendment: GPU and power readings (2026-10-07)

- Sources, all read as a normal user: GPU usage and memory in use from the graphics
  driver's `PerformanceStatistics` (`IOAccelerator`); GPU frequency from IOReport
  group "GPU Stats", channel `GPUPH`, weighted by the steps the GPU's own node lists
  (`sgx`, property `perf-states`); GPU power from IOReport "Energy Model", channel
  "GPU Energy"; GPU temperature and whole-machine power from the controller (SMC):
  every key starting "Tg", and `PSTR` (machine) and `PDTR` (adapter).
- The controller's call layout is not published. It is declared only in `CFtopSys`,
  and only reads are made. Keys differ between chips, so the "Tg" keys are listed once
  at start instead of being named.
- Rejected: IOReport's GPU temperature channels and the HID sensors (the first read 0,
  the second do not say which sensors are the GPU's); `powermetrics` (needs root);
  the CPU's share of power (IOReport returns 0 for it without root, and ftop shows
  nothing rather than a zero).
- Revisit when: a chip has no `sgx` node or a different step count than `GPUPH`
  reports (frequency then shows as unavailable), or `PSTR` is missing.

## Amendment: column motion (2026-10-07)

- Replaces "columns ease to each new reading for 0.4 s". Each column's fill is a layer as
  tall as its track that slides on `position.y`; a reading sets the model value and adds
  an additive `CAKeyframeAnimation` of the difference, so overlapping moves sum in the
  render server and the app still does no per-frame work. Constants are in `Theme.swift`.
- Unmeasured: the render server now animates whenever readings change. Run
  `scripts/perf.sh` before calling the performance budget met or missed for this motion.
