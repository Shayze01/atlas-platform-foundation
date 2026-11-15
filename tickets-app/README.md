# Atlas Service Desk (demo) — Milestone 3, Stage 1

A small support-ticket web app used to prove the Atlas application deployment and
testing flow. **Fictional data only.** It is not connected to any real organisation,
system or data source.

Stage 1 status: the healthy app, its container and local tests only. It is **not yet
deployed to Azure**; Terraform, cloud-init and workflows are unchanged (later stages).

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
  `atlas.variant=healthy`. The deliberately broken variant is Stage 2.
- Runs as UID 10001 with a read-only root filesystem; only `/var/lib/atlas-tickets`
  (data volume) and `/tmp` are writable. Gunicorn access logs are off (they would
  record client IPs).

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
data-lifecycle check and the Docker healthcheck. It is also part of `scripts/validate.sh`.

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
