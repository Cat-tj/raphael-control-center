#!/usr/bin/env python3
"""Copies the pieces Raphael Web shares with the Mac app straight out of the Swift sources,
so there is one source of truth:

  build/collector_linux.sh   MonitorStore.linuxScript (the per-device metrics collector)
  build/schema_v1.sql        WorkspaceSchema migration 1 (same workspace.sqlite format)

Usage: python3 web/extract.py            (run from anywhere)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "web", "build")


def raw_string(swift: str, name: str) -> str:
    m = re.search(r"static let " + name + r' = #"""\n(.*?)\n\s*"""#', swift, re.S)
    if not m:
        sys.exit(f"extract: {name} not found")
    return dedent(m.group(1))


def dedent(block: str) -> str:
    lines = block.split("\n")
    indent = min((len(l) - len(l.lstrip(" ")) for l in lines if l.strip()), default=0)
    return "\n".join(l[indent:] for l in lines) + "\n"


def migrations(swift: str) -> list:
    out = []
    for m in re.finditer(r'\((\d+), """\n(.*?)\n\s*"""\)', swift, re.S):
        out.append((int(m.group(1)), dedent(m.group(2))))
    if not out:
        sys.exit("extract: no workspace migrations found")
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    mon = open(os.path.join(ROOT, "Sources/ControlCenter/MonitorStore.swift"), encoding="utf-8").read()
    with open(os.path.join(OUT, "collector_linux.sh"), "w", encoding="utf-8") as f:
        f.write(raw_string(mon, "linuxScript"))
    schema = open(os.path.join(ROOT, "Sources/Workspace/WorkspaceSchema.swift"), encoding="utf-8").read()
    for version, sql in migrations(schema):
        with open(os.path.join(OUT, f"schema_v{version}.sql"), "w", encoding="utf-8") as f:
            f.write(sql)
    print("extract: ok →", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
