# Milestone 3 live runs (2026-11-17)

Four **Deploy** runs, all `workflow_dispatch` on `main` at `73e4fb4`. Times are UTC
(= UK time, GMT, on this date). Each `azure-deploy` approval was given by the owner after
reviewing the plan summary. No application URL or public IP appears in any job log or file here.

| Run | Scenario, window | Plan | App tests | Deployment job | Window | Cleanup | Run result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [44181640588](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/44181640588) | `healthy`, 0 min | 11 add, policy 14/14 | PASS | PASS | n/a | PASS (in-job destroy, verified) | **PASSED** |
| [44183827536](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/44183827536) | `deliberate-failure-ignore-status`, 0 min | 11 add, policy 14/14 | **FAIL** (expected: API and browser both caught the status bug) | FAIL | n/a (disabled for this scenario) | PASS (failure-cleanup: DESTROY, verified) | **FAILED** (correct) |
| [44186665828](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/44186665828) | `healthy`, 15 min | 11 add, policy 14/14 | PASS | PASS | DONE, 15 min in full | PASS (in-job destroy, verified) | **PASSED** |
| [44191447996](https://github.com/Shayze01/atlas-platform-foundation/actions/runs/44191447996) | `healthy`, 15 min | 11 add, policy 14/14 | PASS | PASS | DONE, 15 min in full | PASS (in-job destroy, verified) | **PASSED** |

| Run | Image digest (`ghcr.io/shayze01/atlas-tickets@sha256:...`) | `ExpiresAt` | Plan SHA-256 | Apply job (UTC) | Window (UTC) |
| --- | --- | --- | --- | --- | --- |
| 44181640588 | `4cae72c1...2aee` (healthy) | 2026-11-17T23:28:00Z | `38eb0d9b...736c` | 21:38:57 -> 21:44:59 | - |
| 44183827536 | `a50f2c79...1586` (broken-ignore-status) | 2026-11-17T23:41:00Z | `ba8b0bc3...5439` | 21:51:55 -> 21:55:50 (failed) | - |
| 44186665828 | `fadfa9b8...375f` (healthy) | 2026-11-18T00:13:00Z | `dd6df82d...af5f` | 22:08:33 -> 22:30:16 | 22:12:57 -> 22:27:57 |
| 44191447996 | `9abbaf98...b6bc` (healthy) | 2026-11-18T00:42:00Z | `6962d4bd...2bfd` | 22:37:08 -> 22:57:44 | 22:40:51 -> 22:55:51 |

Full digests and hashes are in each run's log. Every run built and pushed a new image, so
the digests differ; each plan accepted only the digest built in its own run.

## What each run shows

- **Healthy automated (44181640588):** public checks 7/7, in-VM checks 12/12 (running image
  is exactly the planned digest; guest expiry timer armed), API flow and browser check passed,
  temporary runner rule removed, runner blocked again on 80 and 22, 11 destroyed and cleanup verified.
  `failure-cleanup` was skipped.
- **Deliberate failure (44183827536):** the broken image deployed and passed the same
  deployment checks (public 7/7, in-VM 12/12). The API flow failed with
  `status mismatch: expected 'In progress', got 'Open'` (exit 3), and the browser check with
  `status mismatch after reload: expected 'In progress', got 'Open'`. The apply job failed,
  so the in-job destroy did not run. **`failure-cleanup` ran** with the `azure-destroy`
  credential: decision `DESTROY` because "every workload resource was created by this run
  (the pre-apply state was empty) and carries this run's ExpiresAt", 11 destroyed, cleanup
  verified, `RESULT (failure-cleanup): DESTROYED`. The report kept the run **FAILED** with
  application FAIL and cleanup PASS on separate rows.
- **First inspection run (44186665828):** automation, the pre-window gate (45 min needed, full
  margin kept), the full 15-minute window and cleanup all passed. **Owner-reported:** the
  owner's browser could not reach the app because `ADMIN_SOURCE_IP_CIDR` held an outdated IP.
  The NSG therefore blocked the owner, as designed; the job log shows only `admin <ip>`.
- **Inspection retry (44191447996):** automation, the pre-window gate, the full 15-minute
  window and cleanup passed. **Owner-reported:** the owner tested the app manually during the
  window. No specific manual actions are recorded here.

## Files

| File | Run |
| --- | --- |
| `01-healthy-automated.log` | 44181640588 |
| `02-deliberate-failure.log` | 44183827536 |
| `03-inspection-first.log` | 44186665828 |
| `04-inspection-retry.log` | 44191447996 |

## How these files were produced

- Extracted from the public GitHub job logs of each job (build, plan, apply, failure-cleanup,
  report): result lines only (`PASS`/`FAIL`/`RESULT`/`STEP`, gate and window lines,
  apply/destroy totals, decision and report tables). Command echo, `env:` blocks and setup
  output were dropped; repeated lines were collapsed.
- GitHub had already masked secrets as `***`, and `sanitize.sh` had replaced IPs, GUIDs and
  the public key in piped output. Extraction additionally replaced any remaining GUID with
  `<guid>` and any IPv4 address outside `10.0.0.0/8` with `<ip>`; none remained.
- The files were checked for IP addresses, GUIDs, URLs, host names and SSH keys before commit.
