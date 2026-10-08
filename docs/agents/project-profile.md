# Project profile

verified: 2026-10-06 · owner rules: AGENTS.md · status tokens: off

## Identity
- ftop: a small macOS status monitor as a native floating panel that works at any window size; opened by typing `ftop` (source: docs/intent/2026-10-05-ftop-intent.md)

## Stack
- Swift 6 (strict concurrency), AppKit panel drawn with Core Text from a scene (no SwiftUI), Core Animation for the core columns, one C target for private APIs; SwiftPM only; Apple Silicon, macOS 15+ (source: Package.swift, docs/architecture/2026-10-06-ftop-blueprint.md)

## Commands
- check (the gate): `scripts/check.sh` (source: scripts/check.sh)
- build and install: `scripts/bundle.sh && scripts/install.sh` (source: scripts/)
- format: `swift format --in-place --recursive Package.swift Sources Tests` (source: .swift-format)
- sensors on real hardware: `swift run ftop doctor` (source: Sources/ftop/main.swift)
- reference images: `FTOP_RENDER_DIR=<dir> swift test --filter RenderTests` (source: Tests/FtopUITests/RenderTests.swift)
- README pictures after a change to how the panel looks: `scripts/readme-media.sh`, needs Python with Pillow (source: scripts/readme-media.sh)
- app icon after changing the logo: `scripts/icon.sh` (source: scripts/icon.sh)
- own cost: `scripts/perf.sh` with the panel running (source: scripts/perf.sh)

## Validation baseline
- default: `scripts/check.sh`; for a layout change also regenerate the reference images and look at them (source: AGENTS.md)
- needs the owner: anything with `sudo` (`ftop grant`, `powermetrics`); screen captures (trigger a macOS permission prompt)

## Conventions
- language: English for code and docs; Chinese for owner-facing summaries and choices (source: user-stated, ~/.claude/CLAUDE.md)
- commits: conventional prefixes such as `chore:`, `docs:`, `feat:` (source: project-init default 2026-10-06)
- base branch: `main`, published at github.com/Nongfsq/ftop; it starts from one commit without the btop history or the design sources (source: `git log`, user-stated 2026-10-06)

## Locations
- intent: docs/intent/ (source: project-init default 2026-10-06)
- research: docs/research/ (source: project-init default 2026-10-06)
- product and design decisions: docs/product/; experience specs: docs/product/experience/ (source: project-init default 2026-10-06)
- architecture blueprint and ADRs: docs/architecture/ (source: project-init default 2026-10-06)
- prototype evidence: docs/prototypes/ (source: project-init default 2026-10-06)
- domain model: docs/domain/ (source: project-init default 2026-10-06)
- plans: docs/plans/ (source: project-init default 2026-10-06)
- validation evidence: docs/evidence/ (source: project-init default 2026-10-06)
- progress: docs/progress/ (source: project-init default 2026-10-06)
- design sources: design/ — local only and git-ignored, never published; the owner keeps the canvas in their Claude account (source: user-stated 2026-10-06, .gitignore)

## Delivery
- license: MIT (source: LICENSE)
- ci: none; do not add GitHub Actions without the owner asking (source: legacy AGENTS.md in the archive, user-stated)
- deploy: `scripts/install.sh` into ~/Applications and ~/.local/bin; releases are a tag `v<version>` with `Ftop-<version>-arm64.zip` attached, ad-hoc signed and not notarized (source: scripts/install.sh, github.com/Nongfsq/ftop/releases)
- homebrew: `brew install --cask nongfsq/tap/ftop`; the cask is `Casks/ftop.rb` in github.com/Nongfsq/homebrew-tap and installs the release archive into /Applications, linking `ftop`. After publishing a release, set `version` and `sha256` there (the archive's SHA-256 is the asset digest GitHub shows) and run `brew style --cask` on it. The cask clears the quarantine mark because the app is not notarized (source: github.com/Nongfsq/homebrew-tap, user-stated 2026-10-08)

## Skill applicability
- frank-deploy, frank-github-actions-ci: not applicable — no CI or hosting (source: Delivery)
- frank-ui-craft, frank-ui-motion, frank-swift-engineering: apply; swiftui-specialist: not applicable — no SwiftUI (source: Package.swift, Sources/FtopUI)

## Boundaries
- `upstream` remote is aristocratos/btop: never push there; `origin` is the owner's Nongfsq/ftop (source: `git remote -v`)
- archive/ holds the retired btop-based code as a local zip and is git-ignored (source: .gitignore)
- pushing, creating a remote, publishing a release need approval (source: AGENTS.md)

## Unknowns
- whether Intel Macs will ever be supported (not today: core grouping and frequency are Apple Silicon only)
