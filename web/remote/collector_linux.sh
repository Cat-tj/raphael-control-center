python3 - <<'RAPHAEL_PY'
import json, os, re, subprocess, time, shutil
def sh(c, t=8):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""
def cpu():
    a = [int(x) for x in open('/proc/stat').readline().split()[1:]]; time.sleep(0.4)
    b = [int(x) for x in open('/proc/stat').readline().split()[1:]]
    d = [y - x for x, y in zip(a, b)]; tot = sum(d) or 1
    return 1 - (d[3] + d[4]) / tot
o = {"cpu": round(cpu(), 4), "cores": os.cpu_count()}
mi = {l.split(':')[0]: int(l.split()[1]) * 1024 for l in open('/proc/meminfo') if len(l.split()) > 1}
o["memTotal"] = mi.get("MemTotal", 0)
o["mem"] = round(1 - mi.get("MemAvailable", 0) / max(mi.get("MemTotal", 1), 1), 4)
o["swap"] = round(1 - mi.get("SwapFree", 0) / mi["SwapTotal"], 4) if mi.get("SwapTotal") else 0
o["load"] = os.getloadavg()[0]
o["uptime"] = float(open('/proc/uptime').read().split()[0])
disks = []
seen = set()
for l in open('/proc/mounts'):
    dev, mnt, fs = l.split()[:3]
    if not dev.startswith('/dev/') or fs in ('squashfs', 'tmpfs') or dev in seen or mnt.startswith(('/boot', '/snap')): continue
    seen.add(dev)
    try: st = os.statvfs(mnt)
    except Exception: continue
    tot = st.f_blocks * st.f_frsize
    if tot < 1e9: continue
    disks.append([mnt, round(1 - st.f_bavail / max(st.f_blocks, 1), 4), round(tot / 1e9, 1)])
o["disks"] = disks
rx = tx = 0
for l in open('/proc/net/dev').readlines()[2:]:
    name, data = l.split(':', 1); name = name.strip(); f = data.split()
    if name == 'lo' or name.startswith(('veth', 'docker', 'br-', 'tailscale')): continue
    rx += int(f[0]); tx += int(f[8])
o["rx"], o["tx"] = rx, tx
try: o["temp"] = int(open('/sys/class/thermal/thermal_zone0/temp').read()) / 1000
except Exception: pass
if shutil.which('vcgencmd'):
    m = re.search(r'throttled=(\S+)', sh('vcgencmd get_throttled', 3))
    if m: o["throttled"] = m.group(1)
me = {os.getpid(), os.getppid()}
def top(key):
    out = []
    for l in sh(f'ps -eo pid,comm,%cpu,%mem --sort=-{key} | head -12').splitlines()[1:]:
        p = l.split()
        if len(p) >= 4:
            try: row = [int(p[0]), ' '.join(p[1:-2]), float(p[-2]), float(p[-1])]
            except ValueError: continue
            if row[0] in me or row[1] in ('ps', 'sh', 'sshd-session', 'sshd', 'head'): continue
            out.append(row)
    return out[:5]
o["topCPU"], o["topMem"] = top('%cpu'), top('%mem')
if shutil.which('docker'):
    stats = {}
    for l in sh("docker stats --no-stream --format '{{json .}}'", 12).splitlines():
        try: j = json.loads(l); stats[j["Name"]] = j
        except Exception: pass
    cs = []
    for l in sh("docker ps -a --format '{{.Names}}|{{.Status}}|{{.Label \"com.docker.compose.project\"}}|{{.Label \"com.docker.compose.project.working_dir\"}}|{{.Ports}}'").splitlines():
        if l.count('|') < 4: continue
        name, status, project, wdir, ports = l.split('|', 4)
        if status.startswith('Exited (0)'): continue
        j = stats.get(name, {})
        num = lambda v: float(re.sub(r'[^0-9.]', '', v) or 0)
        cs.append({"name": name, "status": status, "cpu": num(j.get("CPUPerc", "0")), "mem": j.get("MemUsage", "").split(' / ')[0],
                   "memPct": num(j.get("MemPerc", "0")), "net": j.get("NetIO", ""), "project": project, "dir": wdir,
                   "ports": sorted({int(p) for p in re.findall(r':(\d+)->', ports)})})
    if cs:
        rc = {}
        for l in sh("docker inspect -f '{{.Name}} {{.RestartCount}}' $(docker ps -aq) 2>/dev/null").splitlines():
            p = l.split()
            if len(p) == 2: rc[p[0].lstrip('/')] = int(p[1])
        for c in cs: c["restarts"] = rc.get(c["name"], 0)
    o["containers"] = cs
