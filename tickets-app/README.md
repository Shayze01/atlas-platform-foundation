# Atlas Service Desk (demo) — Milestone 3, Stages 1-2

A small support-ticket web app used to prove the Atlas application deployment and
testing flow. **Fictional data only.** It is not connected to any real organisation,
system or data source.

Status: the healthy app, its container and local tests (Stage 1), plus a clearly
labelled deliberate fault build and the proof that the independent tests catch it
(Stage 2). It is **not yet deployed to Azure**; Terraform, cloud-init and workflows are
unchanged (later stages).

## What it does

- List tickets, filter by status and priority.
- Create a ticket (title, requester, priority Low/Medium/High/Critical, description).
- Open a ticket, change its status (Open, In progress, Resolved, Closed) and priority,
  and see its activity history.
- Banner: environment name and planned expiry (from `ATLAS_EXPIRES_AT`, format
  `YYYY-MM-DDTHH:MM:SSZ`; anything else is ignored). Footer: image variant and revision.

API: `GET/POST /api/tickets`, `GET/PATCH /api/tickets/<id>`, `GET /api/environment`,
`GET /health`, `GET /version`. Writes require `Content-Type: application/json`.

## Runtime and image

- Python 3.12, Flask served by Gunicorn (2 workers, port 8080), SQLite.
- Base image `python:3.12-slim` pinned by digest; Python packages pinned by version and
  SHA-256 hash in `requirements.txt` (`pip --require-hashes --no-deps`, wheels only).
- Docker target `healthy`; labels `org.opencontainers.image.revision` and
  `atlas.variant=healthy`. It is the last stage in the Dockerfile, so a build without
  `--target` is healthy.
- Runs as UID 10001 with a read-only root filesystem; only `/var/lib/atlas-tickets`
  (data volume) and `/tmp` are writable. Gunicorn access logs are off (they would
  record client IPs).

## Deliberate fault build (`broken-ignore-status`)

**For the deliberate-failure test scenario only.** Built only with
`docker build --target broken-ignore-status tickets-app`.

- **Fault:** `PATCH /api/tickets/<id>` returns 200 but silently drops the status change,
  so the ticket stays `Open`. Priority updates still save, so the fault is confined to
  status.
- **Where the fault lives:** one file, `faults/fault_ignore_status.py`. It wraps the
  normal app (Gunicorn entry point `fault_ignore_status:app`); the application package
  itself is identical in both images.
- **Labelling:** image labels `atlas.variant=broken-ignore-status` and
  `atlas.deliberate-fault="status updates are ignored"`; `/version` reports the variant;
  the UI shows a red banner "DELIBERATE FAULT BUILD - status updates are ignored".
- **Healthy image stays clean:** the healthy target never copies `faults/`. The local test
  checks that the healthy image (and a build without `--target`) has no `fault_*` file,
  no fault label, and no fault strings in `/app`.
- **Test-the-test:** the unchanged independent API flow check must exit `3` with
  `status mismatch: expected 'In progress', got 'Open'`, and the browser check must exit
  `3` with the same mismatch after reload. Otherwise the local test fails.

Not yet built in CI for publishing, pushed to a registry or deployed; the plan policy that
restricts it to `scenario=deliberate-failure-ignore-status` comes with the workflow stages.

## Ticket data

SQLite file `/var/lib/atlas-tickets/tickets.db` on the container's data volume. It is
seeded with six fictional tickets on first start. It survives a container restart and is
deleted with the volume. No backups. (On Azure it will live on the disposable VM's OS
disk and be deleted with the VM — Stage 3.)

## Run the tests

```bash
./scripts/test-tickets-local.sh      # needs Docker; binds to 127.0.0.1 only
```

It builds the image and a separate pinned Playwright test image, then runs:
unit tests inside the app image, container hardening checks, the independent API flow
check (`tests/app/flow_check.py`), the browser check (`tests/app/ui/ui_check.py`), a
data-lifecycle check and the Docker healthcheck. It then checks that the healthy image
excludes the fault and runs the same flow and browser checks against the fault build,
which must fail with the status mismatch. It is also part of `scripts/validate.sh`.

`flow_check.py` exit codes: `0` saved result correct, `3` wrong saved result,
`2` environment problem. Neither test prints the target URL.

## Run it locally

```bash
docker build --target healthy -t atlas-tickets:dev tickets-app
docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  -v atlas-tickets-data:/var/lib/atlas-tickets -e ATLAS_ENVIRONMENT=local \
  -p 127.0.0.1:8080:8080 atlas-tickets:dev
```

## Preview limitations

The Stage 1 browser preview runs this container on the Devin VM behind Devin's HTTPS
proxy. It works only while that VM is awake, has no expiry timer or cleanup (the banner
time is a sample), and says nothing about the Azure network path or NSG restriction.
