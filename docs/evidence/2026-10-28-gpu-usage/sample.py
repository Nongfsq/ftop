"""Log the released ftop's GPU reading next to the GPU's own residency counters.

Runs until stopped; appends one row every INTERVAL seconds to samples.csv beside this file.
Only the installed release is called, never a development build.
"""

import csv
import datetime
import json
import os
import re
import subprocess
import time

FTOP = os.path.expanduser("~/Applications/Ftop.app/Contents/MacOS/ftop")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples.csv")
INTERVAL = 30
# GPU clock for P1..P13, from `ftop doctor --states` on this Mac (sgx perf-states).
MHZ = [338, 486, 636, 796, 888, 988, 1084, 1182, 1278, 1374, 1470, 1578, 1620]
FIELDS = [
    "time", "driver_device_pct", "driver_renderer_pct", "driver_tiler_pct",
    "hw_active_pct", "hw_active_mhz", "clock_weighted_pct",
    "ftop_usage_pct", "ftop_mhz", "gpu_watts", "system_watts",
    "user_idle_s", "front_app",
]


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=20).stdout


def driver():
    text = run("ioreg", "-r", "-d1", "-c", "IOAccelerator", "-w0")
    get = lambda key: (re.search(r'"%s Utilization %%"=(\d+)' % key, text) or [None, ""])[1]
    return get("Device"), get("Renderer"), get("Tiler")


def residency():
    line = next((l for l in run(FTOP, "doctor", "--states").splitlines() if l.startswith(" GPUPH")), "")
    states = {k: int(v) for k, v in re.findall(r"(OFF|P\d+) (\d+)", line)}
    total = sum(states.values())
    if not total:
        return "", "", ""
    active = total - states.get("OFF", 0)
    weighted = sum(states.get("P%d" % (i + 1), 0) * m for i, m in enumerate(MHZ))
    return (round(100 * active / total, 1), round(weighted / active) if active else 0,
            round(100 * weighted / total / MHZ[-1], 1))


def probe():
    try:
        d = json.loads(run(FTOP, "probe", "--json"))
    except ValueError:
        return "", "", "", ""
    gpu = d.get("gpu", {}).get("value", {}).get("_0", {})
    power = d.get("power", {}).get("value", {}).get("_0", {})
    usage = gpu.get("usage")
    mhz = gpu.get("frequencyMHz", {}).get("value", {}).get("_0")
    watts = power.get("gpuWatts", {}).get("value", {}).get("_0")
    system = power.get("systemWatts")
    fmt = lambda v, n: "" if v is None else round(v, n)
    return fmt(usage * 100 if usage is not None else None, 0), fmt(mhz, 0), fmt(watts, 2), fmt(system, 1)


def context():
    idle = re.search(r'"HIDIdleTime" = (\d+)', run("ioreg", "-c", "IOHIDSystem", "-d4"))
    front = re.search(r'^"([^"]*)"', run("lsappinfo", "info", "-only", "name", run("lsappinfo", "front").strip()))
    return (round(int(idle[1]) / 1e9) if idle else ""), (front[1] if front else "")


def main():
    new = not os.path.exists(OUT)
    while True:
        started = time.monotonic()
        try:
            row = [datetime.datetime.now().isoformat(timespec="seconds"), *driver(), *residency(), *probe(), *context()]
        except Exception as error:  # keep logging through one bad sample
            row = [datetime.datetime.now().isoformat(timespec="seconds"), "error: %s" % error]
        with open(OUT, "a", newline="") as f:
            writer = csv.writer(f)
            if new:
                writer.writerow(FIELDS)
                new = False
            writer.writerow(row)
        time.sleep(max(1, INTERVAL - (time.monotonic() - started)))


if __name__ == "__main__":
    main()
