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
import shutil
import subprocess
import sys
import tempfile

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
    if ((doc.get("defaults") or {}).get("run") or {}).get("shell") != "bash":
        v.append(f"{name}: defaults.run.shell must be bash (GitHub then adds -o pipefail)")
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


# Commands a pipeline step may run; each is stubbed to fail on demand.
CMD = re.compile(r"(?:\./scripts/(?:ci/)?)?([\w-]+\.sh)\b|\b(terraform|az)\b")
STUBBED_SCRIPTS = ["ci/backend-init.sh", "ci/temp-access.sh", "ci/plan-summary.sh", "ci/runner-ip.sh",
                   "ci/wait-for-health.sh", "azure-validate.sh", "verify-cleanup.sh"]
STUB = '#!/usr/bin/env bash\nn="$(basename "$0")"\n[[ "$n" == "${FAIL_CMD:-}" ]] && { echo "boom from $n"; exit 3; }\necho "ok from $n"\n'


def github_shell(doc):
    """The shell GitHub uses for a run step: explicit bash adds pipefail; the default does not."""
    shell = ((doc.get("defaults") or {}).get("run") or {}).get("shell")
    return ["bash", "--noprofile", "--norc", "-eo", "pipefail"] if shell == "bash" else ["bash", "-e"]


def pipeline_steps(doc):
    for job_id, job in (doc.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            run = step.get("run") or ""
            if re.search(r"(?<!\|)\|(?!\|)", run) and "${{" not in run:
                yield job_id, step.get("name", "?"), run


def pipefail_failures(doc, shell):
    """Run each piped step with every command in it failing in turn.
    Returns (masked, checked): failures that still exited 0, and total runs."""
    masked, checked = [], 0
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "scripts", "ci"))
        os.makedirs(os.path.join(tmp, "bin"))
        shutil.copy(os.path.join(ROOT, "scripts", "ci", "sanitize.sh"), os.path.join(tmp, "scripts", "ci"))
        for rel in STUBBED_SCRIPTS + ["../bin/terraform", "../bin/az"]:
            path = os.path.normpath(os.path.join(tmp, "scripts", rel))
            with open(path, "w") as f:
                f.write(STUB)
            os.chmod(path, 0o755)
        env = dict(os.environ, PATH=os.path.join(tmp, "bin") + os.pathsep + os.environ["PATH"],
                   RUNNER_TEMP=tmp, GITHUB_STEP_SUMMARY=os.path.join(tmp, "summary"),
                   GITHUB_OUTPUT=os.path.join(tmp, "out"), GITHUB_ENV=os.path.join(tmp, "env"))
        for job_id, name, run in pipeline_steps(doc):
            script = os.path.join(tmp, "step.sh")
            with open(script, "w") as f:
                f.write(run)
            names = sorted({m.group(1) or m.group(2) for m in CMD.finditer(run)} - {"sanitize.sh"})
            for cmd in names:
                checked += 1
                rc = subprocess.run(shell + [script], cwd=tmp, env=dict(env, FAIL_CMD=cmd),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
                if rc == 0:
                    masked.append(f"{job_id} / {name}: failing '{cmd}' still exited 0")
    return masked, checked


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
        ok = "has_changes" not in str(dj["apply"].get("if")) and any(
            "has_changes == 'true'" in str(st.get("if")) and "terraform apply" in (st.get("run") or "") for st in dj["apply"]["steps"])
        print(("PASS" if ok else "FAIL") + ": apply job also runs for a no-change plan (validates/destroys a kept workload); only the apply step is skipped")
        failures += 0 if ok else 1
        fc = dj["failure-cleanup"]
        ok = "always()" in str(fc.get("if")) and "needs.apply.result == 'failure'" in str(fc.get("if")) and "cancelled" in str(fc.get("if"))
        print(("PASS" if ok else "FAIL") + ": failure-cleanup runs when apply/validation fails or is cancelled")
        failures += 0 if ok else 1

    # Pipeline failures must fail the step (and therefore trigger cleanup).
    for wf_name in ("deploy.yml", "destroy.yml", "ci.yml"):
        doc = docs.get(wf_name)
        if not doc:
            continue
        masked, checked = pipefail_failures(doc, github_shell(doc))
        if masked or (wf_name != "ci.yml" and checked == 0):
            print(f"FAIL: {wf_name}: a failing command is hidden by a later pipeline stage:")
            for m in masked or ["no piped steps found to test"]:
                print(f"    - {m}")
            failures += 1
        else:
            print(f"PASS: {wf_name}: every one of {checked} injected command failures in piped steps fails the step")
    # Control: GitHub's default shell (bash -e, no pipefail) WOULD hide them, so the test is sensitive.
    masked, checked = pipefail_failures(deploy or {}, ["bash", "-e"])
    if masked:
        print(f"PASS: control - without pipefail {len(masked)} of {checked} injected failures in deploy.yml would be masked")
    else:
        print("FAIL: control - the pipefail test did not detect masking without pipefail"); failures += 1
    # Cleanup steps must run even after an earlier step failed.
    for wf_name, job_id in (("deploy.yml", "failure-cleanup"), ("destroy.yml", "destroy")):
        steps = (docs.get(wf_name) or {}).get("jobs", {}).get(job_id, {}).get("steps") or []
        late = [st for st in steps if re.search(r"terraform destroy|verify-cleanup\.sh", st.get("run") or "")]
        ok = len(late) == 2 and all(st.get("if") == "always()" for st in late)
        print(("PASS" if ok else "FAIL") + f": {wf_name}:{job_id} destroy and cleanup verification run with if: always()")
        failures += 0 if ok else 1

    # The checker must reject known-bad workflows.
    expected = {
        "bad-pr-azure.yml": ["pull-request workflow references secrets", "pull-request job has id-token", "action not pinned",
                             "defaults.run.shell must be bash"],
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
