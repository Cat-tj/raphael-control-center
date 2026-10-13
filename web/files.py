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


import os as _os
with open(_os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "remote", "files.py"), encoding="utf-8") as _f:
    SCRIPT = _f.read()                     # shared with the Rust server


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
