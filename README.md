<p align="center"><img src="docs/media/icon.png" width="112" alt="ftop icon: a snowy owl with its eyes closed"></p>
<h1 align="center">ftop</h1>
<p align="center">A small, quiet system monitor for Apple Silicon Macs.<br>One floating glass panel that works at any size.</p>
<p align="center"><a href="README.zh-CN.md">中文说明</a></p>

![The same panel at six sizes](docs/media/sizes.png)

## What it is for

ftop replaces the terminal monitor you keep open in a spare tab (btop, htop) with a
native window you can leave anywhere on the desktop. It is made for the moments when
the machine is working hard — a local model running, an agent compiling, a long
build — and you want to see at a glance what the cores, memory, and network are doing
and which process is responsible.

- **Every core, separately.** Performance and efficiency cores are drawn as two groups
  of columns. Each column shows usage; a tick shows that core's current frequency.
- **Chip temperature**, labeled with the sensor level it really comes from.
- **Memory**: used, total, compressed, swap, and the system's own pressure level.
- **Network**: current download and upload speed.
- **Processes**: the busiest by CPU, and in large windows a second list by memory.
- **Any window size.** Drag any edge. ftop picks the layout that fits and snaps the
  window to it, so nothing is ever clipped and no space is left empty.
- **Nearly free when you are not looking.** Hidden or fully covered, it stops reading
  everything except the one number shown in the menu bar.

It shows the current state only: no history graphs, no disk panels.

## One panel, every size

A small window keeps the essentials; a large window shows more, not bigger type —
per-core numbers, up to 24 process rows, and a second list sorted by memory.

![A large window](docs/media/large.png)

These pictures are produced by ftop's own drawing code with sample readings
(`scripts/readme-media.sh`), placed on a stand-in wallpaper. The real window uses the
macOS glass material, so its background follows whatever is behind it.

## Cost

Measured with `scripts/perf.sh` on a 14-core Apple Silicon Mac, updating once a second:

| State | CPU | Memory |
| --- | --- | --- |
| Small panel (300 × 420) | about 1.0% of one core | 22–38 MB |
| Large panel (about 1050 × 500) | 1.2–1.5% | same range |
| Hidden or fully covered | 0.0–0.1% | same range |

## Install

Requirements: an Apple Silicon Mac with macOS 15 or later.

**From a release.** Download `Ftop-<version>-arm64.zip` from the
[releases page](https://github.com/Nongfsq/ftop/releases/latest), unpack it, and move
`Ftop.app` to `~/Applications`. Then link the command into a directory on your `PATH`:

```bash
mkdir -p ~/.local/bin && ln -sfn ~/Applications/Ftop.app/Contents/MacOS/ftop ~/.local/bin/ftop
```

The app is signed for local use only and is not notarized by Apple, so macOS blocks a
copy downloaded with a browser. Clear the download mark once:

```bash
xattr -dr com.apple.quarantine ~/Applications/Ftop.app
```

**From source.** Needs Xcode (built and tested with Xcode 27).

```bash
git clone https://github.com/Nongfsq/ftop.git
```

```bash
cd ftop && scripts/bundle.sh && scripts/install.sh
```

This puts `Ftop.app` in `~/Applications` and links `ftop` into `~/.local/bin`.

## Use

```bash
ftop            # open the panel
ftop toggle     # hide or show it
ftop quit       # close it
ftop doctor     # which readings are available on this Mac, and why not
```

- Drag the panel to move it; drag an edge to resize it.
- Move the pointer to the top edge for two buttons: pin (keep on top) and hide.
- The menu bar shows `CPU 19%`. Click it to show or hide the panel.
- Hover over a core, the memory bar, or a process for detail.
- Right-click the panel or the menu bar item for colors and **Settings…**.

<img src="docs/media/settings.png" width="290" alt="The settings window">

Settings are also a plain text file, `~/.config/ftop/config.json5` (JSON with
comments). The window and the file stay in step, and a saved change applies at once.

### System processes

Without extra rights macOS only lets ftop see your own processes. To include system
ones such as `WindowServer`, grant access once:

```bash
sudo ftop grant
```

This marks one small helper inside the app as setuid root. The helper takes no
arguments, reads no environment, writes no files, and only prints the process table;
its source is `Sources/ftop-helper/main.swift`.

## Limits

- Apple Silicon only. Core grouping and per-core frequency rely on it.
- Per-core frequency and temperature come from private macOS interfaces (IOReport and
  the HID sensor services). They can change with a macOS update; a reading that is not
  available is shown as unavailable, never as zero. For the same reason ftop cannot be
  distributed through the Mac App Store.
- The interface is in English and Chinese.

## Develop

`scripts/check.sh` is the gate: formatting, a warning-free build, and the tests.
Product decisions are in [docs/product/](docs/product/), the architecture in
[docs/architecture/](docs/architecture/), and the rules for coding agents in
[AGENTS.md](AGENTS.md).

ftop began as a fork of [btop](https://github.com/aristocratos/btop) and was then
rewritten from scratch; it shares no code with it.

## License

[MIT](LICENSE)
