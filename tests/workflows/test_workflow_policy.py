#!/usr/bin/env python3
"""Security policy checks for .github/workflows (offline, no network).

Enforces the Milestone 2 trust boundaries:
  * pull-request workflows get no Azure access (no id-token, secrets or environments)
  * no pull_request_target / workflow_run triggers
  * Azure jobs: trusted triggers only, an environment, and a main-branch guard
  * every action pinned to a full commit SHA; checkout without persisted credentials
  * no artifacts; plans are applied only from the saved, reviewed file
  * Terraform/validation output piped through scripts/ci/sanitize.sh
  * deploy and destroy share one non-cancelling concurrency group
Also runs the checker against deliberately bad fixtures to prove it rejects them.
"""
import glob
import os
import re
import sys

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SHA = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
TRUSTED_AZURE_TRIGGERS = {"workflow_dispatch", "schedule"}
SANITISED = re.compile(r"(terraform (init|apply|destroy|plan)|backend-init\.sh|azure-validate\.sh|verify-cleanup\.sh|temp-access\.sh remove)")


def load(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    # PyYAML (YAML 1.1) parses the key "on" as True.
    triggers = doc.get("on", doc.get(True, {}))
    if isinstance(triggers, str):
        triggers = {triggers: None}
    elif isinstance(triggers, list):
        triggers = {t: None for t in triggers}
    return doc, triggers or {}


def perms_grant_id_token(perms):
    return isinstance(perms, dict) and perms.get("id-token") == "write" or perms == "write-all"


def check(path):
    v = []
    name = os.path.basename(path)
    with open(path) as f:
        text = f.read()
    doc, triggers = load(path)
    jobs = doc.get("jobs", {}) or {}

    if "permissions" not in doc:
        v.append(f"{name}: no top-level permissions block")
    for bad in ("pull_request_target", "workflow_run"):
        if bad in triggers:
            v.append(f"{name}: forbidden trigger {bad}")
    if "upload-artifact" in text:
        v.append(f"{name}: artifacts are not allowed (plans/state must stay private)")

    is_pr = "pull_request" in triggers
    if is_pr:
        if "secrets." in text:
            v.append(f"{name}: pull-request workflow references secrets")
        if perms_grant_id_token(doc.get("permissions")):
            v.append(f"{name}: pull-request workflow grants id-token at top level")

    for job_id, job in jobs.items():
        where = f"{name}:{job_id}"
        steps = job.get("steps", []) or []
        id_token = perms_grant_id_token(job.get("permissions")) or perms_grant_id_token(doc.get("permissions"))
        if is_pr and (id_token or job.get("environment")):
            v.append(f"{where}: pull-request job has id-token or an environment (Azure access)")
        if id_token:
            if not set(triggers) <= TRUSTED_AZURE_TRIGGERS:
                v.append(f"{where}: Azure job reachable from untrusted trigger(s) {sorted(set(triggers) - TRUSTED_AZURE_TRIGGERS)}")
            if not job.get("environment"):
                v.append(f"{where}: Azure job without an environment")
            if "github.ref == 'refs/heads/main'" not in str(job.get("if", "")):
                v.append(f"{where}: Azure job without a main-branch guard")
        for i, step in enumerate(steps):
            sw = f"{where} step {i + 1}"
            uses = step.get("uses")
            if uses and not uses.startswith("./") and not SHA.match(uses):
                v.append(f"{sw}: action not pinned to a commit SHA ({uses})")
            if uses and uses.split("@")[0] == "actions/checkout":
                if str((step.get("with") or {}).get("persist-credentials")).lower() != "false":
                    v.append(f"{sw}: checkout must set persist-credentials: false")
            run = step.get("run", "") or ""
            if re.search(r"terraform plan", run) and "-out=" not in run:
                v.append(f"{sw}: terraform plan without a saved plan file")
            if re.search(r"terraform apply", run) and ("-auto-approve" in run or not re.search(r"terraform apply[^\n]* tfplan", run)):
                v.append(f"{sw}: terraform apply must apply the saved, reviewed plan file")
            if re.search(r"terraform show(?! -json)", run) or re.search(r"cat [^|\n]*tfstate", run):
                v.append(f"{sw}: raw plan/state output in logs")
            if re.search(r"\bset -x\b|\bbash -x\b", run):
                v.append(f"{sw}: shell tracing would leak values")
            for line in run.splitlines():
                if SANITISED.search(line) and not line.strip().startswith("echo ") and "sanitize.sh" not in line and ">\"${RUNNER_TEMP}/plan.log\"" not in line:
                    v.append(f"{sw}: output not piped through scripts/ci/sanitize.sh: {line.strip()}")
    return v


def main():
    failures = 0
    workflows = sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")))
    if not workflows:
        print("FAIL: no workflows found")
        return 1
    for wf in workflows:
        problems = check(wf)
        if problems:
            failures += 1
            print(f"FAIL: {os.path.basename(wf)}")
            for p in problems:
                print(f"    - {p}")
        else:
            print(f"PASS: {os.path.basename(wf)} meets the workflow security policy")

    # Cross-workflow rules.
    docs = {os.path.basename(w): load(w)[0] for w in workflows}
    deploy, destroy = docs.get("deploy.yml"), docs.get("destroy.yml")
    if not deploy or not destroy:
        print("FAIL: deploy.yml and destroy.yml must both exist"); failures += 1
    else:
        groups = {(d.get("concurrency") or {}).get("group") for d in (deploy, destroy)}
        cancels = {(d.get("concurrency") or {}).get("cancel-in-progress") for d in (deploy, destroy)}
        if len(groups) == 1 and None not in groups and cancels == {False}:
            print("PASS: deploy and destroy share one non-cancelling concurrency group")
        else:
            print(f"FAIL: deploy/destroy concurrency groups {groups}, cancel-in-progress {cancels}"); failures += 1
        dj = deploy["jobs"]
        expect = {"plan": "azure-plan", "apply": "azure-deploy", "failure-cleanup": "azure-destroy"}
        got = {k: dj.get(k, {}).get("environment") for k in expect}
        ok = got == expect and dj["apply"].get("needs") == "plan" and destroy["jobs"]["destroy"].get("environment") == "azure-destroy"
        print(("PASS" if ok else "FAIL") + f": environments plan/apply/cleanup/destroy = {got}, destroy={destroy['jobs']['destroy'].get('environment')}")
        failures += 0 if ok else 1
        rm = [s for s in dj["apply"]["steps"] if "temp-access.sh remove" in (s.get("run") or "")]
        ok = bool(rm) and all(s.get("if") == "always()" for s in rm)
        print(("PASS" if ok else "FAIL") + ": apply job removes temporary runner access in an always() step")
        failures += 0 if ok else 1
        fc = dj["failure-cleanup"]
        ok = "always()" in str(fc.get("if")) and "needs.apply.result == 'failure'" in str(fc.get("if")) and "cancelled" in str(fc.get("if"))
        print(("PASS" if ok else "FAIL") + ": failure-cleanup runs when apply/validation fails or is cancelled")
        failures += 0 if ok else 1

    # The checker must reject known-bad workflows.
    expected = {
        "bad-pr-azure.yml": ["pull-request workflow references secrets", "pull-request job has id-token", "action not pinned"],
        "bad-unsafe-deploy.yml": ["forbidden trigger pull_request_target", "Azure job without a main-branch guard",
                                  "Azure job without an environment", "terraform apply must apply the saved",
                                  "artifacts are not allowed", "checkout must set persist-credentials", "not piped through"],
    }
    for fx, needles in expected.items():
        problems = "\n".join(check(os.path.join(ROOT, "tests", "workflows", "fixtures", fx)))
        missing = [n for n in needles if n not in problems]
        if missing:
            print(f"FAIL: checker did not reject {fx} for: {missing}"); failures += 1
        else:
            print(f"PASS: checker rejects fixtures/{fx} ({len(needles)} expected violations)")
    print(f"Workflow policy: {'FAILED' if failures else 'all checks passed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
