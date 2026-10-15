"""Cloudflare Access in front of the public hostname (same rules as rust/src/access.rs).

A request that came through Cloudflare (it carries Cf-Ray) must carry a valid Access token: an
RS256 JWT signed by one of the team's keys, for this application's AUD tag, not expired.
Tailnet requests (tailscale serve) are unchanged.
"""
import base64
import hashlib
import json
import threading
import time
import urllib.request

# DER prefix of a PKCS#1 v1.5 DigestInfo for SHA-256.
SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


def b64url(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def via_cloudflare(headers) -> bool:
    return bool(headers.get("Cf-Ray") or headers.get("Cf-Connecting-Ip"))


def token(headers):
    t = headers.get("Cf-Access-Jwt-Assertion")
    if t:
        return t
    for c in (headers.get("Cookie") or "").split(";"):
        c = c.strip()
        if c.startswith("CF_Authorization="):
            return c[len("CF_Authorization="):]
    return None


def rsa_verify(n: bytes, e: bytes, msg: bytes, sig: bytes) -> bool:
    """RSASSA-PKCS1-v1_5 with SHA-256, using only integer arithmetic."""
    k = len(n)
    if len(sig) != k or k < 256:
        return False
    em = pow(int.from_bytes(sig, "big"), int.from_bytes(e, "big"), int.from_bytes(n, "big")).to_bytes(k, "big")
    want = SHA256_PREFIX + hashlib.sha256(msg).digest()
    return em == b"\x00\x01" + b"\xff" * (k - len(want) - 3) + b"\x00" + want


class Access:
    def __init__(self, team: str, aud: str):
        self.team = team.replace("https://", "").strip("/")
        self.aud = aud
        self.keys, self.loaded = {}, 0.0
        self.lock = threading.Lock()

    @classmethod
    def from_config(cls, cfg):
        a = cfg.get("access") or {}
        return cls(a["team"], a["aud"]) if a.get("team") and a.get("aud") else None

    def _keys(self, force=False):
        with self.lock:
            age = time.time() - self.loaded
            if not self.keys or age > 3600 or (force and age > 60):
                try:
                    with urllib.request.urlopen(f"https://{self.team}/cdn-cgi/access/certs", timeout=10) as r:
                        j = json.loads(r.read())
                    keys = {k["kid"]: (b64url(k["n"]), b64url(k["e"])) for k in j.get("keys") or [] if k.get("kid")}
                    if keys:
                        self.keys, self.loaded = keys, time.time()
                except Exception:  # noqa: BLE001 — keep the old keys
                    pass
            return dict(self.keys)

    def check(self, tok):
        """The signed-in email; raises ValueError with the reason otherwise."""
        if not tok:
            raise ValueError("belum login lewat Cloudflare Access")
        parts = tok.split(".")
        if len(parts) != 3:
            raise ValueError("token Access tidak valid")
        try:
            header, claims, sig = json.loads(b64url(parts[0])), json.loads(b64url(parts[1])), b64url(parts[2])
        except Exception:  # noqa: BLE001
            raise ValueError("token Access tidak valid")
        if header.get("alg") != "RS256":
            raise ValueError("algoritma token Access tidak didukung")
        kid = header.get("kid", "")
        keys = self._keys()
        if kid not in keys:
            keys = self._keys(force=True)
        if kid not in keys:
            raise ValueError("kunci token Access tidak dikenal")
        if not rsa_verify(*keys[kid], f"{parts[0]}.{parts[1]}".encode(), sig):
            raise ValueError("tanda tangan token Access salah")
        aud = claims.get("aud")
        if not (self.aud in aud if isinstance(aud, list) else aud == self.aud):
            raise ValueError("token Access untuk aplikasi lain")
        if (claims.get("exp") or 0) < time.time():
            raise ValueError("sesi Access kedaluwarsa")
        if claims.get("iss") != f"https://{self.team}":
            raise ValueError("penerbit token Access salah")
        return claims.get("email") or ""
