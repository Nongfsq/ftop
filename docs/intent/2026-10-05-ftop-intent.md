# ftop intent

Source: the owner's request on 2026-10-05 and clarifications through 2026-10-06.
Confirmed by the owner in conversation; requirement IDs are stable.

## What ftop is

A Mac status monitor that is small, good-looking, and readable at a glance. The
first attempt modified btop; the owner was unhappy with it: no sense of design (no
mockups existed), it broke in small windows, and btop could not be customized or
trimmed the way they wanted. htop was rejected earlier for lacking elegance.
Technology and form were left open, including a native macOS app, provided the
result is refined, easy to use, and beautiful.

## Requirements

| ID | Requirement |
| --- | --- |
| R1 | Small and beautiful: fits a desktop corner, comfortable colors, understood at a glance, elegant and refined. |
| R2 | Works at any window size, freely resizable from tiny to large. The owner called this "the point". |
| R3 | No history graphs: current state only. |
| R4 | Cores are grouped into performance and efficiency cores, each core showing usage and frequency. |
| R5 | Temperature states which sensor level it was read from. |
| R6 | Memory shows used, total, pressure, compressed, and swap. |
| R7 | No disk information: no capacity, no partitions. |
| R8 | Network shows only upload and download speed. |
| R9 | Processes: only the top consumers, with name, CPU, and memory. Three by default; more when the window is large (agreed 2026-10-06). |
| R10 | Typing `ftop` in iTerm2 starts it. |
| R11 | Modules are highly customizable. |
| R12 | Minimal text in the interface. |
| R13 | Type size, color, motion, effects, and alignment are each deliberately designed. |
| R14 | Follows the macOS light and dark appearance. |

## Open

- Which further optional modules a large window may add (process icons, finer memory
  breakdown, battery). GPU and power were chosen on 2026-10-07; see the decision
  document's amendment.