o["ips"] = sh('hostname -I').split()
# Custom services (regular unit files, not distro symlinks), system and user.
svcs = []
for scope, d in (('', '/etc/systemd/system'), ('--user', os.path.expanduser('~/.config/systemd/user'))):
    try: units = [f for f in os.listdir(d) if f.endswith('.service') and not os.path.islink(os.path.join(d, f))]
    except Exception: units = []
    for u in units:
        props = dict(l.split('=', 1) for l in sh(f"systemctl {scope} show {u} -p ActiveState,SubState,MemoryCurrent,CPUUsageNSec,NRestarts,MainPID,Description,WorkingDirectory").splitlines() if '=' in l)
        if props.get('ActiveState') in (None, '', 'inactive') and props.get('SubState') == 'dead' and props.get('NRestarts', '0') == '0': continue
        def num(v):
            try: return int(v)
            except Exception: return 0
        pid = num(props.get('MainPID'))
        mem = num(props.get('MemoryCurrent')) if props.get('MemoryCurrent', '').isdigit() else 0
        cpu = num(props.get('CPUUsageNSec')) if props.get('CPUUsageNSec', '').isdigit() else 0
        if pid and (not mem or not cpu):
            try:
                st = open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()
                cpu = cpu or int((int(st[11]) + int(st[12])) / os.sysconf('SC_CLK_TCK') * 1e9)
                mem = mem or int(st[21]) * os.sysconf('SC_PAGE_SIZE')
            except Exception: pass
        svcs.append({"unit": u, "user": bool(scope), "state": props.get('ActiveState', ''), "sub": props.get('SubState', ''),
                     "mem": mem, "cpuNs": cpu,
                     "restarts": num(props.get('NRestarts')), "pid": num(props.get('MainPID')), "desc": props.get('Description', ''),
                     "dir": props.get('WorkingDirectory', '')})
o["services"] = svcs
# Listening TCP ports → process (for mapping reverse proxies to apps).
ports = {}
for l in sh('sudo -n ss -ltnpH 2>/dev/null || ss -ltnH').splitlines():
    f = l.split()
    if len(f) < 4 or ':' not in f[3]: continue
    u = re.search(r'users:\(\("([^"]+)",pid=(\d+)', l)
    ports[f[3].rsplit(':', 1)[1]] = [u.group(1) if u else '', int(u.group(2)) if u else 0]
o["listen"] = ports
# Caddy sites → reverse_proxy target or static root.
routes = []
try: cf = open('/etc/caddy/Caddyfile').read()
except Exception: cf = ''
depth, cur = 0, None
for raw in cf.splitlines():
    line = raw.split('#', 1)[0].rstrip()
    if not line.strip(): continue
    if depth == 0 and line.endswith('{'):
        cur = {"hosts": [h.strip().rstrip(',') for h in line[:-1].split() if h.strip()], "proxy": None, "root": None}
        routes.append(cur)
    elif cur is not None:
        t = line.strip().split()
        if t[0] == 'reverse_proxy' and len(t) > 1 and not cur["proxy"]: cur["proxy"] = t[1]
        if t[0] == 'root' and len(t) > 1: cur["root"] = t[-1]
    depth += line.count('{') - line.count('}')
