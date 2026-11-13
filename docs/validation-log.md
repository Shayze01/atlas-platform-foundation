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

