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
Milestone 3 additions:
  * packages: write only on build jobs without Azure access; no continue-on-error
  * the app address is masked wherever it is read and never written to summaries
  * lifetime gates precede apply and the inspection window; apply attempts are recorded
  * failure-cleanup and the hourly sweep destroy only through guarded-destroy.sh
  * the report job runs always, without Azure access, and fails on app failure
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
MASKED_VARS = ("ARM_TENANT_ID", "ARM_SUBSCRIPTION_ID", "ARM_CLIENT_ID", "TFSTATE_STORAGE_ACCOUNT")
SANITISED = re.compile(r"(terraform (init|apply|destroy|plan)|backend-init\.sh|azure-validate\.sh|verify-cleanup\.sh|temp-access\.sh remove|guarded-destroy\.sh|flow_check\.py|ui_check\.py)")
PRIVATE_OUTPUTS = re.compile(r"terraform output[^\n]*\b(web_url|health_url|ssh_command)\b")


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
        perms = job.get("permissions") or {}
        if isinstance(perms, dict) and perms.get("packages") == "write" and (id_token or job.get("environment")):
            v.append(f"{where}: packages: write on a job with Azure access (build jobs must have none)")
        if job.get("continue-on-error") or any(st.get("continue-on-error") for st in steps):
            v.append(f"{where}: continue-on-error would hide a failed test or cleanup")
        if is_pr and (id_token or job.get("environment")):
            v.append(f"{where}: pull-request job has id-token or an environment (Azure access)")
        if id_token:
            if not set(triggers) <= TRUSTED_AZURE_TRIGGERS:
                v.append(f"{where}: Azure job reachable from untrusted trigger(s) {sorted(set(triggers) - TRUSTED_AZURE_TRIGGERS)}")
            if not job.get("environment"):
                v.append(f"{where}: Azure job without an environment")
            if "github.ref == 'refs/heads/main'" not in str(job.get("if", "")):
                v.append(f"{where}: Azure job without a main-branch guard")
            first = (steps[0].get("run") or "") if steps else ""
            if "::add-mask::" not in first or not all(f"${{{var}}}" in first for var in MASKED_VARS):
                v.append(f"{where}: Azure identifiers are not masked by the first step ({', '.join(MASKED_VARS)})")
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
            if "public_ip_address" in run and "::add-mask::" not in run:
                v.append(f"{sw}: reads the app address without masking it")
            if PRIVATE_OUTPUTS.search(run):
                v.append(f"{sw}: prints a URL/SSH output to the public log")
            if "GITHUB_STEP_SUMMARY" in run and re.search(r"APP_IP|public_ip|http://", run):
                v.append(f"{sw}: writes the app address to the public run summary")
            if re.search(r"\bset -x\b|\bbash -x\b", run):
                v.append(f"{sw}: shell tracing would leak values")
            for line in run.splitlines():
                if SANITISED.search(line) and not line.strip().startswith("echo ") and "sanitize.sh" not in line and ">\"${RUNNER_TEMP}/plan.log\"" not in line:
                    v.append(f"{sw}: output not piped through scripts/ci/sanitize.sh: {line.strip()}")
    return v


# Commands a pipeline step may run; each is stubbed to fail on demand.
CMD = re.compile(r"(?:\./scripts/(?:ci/)?)?([\w-]+\.sh)\b|\b(terraform|az)\b")
STUBBED_SCRIPTS = ["ci/backend-init.sh", "ci/temp-access.sh", "ci/plan-summary.sh", "ci/runner-ip.sh",
                   "ci/wait-for-health.sh", "ci/guarded-destroy.sh", "ci/build-push.sh", "ci/inspection-window.sh",
                   "azure-validate.sh", "verify-cleanup.sh"]
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


def step_index(steps, pattern, key="run"):
    for i, st in enumerate(steps):
        if re.search(pattern, str(st.get(key) or "")):
            return i
    return -1


