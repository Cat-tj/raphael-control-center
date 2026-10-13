import glob, json, os, re, subprocess, sys
req = json.loads(sys.argv[1])
def sh(c, t=15):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""
o = {"bootId": open("/proc/sys/kernel/random/boot_id").read().strip(), "uptime": float(open("/proc/uptime").read().split()[0])}
o["mmcErrors"] = sum(1 for l in sh("journalctl -k -b --no-pager 2>/dev/null").splitlines() if re.search(r"mmc\d+.*(error|timeout|crc)", l, re.I))
o["rootRO"] = any(l.split()[1] == "/" and "ro" in l.split()[3].split(",") for l in open("/proc/mounts") if len(l.split()) > 3)
if req.get("knownBoot") and req["knownBoot"] != o["bootId"]:
    o["prevBoot"] = {
        "hints": sh("journalctl -b -1 --no-pager -o short-iso 2>/dev/null | grep -iE 'under-voltage|voltage normalised|watchdog|out of memory|oom-kill|thermal|panic|reboot|shutdown|power key' | tail -n 8"),
        "tail": sh("journalctl -b -1 -n 12 --no-pager -o short-iso 2>/dev/null"),
    }
out = []
for b in req.get("backups", []):
    files = sorted((f for f in glob.glob(b["glob"]) if os.path.isfile(f)), key=os.path.getmtime)
    files = [(f, os.path.getsize(f), os.path.getmtime(f)) for f in files[-5:]]
    out.append({"name": b["name"], "files": files, "count": len(glob.glob(b["glob"]))})
o["backups"] = out
print(json.dumps(o))