o["caddy"] = routes
# ── Scheduled jobs: cron, systemd timers, Hermes cron ─────────────────
jobs = []
o["tz"] = time.localtime().tm_gmtoff
sysnames = ('e2scrub', 'sysstat', 'debian-sa1', 'run-parts', 'popularity-contest', 'apt', 'anacron', 'logrotate', 'man-db', 'dpkg')
cron_runs = {}
for l in sh("sudo -n journalctl -u cron -u crond --since '-26h' -o short-unix --no-pager 2>/dev/null | grep ' CMD ('", 15).splitlines():
    m = re.match(r'([0-9.]+) .*CMD \((.*)\)\s*$', l)
    if m: cron_runs[m.group(2).strip()] = float(m.group(1))
def cron_lines(text, src, has_user):
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=', line): continue
        parts = line.split()
        if parts[0].startswith('@'): expr, rest = parts[0], parts[1:]
        elif len(parts) >= 6: expr, rest = ' '.join(parts[:5]), parts[5:]
        else: continue
        user = rest[0] if has_user and rest else src.split(':')[0]
        cmd = ' '.join(rest[1:] if has_user else rest)
        if not cmd: continue
        seg = re.split(r'\|\||&&|;', re.sub(r'[12]?>>?\s*\S+|2>&1', '', cmd))[-1].split()
        name = os.path.basename(seg[0]) if seg else cmd[:40]
        if name in ('run-parts',) and len(seg) > 1: name = 'run-parts ' + os.path.basename(seg[-1])
        import hashlib
        j = {"kind": "cron", "id": "cron:" + src + ":" + hashlib.sha1((expr + cmd).encode()).hexdigest()[:10], "name": name[:60],
             "expr": expr, "user": user, "command": cmd[:300], "source": src, "enabled": True,
             "system": any(n in cmd for n in sysnames) or any(n in src for n in ('e2scrub', 'sysstat'))}
        if cmd in cron_runs: j["last"] = cron_runs[cmd]
        lm = re.search(r'>>?\s*(/[^\s;|&]+)', cmd)
        if lm:
            log = lm.group(1); j["log"] = log
            tail = sh(f"sudo -n tail -n 6 {log} 2>/dev/null || tail -n 6 {log} 2>/dev/null").strip().splitlines()
            try: j["logModified"] = os.path.getmtime(log)
            except Exception:
                st = sh(f"sudo -n stat -c %Y {log} 2>/dev/null").strip()
                if st.isdigit(): j["logModified"] = float(st)
            if tail:
                lines = [x.strip() for x in tail if x.strip()]
                # Only what came after the last success marker counts (a run that logs "ok" clears older errors).
                okidx = max([i for i, x in enumerate(lines) if re.search(r'\b(ok|success(ful)?|succeeded|done|completed|finished)\b', x, re.I)
                             and not re.search(r'error|fail|fatal', x, re.I)], default=-1)
                bad = [x for x in lines[okidx + 1:][-4:] if re.search(r'error|fail|fatal|refused|denied|traceback|exception', x, re.I)]
                j["detail"] = (bad[0] if bad else (lines[-1] if lines else ''))[:240]
                j["status"] = "failed" if bad else "ok"
        jobs.append(j)
cron_lines(sh('crontab -l 2>/dev/null'), os.environ.get('USER', 'user') + ':crontab', False)
cron_lines(sh('sudo -n crontab -l 2>/dev/null'), 'root:crontab', False)
try: cron_lines(open('/etc/crontab').read(), 'etc:crontab', True)
except Exception: pass
for f in sorted(os.listdir('/etc/cron.d')) if os.path.isdir('/etc/cron.d') else []:
    try: cron_lines(open('/etc/cron.d/' + f).read(), 'cron.d:' + f, True)
    except Exception: pass
