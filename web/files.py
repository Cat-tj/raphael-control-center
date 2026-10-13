"""Read-only file browser for Raphael Web. Lists folders and shows text files on the configured
devices (locally or over SSH) as the service user — no writes, no sudo. Files that usually
hold secrets are refused by name, wherever they are."""
from __future__ import annotations

import json
import re
import subprocess

MAX_BYTES = 512 * 1024

# Names (or path parts) that typically contain credentials: never listed as readable, never shown.
SECRET = re.compile(r"""(^|/)(\.env(\..*)?|.*\.env|\.netrc|\.pgpass|\.npmrc|\.pypirc|\.git-credentials|credentials(\.json)?|
    auth\.json|secrets?(\.\w+)?|.*\.(pem|key|p12|pfx|keystore|jks|kdbx|gpg|asc)|id_(rsa|dsa|ecdsa|ed25519)[^/]*|
    authorized_keys|known_hosts|shadow|gshadow|.*token.*|.*passw(or)?d.*|db\.env)$""", re.I | re.X)
SECRET_DIRS = re.compile(r"(^|/)(\.ssh|\.gnupg|\.password-store|\.aws|\.docker|\.kube|\.config/gh)(/|$)")


def is_secret(path: str) -> bool:
    return bool(SECRET.search(path.rstrip("/"))) or bool(SECRET_DIRS.search(path))


SCRIPT = r'''
import json, os, stat, sys
req = json.loads(sys.stdin.readline())
p = os.path.expanduser(req["path"] or "~")
out = {"path": p, "real": os.path.realpath(p)}
try:
    if req["op"] == "list":
        items = []
        with os.scandir(p) as it:
            for e in it:
                try:
                    st = e.stat(follow_symlinks=True)
                    items.append([e.name, stat.S_ISDIR(st.st_mode), st.st_size, st.st_mtime, e.is_symlink()])
                except OSError:
                    items.append([e.name, False, 0, 0, e.is_symlink()])
        out["items"] = sorted(items, key=lambda x: (not x[1], x[0].lower()))[:2000]
        out["parent"] = os.path.dirname(p.rstrip("/")) or "/"
    else:
        st = os.stat(p)
        out["size"], out["mtime"] = st.st_size, st.st_mtime
        with open(p, "rb") as f:
            data = f.read(req["max"] + 1)
        out["truncated"] = len(data) > req["max"]
        data = data[:req["max"]]
        if b"\0" in data[:8192]:
            out["binary"] = True
        else:
            out["text"] = data.decode("utf-8", "replace")
except PermissionError:
    out["error"] = "tidak ada izin baca (Raphael Web berjalan sebagai user biasa, tanpa sudo)"
except FileNotFoundError:
    out["error"] = "tidak ditemukan"
except NotADirectoryError:
    out["error"] = "bukan folder"
except IsADirectoryError:
    out["error"] = "ini folder"
except OSError as e:
    out["error"] = str(e)
print(json.dumps(out))
'''


def run(node: dict, op: str, path: str) -> dict:
    if is_secret(path):
        return {"path": path, "error": "disembunyikan: file ini biasanya berisi rahasia"}
    req = json.dumps({"op": op, "path": path, "max": MAX_BYTES})
    cmd = ["python3", "-c", SCRIPT] if node.get("local") else \
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", node["ssh"], "python3 -c " + _quote(SCRIPT)]
    try:
        p = subprocess.run(cmd, input=req + "\n", capture_output=True, text=True, timeout=25)
    except subprocess.TimeoutExpired:
        return {"path": path, "error": "timeout"}
    line = next((l for l in reversed(p.stdout.splitlines()) if l.startswith("{")), None)
    if not line:
        return {"path": path, "error": (p.stderr.strip() or "tidak ada jawaban")[-200:]}
    out = json.loads(line)
    if op == "list":
        base = out["path"].rstrip("/")
        if is_secret(out.get("real", "") + "/"):
            return {"path": path, "error": "disembunyikan: folder ini biasanya berisi rahasia"}
        out["items"] = [{"name": n, "dir": d, "size": s, "mtime": m, "link": l, "secret": is_secret(f"{base}/{n}") and not d}
                        for n, d, s, m, l in out.get("items", [])]
    elif is_secret(out.get("path", "")) or is_secret(out.get("real", "")):   # also through symlinks
        return {"path": path, "error": "disembunyikan: file ini biasanya berisi rahasia"}
    return out


def _quote(s: str) -> str:
    return "'" + s.replace("'", "'\"'\"'") + "'"
