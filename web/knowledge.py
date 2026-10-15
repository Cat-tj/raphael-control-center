"""Knowledge (same rules as rust/src/knowledge.rs): agents and profiles with their SOUL and memory
files, the names in each .env (never the values), and graphify graphs. Only discovered files can be
read or written; writes keep a .raphael.bak copy and the permissions, and refuse a newer version."""
import glob
import json
import os
import shutil

MAX_TEXT = 1024 * 1024


def _files(d, pred):
    out = []
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        p = os.path.join(d, n)
        if os.path.isfile(p) and pred(n):
            out.append({"path": p, "name": n, "size": os.path.getsize(p)})
    return sorted(out, key=lambda f: f["name"], reverse=True)


def _env_names(p):
    names = []
    try:
        for line in open(p, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                names.append(line.split("=", 1)[0].replace("export ", "").strip())
    except OSError:
        pass
    return sorted(set(names))


def discover(home_cfg="~/.hermes"):
    home = os.path.expanduser(home_cfg)
    dirs = [home] + sorted(p for p in glob.glob(os.path.join(home, "profiles", "*")) if os.path.isdir(p))  # glob skips dot-dirs
    agents = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        default = d == home
        aid = "default" if default else os.path.basename(d)
        agents.append({"id": aid, "name": "Raphael" if default else aid[:1].upper() + aid[1:],
                       "home": "~/.hermes" if default else f"profiles/{aid}",
                       "soul": _files(d, lambda n: n.startswith("SOUL") and n.endswith(".md")),
                       "memory": _files(os.path.join(d, "memories"), lambda n: n.endswith(".md")) + _files(os.path.join(d, "agent-memory"), lambda n: n.endswith(".md")),
                       "env": _env_names(os.path.join(d, ".env")), "envPath": os.path.join(d, ".env")})
    user = os.path.expanduser("~")
    cands = [os.path.join(home, "agent-memory/graphify-out/graph.json"), os.path.join(user, ".graphify/global-graph.json")]
    cands += sorted(glob.glob(os.path.join(user, "Projects/*/graphify-out/graph.json"))) + sorted(glob.glob(os.path.join(user, "*/graphify-out/graph.json")))
    graphs = []
    for p in cands:
        if any(g["path"] == p for g in graphs) or not os.path.isfile(p):
            continue
        root = os.path.dirname(os.path.dirname(p))
        name = "Global graph" if p.endswith("global-graph.json") else "Agent memory" if root.endswith("agent-memory") else os.path.basename(root)
        try:
            g = json.load(open(p))
            nodes, links = len(g.get("nodes") or []), len(g.get("links") or g.get("edges") or [])
        except Exception:  # noqa: BLE001
            nodes = links = 0
        graphs.append({"path": p, "name": name, "nodes": nodes, "links": links, "mtime": os.path.getmtime(p)})
    return {"agents": agents, "graphs": graphs}


def _allowed(home_cfg, path):
    return any(f["path"] == path for a in discover(home_cfg)["agents"] for f in a["soul"] + a["memory"])


def read(home_cfg, path):
    if not _allowed(home_cfg, path):
        raise ValueError("file ini tidak termasuk SOUL atau memory agent")
    st = os.stat(path)
    return {"path": path, "text": open(path, encoding="utf-8", errors="replace").read(), "size": st.st_size, "mtime": st.st_mtime}


def write(home_cfg, path, text, base_mtime=None):
    """Returns the saved file; raises (code, message) as a tuple in a ValueError's args."""
    if not _allowed(home_cfg, path):
        raise ValueError(400, "file ini tidak termasuk SOUL atau memory agent")
    if len(text.encode()) > MAX_TEXT:
        raise ValueError(400, "teks terlalu besar (maks 1 MB)")
    st = os.stat(path)
    if base_mtime is not None and abs(st.st_mtime - float(base_mtime)) > 0.001:
        raise ValueError(409, "file sudah diubah di tempat lain; muat ulang dulu")
    shutil.copy2(path, path + ".raphael.bak")
    tmp = path + ".raphael.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
    return read(home_cfg, path)


def graph(home_cfg, path):
    if not any(g["path"] == path for g in discover(home_cfg)["graphs"]):
        raise ValueError("graph tidak dikenal")
    g = json.load(open(path))
    nodes = [{"id": n.get("id"), "label": n.get("label") or n.get("norm_label") or n.get("id"), "community": n.get("community"),
              "group": n.get("community_name"), "kind": n.get("file_type") or n.get("node_kind"), "file": n.get("source_file")}
             for n in (g.get("nodes") or [])[:3000]]
    ids = {json.dumps(n["id"]) for n in nodes}
    links = [{"source": l.get("source"), "target": l.get("target"), "relation": l.get("relation")}
             for l in (g.get("links") or g.get("edges") or []) if json.dumps(l.get("source")) in ids and json.dumps(l.get("target")) in ids][:12000]
    return {"path": path, "nodes": nodes, "links": links, "total": len(g.get("nodes") or [])}
