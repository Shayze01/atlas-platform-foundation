# Validation log

This file records checks that were **actually executed** and their results.
Offline checks do not contact Azure and do not prove that a deployment works.

## Offline checks - executed 2026-11-12

Environment: Ubuntu 22.04.5 LTS (x86_64), Terraform v1.9.8, azurerm provider
5.13.0 (from `.terraform.lock.hcl`), Docker Engine 29.9.2, cloud-init 26.1,
ShellCheck 0.11.0.

Command: `./scripts/validate.sh` (all steps passed). The local web test inside
that run used `BASE_IMAGE=mirror.gcr.io/nginxinc/nginx-unprivileged:1.30-alpine`
because Docker Hub temporarily returned HTTP 429 (rate limit). The web test was
then re-run with the default Docker Hub base image
(`nginxinc/nginx-unprivileged:1.30-alpine`) and also passed.

A mutation check was also run once: changing the SSH rule source to `*` made
`tests/networking.tftest.hcl` fail as expected (change reverted).

```text

==> terraform fmt -check -recursive

==> terraform init -backend=false
init OK

==> terraform validate
Success! The configuration is valid.


==> terraform test (mocked provider, no Azure calls)
tests/compute.tftest.hcl... in progress
  run "vm_uses_ssh_keys_only"... pass
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

Success! 8 passed, 0 failed.

==> Render cloud-init
Rendered: build/cloud-init.rendered.yaml

==> Rendered cloud-init embeds ./app files unchanged
PASS: /opt/atlas/app/Dockerfile matches app/Dockerfile
PASS: /opt/atlas/app/nginx.conf matches app/nginx.conf
PASS: /opt/atlas/app/index.html matches app/index.html
PASS: /opt/atlas/app/run-container.sh matches app/run-container.sh

==> cloud-init schema validation
Valid schema build/cloud-init.rendered.yaml

==> shellcheck
shellcheck OK

==> Local web service test
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

All available offline checks passed.
```

Re-run of the web test with the default Docker Hub base image:

```text
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
```

## Azure deployment checks - NOT yet executed

The following require an Azure subscription and have not been run from this
repository. Record results here (and screenshots in `docs/evidence/`) after you
deploy:

| Check | Command / location | Result |
| --- | --- | --- |
| `terraform plan` shows 11 to add | README section 7 | not run |
| `terraform apply` succeeds | README section 7 | not run |
| `/health` returns 200 from admin IP | README section 8 | not run |
| Landing page shows "Atlas Platform Foundation" | README section 8 | not run |
| SSH key login works; `cloud-init status` = done | README section 8 | not run |
| Password authentication refused | README section 8 | not run |
| HTTP/SSH blocked from another network | README section 8 | not run |
| `terraform destroy` + cleanup verification | README section 9 | not run |