def m3_rules(dj, destroy_jobs):
    """Milestone 3 ordering and wiring rules for deploy.yml and destroy.yml. Returns failure count."""
    results = []
    build, plan, apply, fc, rep = (dj.get(k, {}) for k in ("build-image", "plan", "apply", "failure-cleanup", "report"))
    st = apply.get("steps") or []

    results.append(("build-image has packages: write and no Azure access",
                    (build.get("permissions") or {}).get("packages") == "write" and not build.get("environment")
                    and not perms_grant_id_token(build.get("permissions"))))
    results.append(("only build jobs may write packages",
                    all((j.get("permissions") or {}).get("packages") != "write" for k, j in dj.items() if k != "build-image")))
    penv = plan.get("env") or {}
    results.append(("scenario gating: plan derives EXPECTED_APP_VARIANT from inputs.scenario, not from the build output",
                    "inputs.scenario" in str(penv.get("EXPECTED_APP_VARIANT")) and "build-image" not in str(penv.get("EXPECTED_APP_VARIANT"))
                    and "needs.build-image.outputs.app_image" in str(penv.get("EXPECTED_APP_IMAGE"))))
    psteps = plan.get("steps") or []
    lt, tp = step_index(psteps, r"lifetime\.py plan"), step_index(psteps, r"terraform plan")
    results.append(("plan computes expiry (lifetime.py plan) before terraform plan and passes it as TF_VAR_expires_at",
                    0 <= lt < tp and "steps.lifetime.outputs.expires_at" in str((psteps[tp].get("env") or {}).get("TF_VAR_expires_at"))))
    gate, fetch = step_index(st, r"lifetime\.py pre-apply"), step_index(st, r"az storage blob download")
    attempt, tf_apply = step_index(st, r"attempted=true"), step_index(st, r"terraform apply")
    results.append(("pre-apply lifetime gate runs before the plan is fetched; it records stopped=true when it refuses",
                    0 <= gate < fetch and "stopped=true" in str(st[gate].get("run")) and st[gate].get("id") == "gate"))
    results.append(("apply attempt is recorded immediately before terraform apply",
                    attempt >= 0 and tf_apply == attempt + 1 and st[attempt].get("id") == "attempt"
                    and st[attempt].get("if") == st[tf_apply].get("if")))
    pre = step_index(st, r"state_snapshot\.py")
    results.append(("pre-apply state snapshot is taken before the attempt marker and passed to failure-cleanup",
                    0 <= gate < pre < attempt and st[pre].get("id") == "pre_state"
                    and "steps.pre_state.outputs.snapshot" in str((apply.get("outputs") or {}).get("pre_apply_snapshot"))
                    and "needs.apply.outputs.pre_apply_snapshot" in str((fc.get("env") or {}).get("PRE_APPLY_SNAPSHOT"))
                    and "needs.apply.outputs.apply_error" in str((fc.get("env") or {}).get("APPLY_ERROR"))))
    results.append(("report knows whether the plan had changes (no-change plans report real test results)",
                    "needs.plan.outputs.has_changes" in str((rep.get("env") or {}).get("HAS_CHANGES"))))
    blocked, wgate = step_index(st, r"azure-validate\.sh blocked"), step_index(st, r"lifetime\.py pre-window")
    window, destroy = step_index(st, r"inspection-window\.sh"), step_index(st, r"terraform destroy")
    results.append(("inspection window: after runner access is blocked, after the pre-window gate, only on decision == 'pass'",
                    0 <= blocked < wgate < window < destroy and "steps.window_gate.outputs.decision == 'pass'" in str(st[window].get("if"))
                    and "inputs.scenario == 'healthy'" in str(st[wgate].get("if"))))
    for sid in ("flow", "ui"):
        i = step_index(st, sid, key="id")
        results.append((f"application test '{sid}' runs after a failed earlier check (not cancelled) and is reported",
                        i >= 0 and "!cancelled()" in str(st[i].get("if")) and f"steps.{sid}.outcome" in str((apply.get("outputs") or {}).values())))
    fenv = fc.get("env") or {}
    fsteps = fc.get("steps") or []
    g = step_index(fsteps, r"MODE=failure-cleanup \./scripts/ci/guarded-destroy\.sh")
    results.append(("failure-cleanup destroys only via guarded-destroy.sh (if: always()), given this run's apply attempt and expiry",
                    g >= 0 and fsteps[g].get("if") == "always()" and step_index(fsteps, r"terraform destroy") == -1
                    and "needs.apply.outputs.apply_attempted" in str(fenv.get("APPLY_ATTEMPTED"))
                    and "needs.plan.outputs.expires_at" in str(fenv.get("OWN_EXPIRES_AT"))))
    results.append(("report runs always, without Azure access, after apply and failure-cleanup, via run-report.py",
                    rep.get("if") == "always()" and not perms_grant_id_token(rep.get("permissions")) and not rep.get("environment")
                    and {"apply", "failure-cleanup"} <= set(rep.get("needs") or []) and step_index(rep.get("steps") or [], r"run-report\.py") >= 0))
    sweep, dest = destroy_jobs.get("expiry-sweep", {}), destroy_jobs.get("destroy", {})
    ssteps = sweep.get("steps") or []
    results.append(("hourly sweep destroys only via guarded-destroy.sh (MODE=sweep); nightly/manual destroy is a separate job",
                    "github.event.schedule == '17 * * * *'" in str(sweep.get("if")) and "github.event.schedule != '17 * * * *'" in str(dest.get("if"))
                    and step_index(ssteps, r"MODE=sweep \./scripts/ci/guarded-destroy\.sh") >= 0 and step_index(ssteps, r"terraform destroy") == -1
                    and sweep.get("environment") == "azure-destroy"))
    for name, ok in results:
        print(("PASS" if ok else "FAIL") + f": {name}")
    return sum(1 for _, ok in results if not ok)


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
        print(("PASS" if ok else "FAIL") + ": failure-cleanup runs when apply/validation fails, is cancelled or is not approved")
        failures += 0 if ok else 1
        failures += m3_rules(dj, destroy["jobs"])
        # Control: the M3 rules must notice an unconditional destroy in failure-cleanup and a missing gate.
        import copy
        bad = copy.deepcopy(dj)
        bad["failure-cleanup"]["steps"].append({"if": "always()", "run": "terraform destroy -auto-approve | ./scripts/ci/sanitize.sh"})
        bad["apply"]["steps"] = [x for x in bad["apply"]["steps"] if "pre-apply" not in str(x.get("run"))]
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            caught = m3_rules(bad, destroy["jobs"])
        print(("PASS" if caught >= 2 else "FAIL") + f": control - M3 rules catch an unconditional failure-cleanup destroy and a missing pre-apply gate ({caught} failures)")
        failures += 0 if caught >= 2 else 1

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
    for wf_name, job_id in (("destroy.yml", "destroy"),):
        steps = (docs.get(wf_name) or {}).get("jobs", {}).get(job_id, {}).get("steps") or []
        late = [st for st in steps if re.search(r"terraform destroy|verify-cleanup\.sh", st.get("run") or "")]
        ok = len(late) == 2 and all(st.get("if") == "always()" for st in late)
        print(("PASS" if ok else "FAIL") + f": {wf_name}:{job_id} destroy and cleanup verification run with if: always()")
        failures += 0 if ok else 1

    # The mask step must register every non-empty identifier and tolerate an empty one.
    ids = {"ARM_TENANT_ID": "11111111-1111-1111-1111-111111111111", "ARM_SUBSCRIPTION_ID": "22222222-2222-2222-2222-222222222222",
           "ARM_CLIENT_ID": "", "TFSTATE_STORAGE_ACCOUNT": "stexample123"}
    for wf_name, doc in docs.items():
        for job_id, job in (doc.get("jobs") or {}).items():
            if not perms_grant_id_token(job.get("permissions")):
                continue
            run = ((job.get("steps") or [{}])[0].get("run") or "")
            res = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", run],
                                 env=dict(os.environ, **ids), capture_output=True, text=True)
            want = [f"::add-mask::{val}" for val in ids.values() if val]
            ok = res.returncode == 0 and res.stdout.split() == want
            print(("PASS" if ok else "FAIL") + f": {wf_name}:{job_id} first step masks the Azure identifiers (empty values skipped)")
            failures += 0 if ok else 1

    # The checker must reject known-bad workflows.
    expected_m3 = {"bad-m3-deploy.yml": ["packages: write on a job with Azure access", "continue-on-error would hide",
                                         "reads the app address without masking", "prints a URL/SSH output",
                                         "writes the app address to the public run summary"]}
    expected = {
        "bad-pr-azure.yml": ["pull-request workflow references secrets", "pull-request job has id-token", "action not pinned",
                             "defaults.run.shell must be bash"],
        "bad-unsafe-deploy.yml": ["forbidden trigger pull_request_target", "Azure job without a main-branch guard",
                                  "Azure job without an environment", "terraform apply must apply the saved",
                                  "artifacts are not allowed", "checkout must set persist-credentials", "not piped through",
                                  "Azure identifiers are not masked"],
    }
    for fx, needles in {**expected, **expected_m3}.items():
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