for scope in ('', '--user'):
    try: timers = json.loads(sh(f'systemctl {scope} list-timers --all --no-pager --output=json 2>/dev/null') or '[]')
    except Exception: timers = []
    for t in timers:
        svc = t.get('activates') or ''
        props = dict(l.split('=', 1) for l in sh(f'systemctl {scope} show {svc} -p Result,ExecMainStatus,ExecMainExitTimestamp,ActiveState,FragmentPath,Description --timestamp=unix').splitlines() if '=' in l)
        frag = props.get('FragmentPath', '')
        ts = lambda v: (v / 1e6) if isinstance(v, (int, float)) and v > 0 else None
        exit_ts = props.get('ExecMainExitTimestamp', '').lstrip('@')
        j = {"kind": "timer", "id": f"timer:{scope or 'system'}:{t.get('unit')}", "name": (t.get('unit') or '').replace('.timer', ''), "unit": t.get('unit'),
             "service": svc, "command": props.get('Description', ''), "user": 'user' if scope else 'root', "enabled": True,
             "next": ts(t.get('next')), "last": ts(t.get('last')) or (float(exit_ts) if exit_ts.replace('.', '').isdigit() else None),
             "status": "running" if props.get('ActiveState') == 'activating' else ("ok" if props.get('Result') == 'success' and props.get('ExecMainStatus', '0') == '0' else ("failed" if props.get('Result') not in (None, '', 'success') or props.get('ExecMainStatus', '0') not in ('0', '') else "")),
             "detail": "" if props.get('Result') in (None, '', 'success') else f"Result={props.get('Result')} exit={props.get('ExecMainStatus')}",
             "system": frag.startswith(('/lib/', '/usr/lib/')) or any(n in (t.get('unit') or '') for n in sysnames + ('fstrim', 'zram', 'tmpfiles'))}
        jobs.append(j)
for home in [os.path.expanduser('~/.hermes')] + [os.path.join(os.path.expanduser('~/.hermes/profiles'), d) for d in (os.listdir(os.path.expanduser('~/.hermes/profiles')) if os.path.isdir(os.path.expanduser('~/.hermes/profiles')) else [])]:
    jf = os.path.join(home, 'cron', 'jobs.json')
    if not os.path.exists(jf): continue
    try: data = json.load(open(jf))
    except Exception: continue
    hist = {}
    try:
        import sqlite3
        c = sqlite3.connect('file:' + os.path.join(home, 'cron', 'executions.db') + '?mode=ro', uri=True)
        for job_id, status, started, finished, err in c.execute("SELECT job_id, status, started_at, finished_at, substr(COALESCE(error,''),1,200) FROM executions ORDER BY started_at DESC LIMIT 300"):
            hist.setdefault(job_id, [])
            if len(hist[job_id]) < 8: hist[job_id].append([started, finished, status, err])
    except Exception: pass
    profile = 'default' if home.endswith('.hermes') else os.path.basename(home)
    for jb in data.get('jobs', []) if isinstance(data, dict) else data:
        sch = jb.get('schedule') or {}
        jobs.append({"kind": "hermes", "id": f"hermes:{profile}:{jb.get('id')}", "name": jb.get('name') or jb.get('id'), "profile": profile,
                     "expr": sch.get('expr') or '', "schedule": jb.get('schedule_display') or sch.get('display') or '', "enabled": bool(jb.get('enabled', True)) and not jb.get('paused_at'),
                     "state": jb.get('state') or '', "nextISO": jb.get('next_run_at'), "lastISO": jb.get('last_run_at'), "status": {"ok": "ok", "success": "ok", "completed": "ok", "failed": "failed", "error": "failed"}.get(str(jb.get('last_status') or '').lower(), str(jb.get('last_status') or '')),
                     "detail": (jb.get('last_error') or jb.get('last_delivery_error') or '')[:240], "failureStreak": jb.get('failure_streak') or 0,
                     "workdir": jb.get('workdir') or '', "history": hist.get(jb.get('id'), []), "system": False})
