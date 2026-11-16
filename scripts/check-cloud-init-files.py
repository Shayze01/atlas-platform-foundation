#!/usr/bin/env python3
"""Checks the rendered cloud-init (run scripts/render-cloud-init.sh first).

- the helper scripts are embedded byte-for-byte from cloud-init/files/;
- the env file carries exactly the planned image digest and expiry;
- the expiry timer fires at that expiry (UTC) and catches up after a missed run;
- the VM never builds an image and never uses a mutable tag.
Uses PyYAML (installed with cloud-init).
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
IMAGE = "ghcr.io/shayze01/atlas-tickets@sha256:" + "0" * 64
EXPIRES = "2030-01-01T00:00:00Z"
raw = (ROOT / "build" / "cloud-init.rendered.yaml").read_text()
rendered = yaml.safe_load(raw)
files = {f["path"]: f["content"] for f in rendered["write_files"]}
runcmd = [" ".join(map(str, c)) if isinstance(c, list) else c for c in rendered["runcmd"]]
failures = 0


def check(ok, what):
    global failures
    print(("PASS: " if ok else "FAIL: ") + what)
    failures += 0 if ok else 1


for name in ["run-tickets.sh", "atlas-expire.sh"]:
    check(files.get(f"/opt/atlas/{name}") == (ROOT / "cloud-init" / "files" / name).read_text(),
          f"/opt/atlas/{name} matches cloud-init/files/{name}")
env = files.get("/etc/atlas/tickets.env", "").splitlines()
check(f"ATLAS_IMAGE={IMAGE}" in env, "env file pins the planned image digest")
check(f"ATLAS_EXPIRES_AT={EXPIRES}" in env, "env file carries the planned expiry")
timer = files.get("/etc/systemd/system/atlas-expiry.timer", "")
check("OnCalendar=2030-01-01 00:00:00 UTC" in timer, "expiry timer fires at expires_at in UTC")
check("Persistent=true" in timer, "expiry timer catches up at boot if the expiry passed while stopped")
check("ExecStart=/opt/atlas/run-tickets.sh" in files.get("/etc/systemd/system/atlas-tickets.service", ""),
      "app service runs the boot-time expiry check before starting")
check(any("enable --now atlas-expiry.timer" in c for c in runcmd) and
      any("enable --now atlas-tickets.service" in c for c in runcmd), "timer and app service enabled")
check("docker build" not in raw and ":latest" not in raw, "no image build or mutable tag on the VM")
check(len(raw.encode()) < 32 * 1024, f"rendered cloud-init is {len(raw.encode())} bytes (< 32 KiB, Azure limit 64 KiB)")
sys.exit(1 if failures else 0)
