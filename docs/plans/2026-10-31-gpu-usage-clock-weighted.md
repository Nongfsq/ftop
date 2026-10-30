# Plan: GPU usage is busy time weighted by clock (2026-10-31)

Status: ready. Written for an implementer who has not seen the discussion; everything
needed is here or at the paths named. Task IDs `GPU-001` … are new; the repository
had no task ledger before this plan.

## Readiness and sources

- Product and design decision: made 2026-10-31 by K Xie (contributor, delegated by the
  owner, who said a better reading may be built and explained in the pull request).
  Its text is in "Decision to record" below; `GPU-007` writes it into
  `docs/product/2026-10-06-floating-panel-decision.md`. The approved layout rule it
  builds on is that file's amendment "the GPU has a column of its own" (2026-10-09):
  height is usage, the line is frequency; one column; detail in the hover.
- Architecture: `docs/architecture/2026-10-06-ftop-blueprint.md`, amendment "GPU and
  power readings" (2026-10-07, amended 10-08): usage from the graphics driver, frequency
  from IOReport `GPUPH` weighted by the `sgx` node's `perf-states`. `GPU-007` amends it:
  usage now comes from the same `GPUPH` data, the driver is the fallback.
- Evidence: `docs/evidence/2026-10-28-gpu-usage/handoff.md` (34 hours of samples, a
  full-load run, the numbers behind the decision) and `ut-aggd.md` in the same folder
  (why the remaining gap to power cannot be closed: no counter reports how many GPU
  cores are busy, as a normal user or as root). That folder is untracked in the owner's
  checkout at `/Users/shek/Documents/Projects/ftop`; `GPU-001` brings it into the branch.
- Repository rules: `AGENTS.md`; profile `docs/agents/project-profile.md` (check gate
  `scripts/check.sh`, reference images, English docs, `feat:` commits).
- Experience spec, confirmed-understanding IDs, scaffold, prototype: N/A — this project
  keeps decisions in the decision doc's amendments and has none of those artifacts.
- Remaining upstream blockers: none.

## Summary and current reality

A user found the GPU figure high at rest. Measured on an M5 Max driving two 5K
displays: the GPU is busy 20–50 % of the time at its lowest clock (338 MHz) drawing
under 1 W, and ftop shows that busy share because the driver's `Device Utilization %`
is a share of time, blind to clock and to how many cores run.

Today:

- `Sources/CFtopSys/CFtopSys.c` `ftop_gpu_read_stats` (about line 1008) reads the
  driver's `Device Utilization %` into `ftop_gpu_stats.utilization` (0…1).
- `ftop_gpu_frequency` (about line 832) already works out, from `GPUPH` residencies
  and the `perf-states` table, `active` (share of the interval in a non-idle state),
  `mhz` (active-time-weighted frequency) and `max_mhz` (top of the table); the sampler
  `ftop_gpu_sampler_update` fills these each interval. Nothing new is read from the
  system in this plan.
- `Sources/FtopSensors/Providers.swift` `GPUProvider.sample()` (about line 263) returns
  the whole GPU unavailable when the driver read fails, else `GPUSample(usage:
  stats.utilization, …)`.
- `Sources/FtopCore/Model.swift` `GPUSample` (about line 110): `usage`,
  `frequencyMHz`, `maxFrequencyMHz`, `memoryBytes`, `temperature`,
  `frequencyFraction` (= mhz / max).
- UI reads `gpu.usage` for the column height, the ring, the figures, and the menu bar
  (`Sources/FtopUI/SceneBuilder.swift` lines 192, 271, 331, 373, 419, 547, 800, 1018;
  `Sources/FtopUI/Theme.swift` `Strings.gpu` line 340 builds the hover). The column's
  tick is `frequencyFraction` (`Sources/FtopUI/CoreBars.swift` line 253).
- CLI: `Sources/ftop/main.swift` prints the figure in `probe` (line 99) and the line
  `gpu usage … from the graphics driver` in `doctor` (line 141).
- The driver field also reads a false 0 now and then while the hardware is busy
  (handoff §3.4); `GPUPH` never did in two days of samples.

