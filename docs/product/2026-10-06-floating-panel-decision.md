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
  first a standard settings window, since replaced by the control block described
  below, with every setting as a control; a change is written to the file and applied at once. The JSON5 file stays
  as the store and for people who prefer a file; macOS has no default app for `.json5`
  (nor for YAML), so the file is opened in TextEdit when nothing claims it.
- Menu bar: the text "CPU 19%" and nothing else. The owner rejected a bar glyph there
  ("I have no use for bars in the menu bar") and found a bare number odd.

## Amendment: GPU, power, and how a module is added (2026-10-07)

Partly replaced the same day by "badges instead of words" below; read that one for how the GPU and power look.

Approved by the owner on the boards "GPU 与功耗 · 各尺寸", "GPU 与功耗 · 菜单与设置", and
"加模块的规则" of the design canvas ("GPU 进面板", "功耗和 GPU 一起做", "用「VRAM」，频率一起显示").
A user had asked for a GPU monitor.

- GPU is a third group of columns after the core columns, in a color of its own, read
  the same way: height is usage, the line is frequency. It is one column because the
  system reports one figure for the whole GPU, not one per GPU core. In the detailed
  layout it has the same two numbers under it as a core.
- Power is the whole machine's, in watts. Parts of it (the GPU's share) are secondary
  and never replace the whole-machine figure.
- A figure is shown only where it cannot be taken for another part's. The first version
  put the watts beside the temperature in the title row, next to the CPU percentage, and
  put "Power 18.6 W" and "GPU 3.1 W" on one row; the owner found it unclear what each
  covered. So power is not in the title row or in any strip, and wherever it appears a
  scope name leads its row.
- Scope rows: every column layout that shows the memory detail has, under the network
  row, one row per scope. The row starts with the scope's name and every figure in it
  belongs to that scope, known by its unit: "GPU 37 % 3.1 W 56°" with "VRAM 1.4 GB" on
  the side column, and "Machine 18.6 W" with "AC 19.9 W" (adapter). These layouts are two
  caption rows taller than before; the owner accepted that for the clarity. Beside two
  process lists the rows take height from the core columns instead.
- By size: the smallest layout and the compact layout show neither. The plain strip
  adds the GPU column to the core columns. The rich strip shows the GPU as a small
  column in front of its percentage. The vertical strip adds a GPU row. The corner adds
  the GPU column. Column layouts add the GPU column and the scope rows.
- Where there are no scope rows, the GPU's power, temperature, and memory are in the
  hover chip of its column.
