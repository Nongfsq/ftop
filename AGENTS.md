# ftop agent contract

## Purpose and precedence
- ftop is a small macOS status monitor shown as a native floating panel that works
  at any window size. The user's current request comes first, then this file, then
  the documents it points to.

## Authority
- Inspect, review, and plan requests are read-only. Change requests authorize
  scoped local edits and non-destructive validation.
- Pushing, publishing, deploying, deleting, rewriting history, and writing to
  external systems need explicit approval.
- Never push to the `upstream` remote; it is the btop project this repository was
  forked from and ftop no longer shares code with it.

## Product invariants
- The panel must stay usable at every window size: content degrades by priority and
  is never clipped. The window snaps to the layout it shows, so no size leaves empty
  space. A layout change is not done until the reference images are regenerated and
  looked at, and the real panel has been dragged through small, thin, and large sizes.
- Show current state only: no history graphs, no disk panels.
- Keep text minimal; shape and position carry meaning, detail appears on hover. Do
  not add divider lines or thin decorative strips between or under elements.
- A value the hardware does not report is shown as unavailable, never as zero.
  Temperature is labeled with the sensor level it actually comes from.

## Code boundaries
- Only `FtopSensors` and `CFtopSys` touch system APIs; private symbols are declared only
  in `Sources/CFtopSys`. `FtopUI` never imports `FtopSensors`.
- Colors, type sizes, and spacing are written only in `Sources/FtopUI/Theme.swift`.
- The panel is not SwiftUI. It is drawn from a `Scene` (plain geometry) by
  `PanelCanvasView`; per-sample animation is Core Animation layers only. Do not add
  views that lay out or redraw between samples. Measure with `scripts/perf.sh`.
- A layout's size must not depend on the readings: position text from the widest
  value a field can show, never from the current one.
- `Sources/ftop-helper` may be installed setuid root. Keep it free of arguments,
  environment reads, and file writes.

## Workflow and artifacts
- Project profile: docs/agents/project-profile.md — read before choosing commands,
  artifact locations, or terminology; skipping it reintroduces defaults that do not
  fit this project.
- Decisions, specs, and plans live at the locations the profile lists; update them
  instead of keeping decisions only in conversation.
- Before changing how the panel looks or adapts, read
  docs/product/2026-10-06-floating-panel-decision.md; it owns the approved layout
  rules, and skipping it repeats options the owner already rejected.

## Issues and pull requests from outside
- CONTRIBUTING.md holds the rules; apply them the same way every time. Pull requests
  are limited to collaborators in the repository settings; do not reopen that or merge
  outside code without the owner asking.
- Advertisements, invitations, and anything not about ftop: close as not planned and
  lock as spam, then tell the owner, who deletes the issue and blocks the account.
- Homebrew and other third-party packaging are declined; the README links only to
  installs this project maintains.
- A real report (a reading wrong or missing, with `ftop doctor` output) is answered,
  even when the form was skipped: ask for what is missing instead of closing it.
- Replies, closures, and anything posted under the owner's account still need the
  owner's approval unless this section says otherwise.

## Validation
- Run the profile's validation baseline before reporting a change complete, and
  report checks that were not run.

## Maintenance
- Keep this file for durable rules. Status goes to the progress location in the
  profile; a recurring failure becomes the smallest durable rule here.
