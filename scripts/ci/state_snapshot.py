#!/usr/bin/env python3
"""Compact, non-sensitive summary of raw Terraform state (`terraform state pull`).

Used before and after `terraform apply` so failure-cleanup can tell whether the apply
recorded any change and which resources existed before it (ownership). Prints JSON:
  {"exists": bool, "lineage_sha256": str, "serial": int|null,
   "addresses": [managed resource addresses], "expires_at": [distinct carrier ExpiresAt]}
The lineage is hashed and no attribute values other than ExpiresAt are emitted.
An empty input (no state stored yet) is a valid "exists": false snapshot.
Exit 0, or 2 when the input is not valid Terraform state.
Usage: state_snapshot.py RAW_STATE_FILE
"""
import hashlib
import json
import sys

from expiry_map import CARRIERS, TAG


def address(res, inst):
    base = f"{res['type']}.{res['name']}"
    if res.get("module"):
        base = f"{res['module']}.{base}"
    key = inst.get("index_key")
    if isinstance(key, bool) or key is None:
        return base
    return f"{base}[{key}]" if isinstance(key, int) else f"{base}[{json.dumps(key)}]"


def snapshot(text):
    if not text.strip():
        return {"exists": False, "lineage_sha256": "", "serial": None, "addresses": [], "expires_at": []}
    state = json.loads(text)
    lineage, serial = state.get("lineage"), state.get("serial")
    if not isinstance(lineage, str) or not lineage or not isinstance(serial, int) or isinstance(serial, bool):
        raise ValueError("lineage or serial missing")
    addrs, exps = set(), set()
    for res in state.get("resources") or []:
        if res.get("mode") != "managed":
            continue
        for inst in res.get("instances") or []:
            addrs.add(address(res, inst))
            if res.get("type") in CARRIERS:
                tag = ((inst.get("attributes") or {}).get("tags") or {}).get(TAG)
                exps.add(tag if isinstance(tag, str) else "<missing>")
    return {"exists": True, "lineage_sha256": hashlib.sha256(lineage.encode()).hexdigest(), "serial": serial,
            "addresses": sorted(addrs), "expires_at": sorted(exps)}


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        with open(argv[1]) as f:
            snap = snapshot(f.read())
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as e:
        print(f"state_snapshot: not valid Terraform state ({e.__class__.__name__})", file=sys.stderr)
        return 2
    print(json.dumps(snap, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
