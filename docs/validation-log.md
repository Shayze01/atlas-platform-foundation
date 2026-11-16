# Validation log

This file records checks that were **actually executed** and their results.
Offline checks do not contact Azure and do not prove that a deployment works.

## 1. HISTORICAL - offline checks before deployment (executed 2026-11-12)

> Historical record, kept unchanged. The code has changed since (temporary test
> rule, auto-shutdown, validation-script fixes). The current offline result is in
> [section 5](#5-offline-checks-after-deployment-executed-2026-11-13).

Environment: Ubuntu 22.04.5 LTS (x86_64), Terraform v1.9.8, azurerm provider
5.13.0 (from `.terraform.lock.hcl`), Docker Engine 29.9.2, cloud-init 26.1,
ShellCheck 0.11.0. The local web test used the default base image
`nginxinc/nginx-unprivileged:1.30-alpine` from Docker Hub.

### Summary: 10 passed, 0 failed, 0 skipped

| # | Check | Result | Detail |
| --- | --- | --- | --- |
| 1 | `terraform fmt -check -recursive` | PASS | No formatting differences. |
| 2 | `terraform init -backend=false` | PASS | azurerm v5.13.0 from the lock file. |
| 3 | `terraform validate` | PASS | "The configuration is valid." |
| 4 | `terraform test` (mocked provider) | PASS | 9/9 runs passed, 0 failed, 0 skipped. |
| 5 | Render cloud-init | PASS | `build/cloud-init.rendered.yaml` produced. |
| 6 | Embedded app files unchanged | PASS | 4/4 files match `./app`. |
| 7 | `cloud-init schema` | PASS | "Valid schema". |
| 8 | Script behaviour tests (stubs, no network) | PASS | 29/29 cases passed (13 `verify-cleanup.sh`, 16 `connectivity-check.sh`), 0 failed. |
| 9 | `shellcheck` | PASS | No findings in `app/run-container.sh`, `scripts/*.sh`, `tests/scripts/*.sh`, `tests/scripts/stubs/*`. |
| 10 | Local web service test (Docker) | PASS | 9/9 checks passed. |

`terraform test` runs (all PASS):

| File | Run | Result |
| --- | --- | --- |
| `tests/compute.tftest.hcl` | `vm_uses_ssh_keys_only` | PASS |
| `tests/compute.tftest.hcl` | `public_ip_attached_to_nic_for_explicit_outbound` | PASS |
| `tests/networking.tftest.hcl` | `nsg_allows_only_admin_ip_on_ssh_and_http` | PASS |
| `tests/root.tftest.hcl` | `plan_with_valid_inputs` | PASS |
| `tests/root.tftest.hcl` | `rejects_internet_wide_source` | PASS |
| `tests/root.tftest.hcl` | `rejects_ip_range_wider_than_32` | PASS |
| `tests/root.tftest.hcl` | `rejects_ip_without_prefix` | PASS |
| `tests/root.tftest.hcl` | `rejects_private_key` | PASS |
| `tests/root.tftest.hcl` | `rejects_reserved_admin_username` | PASS |

Script behaviour tests use stub `az`, `terraform`, `curl`, `ssh` and `timeout`
commands (`tests/scripts/stubs/`) placed first on `PATH`; no Azure or network
calls are made. Each case and its result appears in the raw output below.

## 2. HISTORICAL - additional manual checks (executed 2026-11-12, not part of `validate.sh`)

| Check | Expected | Result |
| --- | --- | --- |
| Mutation: SSH rule source changed to `*` | `networking` test fails | PASS - test failed as expected; change reverted |
| Mutation: `public_ip_address_id` removed from the NIC | `public_ip_attached_to_nic_for_explicit_outbound` fails | PASS - test failed as expected; change reverted |
| Mutation: `default_outbound_access_enabled = true` | `networking` test fails | PASS - test failed as expected; change reverted |
| Script tests run against the **previous** `verify-cleanup.sh` and `connectivity-check.sh` (which treated errors as absence and always exited 0) | Tests detect the old behaviour | PASS - 1 passed, 28 failed (only the custom-suffix scoping case passed on the old code); run in a scratch copy, repository unchanged |

After the Terraform mutation checks, `terraform test` was re-run on the
restored code: 9 passed, 0 failed.

## 3. HISTORICAL - raw output of `./scripts/validate.sh` (2026-11-12)

```text

==> terraform fmt -check -recursive

==> terraform init -backend=false
Initializing modules...
Initializing provider plugins...
- Reusing previous version of hashicorp/azurerm from the dependency lock file
- Using previously-installed hashicorp/azurerm v5.13.0

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.

==> terraform validate
Success! The configuration is valid.


==> terraform test (mocked provider, no Azure calls)
tests/compute.tftest.hcl... in progress
  run "vm_uses_ssh_keys_only"... pass
  run "public_ip_attached_to_nic_for_explicit_outbound"... pass
tests/compute.tftest.hcl... tearing down
tests/compute.tftest.hcl... pass
tests/networking.tftest.hcl... in progress
  run "nsg_allows_only_admin_ip_on_ssh_and_http"... pass
tests/networking.tftest.hcl... tearing down
tests/networking.tftest.hcl... pass
tests/root.tftest.hcl... in progress
  run "plan_with_valid_inputs"... pass
  run "rejects_internet_wide_source"... pass
  run "rejects_ip_range_wider_than_32"... pass
  run "rejects_ip_without_prefix"... pass
  run "rejects_private_key"... pass
  run "rejects_reserved_admin_username"... pass
tests/root.tftest.hcl... tearing down
tests/root.tftest.hcl... pass

Success! 9 passed, 0 failed.

==> Render cloud-init
Rendered: build/cloud-init.rendered.yaml

==> Rendered cloud-init embeds ./app files unchanged
PASS: /opt/atlas/app/Dockerfile matches app/Dockerfile
PASS: /opt/atlas/app/nginx.conf matches app/nginx.conf
PASS: /opt/atlas/app/index.html matches app/index.html
PASS: /opt/atlas/app/run-container.sh matches app/run-container.sh

==> cloud-init schema validation
2026-11-12 22:13:09,188 - sources[WARNING]: failed loading pickle in /var/lib/cloud/instance/obj.pkl: [Errno 13] Permission denied: '/var/lib/cloud/instance/obj.pkl'
2026-11-12 22:13:09,190 - log_util.py[WARNING]: Failed pickling datasource to /var/lib/cloud/instance/obj.pkl
2026-11-12 22:13:09,191 - log_util.py[WARNING]: Getting data from <class 'cloudinit.sources.DataSourceNone.DataSourceNone'> failed
2026-11-12 22:13:09,198 - schema.py[WARNING]: datasource not detected, using default instance-data/user-data paths.
Valid schema build/cloud-init.rendered.yaml

==> Script behaviour tests (stubbed az/terraform/curl/ssh, no network)
== verify-cleanup.sh ==
PASS: cleanup: all resources absent -> exit 0
PASS: cleanup: custom suffix stays scoped to its own resource group
PASS: cleanup: remaining resource group, public IP and state -> exit 1
PASS: cleanup: not logged in (az account show fails) -> exit 2, authentication
PASS: cleanup: expired token on queries -> exit 2, authentication
PASS: cleanup: AuthorizationFailed -> exit 2, permission
PASS: cleanup: network failure -> exit 2, network
PASS: cleanup: unexpected Azure error -> exit 2, unexpected
PASS: cleanup: unexpected 'az group exists' output -> exit 2
PASS: cleanup: one lookup hits a network error -> exit 2, others still PASS
PASS: cleanup: failed 'terraform state list' is not an empty state -> exit 2
PASS: cleanup: no state file in this folder -> exit 2
PASS: cleanup: remaining resources take precedence over inconclusive -> exit 1

== connectivity-check.sh ==
PASS: connectivity: everything healthy -> exit 0
PASS: connectivity: /health returns HTTP 500 -> exit 1
PASS: connectivity: /health 200 but wrong body -> exit 1
PASS: connectivity: landing page missing title -> exit 1
PASS: connectivity: HTTP timeout -> exit 1
PASS: connectivity: HTTP connection refused -> exit 1
PASS: connectivity: SSH timeout never counts as password auth disabled -> exit 1
PASS: connectivity: probe timeout with working key session -> exit 1
PASS: connectivity: key rejected -> exit 1
PASS: connectivity: password authentication enabled -> exit 1
PASS: connectivity: sshd -T unreadable (sudo fails) -> exit 1
PASS: connectivity: cloud-init error -> exit 1
PASS: connectivity: container unhealthy -> exit 1
PASS: connectivity: TCP ports closed -> exit 1
PASS: connectivity: Terraform outputs missing -> exit 2
PASS: connectivity: SSH key missing -> exit 2

Script tests: 29 passed, 0 failed (of 29)

==> shellcheck

==> Local web service test (Docker)
Building and starting container (log: build/test-web-local.log) ...
Waiting for http://127.0.0.1:8088/health ...
PASS: /health returns HTTP 200 (got 200)
PASS: /health body reports ok: {"status":"ok","service":"atlas-platform-foundation"}
PASS: / returns HTTP 200 (got 200)
PASS: / displays 'Atlas Platform Foundation'
PASS: unknown path returns HTTP 404 (got 404)
PASS: nginx version hidden (Server: nginx)
PASS: container runs as non-root (uid 101)
PASS: container root filesystem is read-only
Waiting for Docker HEALTHCHECK ...
PASS: Docker HEALTHCHECK reports healthy (got healthy)

All local web service checks passed.

================ Summary ================
PASS | terraform fmt -check -recursive
PASS | terraform init -backend=false
PASS | terraform validate
PASS | terraform test (mocked provider, no Azure calls)
PASS | Render cloud-init
PASS | Rendered cloud-init embeds ./app files unchanged
PASS | cloud-init schema validation
PASS | Script behaviour tests (stubbed az/terraform/curl/ssh, no network)
PASS | shellcheck
PASS | Local web service test (Docker)
Passed: 10  Failed: 0  Skipped: 0
Azure deployment checks are NOT part of this script (see README sections 7-9).
```

## 4. Azure deployment checks (executed 2026-11-13, East US)

Deployed from the saved, user-approved plan `deploy.tfplan` by a certificate-based
service principal holding **Contributor on `rg-atlas-foundation-dev` only**.
Sanitised raw output is in [`evidence/2026-11-13-deployment/`](evidence/2026-11-13-deployment/)
(subscription ID and all IP addresses redacted; `<test-ip-a>`/`<test-ip-b>` are the two
temporary test sources, `<admin-ip>` is the administrator's /32; before publication the
administrator's SSH public key, its fingerprint and the `Owner` tag value were also redacted).
Times are UTC (= UK time, GMT, on this date).

### 4.1 Results

| # | Check | How / where it ran | Result | Evidence |
| --- | --- | --- | --- | --- |
| 1 | `terraform plan` | `deploy.tfplan`: 12 to add, 1 to change (RG `Owner` tag), 0 to destroy | PASS | plan reviewed before apply |
| 2 | `terraform apply deploy.tfplan` (23:10:32-23:11:24) | Terraform, VM size `Standard_B2ats_v2` | PASS - 12 added, 1 changed, 0 destroyed | `01-apply.log` |
| 3 | Landing page: HTTP 200 + "Atlas Platform Foundation" | **Public**, from a temporary test source | PASS | `02-public.log` |
| 4 | `/health`: HTTP 200 + `"status":"ok"` | **Public**, from a temporary test source | PASS | `02-public.log` |
| 5 | No-key SSH refused with `Permission denied (publickey)` | **Public** | PASS | `02-public.log` |
| 6 | `cloud-init status` = `status: done` | **In-VM** (Azure Run Command) | PASS | `04-in-vm-rerun.log` |
| 7 | Container `atlas-web` health = `healthy`; local `/health` 200 + ok | **In-VM** (Run Command) | PASS | `04-in-vm-rerun.log` |
| 8 | Effective `sshd -T`: passwordauthentication no, kbdinteractiveauthentication no, permitrootlogin no, pubkeyauthentication yes | **In-VM** (Run Command) | PASS on rerun (first run FAIL, see 4.2) | `03-in-vm.log`, `04-in-vm-rerun.log` |
| 9 | Admin key fingerprint `SHA256:<admin-key-fingerprint-redacted>` in `authorized_keys` | **In-VM** (Run Command) | PASS | `04-in-vm-rerun.log` |
| 10 | Outbound IP seen from inside the VM = the NIC's Standard public IP | **In-VM** (Run Command) | PASS | `04-in-vm-rerun.log` |
| 11 | NIC has the Standard static public IP attached; subnet `defaultOutboundAccess = False` | Azure CLI | PASS | `05-resources.log` |
| 12 | Auto-shutdown schedule: Enabled, 0200, `GMT Standard Time`, `ComputeVmShutdownTask` | Azure CLI | PASS (configuration only; it was **not** observed firing) | `05-resources.log` |
| 13 | Temporary test rule removed by `terraform apply` (0 added, 0 changed, 1 destroyed) | Terraform | PASS | `06-remove-test-rule.log` |
| 14 | NSG has exactly admin SSH/HTTP from `<admin-ip>/32` + Internet deny, no temporary rule | Azure CLI | PASS on rerun (first run stopped, see 4.2) | `07-blocked.log`, `08-blocked-rerun.log` |
| 15 | HTTP and TCP/22 from the former test sources no longer connect | **Public** | PASS | `08-blocked-rerun.log` |
| 15a | VM ED25519 host key = `SHA256:Kk8+pxM3zOLQELEZtzMmE57OOwDZPFjJ2P0NyeHbzaU` (matches fingerprint seen on admin laptop) | **In-VM** (Run Command) | PASS | `09-hostkey.log` |
| 16 | Key-authenticated SSH login from the administrator's laptop | administrator's laptop (private key never left it) | PASS - key session succeeded; cloud-init done, container healthy, effective sshd settings correct; `/health` 200 from admin IP | `09b-admin-laptop-keylogin.log` |
| 17 | `terraform destroy` | Terraform | PASS - 12 destroyed (23:20:26-23:22:36 UTC), including the resource group | `10-destroy.log` |
| 18 | `scripts/verify-cleanup.sh` exit 0 | Azure CLI + Terraform state | PASS - exit 0: state empty, `ResourceGroupNotFound` for the RG, all 6 exact names not found, 0 inconclusive (23:22:59 UTC) | `11-verify-cleanup.log` |
| 19 | No new cost for `rg-atlas-foundation-dev` after deletion | Cost analysis, 24-48 h later | not run (billing data lags) | - |

### 4.2 Problems found and fixed during deployment

- **`sshd -T` failed in-VM** with `Missing privilege separation directory: /run/sshd`.
  Ubuntu 24.04 starts SSH through `ssh.socket`, so `/run/sshd` does not exist until
  sshd first runs, and `sshd -T` refuses to run without it. The four effective-config
  checks therefore reported FAIL (never PASS). Fix: `scripts/azure-validate.sh` and
  `scripts/connectivity-check.sh` now run `install -d -m 0755 /run/sshd` before
  `sshd -T`. Rerun: 10/10 PASS. Script tests: 44/44 PASS, ShellCheck clean.
- **First blocked-mode run stopped (exit 2)** because `EXPECTED_ADMIN_CIDR` was not
  set; rerun with it set: 3/3 PASS.
- **Blocked-mode probe classification tightened after the deployment.** The live
  run on 2026-11-13 (`08-blocked-rerun.log`) used the earlier script, which
  counted curl exit 7 or 28 as blocked and **any** failed TCP connect as blocked.
  Its recorded result was curl exit 28 for HTTP; the TCP line did not record why
  the connect failed. The script now passes only a connect-phase timeout, treats
  refused/unreachable connections, probe-tool errors, missing tools, invalid
  options and a failed Internet control request as INCONCLUSIVE (exit 2), and was
  re-tested offline only (section 5). The live logs are kept as recorded.
- The in-VM key-fingerprint check is skipped unless `ADMIN_PUBKEY_FILE` is set; the
  rerun set it.

### 4.3 Limitations

- Public checks came from two temporary /32 test sources, not from the admin IP.
- "Blocked" was proven only for the former test sources, not for every other network.
- The 02:00 auto-shutdown was confirmed as configured, not observed running.
- Key login is recorded as passed only if the administrator ran it and reported output.

## 5. Offline checks after deployment (executed 2026-11-13)

New run, separate from the historical section 1 and the live Azure results in
section 4. No Azure access was used. Raw output:
[`evidence/offline-validate-2026-11-13.log`](evidence/offline-validate-2026-11-13.log).

Environment: Ubuntu 22.04.5 LTS (x86_64), Terraform v1.9.8, azurerm provider
5.13.0 (lock file), Docker Engine 29.9.2, cloud-init 26.1, ShellCheck 0.11.0.

### Summary: 10 passed, 0 failed, 0 skipped (`./scripts/validate.sh`, exit 0)

| # | Check | Result | Detail |
| --- | --- | --- | --- |
| 1 | `terraform fmt -check -recursive` | PASS | No differences. |
| 2 | `terraform init -backend=false` | PASS | azurerm v5.13.0 from the lock file. |
| 3 | `terraform validate` | PASS | "The configuration is valid." |
| 4 | `terraform test` (mocked provider) | PASS | 15 passed, 0 failed. |
| 5 | Render cloud-init | PASS | |
| 6 | Embedded app files unchanged | PASS | 4/4 files match `./app`. |
| 7 | `cloud-init schema` | PASS | "Valid schema". |
| 8 | Script behaviour tests (stubs, no network) | PASS | 60 passed, 0 failed (13 `verify-cleanup.sh`, 16 `connectivity-check.sh`, 31 `azure-validate.sh`). |
| 9 | `shellcheck` | PASS | No findings. |
| 10 | Local web service test (Docker) | PASS | 9/9 checks passed. |

Changes covered by this run: `azure-validate.sh` blocked-mode probe
classification and argument/tool checks (16 new script cases and one changed
case: NSG read error is now exit 2 INCONCLUSIVE instead of exit 1), and test
fixtures using only RFC 5737 documentation addresses.

## 6. Milestone 2 offline checks (executed 2026-11-14, feature branch)

New run on the Milestone 2 branch, separate from every result above. **No Azure or
GitHub resources were created or changed**; the bootstrap, GitHub setup and workflows
have not run for real yet. Raw output:
[`evidence/offline-validate-2026-11-14-m2.log`](evidence/offline-validate-2026-11-14-m2.log).

Command: `REQUIRE_ALL=1 ./scripts/validate.sh` (a skipped check would fail the run).
Environment: Ubuntu 22.04.5 LTS, Terraform v1.9.8, azurerm 5.13.0, Docker 29.9.2,
cloud-init 26.1, ShellCheck 0.11.0, actionlint 1.7.12, PyYAML 5.4.1.

### Summary: 12 passed, 0 failed, 0 skipped (exit 0)

| # | Check | Result | Detail |
| --- | --- | --- | --- |
| 1 | `terraform fmt -check -recursive` | PASS | |
| 2 | `terraform init -backend=false` | PASS | |
| 3 | `terraform validate` | PASS | |
| 4 | `terraform test` (mocked provider) | PASS | 17 passed, 0 failed (2 new: resource group created by default / existing group used when `create_resource_group = false`). |
| 5 | Render cloud-init | PASS | |
| 6 | Embedded app files unchanged | PASS | |
| 7 | `cloud-init schema` | PASS | |
| 8 | Script behaviour tests | PASS | 110 passed, 0 failed: 18 `verify-cleanup.sh` (5 new), 16 `connectivity-check.sh`, 31 `azure-validate.sh`, 10 `bootstrap.sh`, 6 `teardown.sh`, 5 `setup-github.sh`, 24 `scripts/ci/*`. |
| 9 | Workflow security policy tests | PASS | `ci.yml`, `deploy.yml`, `destroy.yml` pass; 4 cross-workflow rules pass; both bad fixtures rejected. |
| 10 | `actionlint` | PASS | No findings. |
| 11 | `shellcheck` | PASS | No findings (now includes `bootstrap/`, `scripts/ci/`, `scripts/github/`, `stubs-m2/`). |
| 12 | Local web service test (Docker) | PASS | 9/9 checks. |

Not yet verified (requires the owner-run setup and an approved live window): OIDC
login with the customised subject, Reader being sufficient for `terraform plan`, Run
Command and NSG changes with the RG-scoped Contributor role, storage lifecycle and
lock behaviour, the GitHub environment approval flow, and the first `ci.yml` run on
GitHub.

## 7. Milestone 2 offline checks after review fixes (executed 2026-11-14)

Second offline run on the PR branch after three requested fixes. No Azure or GitHub
resources were created or changed. Section 6 stays as the earlier record. Raw output:
[`evidence/offline-validate-2026-11-14-m2-r2.log`](evidence/offline-validate-2026-11-14-m2-r2.log).

Fixes covered:
1. `defaults.run.shell: bash` in all workflows (GitHub then runs `bash -eo pipefail`).
   The policy test runs every piped step with each command failing in turn: deploy.yml
   16/16 and destroy.yml 4/4 injected failures fail the step (backend init, apply,
   public/in-VM/blocked validation, temporary-rule removal, destroy, cleanup
   verification). Control: under GitHub's default `bash -e`, 14/16 would have been masked.
2. `bootstrap/teardown.sh` validates the state blob as a Terraform v4 state before
   counting; `{}`, `null`, empty file, malformed JSON, missing or wrong-type
   `resources`, entries without a valid `mode`, version 3, and an unexpected
   `az group exists` answer are each inconclusive (exit 2) with no deletions. The empty-file
   case found a real gap (jq returned success on empty input), now fixed with `--slurp`.
3. The plan summary adds allowlisted details and 9 fail-closed policy checks
   (`scripts/ci/plan_policy.py`); 13 non-compliant or unevaluable plan fixtures each
   exit 1 with no plan outputs written.

### Summary: 12 passed, 0 failed, 0 skipped (`REQUIRE_ALL=1`, exit 0)

| Check | Result |
| --- | --- |
| `terraform fmt`, `init -backend=false`, `validate` | PASS |
| `terraform test` | PASS - 17/17 |
| cloud-init render, embedded files, schema | PASS |
| Script behaviour tests | PASS - 134/134 (24 new: 9 teardown state-validation, 15 plan policy/details) |
| Workflow security policy tests | PASS - incl. pipefail injection and control |
| actionlint, ShellCheck | PASS |
| Local web service test (Docker) | PASS - 9/9 |

Still not verified live: everything listed at the end of section 6.


## 8. OIDC subject fix after live GitHub setup (executed 2026-11-14)

**Live observation (not an offline check).** After the owner ran `bootstrap/bootstrap.sh --apply`
and `scripts/github/setup-github.sh --apply`, GitHub's API reported for this repository
`use_immutable_subject: true` and `sub_claim_prefix: repo:Shayze01@99360721/atlas-platform-foundation@1457226611`.
GitHub always uses this immutable format for repositories created after 2026-07-15. The
federated credentials created by the first bootstrap expected the old name-only subject
(`repo:Shayze01/atlas-platform-foundation:environment:<env>:ref:refs/heads/main`), so
Azure sign-in would have failed (`AADSTS70021`). No Deploy run had been started.

Fix: `bootstrap.sh` builds the immutable subject from the owner and repository IDs
(defaults for this repository; `--github-owner-id`/`--github-repo-id` for another
`--github-repo`), and re-running it updates a federated credential whose subject differs
(or whose issuer or audience differs) instead of skipping it. `setup-github.sh` sets `use_immutable_subject: true` explicitly.
Raw output: [`evidence/offline-validate-2026-11-14-m2-r3.log`](evidence/offline-validate-2026-11-14-m2-r3.log).

### Summary: 12 passed, 0 failed, 0 skipped (`REQUIRE_ALL=1`, exit 0)

| Check | Result |
| --- | --- |
| `terraform test` | PASS - 17/17 |
| Script behaviour tests | PASS - 139/139 (5 new: legacy subjects updated in place, correct subjects unchanged, wrong issuer/audience repaired, other repo without IDs refused, non-numeric ID refused) |
| Workflow security policy tests, actionlint, ShellCheck | PASS |
| Local web service test (Docker) | PASS - 9/9 |

Still not verified live: Azure accepting the GitHub token, role sufficiency, lifecycle filters
and the approval flow (section 6 list, minus the GitHub environment settings now observed).

## 9. First live Milestone 2 run (executed 2026-11-14, East US)

GitHub Actions run [43588089749](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/43588089749)
(Deploy, `main` at `4c0674b`, `after_validation = destroy`). Sanitised step output:
[`evidence/2026-11-14-m2-live-run/`](evidence/2026-11-14-m2-live-run/). Times are UTC.

Before the run, the owner ran `bootstrap/bootstrap.sh` (dry run, then `--apply`: 16
changes) and `scripts/github/setup-github.sh` (dry run, then `--apply`), then updated
the three federated credential subjects to the immutable format (section 8). Those
outputs were reviewed in the working session and are not stored in the repository.

### 9.1 Live-tested in this run

| # | Behaviour | Result | Evidence |
| --- | --- | --- | --- |
| 1 | OIDC login, plan identity, `azure-plan` immutable subject | PASS | `01-plan.log` |
| 2 | Remote state backend init with Entra ID (no storage keys) | PASS | `01-plan.log`, `02-apply.log` |
| 3 | Plan with Reader on the (empty) workload group: `add=11 change=0 destroy=0 replace=0` | PASS | `01-plan.log` |
| 4 | Sanitised summary and 9 fail-closed policy checks (size, region, disk, password auth, 02:00 shutdown, /32 sources, Internet deny, no temporary rule, no implicit outbound) | PASS - 9/9 | `01-plan.log` |
| 5 | Reviewed plan stored privately, `azure-deploy` approval required and given by the owner | PASS | `01-plan.log`, run page |
| 6 | OIDC login, deploy identity, `azure-deploy` immutable subject | PASS | `02-apply.log` |
| 7 | Downloaded plan SHA-256 matched the reviewed hash before apply (`tfplan: OK`). | PASS | `02-apply.log` |
| 8 | Apply exactly that plan: 11 added, 0 changed, 0 destroyed; stored plan deleted | PASS | `02-apply.log` |
| 9 | Temporary `/32` rule for the runner added (TCP 22, 80); web service healthy after 45 s | PASS | `03-temp-access-add.log` |
| 10 | Public checks: `/` 200 + page text, `/health` 200 + ok, SSH offers only `publickey` | PASS - 5/5 | `04-public.log` |
| 11 | In-VM checks with Run Command under Contributor: cloud-init done, container healthy, local `/health`, effective sshd settings, admin key present, outbound via NIC public IP | PASS - 10/10 | `05-in-vm.log` |
| 12 | Temporary rule removed and confirmed absent | PASS | `06-temp-access-remove.log` |
| 13 | NSG has exactly the intended rules; HTTP and SSH from the runner time out | PASS - 3/3 | `07-blocked.log` |
| 14 | Destroy after validation: 11 destroyed; state tracks no resources; workload group kept and empty; VM, disk, NIC, IP, NSG, VNet not found | PASS | `08-destroy-verify-cleanup.log` |
| 15 | No administrator IP, SSH key or owner tag in the job log (masked or sanitised) | PASS (checked by search) | all files |

### 9.2 Not live-tested yet

- **Failure cleanup** (`failure-cleanup` job): skipped because nothing failed. Destroy
  after a failed or cancelled apply has only stubbed tests and pipefail injection.
- **Deliberate plan hash-mismatch rejection**: the successful run verified a matching hash;
  rejection of a deliberately mismatched plan was not exercised live.
- **`azure-destroy` federated credential and `destroy.yml`**: neither the manual nor the
  scheduled (03:30 UTC) Destroy workflow has run. The routine destroy above ran inside
  the Deploy job under `azure-deploy`.
- **02:00 UK auto-shutdown**: the schedule was planned with the approved settings (policy
  check), but the VM existed for about 5 minutes; it has never been observed firing.
- **`keep-running`** option, shared-concurrency blocking, state-lock contention and
  recovery (lease break, version restore, soft-delete restore), lifecycle-rule expiry of
  plans and old state versions.
- **Plan with existing resources** (Reader refreshing a non-empty group).
- **`bootstrap/teardown.sh`** (complete teardown) has not been run.

### 9.3 Cost (estimate, pending billing data)

By list prices in `docs/milestone-2.md` section 8, about 5 minutes of VM, public IP and
disk is roughly £0.001 excluding VAT (under £0.01 including VAT). The persistent
bootstrap resources are estimated at well under £0.01/month. Not yet confirmed against
Azure Cost Management, which reports with a delay.


## 10. Log-masking hardening after the first live run (executed 2026-11-15, offline)

**Why:** the public job log of run 43588089749 (section 9) showed Azure identifiers that
the evidence files had to redact by hand. These are identifiers, not credentials:
- Terraform's `Still destroying... [id=/subscriptions/xxxxxxxx-...]` progress lines show a
  truncated subscription ID, which `scripts/ci/sanitize.sh` missed because it only matched
  complete GUIDs.
- The tenant, subscription and client IDs and the storage account name are GitHub
  *variables*, not secrets, so they appeared in every step's `env:` block.

**Changes:**
- `sanitize.sh` masks truncated GUIDs (`<guid>...`) and truncated `/subscriptions/` prefixes.
  Run over the recorded live apply log, 0 `Still destroying` lines keep the raw prefix.
- The first step of every Azure job (`plan`, `apply`, `failure-cleanup`, `destroy`)
  registers `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `ARM_CLIENT_ID` and
  `TFSTATE_STORAGE_ACCOUNT` with `::add-mask::`, skipping empty values.

No Azure deployment was run for this change.
Raw output: [`evidence/offline-validate-2026-11-15-masking.log`](evidence/offline-validate-2026-11-15-masking.log).

### Summary: 12 passed, 0 failed, 0 skipped (`REQUIRE_ALL=1`, exit 0)

| Check | Result |
| --- | --- |
| `terraform test` | PASS - 17/17 |
| Script behaviour tests | PASS - 140/140 (1 new: truncated GUIDs in Terraform progress lines masked, unrelated ellipses kept; fails against the previous `sanitize.sh`, 139/140) |
| Workflow security policy tests | PASS (new: every Azure job's first step masks all four identifiers; an empty value is skipped, not registered as a bare `::add-mask::`) |
| actionlint, ShellCheck | PASS |
| Local web service test (Docker) | PASS - 9/9 |

### Remaining limitation

- GitHub prints a step's `env:` header before the step runs, so the first (masking) step
  of each Azure job still shows the four identifiers once in clear. Every later step shows
  `***`. Removing that last occurrence would mean storing them as secrets, which changes
  `setup-github.sh` and the owner's GitHub configuration. It was not done.
- `sanitize.sh` is pattern-based: it masks only values piped through it that match its
  patterns (IPv4, full or truncated GUIDs, SSH keys/fingerprints, SAS signatures).
- Not yet verified live: the masking first appears in the next real Deploy or Destroy run log.

## 11. Milestone 3 Stage 1: ticket app, container and local tests (executed 2026-11-15, offline)

**Scope:** the healthy Atlas Service Desk demo app (`tickets-app/`: Flask + Gunicorn,
SQLite, fictional data only), its Docker image, and local tests. Terraform, cloud-init,
`app/` (the Milestone 2 page) and all workflows are unchanged. Nothing was deployed to
Azure. See [`tickets-app/README.md`](../tickets-app/README.md).

Raw output: [`evidence/offline-validate-2026-11-15-m3-stage1.log`](evidence/offline-validate-2026-11-15-m3-stage1.log).

### Summary: 13 passed, 0 failed, 0 skipped (`REQUIRE_ALL=1`, exit 0)

| Check | Result |
| --- | --- |
| Existing 12 checks (Terraform, cloud-init, script tests 140/140, workflow policy, actionlint, ShellCheck, Milestone 2 web test 9/9) | PASS, unchanged |
| New: ticket app (`scripts/test-tickets-local.sh`) | PASS - unit tests 13/13 inside the image (incl. write lock taken before reading on update); 10 container/hardening checks; independent API flow check (exit 0); Playwright/Chromium browser check (exit 0; includes no horizontal overflow at 375px and a visible error for an overlong title); data kept across restart and deleted with the volume; Docker healthcheck healthy |

### Not covered by Stage 1

- The deliberately broken variant and the test-the-test (Stage 2).
- Azure deployment, image registry, digest pinning on the VM, expiry, cleanup and the
  live tests (Stages 3-7).
- Browsers other than Chromium; load or concurrent users; accessibility beyond basic
  labels.

## 12. Milestone 3 Stage 2: deliberate fault build and test-the-test (executed 2026-11-16, offline)

**Scope:** a clearly labelled Docker target `broken-ignore-status` (`PATCH` answers 200
but drops status changes), proof that the unchanged independent tests catch it, and proof
that the healthy image contains none of the fault. Terraform, cloud-init, `app/` and all
workflows are unchanged. Nothing was built for a registry or deployed to Azure. See
[`tickets-app/README.md`](../tickets-app/README.md#deliberate-fault-build-broken-ignore-status).

Raw output: [`evidence/offline-validate-2026-11-16-m3-stage2.log`](evidence/offline-validate-2026-11-16-m3-stage2.log).

### Summary: 13 passed, 0 failed, 0 skipped (`REQUIRE_ALL=1`, exit 0)

| Check | Result |
| --- | --- |
| Existing 12 checks and all Stage 1 ticket-app checks (unit tests 13/13, hardening, flow exit 0, browser exit 0, data lifecycle, healthcheck) | PASS, unchanged |
| A build without `--target` produces the healthy image (`healthy` is the last Dockerfile stage) | PASS |
| Healthy image: no `atlas.deliberate-fault` label, no `fault_*` file anywhere, no fault strings under `/app` | PASS |
| Fault image: labelled `broken-ignore-status`, adds exactly one file (`/app/fault_ignore_status.py`), `/version` and the UI banner say "DELIBERATE FAULT BUILD" | PASS |
| Independent API flow check against the fault image | PASS - **fails as required**: exit 3, `status mismatch: expected 'In progress', got 'Open'` |
| Browser check against the fault image | PASS - **fails as required**: exit 3, `status mismatch after reload: expected 'In progress', got 'Open'` |
| Fault confined to status: a priority-only update still saves on the fault image | PASS |

### Not covered by Stage 2

- Building or publishing either image in CI for deployment, and the plan policy that
  allows the fault image only for `scenario=deliberate-failure-ignore-status` (Stages 3-4).
- Any live run of the fault image, `failure-cleanup` or the report job (Stage 7).


## 13. Milestone 3 Stage 3: image by digest, expiry tags and timer, plan policy, mapping (executed 2026-11-16, offline)

Raw output: [`evidence/offline-validate-2026-11-16-m3-stage3.log`](evidence/offline-validate-2026-11-16-m3-stage3.log). **15 passed, 0 failed, 0 skipped.**

| Check | Result |
| --- | --- |
| `terraform test`: digest-only `app_image`, variant, exact real-UTC `expires_at`, `ExpiresAt`/`AppVariant` tags, cloud-init pins image and expiry | 23/23 (6 new rejections) |
| Rendered cloud-init: embedded scripts byte-for-byte, env file, timer `OnCalendar` in UTC with `Persistent=true`, no build/tag, 5.4 KB; schema valid | 10/10 |
| Expiry-tag carriers and state-to-Azure mapping on a complete deployment (all rules, association, managed OS disk), drift guard against the `.tf` files, every protect-on-uncertainty case | 23/23 |
| Guest scripts: past expiry never starts the app and deletes data; a pull spanning the expiry never starts it; malformed/impossible/missing expiry, tag, foreign namespace, digest mismatch refused; env file never executed; guest app stop succeeds only after Docker confirms the container and volume are absent (already absent OK; failed removal, stuck volume or unreachable Docker exit 1, no marker) | 16/16 |
| Plan policy (14 checks) incl. fault build refused for `healthy`, healthy refused for the failure scenario, cap, missing carrier tag, cloud-init mismatch; `azure-validate` digest/timer/variant checks | script tests 158/158 |

## 14. Milestone 3 Stage 4: workflows, lifetime gates, guarded cleanup, sweep, report (executed 2026-11-16, offline)

Raw output: [`evidence/offline-validate-2026-11-16-m3-stage4.log`](evidence/offline-validate-2026-11-16-m3-stage4.log). **19 passed, 0 failed, 0 skipped.**

| Owner requirement (2026-11-16) | Test | Result |
| --- | --- | --- |
| 1. Full safety margin; recheck before the window; never shorten it | `tests/lifetime/test_lifetime.py` (95 min left passes, 94 refused; window at exactly 60 min passes, 59 refused; no "shortened" output; start inside 03:20-03:30 UTC refused) | 19/19 |
| 2. 02:00 UK auto-shutdown and 03:30 UTC Destroy with time-zone conversion | same file: GMT 02:00 UTC vs BST 01:00 UTC at the same clock time, spring-forward and autumn-back nights, 03:20 UTC guard, constants match `variables.tf` and the cron | included above |
| 3. Carriers/mapping, protect on uncertainty | `tests/expiry/test_guarded_destroy.py`: every revision 2 section 6.3 row incl. state lock; destroy only on DESTROY; no call to the backend, identities or group delete; an equal ExpiresAt without an apply attempt is protected; after an apply attempt, ownership from state snapshots (section 17) | 42/42 |
| 4. Stopped before apply vs apply attempted; rejected plan keeps a pre-existing unexpired environment | `test_rejected_plan_never_destroys_a_preexisting_unexpired_environment` (+ NOOP, own-expiry, uncertain cases; apply-attempted cases in section 17); workflow policy enforces snapshot/marker/gate order and catches a mutated unconditional destroy | PASS |
| Separate application/cleanup results | `tests/expiry/test_run_report.py` (incl. failed deployment check with passing tests = FAILED; no-change plan pass/fail, section 17) | 16/16 |
| Image build and inspection window scripts | `tests/scripts/test-ci-helpers.sh` (stub docker, fake clock) | 11/11 |
| Private URL, no `continue-on-error`, packages scope, gate/window order, guarded cleanup wiring | workflow policy tests (15 new rules + 2 controls) | PASS |

## 15. Milestone 3 Stage 5: documentation (2026-11-16)

Owner requirement 5: the design is now revision 3 ([`milestone-3-design.md`](milestone-3-design.md)):
- **Baseline:** `ac8a1a2` (merged Stage 1).
- **Paths:**
  - app: `tickets-app/`;
  - tests: `tests/app/unit/`, `tests/app/flow_check.py`, `tests/app/ui/ui_check.py` and `scripts/test-tickets-local.sh`.
- **Preview wording:** preview data lives in a named Docker volume. It survives container restarts and re-creation, and is deleted only with the volume.
- **New sections:** the lifetime gates, the safety-net time zones, the carrier mapping and the failure-cleanup decision table are documented in sections 6.2-6.4. Changes are listed in section 17.

Docs-only stage. The full offline suite was re-run on this branch; raw output: [`evidence/offline-validate-2026-11-16-m3-stage5.log`](evidence/offline-validate-2026-11-16-m3-stage5.log).

### Still not live-tested after Stages 1-5
- **Image and VM:** the GHCR pull and digest check, the guest timer and the boot-time check.
- **Cleanup:**
  - the hourly sweep;
  - failure-cleanup with the `azure-destroy` credential;
  - a rejected approval;
  - outputs after a cancelled apply;
  - the lifetime gates refusing live.
- **Safety nets:** the auto-shutdown and the nightly Destroy.
- **Tests and mapping:** Playwright from the runner, and `az resource list` matching the mapping fixture.
- **Costs:** billing data.

## 16. Pre-merge fixes (2026-11-16, offline)

Owner review before merging, carried up through the stacked branches:

| Fix | Branch | Test | Result |
| --- | --- | --- | --- |
| `atlas-expire.sh` reports success only after Docker confirms the `atlas-tickets` container and `atlas-tickets-data` volume are absent. Removal or verification failure exits 1 and writes no expired marker; the boot-time path in `run-tickets.sh` propagates it | Stage 3 (#8) | `tests/scripts/test-guest-expiry.sh`: normal removal, already absent, container removal fails, volume stuck, Docker unreachable, boot after expiry with a failed removal | 16/16 |
| Tracked `scripts/ci/__pycache__/plan_policy.cpython-310.pyc` removed; `.gitignore` keeps `__pycache__/` and `*.pyc` | Stage 2 (#7) | `git ls-files` has no `.pyc` on any branch | PASS |
| Devin Review fixes from #8 (expiry recheck around `docker run`) and #9 (equal ExpiresAt not ownership, "Deployment job" report row, 03:20-03:30 UTC band) | #8, #9 | sections 13-14 | PASS |

The full offline suite was re-run on each branch and the evidence logs replaced:
- Stage 3: 15 passed, 0 failed.
- Stage 4: 19 passed, 0 failed.
- Stage 5: 19 passed, 0 failed.

The guest app stop and its failure exit are **not live-tested**.

## 17. Devin Review fixes on #9: failed-apply ownership and no-change reports (2026-11-16, offline)

Owner rules (2026-11-16): compare state lineage and serial before and after apply without treating an unchanged serial as proof Azure is untouched; protect pre-existing unexpired resources when apply is refused without changes; a changed serial alone never authorises destroying an existing environment; unreadable state, persistence failure or uncertain ownership is INCONCLUSIVE with recovery; a no-change plan reports the real test results.

| Case | Test (`tests/expiry/test_guarded_destroy.py` unless stated) | Decision |
| --- | --- | --- |
| Stale plan, pre-existing unexpired environment | `test_stale_plan_protects_preexisting_unexpired_environment` | PROTECT, no destroy |
| Lock rejection, pre-existing unexpired environment | `test_lock_rejection_protects_preexisting_unexpired_environment` | PROTECT, no destroy |
| Refused apply, environment expired / state empty | `test_rejected_apply_with_expired_environment_follows_sweep_rules`, `test_rejected_apply_into_empty_state_is_noop` | DESTROY / NOOP |
| Unchanged serial, but Azure has an unrecorded resource or a changed tag | `test_unchanged_serial_does_not_prove_azure_untouched` | INCONCLUSIVE |
| Unchanged serial, state differs from the snapshot | `test_unchanged_serial_but_different_state_is_inconclusive` | INCONCLUSIVE |
| Partial apply over a pre-existing unexpired environment (mixed tags) | `test_partial_apply_over_preexisting_unexpired_environment_is_inconclusive` | INCONCLUSIVE |
| Changed serial, every carrier now this run's `ExpiresAt`, environment existed before | `test_changed_serial_alone_never_authorises_destroying_a_preexisting_environment` | INCONCLUSIVE |
| Changed pre-existing environment that had itself expired | `test_changed_preexisting_environment_that_had_expired_is_destroyed` | DESTROY |
| Fresh deployment (complete or partial) from an empty state with this run's `ExpiresAt` | `test_attempt_fresh_deployment_*`, `test_partial_apply_from_empty_state_destroys_only_what_it_created` | DESTROY + verify |
| Partial apply from empty state, foreign `ExpiresAt` | `test_partial_apply_from_empty_state_with_foreign_expiry_is_inconclusive` | INCONCLUSIVE |
| State persistence failure | `test_state_persistence_failure_is_inconclusive` | INCONCLUSIVE, manual recovery |
| State read failure (`show`, `state pull`, invalid state) or Azure list failure | `test_state_read_failures_after_attempt_are_inconclusive` | INCONCLUSIVE |
| Missing or invalid pre-apply snapshot; lineage replaced; serial backwards | `test_missing_or_bad_pre_apply_snapshot_is_inconclusive`, `test_replaced_state_lineage_or_older_serial_is_inconclusive` | INCONCLUSIVE |
| Snapshot content: hashed lineage, addresses incl. indexes, data sources skipped, no state yet, invalid input | `StateSnapshot` (3 tests) | PASS |
| No-change plan, both tests pass | `tests/expiry/test_run_report.py::test_no_change_plan_with_passing_tests_passes` | PASSED |
| No-change plan, API flow fails | `test_no_change_plan_with_failing_test_fails` | FAILED |
| No-change plan, tests pass but deployment check, window or cleanup fails | `test_no_change_plan_still_needs_deployment_window_and_cleanup` (4 sub-cases) | FAILED |
| Workflow wiring: snapshot before the attempt marker, passed to failure-cleanup with the apply error; report gets `HAS_CHANGES` | `tests/workflows/test_workflow_policy.py` (2 new rules) | PASS |

Terraform 1.9.8 locally (local backend, `terraform_data`, no Azure): a stale saved plan fails with "Saved plan is stale" and a held lock with "Error acquiring the state lock"; the serial stayed unchanged in both. These are the strings the workflow classifies.

Totals: guarded cleanup 42/42 (was 23), report 16/16 (was 12). Full offline suite re-run on Stage 4 and Stage 5: 19 passed, 0 failed, 0 skipped (step count unchanged; the new tests are inside existing steps).

**Not live-tested:** the pre-apply snapshot with the `azure-deploy` identity, apply-error classification against the Azure backend, and every failure-cleanup decision above against real Azure.