Approved scope: the usage figure's definition and source, its fallbacks, the hover
and CLI wording that explain it, the tests, the decision and blueprint amendments, the
progress note, and the README clause. Non-goals: per-process GPU time ("who uses the
GPU", a later pull request); any new panel element or layout; calibration or per-model
tables (rejected by the owner); recovering the number of busy cores (not readable, see
`ut-aggd.md`); changes to the CPU core columns.

## Decision to record (imported as a constraint; `GPU-007` writes it)

Append to `docs/product/2026-10-06-floating-panel-decision.md` after the "Resize
cursors" section, as an amendment titled
"GPU usage is busy time weighted by clock (2026-10-31, approved by delegation)":

- Approved by the owner's delegation to the contributor who measured it; the user who
  reported it found the GPU figure high at rest. Evidence in
  `docs/evidence/2026-10-28-gpu-usage/`.
- The GPU's usage is the share of its peak throughput in use: for each performance
  state, the time in it times its clock, summed, over the interval times the top clock
  (`Σ residency_i × f_i ÷ (total × f_max)`). The data is IOReport `GPUPH` and the
  `sgx` node's `perf-states`, the same data the frequency line uses. It equals busy
  share × frequency ÷ top frequency.
- Why: the figure should answer "how much of the GPU is being used", not "what share
  of the time was it awake". Watts already answer the power question in the GPU's
  pair. Voltage was considered (V²·f) and rejected: it restates the watts, needs a
  voltage table the chip lists four variants of, and breaks the geometry below. Windows
  has used the clock-weighted definition for the CPU since Windows 8.
- Geometry: the column's height is this usage and its line is frequency ÷ top
  frequency, so the column never rises above the line, and the column touching the
  line means 100 % busy at that clock. A column touching a line held mid-way reads
  "saturated, clock held down" (thermal or power limit); a low line with a low column
  reads "slow compositing". The limit signal lives in the shape, with no new element.
- Fallbacks, in order, each named in `ftop doctor` as the temperature's sensor level
  is: clock-weighted (`GPUPH` with a known clock) → busy share from `GPUPH` when the
  clock is unknown (a state past the table, as on the M6, or no table) → the driver's
  `Device Utilization %` when IOReport gives nothing. A value none of them can give is
  unavailable, never 0. Busy share 0 with the table known is a true 0.
- The hover gains the busy share, only when it differs from the figure:
  `GPU 10 % · busy 37 % · 0.34 GHz · 0.9 W · VRAM 1.4 GB · 56°`. Nothing else on the
  panel changes; the menu bar reading follows the figure.
- The word stays "usage". Activity Monitor and `nvidia-smi` show busy time, so the
  numbers differ from theirs; the hover's busy share is their number.
- Known gap, accepted: a lightly loaded GPU at full clock (a few of its cores busy)
  reads higher than its share of full-load power, by about 2–3× in the measurements.
  No readable counter reports how many cores are busy (`ut-aggd.md`), and the only
  reading that tracks it is the watts, which are beside the figure.
- Not done: the CPU core columns keep their time-share definition; the GPU column is
  the one column with the clock-weighted one, and the hover says so.

Append to `docs/architecture/2026-10-06-ftop-blueprint.md` under "GPU and power
readings": usage is derived in `FtopCore` from the `GPUPH` sampler's active share,
weighted frequency and top frequency (`ftop_gpu_freq`), with the busy share and then
the driver's `Device Utilization %` as fallbacks; `ftop_gpu_read_stats` still supplies
memory. Reason: the driver's field is blind to clock and reads a false 0 at times.

## Imported constraints

- `AGENTS.md`: only `FtopSensors` and `CFtopSys` touch system APIs; `FtopUI` never
  imports `FtopSensors`; strings and sizes only in `Theme.swift`; a layout's size never
  depends on readings; unavailable is never shown as 0; `ftop-helper` untouched.
- Decision doc: height is usage, line is frequency; one column; hover carries detail;
  no new elements or divider lines; text minimal.
- `GPUSample` is `Codable` and appears in `ftop probe --json`: new fields are additive;
  nothing decodes it back, so no compatibility window is needed.
- The GPUPH sampler needs two reads for a delta; `probe` already waits for one interval
  to show a frequency, so the usage arrives the same way.

## Workstreams

- Client (panel, menu bar): hover text only; column, ring, figures and menu bar follow
  `usage` unchanged. (`GPU-004`)
- Sensors and model: the usage ladder as a pure function in `FtopCore`, wired in
  `GPUProvider`. (`GPU-002`, `GPU-003`)
- Data and compatibility: additive JSON fields; no migration. N/A beyond that.
- Security, privacy, observability: N/A — no new system reads, no new privileges;
  `doctor` names the source (`GPU-005`).
- Tests, docs, rollout, rollback: `GPU-002` tests, `GPU-006` validation, `GPU-007`
  docs, `GPU-008` progress, `GPU-009` branch and pull request.

## Tasks

### GPU-001: Branch from `main` with the evidence folder

- Status: pending
- Depends on: none
- Files: new worktree on branch `feat/gpu-usage-clock-weighted` cut from `main`
  (`a318876` or later); `docs/evidence/2026-10-28-gpu-usage/` (copy, all files);
  `docs/plans/2026-10-31-gpu-usage-clock-weighted.md` (copy, this file).
- Change: Cut the branch from `main`, not from `fix/power-state-crash` (that checkout's
  current branch, with an open pull request). Copy the two untracked paths from
  `/Users/shek/Documents/Projects/ftop` into the worktree and commit them as
  `docs: GPU usage evidence and plan`.
- Acceptance: `git log main..HEAD` shows one commit; `git status` clean; the evidence
  folder's `handoff.md`, `ut-aggd.md`, CSVs and sources are in it.
- Validation: `git diff --stat main..HEAD` lists only `docs/evidence/…` and
  `docs/plans/…`.
- Parallelism: first; everything depends on it.

### GPU-002: The usage ladder as a pure function, with tests

- Status: pending
- Depends on: GPU-001
- Files: `Sources/FtopCore/Model.swift` (modify `GPUSample`),
  `Tests/FtopCoreTests/CoreTests.swift` (new suite `GPUUsageTests`).
- Change: Add `public enum GPUUsageSource: String, Sendable, Codable { case
  clockWeighted, busyTime, driver }`. Add to `GPUSample` the stored fields
  `busy: Reading<Double>` (share of the interval in a non-idle state, from `GPUPH`)
  and `usageSource: GPUUsageSource`; keep `usage: Double` and all existing fields;
  update the doc comment on `usage` to "0...1 share of the GPU's peak throughput in
  use; see `usageSource`". Add a pure static
  `GPUSample.usage(busy: Double?, mhz: Double?, maxMHz: Double?, driver: Double?)
  -> (usage: Double, source: GPUUsageSource)?` implementing: if `busy` and `maxMHz > 0`
  are known and (`busy == 0` or `mhz > 0`) → (`busy × mhz ÷ maxMHz`, clamped 0…1, or 0
  when `busy == 0`; `.clockWeighted`); else if `busy` is known → (`busy`, `.busyTime`);
  else if `driver` is known → (`driver`, `.driver`); else `nil`. Update every
  `GPUSample.init` call site to pass the new fields; there are three:
  `Sources/FtopSensors/Providers.swift:291`, `Sources/FtopCore/Model.swift:407` (the
  sample snapshot: keep usage 0.37 at 620 of 1578 MHz and give it `busy: .value(0.94)`,
  `usageSource: .clockWeighted`, so the sample obeys usage = busy × f ÷ f_max),
  `Tests/FtopUITests/FitSweepTests.swift:122`.
- Acceptance: the function returns, from the handoff's numbers: (0.479, 451, 1620, …)
  → 0.133 clockWeighted; (0.999, 1619, 1620, …) → 0.998 clockWeighted; (0, nil, 1620,
  0.37) → 0 clockWeighted; (0.5, nil, nil, 0.4) → 0.5 busyTime; (nil, nil, nil, 0.37)
  → 0.37 driver; (nil, nil, nil, nil) → nil; a product above 1 clamps to 1.
- Validation: `swift test --filter GPUUsageTests` passes; `swift build` passes for all
  targets.
- Parallelism: owns `Model.swift` and `CoreTests.swift`; `GPU-003` and `GPU-004`
  follow it.

### GPU-003: `GPUProvider` uses the ladder and no longer needs the driver

- Status: pending
- Depends on: GPU-002
- Files: `Sources/FtopSensors/Providers.swift` (modify `GPUProvider.sample()`, about
  lines 263–296).
- Change: Read the driver stats and the GPUPH sampler as today, but do not return
  unavailable when the driver read fails. Build `busy` from `raw.active` (≥ 0 →
  `.value`, else `.unavailable("IOReport reports no GPU activity data")`), `mhz` from
  `raw.mhz > 0`, `maxMHz` from `raw.max_mhz > 0`, `driver` from
  `stats.utilization >= 0`. Call `GPUSample.usage(…)`; when it returns `nil`, return
  `.unavailable("neither IOReport nor the graphics driver reports GPU usage")`.
  Memory stays from the driver (`.unavailable` when the driver read failed).
  Frequency reasons stay as they are. Keep the temperature cadence.
- Acceptance: on the M5 Max at rest, `ftop probe` shows a GPU usage in the low single
  digits with busy 30–50 %; the `stress.swift` full load (in the evidence folder) shows
  98–100 %; a run where the IOReport sampler is forced to fail (temporarily, locally)
  shows the driver figure with source `driver`; nothing shows 0 where a value is
  unavailable.
- Validation: `swift run ftop probe` and `swift run ftop probe --json` (the JSON has
  `busy` and `usageSource`); the full-load check above.
- Parallelism: owns `Providers.swift`; can run beside `GPU-004` and `GPU-005`.

### GPU-004: The hover names the busy share

- Status: pending
- Depends on: GPU-002
- Files: `Sources/FtopUI/Theme.swift` (modify `Strings.gpu`, about line 340),
  `Sources/FtopUI/SceneBuilder.swift` (doc comment at line 327 only).
- Change: After the usage part, when `gpu.usageSource == .clockWeighted` and
  `gpu.busy.value` exists, append `pick("busy", "忙碌") + " \(Format.percent(busy))%"`.
  For the other two sources add nothing (the figure already is the busy share). Update
  the comment at `SceneBuilder.swift:327` to say height is clock-weighted usage. No
  other panel text, size, or element changes.
- Acceptance: hover at rest reads like `GPU 4% · busy 37% · 0.34 GHz · 0.7 W · VRAM
  2.6 GB · 45°`; under full load `GPU 100% · busy 100% · 1.62 GHz …`; with the driver
  source no `busy` part appears; the panel's layout and sizes are unchanged in the
  reference images.
- Validation: `swift test --filter RenderTests` passes; the hover is checked on the
  real panel in `GPU-006`.
- Parallelism: owns `Theme.swift` and the one comment; parallel with `GPU-003`.

### GPU-005: `probe` and `doctor` say which usage this is

- Status: pending
- Depends on: GPU-002
- Files: `Sources/ftop/main.swift` (modify lines about 95–99 and 141).
- Change: `probe` prints `GPU 4%, busy 37%, 0.34 GHz, …` when the source is
  clock-weighted, else as today. `doctor`'s `gpu usage` line reports the source:
  clockWeighted → `busy time weighted by clock, from IOReport (GPUPH and perf-states)`;
  busyTime → `busy time only, from IOReport; clock unknown: <frequency reason>`;
  driver → `busy time from the graphics driver; IOReport gave no GPU activity`. The
  line is `ok` for the first, `ok` with the reason for the second, `MISS`-style only
  when the GPU is unavailable, as today.
- Acceptance: `swift run ftop doctor` on the M5 Max prints the first wording;
  `--states` output is unchanged.
- Validation: run `swift run ftop doctor` and `swift run ftop probe`; compare with
  `GPU-003`'s acceptance.
- Parallelism: owns `Sources/ftop/main.swift`; parallel with `GPU-003` and `GPU-004`.

### GPU-006: Validation on the real panel

- Status: pending
- Depends on: GPU-003, GPU-004, GPU-005
- Files: none in the repository; reference images to a scratch folder for review.
- Change: Run the gate and the layout checks the decision doc requires for a change to
  what the panel shows.
- Acceptance: `scripts/check.sh` passes (use Xcode's toolchain: the profile notes the
  Command Line Tools alone fail the second `swift test`); the reference images are
  regenerated and looked at; the panel is run from the worktree (`scripts/bundle.sh`,
  then launch the built app, not `scripts/install.sh`, so the installed 0.2.7 stays)
  and dragged through small, thin, and large sizes with the GPU hover shown in each;
  the menu bar GPU reading follows the new figure; `stress.swift` at full load shows the
  column touching its line at the top; at rest the column sits well below the line.
- Validation: `scripts/check.sh`; `FTOP_RENDER_DIR=<scratch> swift test --filter
  RenderTests`; the manual pass above, recorded with screenshots in the scratch folder
  and summarised in `GPU-008`. The owner's delegate (K Xie) looks at the images before
  the pull request opens.
- Parallelism: not parallel; last before the docs.

### GPU-007: Decision and blueprint amendments, README clause

- Status: pending
- Depends on: GPU-002
- Files: `docs/product/2026-10-06-floating-panel-decision.md` (append the amendment
  from "Decision to record"), `docs/architecture/2026-10-06-ftop-blueprint.md` (append
  under "GPU and power readings" as given above), `README.md` (line 40: after "the fill
  is usage" add ", busy time weighted by clock, so a GPU idling at its lowest clock reads
  low").
- Change: Write the texts as given, English, in the files' existing voice. The decision
  doc's "Open" list (about line 576) has no item on the GPU's usage; add none.
- Acceptance: the amendment reproduces every bullet of "Decision to record"; the
  blueprint names the new source and fallbacks; the README clause is one sentence.
- Validation: read back. `scripts/check.sh` has no docs step (it lints Swift format,
  builds with warnings as errors, and runs the tests), so the texts are checked by eye.
- Parallelism: docs only; parallel with `GPU-003`–`GPU-005`.

### GPU-008: Progress note

- Status: pending
- Depends on: GPU-006, GPU-007
- Files: `docs/progress/2026-10-31.md` (new).
- Change: In the form of `docs/progress/2026-10-21.md`: what was built and why (one
  paragraph pointing at the amendment), what was checked (the `GPU-006` list, with the
  rest and full-load figures observed), what was not checked (M1–M4 and M6 hardware; a
  single display; graphics-heavy loads), and found-on-the-way notes. No cost table is
  required: the change adds no system reads; say so.
- Acceptance: a reader of the note alone knows what changed, what was seen, and what
  was not.
- Validation: read back.
- Parallelism: last.

### GPU-009: Push to the fork and draft the pull request text for review

- Status: pending
- Depends on: GPU-008
- Files: none in the repository; `pr.md` in the session's scratch folder.
- Change: Commit in conventional prefixes (`feat: GPU usage is busy time weighted by
  clock`, `docs: …`), run `scripts/check.sh` once more, push the branch to `origin`
  (`https://github.com/yume-shek/ftop.git`, the contributor's fork) and never to
  `upstream` (`Nongfsq/ftop`, the owner's repository). Write the pull request title and
  body to `pr.md`: the problem (high figure at rest, with the measured numbers), the
  definition and the geometry, the fallbacks, what was rejected and why (V²·f, tables,
  the UT channels), what was checked and not, and links to the evidence folder and the
  amendment. Do not open the pull request; show `pr.md` to K Xie and stop.
- Acceptance: the branch is on `origin`; `pr.md` exists and is complete; no pull request
  exists yet.
- Validation: `git log origin/feat/gpu-usage-clock-weighted -1`; `gh pr list --repo
  Nongfsq/ftop --head yume-shek:feat/gpu-usage-clock-weighted` shows none.
- Parallelism: last. Opening the pull request (`gh pr create --repo Nongfsq/ftop --base
  main --head yume-shek:feat/gpu-usage-clock-weighted`) happens only after K Xie
  approves the text.

## Test, rollout, rollback, handoff

- Tests: `GPUUsageTests` (pure ladder), existing `GPUFrequencyTests` unchanged,
  `RenderTests` regenerated. No hardware test can run in CI (there is none).
- Rollout: one pull request; no setting, no migration; `probe --json` gains two fields.
- Rollback: revert the pull request; nothing persists the new fields.
- Risks: the `GPUPH` active share on M1–M4 and M6 has only been read for frequency so
  far; the ladder falls back to busy share or the driver where the table is missing or
  a state is uncovered, and `doctor` says which. Two open pull requests from the same
  fork (28, 29) may touch the decision doc's and progress folder's ends; resolve on
  merge order, nothing else overlaps.
- Authority already granted by K Xie (2026-10-31): implement on a branch, run the
  checks, push to `origin` only. Not granted: opening the pull request, merging,
  pushing anywhere else, `scripts/install.sh`.
- Next executable: `GPU-001`, then `GPU-002`; then `GPU-003`, `GPU-004`, `GPU-005`,
  `GPU-007` in parallel; then `GPU-006`, `GPU-008`, `GPU-009`.
