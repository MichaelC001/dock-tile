#!/usr/bin/env python3
"""Temporary memory watcher for DEV tiles. Remove once there is enough data.

Samples every running dev helper's footprint and IOSurface usage on a timer and correlates it with
how many times the popover was opened, so the question "does a tile's memory creep with use?" gets
answered from days of real use instead of a ten-open test.

  memwatch.py install      start sampling every 10 minutes (per-user LaunchAgent)
  memwatch.py sample       take one sample now
  memwatch.py report       summarise what has been collected
  memwatch.py uninstall    stop sampling and remove the agent (data is kept; --purge deletes it)

External on purpose: no product code, nothing to strip from a release, and the tiles are not
perturbed by their own instrumentation. Dev tiles only: their log records popover opens (verbose
logging is dropped in Release), and production data is never touched.
"""
import csv, json, os, re, subprocess, sys
from datetime import datetime, timezone

LABEL = "com.docktile.dev.memwatch"
INTERVAL = 600
SUPPORT = os.path.expanduser("~/Library/Application Support/DockTile-Dev")
DATA = os.path.join(SUPPORT, "memwatch.csv")
STATE = os.path.join(SUPPORT, "memwatch-state.json")
LOG = os.path.join(SUPPORT, "diagnostics.log")
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
FIELDS = ["time", "tile", "pid", "uptime_s", "footprint_mb", "iosurface_mb", "iosurface_regions", "opens"]
UNIT = {"B": 1 / 1048576, "KB": 1 / 1024, "MB": 1.0, "GB": 1024.0}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def elapsed_seconds(etime):
    """Parse ps `etime` ([[dd-]hh:]mm:ss). This macOS ps has no `etimes`, so the numeric form is
    not available — asking for it made ps fail outright and the watcher silently saw no tiles."""
    days, _, rest = etime.strip().rpartition("-")
    parts = [int(p) for p in rest.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts
    return (int(days) if days else 0) * 86400 + h * 3600 + m * 60 + s


def helpers():
    """(pid, tile name, uptime seconds) for every running dev helper."""
    found = []
    for line in run("ps", "-Ao", "pid=,etime=,command=").splitlines():
        m = re.match(r"\s*(\d+)\s+(\S+)\s+.*/DockTile-Dev/(.+?)\.app/Contents/MacOS/", line)
        if m:
            found.append((m.group(1), m.group(3), elapsed_seconds(m.group(2))))
    return found


def to_mb(value, unit):
    return float(value) * UNIT.get(unit, 0)


def measure(pid):
    out = run("footprint", pid)
    fp = re.search(r"Footprint:\s+([\d.]+)\s+(B|KB|MB|GB)", out)
    io_mb, io_regions = 0.0, 0
    for line in out.splitlines():
        if line.rstrip().endswith("IOSurface"):
            sizes = re.findall(r"([\d.]+)\s+(B|KB|MB|GB)", line)
            io_mb = sum(to_mb(v, u) for v, u in sizes)          # dirty + swapped + clean
            count = re.search(r"(\d+)\s+IOSurface\s*$", line)
            io_regions = int(count.group(1)) if count else 0
    return (round(to_mb(*fp.groups()), 1) if fp else None), round(io_mb, 1), io_regions


def new_opens(since_iso):
    """Popover opens per pid logged after `since_iso`. The log is trimmed to an hour on main-app
    launch, so opens are accumulated in the state file rather than recounted from scratch."""
    counts = {}
    try:
        with open(LOG, errors="replace") as f:
            for line in f:
                if "✔ Show popover" not in line or line[:24] <= since_iso:
                    continue
                m = re.search(r"\[helper:.*? (\d+)\]", line)
                if m:
                    counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    except FileNotFoundError:
        pass
    return counts


def sample():
    os.makedirs(SUPPORT, exist_ok=True)
    state = {"since": "", "opens": {}}
    if os.path.exists(STATE):
        state = json.load(open(STATE))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    for pid, n in new_opens(state["since"]).items():
        state["opens"][pid] = state["opens"].get(pid, 0) + n
    live = helpers()
    fresh = not os.path.exists(DATA)
    with open(DATA, "a", newline="") as f:
        w = csv.DictWriter(f, FIELDS)
        if fresh:
            w.writeheader()
        for pid, tile, uptime in live:
            fp, io_mb, regions = measure(pid)
            if fp is None:
                continue
            w.writerow(dict(time=now, tile=tile, pid=pid, uptime_s=uptime, footprint_mb=fp,
                            iosurface_mb=io_mb, iosurface_regions=regions,
                            opens=state["opens"].get(pid, 0)))
    state["since"] = now
    state["opens"] = {p: c for p, c in state["opens"].items() if p in {h[0] for h in live}}
    json.dump(state, open(STATE, "w"))
    print(f"sampled {len(live)} dev helper(s) at {now}")


def report():
    if not os.path.exists(DATA):
        sys.exit("no data yet — run `memwatch.py install` and come back later")
    runs = {}
    for row in csv.DictReader(open(DATA)):
        runs.setdefault((row["tile"], row["pid"]), []).append(row)
    print(f"{'tile':<12}{'pid':>7}{'samples':>9}{'hours':>7}{'opens':>7}"
          f"{'footprint MB':>16}{'IOSurf regions':>16}{'MB/100 opens':>14}")
    for (tile, pid), rows in sorted(runs.items(), key=lambda kv: kv[1][0]["time"]):
        a, b = rows[0], rows[-1]
        opens = int(b["opens"]) - int(a["opens"])
        grew = float(b["footprint_mb"]) - float(a["footprint_mb"])
        per100 = f"{grew / opens * 100:+.1f}" if opens >= 10 else "n/a (<10)"
        hours = (int(b["uptime_s"]) - int(a["uptime_s"])) / 3600
        print(f"{tile:<12}{pid:>7}{len(rows):>9}{hours:>7.1f}{opens:>7}"
              f"{a['footprint_mb'] + ' -> ' + b['footprint_mb']:>16}"
              f"{a['iosurface_regions'] + ' -> ' + b['iosurface_regions']:>16}{per100:>14}")
    print("\nHealthy: footprint flat once warm, MB/100 opens near 0. The pre-2.0.2 leak was about"
          " +300 to +500 MB per 100 opens.\nEach row is one helper process; a relaunch (Update,"
          " migration, reboot) starts a new row.")


def install():
    os.makedirs(os.path.dirname(PLIST), exist_ok=True)
    script = os.path.abspath(__file__)
    open(PLIST, "w").write(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>{script}</string><string>sample</string></array>
  <key>StartInterval</key><integer>{INTERVAL}</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>{SUPPORT}/memwatch.err</string>
</dict></plist>
""")
    uid = str(os.getuid())
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"], capture_output=True)
    r = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"launchctl bootstrap failed: {r.stderr.strip()}")
    print(f"installed {LABEL}: sampling every {INTERVAL // 60} min into {DATA}")


def uninstall():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
    for p in [PLIST] + ([DATA, STATE, os.path.join(SUPPORT, "memwatch.err")] if "--purge" in sys.argv else []):
        if os.path.exists(p):
            os.remove(p)
    print("uninstalled" + (" and data purged" if "--purge" in sys.argv else f"; data kept at {DATA}"))


if __name__ == "__main__":
    {"sample": sample, "report": report, "install": install, "uninstall": uninstall}.get(
        sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
