"""Summarises game-4k120-samples.csv from the exact GPUPH residency of each state.

Usage: python3 game-4k120-summary.py game-4k120-samples.csv [play-from play-to [loading-from]]

Segments: baseline before the start cue (15 s); loading from `loading-from` (default 16 s)
to `play-from`;
play from `play-from` to `play-to` seconds (default: the longest run above 3 W).

Per row: busy share, busy-weighted MHz, the driver's Device %, the clock-weighted
usage (ftop's new figure: sum of residency x f over total time over 1620 MHz), V^2*f
(sum of residency x V^2 x f over total time over 1075 mV^2 x 1620 MHz), and GPU watts
as a share of 84 W full load. A value that was not read is left out, never taken as 0.
"""

import csv
import statistics
import sys

MHZ = [338, 486, 636, 796, 888, 988, 1084, 1182, 1278, 1374, 1470, 1578, 1620]  # P1..P13
MV = [645, 655, 675, 730, 740, 780, 805, 830, 880, 905, 960, 1040, 1075]
TOP_MHZ, TOP_MV, FULL_W = 1620, 1075, 84.0
PREFIX = "GPU_Performance_States:GPUPH:"


def number(text):
    return float(text) if text not in ("", None) else None


def rows(path):
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            states = {k[len(PREFIX):]: float(v) for k, v in r.items() if k.startswith(PREFIX) and v != ""}
            p = [states.get(f"P{i + 1}", 0.0) for i in range(len(MHZ))]
            past_table = sum(v for k, v in states.items() if k.startswith("P") and int(k[1:]) > len(MHZ))
            total = sum(states.values())
            busy = sum(p) + past_table
            row = {"t": float(r["t"]), "p": p, "total": total, "uncovered": past_table}
            row["busy"] = 100 * busy / total if total > 0 else None
            known = total > 0 and past_table == 0
            row["mhz"] = sum(x * f for x, f in zip(p, MHZ)) / sum(p) if known and sum(p) > 0 else None
            row["clock"] = 100 * sum(x * f for x, f in zip(p, MHZ)) / total / TOP_MHZ if known else None
            row["v2f"] = 100 * sum(x * v * v * f for x, v, f in zip(p, MV, MHZ)) / total / (TOP_MV**2 * TOP_MHZ) if known else None
            watts = number(r["gpu_w"])
            row["watts"] = watts
            row["power"] = 100 * watts / FULL_W if watts is not None else None
            row["driver"] = number(r["driver_device_pct"])
            yield row


def longest_run(data, test):
    best, current = [], []
    for r in data:
        if test(r):
            current.append(r)
            if len(current) > len(best):
                best = current
        else:
            current = []
    return best


def stats(values):
    v = [x for x in values if x is not None]
    if not v:
        return "unavailable"
    return f"{statistics.mean(v):6.1f} {statistics.median(v):6.1f} {min(v):6.1f} {max(v):6.1f}  (n={len(v)})"


def ratio(a, b):
    """Ratio of the means, as text; unavailable when either side was not read."""
    a = [x for x in a if x is not None]
    b = [x for x in b if x is not None]
    return f"{statistics.mean(a) / statistics.mean(b):.2f}x" if a and b and statistics.mean(b) > 0 else "unavailable"


def main(path, play_from=None, play_to=None, loading_from=16):
    data = list(rows(path))
    if play_from is not None:
        game = [r for r in data if play_from <= r["t"] <= play_to]
    else:
        game = longest_run(data, lambda r: r["watts"] is not None and r["watts"] > 3)
    baseline = [r for r in data if r["t"] < 14]
    loading = [r for r in data if loading_from <= r["t"] < game[0]["t"]] if game else []
    print(f"rows {len(data)}; baseline t < 14 s ({len(baseline)} rows); loading {loading_from:.0f} s to play ({len(loading)} rows); "
          f"play t {game[0]['t']:.0f}-{game[-1]['t']:.0f} s ({len(game)} rows)" if game else "no game segment")
    for name, part in (("baseline", baseline), ("loading", loading), ("game", game)):
        print(f"\n== {name}: mean median min max")
        for key, label in (("busy", "busy %"), ("mhz", "MHz while busy"), ("driver", "driver Device %"),
                           ("clock", "clock-weighted % (ftop)"), ("v2f", "V^2*f %"), ("power", "power share % of 84 W"),
                           ("watts", "GPU W")):
            print(f"{label:26} {stats([r[key] for r in part])}")
        print(f"{'clock-weighted / power':26} {ratio([r['clock'] for r in part], [r['power'] for r in part])}")
        print(f"{'V^2*f / power':26} {ratio([r['v2f'] for r in part], [r['power'] for r in part])}")
        print(f"{'driver / power':26} {ratio([r['driver'] for r in part], [r['power'] for r in part])}")
        uncovered = sum(r["uncovered"] for r in part)
        if uncovered:
            print(f"time in states past the table: {uncovered:.0f} (rows left out of MHz, clock and V^2*f)")
    if game:
        busy_time = sum(sum(r["p"]) for r in game)
        print("\n== game: share of busy time in each GPUPH state")
        for i, f in enumerate(MHZ):
            share = 100 * sum(r["p"][i] for r in game) / busy_time if busy_time else 0
            if share >= 0.05:
                print(f"P{i + 1:<3} {f:5} MHz {MV[i]:5} mV  {share:5.1f} %")


if __name__ == "__main__":
    main(sys.argv[1], *(float(x) for x in sys.argv[2:5]))
