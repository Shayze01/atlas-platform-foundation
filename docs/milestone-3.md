# Milestone 3: support-ticket application on Atlas

**Status (2026-11-16): implemented and tested offline only (Stages 1-4). No live Azure
run of Milestone 3 yet.** Live runs (Stage 7) follow implementation review and the owner
setup in Stage 6. The reviewed design is [`milestone-3-design.md`](milestone-3-design.md)
(revision 3); this page is the implementation guide.

| Stage | Content | PR |
| --- | --- | --- |
| 1 | Atlas Service Desk demo (Flask/Gunicorn, SQLite, fictional data), container, local tests, browser preview | #6 (merged) |
| 2 | Deliberate fault build `broken-ignore-status`; the independent tests catch it; the healthy image has no fault code | #7 |
| 3 | Terraform `app_image`/`app_variant`/`expires_at`, cloud-init pull-by-digest + guest expiry timer, plan policy, `azure-validate` for the ticket app, expiry-tag carriers and state-to-Azure mapping | #8 |
| 4 | Workflows: image build, scenarios, lifetime gates, inspection window, guarded failure-cleanup, hourly sweep, report | #9 |
| 5 | Documentation, validation log, offline evidence (this) | #10 |

## How a Deploy run works

```text
build-image  (no Azure)   build the scenario's target only -> push to GHCR -> digest
plan         (azure-plan) ExpiresAt = now + 45 min approval allowance + budget
                          -> terraform plan -> 14 fail-closed policy checks -> sanitised summary
             (approval)   owner reviews digest, variant, ExpiresAt, policy -> approves azure-deploy
apply        (azure-deploy) gate 1 (full budget incl. margin, safety nets) -> fetch plan, verify SHA-256
                          -> attempted=true -> terraform apply -> mask address -> runner /32
                          -> public + in-VM checks (digest, expiry timer) -> API flow test -> browser test
                          -> remove runner /32 (always) -> confirm blocked
                          -> gate 2 -> inspection window (full or not at all) -> destroy + verify
failure-cleanup (azure-destroy) guarded destroy: only what this run attempted to apply
report       (no Azure)   Application / Inspection / Cleanup / Run result rows; fails unless the app passed
```

Inputs: `scenario` = `healthy` (default) or `deliberate-failure-ignore-status`;
`inspection_minutes` = 0, 15, **30** (default) or 45 (ignored for the failure scenario).

## Lifetime and the safety nets

Budget = provision 20 + tests 15 + inspection + cleanup 20 + margin 10 minutes.

- **Plan:** `ExpiresAt` = now + 45 + budget (healthy, 30 min: 140 min), capped at 3 h.
- **Gate 1 (before apply):** the full budget, margin included, must fit before `ExpiresAt`.
  Otherwise the step records `stopped=true` and nothing is created.
- **Gate 2 (before the inspection window):** window + cleanup + margin must fit. Otherwise
  the window is **not started** (never shortened), the workload is destroyed and the run fails.
- **Safety nets** an environment must never be alive across:
  - the **02:00 UK auto-shutdown** (02:00 UTC on GMT, **01:00 UTC on BST**);
  - the **03:30 UTC nightly Destroy** (guarded from 03:20 UTC).

  `scripts/ci/lifetime.py` converts with `Europe/London`.

## Times after deployment (no single "URL stops working" guarantee)

| Time | What happens | Limits |
| --- | --- | --- |
| Inspection end | in-job destroy starts (usually done in about 10 min) | only if the apply job is alive |
| `ExpiresAt` (guest app stop) | the VM timer stops the app and deletes the ticket volume; the boot-time check never starts it again | only while the VM runs; doesn't stop billing |
| `ExpiresAt` + 15 min | hourly sweep may destroy | GitHub may delay or skip it |
| 03:30 UTC | nightly Destroy (unconditional) | same as the sweep |

If every layer fails, resources keep billing (about £0.30-0.36/day running, £0.15-0.16/day
deallocated) until removed by hand: see the manual recovery in the design, section 12.

## Guarded cleanup

`scripts/ci/guarded-destroy.sh` with `scripts/ci/expiry_decision.py` and
`scripts/ci/expiry_map.py`:

- **Carriers** (tagged `ExpiresAt`): VNet, NSG, public IP, NIC, VM, auto-shutdown schedule.
- **Children:**
  - subnet and NSG association → VNet;
  - all NSG rules → NSG;
  - the VM's OS disk is a managed child of the VM.
- **Never in the workload state:** the resource group. Its presence in state is a problem.
- **Hourly sweep:**
  - **destroys** only when every carrier has the same valid `ExpiresAt`, state and Azure agree, and `ExpiresAt` + 15 min has passed;
  - **protects** (INCONCLUSIVE, the run fails) on any missing, malformed, conflicting or mismatched tag, an expiry more than 3 h ahead, a state↔Azure difference, a read error or a state lock.
- **failure-cleanup:**
  - **destroys** when this run attempted apply;
  - otherwise applies exactly the sweep rules (destroys only expired environments);
  - **never** destroys an unexpired environment when apply was not attempted (an equal `ExpiresAt` is not proof of ownership).
- **Scope:** only `rg-atlas-foundation-dev`. It never touches the state backend, the identities or the group itself.

## Private URL and network access

The address is masked as soon as it's read, and is never written to logs or summaries
(enforced by the workflow policy tests). During the window I send the owner, in the private
session, the read-only Cloud Shell command that prints the IP. The NSG allows 80/22 only from
`ADMIN_SOURCE_IP_CIDR` (one `/32`), plus the runner's temporary `/32` during the automated
tests. That rule is removed and confirmed blocked before the window starts. HTTP only, no
app login.

## Ticket data

The data is a SQLite file in the `atlas-tickets-data` Docker volume on the VM's OS disk. It
is deleted by the guest app stop or with the VM. It is not in state, GitHub, logs or the image.
CI tickets are labelled `CI-TEST <run id>`. In the Stage 1 preview the data sits in a named
volume on Devin's VM: it survives container restarts and re-creation, and is deleted only
with that volume.

## Owner setup before live runs (Stage 6)

1. Run **Build image** once, then make the `atlas-tickets` GHCR package public.
2. Set the `ADMIN_SOURCE_IP_CIDR` secret to your current IP `/32`.
3. Approve each `azure-deploy` after reviewing the plan.

No new Azure roles, environments or federated credentials are needed.

## Tested offline vs not yet tested

Offline results are in [`validation-log.md`](validation-log.md) sections 12-15.
**Not live-tested:**
- the GHCR pull and digest check on a real VM;
- the guest timer and boot-time check;
- the hourly sweep;
- failure-cleanup and the `azure-destroy` credential;
- a rejected approval triggering failure-cleanup;
- job outputs after a cancelled apply (if lost, the workload is protected until it expires, then the sweep destroys it);
- the lifetime gates refusing live;
- the 02:00 auto-shutdown and nightly Destroy;
- Playwright from the runner;
- that `az resource list` matches the mapping fixture exactly.

Costs are estimates pending billing data.
