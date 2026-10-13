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