- "VRAM" is the label for the unified memory the GPU holds (owner's choice); the chip
  has no separate video memory.
- Both are on by default and can be turned off. No admin rights are needed for any of it.
- Menu: the right-click menu has one "Show" entry whose submenu lists the modules; the
  settings window lists the same ones. The menu bar still shows only CPU.

Rules for the next module, so the layouts keep adapting:

1. It uses only the six existing forms: a mark, a figure (one number known by its mark
   or its unit), a column group, a bar, a labeled row, a list (processes only).
2. It goes into one of four places: the column area, the stack (one row per scope: its name, then its figures, one more on
   the side column), the lists (no new list), the strip sequence.
3. It names its form at every size before it is built. One with no small form stays
   out of strips and the corner.
4. It takes room from the column area or the core columns' height before it makes any
   window larger; the one thing that may add height is a scope row. Its figures say
   whose they are: without a scope name beside it, a figure is shown only if it cannot
   be mistaken for another part's.
5. It is on or off, nothing else. Order is fixed: CPU, memory, network, GPU, power,
   later modules, processes.
6. Turning one off is recorded (`hidden` in the settings file), so a module added in a
   later version shows for everyone who has not turned it off.

## Amendment: capsule columns and continuous column motion (2026-10-07)

The owner chose form A on the board "核心图 · 动法与三种形式" and asked for motion that
reads as seamless on a 120 Hz display, with elegance first and its cost looked at afterwards.
This replaces "wide columns are performance cores, slim ones efficiency cores" in rule 4
and "columns ease to each reading" in the first amendment.

- Shape: every core column has the same width; the two kinds differ by color and by the
  gap between the groups. Track and fill are capsules (corner radius half the width, at
  most 8 pt at scale 1). The track is fainter than other tracks. The frequency line is
  1.5 pt, rounded, and stops short of the column's sides. An idle core keeps a 4 pt cap.
- Motion: a new reading moves the column's target at once and adds one animation that
  plays back the difference. Animations that overlap add up, so a column never stops to
  start again. Each one leaves and arrives with no speed and no acceleration, and about
  17% of it is still left when the next reading lands. Columns start 18 ms apart from
  left to right. The column ends on the reading itself; the value is not smoothed.
- Cost accepted by the owner for now: a column reaches a reading about 0.65 s late on
  average, and while readings change the render server is animating all the time.
  The 2026-10-06 measurements that led to the short ease still stand and were not
  repeated for this motion.
- Reduced motion and Low Power Mode: columns jump to the reading, as before.
- Not chosen: dots (no frequency) and a ribbon across the cores (implies transitions
  between neighbouring cores that do not exist).

## Amendment: badges instead of words, and the GPU out of the column area (2026-10-07)

Approved by the owner on the boards "B 方向 · 各尺寸与柱子重画" and "图标 · 系统图标对照"
("选 B 方向", "按你的建议来，开始实现"), after rejecting labels above or beside figures,
text scope rows ("谁会想看一堆文字"), and badges of different sizes in one row or block.
This replaces, in the GPU and power amendment above: the GPU as a third column group,
the scope rows written as text, the "By size" list, and rules 1, 2, and 4 for the next
module where they speak of a column group or a scope name.

- Every figure is led by a badge: a 20 pt circle with a 10 pt glyph. It is that size at
  every window size and in every row; only the type beside it changes. No figure has a
  word before it. Names are in the hover chip.
- One silhouette: every badge is the same soft disc, and every glyph's longer side is
  10.5 pt. A gauge adds an arc around the disc's edge, and the arc is the value:
  processor, GPU, memory (arc is the share used, color is the pressure). Temperature,
  watts, adapter, GPU memory, download, and upload have no arc.
- One type size in a row (owner, on the board: the processor's figure, text, and badge
  must not differ from the two beside it). The title row's processor, GPU, and chip
  temperature are all in the emphasis size, the same as the memory figure; the
  processor no longer has a larger number of its own. The owner confirmed it: the
  core columns already show the processor, so it needs no largest figure. In column layouts the temperature
  starts on the side column, so the title row is a pair like the rows below.
- Corner (owner, on the board): download, upload, and the whole machine's watts sit
  under processor, GPU, and temperature on the same three columns, so nothing is left
  empty on the right. This is the one place power appears outside the pairs; it is the
  machine's, with the laptop glyph. The vertical strip has its columns on top and the
  figures as one list under them.
- Whose the temperature is (owner, on the board: settle what it measures before
  aligning it). On the M4 Pro it comes from sensors across the whole chip, which the
  GPU shares, so it is not the processor's. Where the machine's pair is shown, that
  pair is watts and chip temperature, the same shape as the GPU's pair above it, with a
  plain badge; the title row is the processor alone, and what the adapter delivers is
  in the hover. Where there is no machine pair (power off, compact, corner, strips) the
  temperature keeps its place with a plain badge. On a chip that reports sensors on the
  processor's own clusters, the badge takes the processor's color and sits right after
  the processor's figure. That case is built but was not seen on real hardware.
- One temperature on the panel (owner: two temperatures a few degrees apart made no
  sense). The GPU's own temperature and its watts are in the GPU's hover; the GPU has
  one pair, usage and memory. This replaces "the GPU is two pairs" and the GPU-colored
  watts and temperature badges above.
- The network pair and the GPU and machine pairs are one grid: the same distance
  between all of its rows, and the block gap only above and below it.
- Color says whose a figure is: the GPU's three discs (memory, watts, temperature) are
  in the GPU's color, the machine's two are neutral.
- The column area is the cores and nothing else. The GPU is a ring: at the head of its
  own row where it has one, in the title row where it does not.
- Rows are pairs: one figure on the left edge, one on the side column, so the badges
  form two vertical lines that match the two ends of the memory and swap bars. Network
  is one pair. The GPU is two pairs (usage and memory; watts and temperature). The
  machine is one pair (whole machine and adapter; see the temperature rule below).
- Glyphs: system symbols for the arrows, the bolt, the plug, the laptop, and the GPU's
  stack; the chip, the memory module, and the thermometer are drawn in the app, because
  the system's close up at this size.
- By size: the smallest layout is three rings and no numbers. The plain strip is the
  mini columns, processor, memory, and the two rates. The rich strip adds temperature,
  the GPU, and the busiest process. The vertical strip is one figure a row. The corner
  and the compact layout carry the GPU ring in the title row. Column layouts with the
  memory detail have the pairs under the network row.
- Ring arcs follow readings the way the columns do (see the motion amendment below).
- Cost the owner accepted: the layouts are larger than before. The plain strip is about
  390 pt wide instead of 270, the vertical strip 86 instead of 60, the corner about
  255 by 125, and the standard panel three badge rows taller. A window smaller than a
  layout falls to the next smaller one, as before.
- Still text: the pressure word, and "Compressed" and "Swap" under the memory bar.
- The menu and the settings are one surface (board "菜单与设置 · 重新设计", built
  2026-10-07 on the owner's go-ahead, not yet seen by the owner on screen). A right-click
  on the panel or on the menu bar number brings up one block of round switches
  (`Sources/FtopUI/ControlPanel.swift`): the five optional modules; on top, menu bar,
  smooth motion, hide, quit; the three palettes; and "More", which opens in place the
  settings that have a value (interval, process rows, language, updates) and the settings
  file. A value is picked from a system menu. The right-click menu and the settings
  window are gone. A switch gives under the press; turning on, color spreads from its
  center and settles after passing full size once; turning off, it draws back without
  that. The ring around the chosen palette slides to the new one. With Reduce Motion
  on, only colors fade. A module that is on but that this machine gives no reading for
  is shown dimmed.

Rules for the next module, replacing 1, 2, and 4 above:

1. Its figures use a badge of the one size: a ring if the figure is a share of
   something, a disc if not. It brings a glyph that stays clear at 10 pt.
2. It goes into the stack as pairs, into the strip sequence as a figure, or into the
   title row as a ring. The column area is not available.
4. Its badges take the color of the part they belong to, or stay neutral for the whole
   machine. It takes height as whole pairs.

## The process list (2026-10-08, approved and built)

Approved by the owner on the board "进程列表 · 图标、悬停与点击" ("这样是好的", "就这样",
"走推荐路线就行了"). This replaces the two process lists side by side and the three-column
rows (name, processor, memory) in the layout rules above.

- A row is the app's icon in the same badge every figure has, the name, and the one
  figure the list is ranked by. The arc around the badge is the entry's share of what
  is in use right now. A process outside any app has a gear.
- Helper processes are folded into their app, under the app's name and icon, with
  their figures summed.
- The large window has one list. Two badges above it, processor and memory, choose
  what it is ranked by, the color of the arcs, and the figure. The extra width
  continues the ranking in a second column. Smaller layouts rank by processor and have
  no switch. The choice is kept as `processSort` in the settings file.
- The pointer on a row lights it and lets the others recede. No chip: the detail is in
  the card (owner: a chip over a process row or over the rates is not needed).
- A hover chip appears only where it says something the panel does not. Download and
  upload have none.
- A click brings up a floating card, a window of its own, so the panel keeps its size:
  icon, name, processor and memory behind the panel's own badges, and the heaviest
  folded processes. It has no buttons. It goes away on a second click, a click
  elsewhere, another app coming forward, Escape, a drag of the panel, or when its row
  leaves the list.
- Motion: a pressed row shrinks to 97% under a full highlight and springs back; the
  card grows out of its row on the same spring and leaves in a tenth of a second; a row
  whose rank changed slides to its place, an arriving row fades in; arcs follow readings
  like the columns. With motion off none of this moves.
- Rejected by the owner: a row that expands in place on a click, and a magnifier button.
- While a card is open nothing else speaks: no hover chip, and no other row lights up
  (owner: the chip appeared over the card).
- A list too short to fill both columns of the large window is split evenly between
  them instead of leaving one full column and a stub.
- Limits. The helper reports the 96 busiest processes and the 96 holding the most
  memory (32 until protocol 4; a helper granted before that needs `sudo ftop grant`
  again, and until then a large window's list can run short), so an app's sum covers its processes within those and can be a little low.
  The other figure in the hover and on the card comes from the other ranking when the
  app is in it. Ranks are not held steady when two entries are close; the board
  proposed that and it is not built.
- Measured on the M4 Pro without admin rights: of 2271 processes 4 had no readable
  path; 29 of the 30 holding the most memory sit inside an app bundle, helpers
  included. Faderly's `AppIcons.swift` was the model: ask the system for the app's
  icon, cache it, trim its transparent margin.


### A list that rests (2026-10-07, built, awaiting the owner's look)

The owner's report: readings of busy processes cross every second, so the list re-sorted
every second, and in the wide two-column list rows flew from one column to the other.
Each move was fine; all of them together looked hurried.

- The list is ranked by a level, not by the current reading. The level rises with the
  reading at once and falls slowly (about four seconds), so a process that becomes busy
  takes its place immediately and does not drop out after one quiet second.
- An entry passes another only when it is clearly ahead: by 12% plus one point for
  processor use, by 4% plus 24 MB for memory. Two rows shown out of order therefore
  differ by less than that. The figures on the rows stay the current readings.
- How a row moves depends on how far it goes. Trading places with its neighbor, it
  slides past it (a spring that settles in about a third of a second and does not pass
  its place). Going two rows or more, or to the other column, it would cross the rows
  between, so it turns over where it stands: what it showed rises 6 pt and fades in
  140 ms, then it comes in at its new place from 6 pt below in 220 ms. A row new to the
  list fades in (220 ms), one dropping out fades away (160 ms), neither travels.
- All moves of one sample start together, and all are over within 400 ms, so the list
  is still for most of every second. Figures change without animation. With the
  system's Reduce Motion on, every move is a fade in place.
- Considered and not built: a three-dimensional flip of each row (the owner's
  split-flap idea). It says "this slot changed", not "this row went there", and at a
  row height of 20 pt the perspective does not read; the turn in place above keeps its
  rhythm without the perspective.
- While the pointer is on a row the order is held, so a click lands on the row it was
  aimed at. Figures and arcs keep updating.

The rule is `SteadyRanking` in `Sources/FtopCore/ProcessRanking.swift`.

## Amendment: one group per kind of core (2026-10-08)

A user's M6 has three kinds of core (super, performance, efficiency; issue 8) and the
panel had two groups. The owner asked for any number ("可以写成 N 组 … 能自适应，这个很重要")
and accepted the color rule. This extends "the two kinds differ by color and by the gap
between the groups".

- A chip has as many groups as it has kinds of core, fastest first, with the same gap
  between each. Nothing names a chip or a count. Chips with two kinds are unchanged.
- Colors run in even steps from the palette's performance color to its efficiency
  color: three groups put the middle one halfway, four at thirds. No palette gained a
  hand-picked color.
- Seen by the owner only as reference images of three groups; four groups and the real
  panel on such a chip have not been seen.

## Full-screen spaces (2026-10-08, built, confirmed by the owner on the real panel)

The owner's report: the panel, unpinned and covered by other windows, appeared on top of
a full-screen video in Chrome. It had been allowed into every app's full-screen space
whether pinned or not, and in that space nothing else covers it.

- Unpinned, the panel is an ordinary window: other windows cover it, it does not enter
  another app's full-screen space, and it lives on one desktop. A click on the menu bar
  number brings it to the desktop in view.
- Why one desktop: a first build kept it on every desktop and only withdrew the
  full-screen permission; the owner still saw it over the video. A panel that follows
  every desktop follows into full-screen ones too.
- Pinned, it is on top everywhere, full-screen spaces included (owner: "置顶时出现"), so
  it can be watched beside a full-screen game or render. One click on the pin removes it.
- No new switch. The right-click block still opens over a full-screen app from the menu
  bar number.
- Not chosen: keeping the panel out of full screen even when pinned; in full screen the
  menu bar is tucked away too, so nothing of ftop would be in view.

## The menu bar item: one reading, a glyph and its number (2026-10-08, approved and built)

Approved by the owner on the boards "菜单栏显示哪一项" ("我可以选 A") and "菜单栏 · 图标与数字"
("画法一挺好的"), with two corrections: no Chinese in the menu bar, and the network as one
direction only so the item stays short. This replaces "Menu bar: the text "CPU 19%" and
nothing else" and "The menu bar still shows only CPU" above.

- The menu bar shows one reading, chosen by the user: processor, memory, GPU, download,
  upload, or whole-machine power. Processes are not offered. The default is the
  processor. It is `menuBarShows` in the settings file.
- The choice is one row under "More" in the control block, picked from a system menu.
  The closed block is unchanged. The row is dimmed and inert while the menu bar item is
  off. Not chosen: a row of five discs in the block (the same glyphs twice, one row for
  the panel and one for the menu bar, with nothing to tell them apart).
- The item is the reading's glyph and its number, no word: the glyph is the name, so
  there is no language in it. The glyphs are the panel's, in one color that follows the
  menu bar. The unit is smaller and lighter than the number, as in the panel.
- Not chosen: the number inside the glyph (7 pt digits, and "100" does not fit), a
  translucent number over the glyph, the panel's ring badge (its glyph is 8 pt there),
  a ring with no number.
- Alignment (owner: "this is very important"). The item is drawn as one picture,
  `Sources/FtopUI/MenuBarPicture.swift`, not laid out by the button. The glyph's middle
  and the middle of the digits' height are the same line. The figure starts a fixed
  distance after the glyph's ink, not after its box, so a narrow arrow and the wide chip
  are spaced alike. The glyph sits on whole pixels.
- Width (owner, on the first build: "a large empty area on the right; what about two
  digits?"). The first build kept room for the widest figure, "100%", so every two-digit
  figure left a hole. Now the item is as wide as its figure. It grows at once when a
  wider figure comes and narrows only after no figure that wide has come for a minute,
  so the items beside it move rarely. Inside that room the glyph and the number are one
  group in the middle, so what a shorter figure leaves is the same on both sides and at
  most half a digit a side in the usual case. Rates and watts have one decimal below
  100 and none above, so no figure has more than four characters.
- The reading does not have to be one the panel shows. A reading the machine does not
  give is a dash.

## Rejected by the owner (do not reintroduce)

- A processor figure larger than the figures beside it (2026-10-08): the core columns
  already carry it.
- Divider lines between modules.
- Thin strips: bars under the network numbers, hairlines under process names.
- A network row that mirrors the memory capsule (it read as "capsule = download,
  capsule = upload").
- Spreading download and upload to opposite edges with bold enlarged numbers.

## Open

- Whether the frequency line across each core column stays; the owner was asked and
  answered "leave it as is", so it stays for now.
- The GPU's frequency is now only in its hover chip; the owner had asked for it to be
  shown ("频率一起显示") when the GPU was a column with a frequency line. Whether it gets
  a place in the new layout is open.
- Further optional modules (process icons, finer memory breakdown, battery). GPU and
  power are decided above.
- A module that is off and that this machine could not read is not dimmed in the
  control block: nothing is sampled for a module that is off, so it is not known.

## Evidence and limits

- The interactive trial in design/trial/ was checked in a browser at standard,
  full-stage, wide-strip, and tall-strip sizes. It is an HTML mockup with sample
  data; it proves the layout rules, not native rendering or real sensor readings.
- The canvas boards in design/canvas/ were never rendered by the author; only the
  owner viewed them. Their wide, corner, and strip panels predate rule 5.
