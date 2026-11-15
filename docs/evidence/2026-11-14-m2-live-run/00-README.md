# First live Milestone 2 run (2026-11-14)

GitHub Actions run [43588089749](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/43588089749):
**Deploy**, `workflow_dispatch` on `main` at `4c0674b`, `after_validation = destroy`.
Result: **success**. Times are UTC (= UK time, GMT, on this date).

| Job | Start -> end (UTC) | Result |
| --- | --- | --- |
| Plan (sanitised summary), environment `azure-plan` | 11:02:28 -> 11:02:58 | success |
| `azure-deploy` review | approved by `Shayze01` after the plan summary was reviewed | approved |
| Apply reviewed plan and validate, environment `azure-deploy` | 11:16:39 -> 11:21:57 | success |
| Cleanup after failed or cancelled deployment | - | **skipped** (nothing failed, so this path was not exercised) |

Workload lifetime: created by `terraform apply` 11:16:58-11:17:39, destroyed by 11:21:54
(about 5 minutes).

## Files

| File | Step(s) |
| --- | --- |
| `01-plan.log` | OIDC login (plan identity, immutable subject), backend init, sanitised plan summary with 9 policy checks, private plan upload |
| `02-apply.log` | OIDC login (deploy identity), backend init, plan SHA-256 check, apply (11 added), stored plan deleted |
| `03-temp-access-add.log` | Runner IP (masked), temporary `/32` rule added, wait for `/health` |
| `04-public.log` | Public checks from the runner: 5 passed |
| `05-in-vm.log` | In-VM checks via Azure Run Command: 10 passed |
| `06-temp-access-remove.log` | Temporary rule removed and confirmed absent |
| `07-blocked.log` | Blocked checks: 3 passed |
| `08-destroy-verify-cleanup.log` | `terraform destroy` (11 destroyed) and `verify-cleanup.sh` with `KEEP_RESOURCE_GROUP=1` |

## How these files were produced

- Extracted from the public GitHub job logs: step output only. Command echo, `env:` and
  action-input blocks were dropped.
- In the job log, GitHub had already masked the environment secrets as `***`
  (administrator CIDR, SSH public key, owner tag). The client ID is a variable, not a
  secret: `azure/login` masks it only from its own step onwards, so it is still shown
  in clear in the `env:` blocks of the earlier steps. `scripts/ci/sanitize.sh` had
  replaced IP addresses, GUIDs and the public key in piped output.
- Extraction additionally replaced every remaining GUID (including truncated
  subscription IDs in Terraform's `Still destroying... [id=/subscriptions/...]` progress
  lines, which `sanitize.sh` did not catch) with `<guid>` and every IPv4 address
  outside `10.0.0.0/8` with `<ip>`.
- Note: the public job log itself still shows the subscription and tenant IDs (in every
  step's `env:` block and in those truncated progress lines) and the client ID (in
  `env:` blocks before the login step). They are identifiers, not
  credentials, and the workflows are unchanged by this documentation PR.

Not stored anywhere public: the raw plan, the state, the administrator IP, the SSH key
or the owner-run bootstrap/setup output.
