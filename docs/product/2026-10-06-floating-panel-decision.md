# Decision: native floating panel, glass style

Status: approved by the owner on 2026-10-06 ("就这样吧 … 设计稿就这边结束了").
Requirement IDs refer to docs/intent/2026-10-05-ftop-intent.md.

## Decision

ftop is a native macOS floating panel, not a terminal UI. The `ftop` command opens
it (R10). The btop fork is retired.

## Why not the alternatives

| Option | Rejected because |
| --- | --- |
| Keep modifying btop | Fixed box layout with hard minimum sizes; graphs are embedded in every box; trimming fights upstream code (R2, R11). |
| New terminal UI | Character grid caps refinement: no type scale, no pixel spacing, colors depend on the terminal theme; a terminal window cannot float in a corner (R1, R13). |
| Menu bar app | Not a corner panel; crowded category. |
| WidgetKit desktop widget | The system limits refresh rate; not real time. |
| Tauri / Electron | A monitor should not itself be a top resource consumer. |

## Visual direction

- Direction A "glass" is the product look: translucent panel, rounded system
  typeface, light and dark following the system (R14).
- Palettes: "sea" (blue performance cores, teal efficiency cores) is the default;
  "graphite" and "warm" are selectable.
- Direction C "line" (white, black bars) is kept to become a theme later.
- Direction B "instrument" (dark, amber segments) was not chosen; the owner said it
  looked like a music player.

## Layout rules the owner approved

1. Any size works (R2). The panel picks the richest layout that fits completely and
   never clips. Ladder, richest first: per-core columns with numbers → per-core
   columns → fewer processes → no processes → one-line strip → CPU percent and
   memory-pressure dot. Wide windows use two or three columns.
2. Thin windows are not reduced to a single number: a wide thin window shows a
   strip (cores, CPU, temperature, memory, network, top process); a tall thin
   window stacks the same items vertically. Text may shrink to about 76% before a
   layout gives up content.
3. Large windows add processes (3 → 5 → 7 → 9 → 12) and network sits directly
   under memory. CPU columns keep a minimum height before process rows are added.
4. Encoding: column height is a core's usage, the line across it is its frequency;
   wide columns are performance cores, slim ones efficiency cores. Memory bar: solid
   is app memory, lighter is compressed, the separate capsule on the right is swap.
5. One vertical split: a fixed-width side column on the right holds the swap
   capsule, the "swap" label, upload, and the process number columns; download and
   "compressed" start at the left edge.
6. Units are smaller and lighter than their numbers. Numbers use tabular figures.
7. Detail on hover: pointing at a core, memory segment, or process shows its exact
   values in a small chip; other cores dim.
8. Motion: columns move continuously; only the large numbers roll digit by digit;
   a layout change cross-fades briefly; dragging lifts the panel slightly. All of
   it is off under reduced motion.
9. The window can be moved, resized from any edge, and snaps to screen margins; it
   remembers size and position.

## Amendments after the owner used the first build (2026-10-06)

The owner dragged the first build through sizes and reported: content cut off in a
tall narrow window, numbers not under their columns, a hole under the network row and
under the process list in large windows, and a panel that had nowhere to live because
it was always on top. The owner asked for alignment at every size and proposed snapping
to set proportions instead of fully free sizes. These replace rules 1, 3, 8, and 9.

- The window snaps to its layout. While an edge is dragged the panel shows the layout
  that size would get; on release the window springs to exactly fit it. No size leaves
  empty space or clips, because the window is never a size the content was not made for.
- A layout may grow a limited amount where growing keeps it well proportioned: core
  columns taller and wider, the name column wider. Only the excess beyond that snaps.
- The layout for a dragged size is the one that covers most of it; among layouts that
  cover at least 90% as much, the one with more content wins.
- Columns: one column; or two (core columns | memory, network, processes); or three
  (core columns | memory, network | processes) only with five process rows, where the
  middle column is as tall as the list beside it. The core columns take the full
  height of the columns beside them.
- A layout's size depends only on the machine, the settings, and the scale. Positions
  come from the widest text a field can show, so nothing moves as numbers change.
- Pin: unpinned by default, so other windows can cover the panel; a pin button keeps it
  on top. Hide: a button sends it away; the number in the menu bar brings it back.
  Both buttons appear while the pointer is along the panel's top edge, and both are in
  the right-click menu.
- Menu bar: the total CPU percentage, always visible; click shows or hides the panel,
  right-click opens the menu. Can be turned off (`menuBar: false`).
- First launch shows core columns, memory, network, and the three busiest processes.
- Motion: columns ease to each reading; a layout change cross-fades; the snap overshoots
  slightly. Digits no longer roll (cost; see the blueprint amendments).
- The hover chip is its own small window, so the panel's edge cannot cut it off.
- Not done: full screen (a monitor filling the screen was judged not useful; the
  largest layout is twice the natural size), and a desktop widget (the system refreshes
  widgets on the order of minutes).

- Later the same day, agreed with the owner: a large window gets more content, not
  larger type. Type stops growing at 1.3 times its natural size (was 2). Beyond that
  the process list grows to 16 and 24 rows, and from 7 rows a second list appears
  beside it: the same processes ordered by memory. The two lists have the same columns;
  the figure a list is ordered by is the strong one, which is the only cue (no
  headers). They share every row line and end on the same row.

- With two lists the layout is three level columns: core columns with memory and
  network under them; processes by CPU; processes by memory. Both lists have the same
  number of rows.
- Logo (approved by the owner, 2026-10-06): a snowy owl with its eyes closed under a
  night sky, design `A2` on the board "标志 · 菜单栏" of the design canvas. Three colors:
  ink blue, warm white, a little amber. Drawn by `Sources/FtopUI/Logo.swift`. The owner
  rejected, in order: the core-columns mark, letter marks ("letters are unnecessary"),
  and bare geometric animals with staring eyes ("ugly, minimal to the point of creepy").
- Settings (owner, 2026-10-06: "this version must give the user a window to edit in"):
  a standard settings window (`Sources/FtopUI/SettingsWindow.swift`) with every setting
  as a control; a change is written to the file and applied at once. The JSON5 file stays
  as the store and for people who prefer a file; macOS has no default app for `.json5`
  (nor for YAML), so the file is opened in TextEdit when nothing claims it.
- Menu bar: the text "CPU 19%" and nothing else. The owner rejected a bar glyph there
  ("I have no use for bars in the menu bar") and found a bare number odd.

## Rejected by the owner (do not reintroduce)

- Divider lines between modules.
- Thin strips: bars under the network numbers, hairlines under process names.
- A network row that mirrors the memory capsule (it read as "capsule = download,
  capsule = upload").
- Spreading download and upload to opposite edges with bold enlarged numbers.

## Open

- Whether the frequency line across each core column stays; the owner was asked and
  answered "leave it as is", so it stays for now.
- Optional modules for large windows (see intent, Open).

## Evidence and limits

- The interactive trial in design/trial/ was checked in a browser at standard,
  full-stage, wide-strip, and tall-strip sizes. It is an HTML mockup with sample
  data; it proves the layout rules, not native rendering or real sensor readings.
- The canvas boards in design/canvas/ were never rendered by the author; only the
  owner viewed them. Their wide, corner, and strip panels predate rule 5.
