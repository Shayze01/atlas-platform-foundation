#!/usr/bin/env python3
"""Checks that the rendered cloud-init embeds the ./app files byte-for-byte.

Run scripts/render-cloud-init.sh first. Uses PyYAML (installed with cloud-init).
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
rendered = yaml.safe_load((ROOT / "build" / "cloud-init.rendered.yaml").read_text())
embedded = {f["path"]: f["content"] for f in rendered["write_files"]}

failures = 0
for name in ["Dockerfile", "nginx.conf", "index.html", "run-container.sh"]:
    vm_path = f"/opt/atlas/app/{name}"
    expected = (ROOT / "app" / name).read_text()
    if embedded.get(vm_path) == expected:
        print(f"PASS: {vm_path} matches app/{name}")
    else:
        print(f"FAIL: {vm_path} differs from app/{name}")
        failures += 1

sys.exit(1 if failures else 0)