o["jobs"] = jobs
o["failed"] = [l.split()[0] for l in sh("systemctl --failed --no-legend --plain 2>/dev/null; systemctl --user --failed --no-legend --plain 2>/dev/null").splitlines() if l.strip()]
# cloudflared tunnel metrics (Prometheus endpoint on localhost)
if 'cloudflared' in sh('ps -eo comm'):
    ports = set(re.findall(r'127\.0\.0\.1:(\d+).*cloudflared', sh('sudo -n ss -ltnp 2>/dev/null')))
    for port in sorted(ports) or ['20241']:
        txt = sh(f'curl -s -m 3 http://127.0.0.1:{port}/metrics', 5)
        if 'cloudflared_tunnel' not in txt: continue
        g = lambda n: sum(float(m) for m in re.findall(r'^%s(?:\{[^}]*\})? ([0-9.e+]+)$' % n, txt, re.M))
        codes = {m[0]: float(m[1]) for m in re.findall(r'^cloudflared_tunnel_response_by_code\{status_code="(\d+)"\} ([0-9.e+]+)$', txt, re.M)}
        hosts = []
        for f in ('/etc/cloudflared/config.yml', os.path.expanduser('~/.cloudflared/config.yml')):
            try: hosts += re.findall(r'hostname:\s*(\S+)', open(f).read())
            except Exception: pass
        o["tunnel"] = {"port": int(port), "total": g('cloudflared_tunnel_total_requests'), "errors": g('cloudflared_tunnel_request_errors'),
                       "ha": g('cloudflared_tunnel_ha_connections'), "concurrent": g('cloudflared_tunnel_concurrent_requests_per_tunnel'),
                       "codes": codes, "hosts": sorted(set(hosts))}
        break
if __SLOW__:
    hw = {}
    try: hw["model"] = open('/proc/device-tree/model').read().strip('\x00 \n')
    except Exception:
        try: hw["model"] = (open('/sys/class/dmi/id/sys_vendor').read().strip() + ' ' + open('/sys/class/dmi/id/product_name').read().strip()).strip()
        except Exception: pass
    try: hw["os"] = re.search(r'PRETTY_NAME="([^"]+)"', open('/etc/os-release').read()).group(1)
    except Exception: pass
    cpu = sh('lscpu')
    m = re.search(r'Model name:\s*(.+)', cpu); mh = re.search(r'CPU max MHz:\s*([\d.]+)', cpu)
    hw["cpu"] = ((m.group(1).strip() if m else '') + (f" @ {float(mh.group(1))/1000:.1f} GHz" if mh else '')).strip()
    hw["kernel"] = os.uname().release
    hw["storage"] = []
    for l in sh('lsblk -dno NAME,SIZE,TRAN,MODEL').splitlines():
        f = l.split(None, 3)
        if not f or f[0].startswith(('loop', 'zram', 'ram')): continue
        kind = 'microSD' if f[0].startswith('mmcblk') else 'NVMe' if f[0].startswith('nvme') else ('USB ' if len(f) > 2 and f[2] == 'usb' else '') + 'disk'
        hw["storage"].append(f"{kind} {f[1] if len(f) > 1 else ''}" + (f" ({f[3].strip()})" if len(f) > 3 else ''))
    o["hw"] = hw
    up = sh('apt list --upgradable 2>/dev/null', 20).splitlines()
    o["updates"] = sum(1 for l in up if '/' in l)
    o["security"] = sum(1 for l in up if '-security' in l)
    o["sshFails"] = len(re.findall(r'Failed password|Invalid user|authentication failure',
                                   sh("sudo -n journalctl --since '-24h' -u ssh -u sshd --no-pager 2>/dev/null", 15)))
    o["reboot"] = os.path.exists('/var/run/reboot-required')
print(json.dumps(o))
RAPHAEL_PY
