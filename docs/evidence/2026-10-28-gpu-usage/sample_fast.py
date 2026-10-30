"""Same readings as the observation sampler, back to back, for the given number of seconds."""
import csv, datetime, importlib.util, sys, time

spec = importlib.util.spec_from_file_location("sample", "/Users/shek/Documents/Projects/ftop/docs/evidence/2026-10-28-gpu-usage/sample.py")
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
out, seconds = sys.argv[1], float(sys.argv[2])
end = time.monotonic() + seconds
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(s.FIELDS[:-2])
    while time.monotonic() < end:
        w.writerow([datetime.datetime.now().isoformat(timespec="seconds"), *s.driver(), *s.residency(), *s.probe()])
        f.flush()
