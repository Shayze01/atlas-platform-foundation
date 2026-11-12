# Validation log

This file records checks that were **actually executed** and their results.
Offline checks do not contact Azure and do not prove that a deployment works.

## 1. Offline checks - `./scripts/validate.sh` (executed 2026-11-12)

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

## 2. Additional manual checks (executed 2026-11-12, not part of `validate.sh`)

| Check | Expected | Result |
| --- | --- | --- |
| Mutation: SSH rule source changed to `*` | `networking` test fails | PASS - test failed as expected; change reverted |
| Mutation: `public_ip_address_id` removed from the NIC | `public_ip_attached_to_nic_for_explicit_outbound` fails | PASS - test failed as expected; change reverted |
| Mutation: `default_outbound_access_enabled = true` | `networking` test fails | PASS - test failed as expected; change reverted |
| Script tests run against the **previous** `verify-cleanup.sh` and `connectivity-check.sh` (which treated errors as absence and always exited 0) | Tests detect the old behaviour | PASS - 1 passed, 28 failed (only the custom-suffix scoping case passed on the old code); run in a scratch copy, repository unchanged |

After the Terraform mutation checks, `terraform test` was re-run on the
restored code: 9 passed, 0 failed.

## 3. Raw output of `./scripts/validate.sh`

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

## 4. Azure deployment checks - NOT executed

The following require an Azure subscription and have **not** been run. Record
results here (and screenshots in `docs/evidence/`) after you deploy:

| Check | Command / location | Result |
| --- | --- | --- |
| `terraform plan` shows 11 to add, all in `rg-atlas-foundation-dev` | README section 7 | not run |
| `terraform apply` succeeds | README section 7 | not run |
| `/health` returns 200 from admin IP | README section 8 | not run |
| Landing page shows "Atlas Platform Foundation" | README section 8 | not run |
| `scripts/connectivity-check.sh` exits 0 (14/14 PASS: HTTP status/body, key-authenticated SSH, `cloud-init status: done`, container healthy, effective `sshd -T` settings, only `publickey` offered) | README section 8 | not run |
| HTTP/SSH blocked from another network | README section 8 | not run |
| Outbound uses the VM's public IP (`curl -4 ifconfig.me` on the VM) | README section 10.3 | not run |
| `terraform destroy` + `scripts/verify-cleanup.sh` exits 0 (no `INCONCLUSIVE`) | README section 9 | not run |
| No new cost for `rg-atlas-foundation-dev` after deletion (Cost analysis, 24-48 h later) | README section 9 | not run |
