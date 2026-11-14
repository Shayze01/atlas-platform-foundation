# shellcheck shell=bash
# Variables such as ROOT, WORK, OUT, NAME and current_ok belong to run-script-tests.sh.
# shellcheck disable=SC2034,SC2153
# Milestone 2 script tests, sourced by run-script-tests.sh (uses its run_case/has/lacks/
# done_case helpers). Stubs in tests/scripts/stubs-m2 come first on PATH; nothing
# contacts Azure or GitHub.
M2="${ROOT}/tests/scripts/stubs-m2"
M2PATH="${M2}:${STUBS}:${PATH}"
T=11111111-1111-1111-1111-111111111111
S=22222222-2222-2222-2222-222222222222
SA_NAME="statlas$(printf '%s' "${S}" | sha256sum | cut -c1-11)"
WL_SCOPE="/subscriptions/${S}/resourceGroups/rg-atlas-foundation-dev"
C_SCOPE="/subscriptions/${S}/resourceGroups/rg-atlas-tfstate/providers/Microsoft.Storage/storageAccounts/${SA_NAME}/blobServices/default/containers/tfstate"
BOOT=(--tenant "${T}" --subscription "${S}" --owner-tag "Test Owner")

az_writes() { grep -E '^az .* (create|update|delete)( |$)' "${STUB_LOG}" || true; }
no_writes() { local w; w="$(az_writes)"; [[ -z "${w}" ]] || note "unexpected Azure write(s): ${w}"; }
log_has() { grep -qE -- "$1" "${STUB_LOG}" || note "call log missing /$1/"; }
log_lacks() { if grep -qE -- "$1" "${STUB_LOG}"; then note "call log unexpectedly matches /$1/"; fi; }
log_count() { local n; n="$(grep -cE -- "$1" "${STUB_LOG}" || true)"; [[ "${n}" == "$2" ]] || note "expected $2 calls matching /$1/, got ${n}"; }

echo; echo "== bootstrap/bootstrap.sh =="
run_case "bootstrap: dry run lists changes and makes no Azure writes -> exit 0" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" -- "${BOOT[@]}"
has "DRY RUN"; has "WOULD RUN \\(storage account \\(Entra-only\\)\\)"; has "RESULT: dry run"; no_writes; done_case

run_case "bootstrap: signed in to a different tenant -> exit 1, nothing changed" 1 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" STUB_TENANT=99999999-9999-9999-9999-999999999999 -- "${BOOT[@]}" --apply
has "SAFETY: signed-in tenant/subscription"; no_writes; log_lacks "group exists"; done_case

run_case "bootstrap: signed in to a different subscription -> exit 1, nothing changed" 1 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" STUB_SUB=99999999-9999-9999-9999-999999999999 -- "${BOOT[@]}" --apply
has "SAFETY"; no_writes; done_case

run_case "bootstrap: Azure CLI not signed in -> exit 2" 2 ../bootstrap/bootstrap.sh PATH="${M2PATH}" AZ_ACCOUNT=fail -- "${BOOT[@]}"
has "az account show' failed"; no_writes; done_case

run_case "bootstrap: workload group already holds resources -> exit 1 before any write" 1 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" EXISTS_WORKLOAD=true WORKLOAD_NAMES=vm-atlas-foundation-dev -- "${BOOT[@]}" --apply
has "SAFETY: rg-atlas-foundation-dev already contains"; has "vm-atlas-foundation-dev"; no_writes; done_case

run_case "bootstrap: unexpected resource in the state group -> exit 1 before any write" 1 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" EXISTS_STATE=true STATE_RG_NAMES=$'id-atlas-gha-plan\nsomeone-elses-vm' -- "${BOOT[@]}" --apply
has "someone-elses-vm"; no_writes; done_case

run_case "bootstrap: resource group check error -> exit 2" 2 ../bootstrap/bootstrap.sh PATH="${M2PATH}" EXISTS_STATE=error -- "${BOOT[@]}"
has "could not check rg-atlas-tfstate"; no_writes; done_case

run_case "bootstrap: missing --owner-tag -> exit 2" 2 ../bootstrap/bootstrap.sh PATH="${M2PATH}" -- --tenant "${T}" --subscription "${S}"
has "owner-tag is required"; done_case

run_case "bootstrap --apply: hardened state storage, delete lock, versioning, soft delete" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" IDENTITIES_EXIST=1 -- "${BOOT[@]}" --apply
log_has "storage account create --name ${SA_NAME} .*--allow-shared-key-access false"
log_has "storage account create .*--allow-blob-public-access false"
log_has "storage account create .*--min-tls-version TLS1_2"
log_has "blob-service-properties update .*--enable-versioning true .*--enable-delete-retention true .*--enable-container-delete-retention true"
log_has "storage container-rm create .*--name tfstate --public-access off"
log_has "lock create .*--lock-type CanNotDelete .*--resource ${SA_NAME} --resource-type Microsoft.Storage/storageAccounts"
log_has "management-policy create"
has "RESULT: applied"
done_case

run_case "bootstrap --apply: least-privilege roles, no role-assignment rights, exact OIDC subjects" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" IDENTITIES_EXIST=1 -- "${BOOT[@]}" --apply
log_count "role assignment create" 4
log_has "role assignment create .*--role Reader --scope ${WL_SCOPE}\$"
log_has "role assignment create .*--role Contributor --scope ${WL_SCOPE}\$"
log_count "role assignment create .*--role Storage Blob Data Contributor --scope ${C_SCOPE}\$" 2
log_lacks "--role (Owner|User Access Administrator|Role Based Access Control Administrator)"
log_lacks "--scope /subscriptions/${S}( |\$)"
log_lacks "--scope /subscriptions/${S}/resourceGroups/rg-atlas-tfstate( |\$)"
log_count "federated-credential create" 3
log_has "--subject repo:Shayze01@99360721/atlas-platform-foundation@1457226611:environment:azure-plan:ref:refs/heads/main "
log_has "--subject repo:Shayze01@99360721/atlas-platform-foundation@1457226611:environment:azure-deploy:ref:refs/heads/main "
log_has "--subject repo:Shayze01@99360721/atlas-platform-foundation@1457226611:environment:azure-destroy:ref:refs/heads/main "
log_lacks "--subject [^ ]*\\*"
log_lacks "NetworkWatcherRG"
bad_rg="$(grep -oE -- '--(resource-group|name) rg-[^ ]+' "${STUB_LOG}" | awk '{print $2}' | sort -u | grep -vxE 'rg-atlas-tfstate|rg-atlas-foundation-dev' || true)"
[[ -z "${bad_rg}" ]] || note "touched other resource groups: ${bad_rg}"
log_lacks "^az (group|resource|identity|lock) delete"
done_case

run_case "bootstrap --apply: legacy name-only OIDC subjects are updated to the immutable format" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" IDENTITIES_EXIST=1 FED_SUBJECT=legacy -- "${BOOT[@]}" --apply
log_count "federated-credential update" 3; log_count "federated-credential create" 0
log_has "update --name gha-azure-deploy-main .*--subject repo:Shayze01@99360721/atlas-platform-foundation@1457226611:environment:azure-deploy:ref:refs/heads/main "
log_lacks "--subject repo:Shayze01/atlas-platform-foundation:"
done_case

run_case "bootstrap --apply: correct OIDC subjects are left unchanged" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" IDENTITIES_EXIST=1 FED_SUBJECT=immutable -- "${BOOT[@]}" --apply
has "OK: gha-azure-plan-main already trusts"; log_count "federated-credential (create|update)" 0; done_case

run_case "bootstrap --apply: correct subject but wrong issuer or audience is repaired" 0 ../bootstrap/bootstrap.sh \
  PATH="${M2PATH}" IDENTITIES_EXIST=1 FED_SUBJECT=immutable FED_AUDIENCE=api://wrong -- "${BOOT[@]}" --apply
log_count "federated-credential update .*--issuer https://token.actions.githubusercontent.com .*--audiences api://AzureADTokenExchange" 3
lacks "already trusts"; done_case

run_case "bootstrap: another --github-repo without its IDs -> exit 2" 2 ../bootstrap/bootstrap.sh PATH="${M2PATH}" -- \
  "${BOOT[@]}" --github-repo someone/fork
has "must be numeric"; no_writes; done_case

run_case "bootstrap: non-numeric --github-repo-id -> exit 2" 2 ../bootstrap/bootstrap.sh PATH="${M2PATH}" -- \
  "${BOOT[@]}" --github-owner-id 99360721 --github-repo-id 'x*'
has "must be numeric"; no_writes; done_case

echo; echo "== bootstrap/teardown.sh =="
TD=(--tenant "${T}" --subscription "${S}")
run_case "teardown: dry run with workload gone and empty state -> exit 0, nothing deleted" 0 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_STATE=true STATE_BLOB=empty IDENTITIES_EXIST=1 -- "${TD[@]}"
has "OK: Terraform state tracks no managed resources"; has "WOULD RUN \\(delete rg-atlas-tfstate"; no_writes; done_case

run_case "teardown: workload resources still present -> exit 1, nothing deleted" 1 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_WORKLOAD=true WORKLOAD_COUNT=3 EXISTS_STATE=true -- "${TD[@]}" --apply
has "still contains 3 resource"; no_writes; done_case

run_case "teardown: state still tracks managed resources -> exit 1, nothing deleted" 1 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_STATE=true STATE_BLOB=resources -- "${TD[@]}" --apply
has "Terraform state still tracks 1 managed"; no_writes; done_case

run_case "teardown: state unreadable (permission) is inconclusive -> exit 2, nothing deleted" 2 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_STATE=true STATE_BLOB=denied -- "${TD[@]}" --apply
has "INCONCLUSIVE: could not read the Terraform state"; no_writes; done_case

for blob in braces null noresources wrongtype malformed badmode v3 emptyfile; do
  run_case "teardown: unsupported state blob '${blob}' is inconclusive -> exit 2, nothing deleted" 2 ../bootstrap/teardown.sh \
    PATH="${M2PATH}" EXISTS_STATE=true STATE_BLOB="${blob}" IDENTITIES_EXIST=1 -- "${TD[@]}" --apply
  has "INCONCLUSIVE: the state blob is not a supported Terraform state"; lacks "OK: Terraform state tracks no managed"; no_writes; done_case
done

run_case "teardown: unexpected state-group existence answer is inconclusive -> exit 2, nothing deleted" 2 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_STATE=maybe IDENTITIES_EXIST=1 -- "${TD[@]}" --apply
has "INCONCLUSIVE: unexpected 'az group exists' output for rg-atlas-tfstate"; no_writes; done_case

run_case "teardown: wrong subscription -> exit 1" 1 ../bootstrap/teardown.sh PATH="${M2PATH}" STUB_SUB=99999999-9999-9999-9999-999999999999 -- "${TD[@]}" --apply
has "SAFETY"; no_writes; done_case

run_case "teardown --apply: workload group, identities, lock, then state backend LAST" 0 ../bootstrap/teardown.sh \
  PATH="${M2PATH}" EXISTS_WORKLOAD=true WORKLOAD_COUNT=0 EXISTS_STATE=true STATE_BLOB=empty IDENTITIES_EXIST=1 -- "${TD[@]}" --apply
order="$(az_writes | sed -E -e 's/^az //' -e 's/^([a-z ]+ delete) .*--name ([^ ]+).*/\1 \2/' -e 's/^(role assignment delete) .*/\1/' | tr '\n' '|')"
[[ "${order}" == "group delete rg-atlas-foundation-dev|role assignment delete"*"|identity delete id-atlas-gha-plan|"*"identity delete id-atlas-gha-deploy|lock delete lock-atlas-tfstate-nodelete|group delete rg-atlas-tfstate|" ]] \
  || note "unexpected delete order: ${order}"
log_lacks "NetworkWatcherRG"
done_case

echo; echo "== scripts/github/setup-github.sh =="
PUBKEY="${WORK}/admin.pub"; NOTKEY="${WORK}/notkey.pub"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ atlas-test-only" >"${PUBKEY}"
echo "PRIVATE KEY placeholder - simulates pasting a private key" >"${NOTKEY}"
GHV=(PATH="${M2PATH}" AZURE_TENANT_ID="${T}" AZURE_SUBSCRIPTION_ID="${S}"
     AZURE_PLAN_CLIENT_ID=55555555-5555-5555-5555-555555555555 AZURE_DEPLOY_CLIENT_ID=66666666-6666-6666-6666-666666666666
     TFSTATE_STORAGE_ACCOUNT="${SA_NAME}" TFSTATE_CONTAINER=tfstate ADMIN_SOURCE_IP_CIDR=198.51.100.20/32
     ADMIN_SSH_PUBLIC_KEY_FILE="${PUBKEY}" OWNER_TAG="Test Owner")
run_case "github setup: dry run changes nothing and never prints secret values -> exit 0" 0 github/setup-github.sh "${GHV[@]}"
has "WOULD RUN \\(environment azure-deploy\\)"; lacks "198\\.51\\.100\\.20"; lacks "AAAAC3Nz"
log_lacks "^gh (api -X|variable|secret)"; done_case

run_case "github setup --apply: self-approvable reviewer only on azure-deploy, main-only, OIDC claims" 0 github/setup-github.sh "${GHV[@]}" -- --apply
log_has '"include_claim_keys":\["repo","context","ref"\],"use_immutable_subject":true'
log_has '"default_workflow_permissions":"read"'
log_count '"prevent_self_review":false' 3
log_count '"reviewers":\[\{"type":"User","id":12345\}\]' 1
log_count '"custom_branch_policies":true' 3
log_count "deployment-branch-policies -f name=main -f type=branch" 3
log_has "variable set AZURE_CLIENT_ID --repo Shayze01/atlas-platform-foundation --env azure-plan --body 55555555-"
log_count "variable set AZURE_CLIENT_ID .*--body 66666666-" 2
log_count "^gh secret set" 9
log_lacks "198\\.51\\.100\\.20"; lacks "198\\.51\\.100\\.20"; log_lacks "AAAAC3Nz"
done_case

run_case "github setup: gh not signed in as a repository admin -> exit 2" 2 github/setup-github.sh "${GHV[@]}" GH_ADMIN=false -- --apply
has "not signed in as an admin"; done_case

run_case "github setup: internet-wide admin source rejected -> exit 2" 2 github/setup-github.sh "${GHV[@]}" ADMIN_SOURCE_IP_CIDR=0.0.0.0/0 -- --apply
has "ADMIN_SOURCE_IP_CIDR must be a single IPv4 /32"; done_case

run_case "github setup: non-public-key file rejected -> exit 2" 2 github/setup-github.sh "${GHV[@]}" ADMIN_SSH_PUBLIC_KEY_FILE="${NOTKEY}" -- --apply
has "must be an SSH PUBLIC key file"; done_case

echo; echo "== scripts/ci helpers =="
BE=(PATH="${M2PATH}" TF_DIR="${WORK}" TFSTATE_STORAGE_ACCOUNT="${SA_NAME}" TFSTATE_CONTAINER=tfstate
    ARM_CLIENT_ID=55555555-5555-5555-5555-555555555555 ARM_TENANT_ID="${T}" ARM_SUBSCRIPTION_ID="${S}")
run_case "backend-init: Entra ID + OIDC backend, no keys -> exit 0" 0 ci/backend-init.sh "${BE[@]}"
log_has "terraform init .*storage_account_name=${SA_NAME}.*use_azuread_auth=true.*use_oidc=true"
log_lacks "access_key|sas_token|client_secret"
grep -q 'backend "azurerm"' "${WORK}/backend_override.tf" 2>/dev/null || note "backend_override.tf not written"
done_case

run_case "backend-init: ARM_CLIENT_SECRET present -> refused, exit 2" 2 ci/backend-init.sh "${BE[@]}" ARM_CLIENT_SECRET=x
has "ARM_CLIENT_SECRET is set"; log_lacks "terraform init"; done_case

run_case "backend-init: storage access key present -> refused, exit 2" 2 ci/backend-init.sh "${BE[@]}" ARM_ACCESS_KEY=x
has "ARM_ACCESS_KEY is set"; log_lacks "terraform init"; done_case

run_case "backend-init: missing storage account variable -> exit 2" 2 ci/backend-init.sh "${BE[@]}" TFSTATE_STORAGE_ACCOUNT=
has "TFSTATE_STORAGE_ACCOUNT is not set"; done_case

PLANF="${WORK}/tfplan"; echo "binary-plan-placeholder" >"${PLANF}"
PSHA="$(sha256sum "${PLANF}" | cut -d' ' -f1)"
run_case "plan-summary: addresses/actions/counts only, no values; writes outputs -> exit 0" 0 ci/plan-summary.sh \
  PATH="${M2PATH}" GITHUB_OUTPUT="${WORK}/gh_output" -- "${PLANF}"
has "add=2 change=1 destroy=1 replace=1"; has "\\| create \\| \`module.compute.azurerm_linux_virtual_machine.this\` \\|"
has "\\| delete\\+create \\| \`module.compute.azurerm_public_ip.vm\`"; has "${PSHA}"
lacks "203\\.0\\.113"; lacks "ssh-ed25519"; lacks "I2Nsb3Vk"; lacks "data.azurerm_resource_group"
if ! { grep -qx "has_changes=true" "${WORK}/gh_output" && grep -qx "plan_sha256=${PSHA}" "${WORK}/gh_output"; }; then note "GITHUB_OUTPUT not written correctly"; fi
done_case

run_case "plan-summary: reads and no-ops only -> has_changes=false" 0 ci/plan-summary.sh \
  PATH="${M2PATH}" PLAN_SCENARIO=nochanges GITHUB_OUTPUT="${WORK}/gh_output2" -- "${PLANF}"
has "No changes."; grep -qx "has_changes=false" "${WORK}/gh_output2" || note "has_changes=false missing"; done_case

has_details() {
  has "\\| VM size \\| \`Standard_B2ats_v2\` \\|"; has "\\| Region \\| \`eastus\` \\|"; has "\\| OS disk type \\| \`Standard_LRS\` \\|"
  has "\\| Password authentication \\| disabled \\|"; has "\\| Auto-shutdown \\| enabled, 0200 \`GMT Standard Time\` \\|"
  has "\\| Inbound allow rules \\| 2: port 22 from 1 source\\(s\\); port 80 from 1 source\\(s\\) \\|"
}
run_case "plan-summary: allowlisted details + 9 policy checks pass, no private values" 0 ci/plan-summary.sh \
  PATH="${M2PATH}" GITHUB_OUTPUT="${WORK}/gh_output3" -- "${PLANF}"
has_details; has "Policy checks: 9 passed"; count "\\| PASS \\|" 9
lacks "203\\.0\\.113"; lacks "52\\.142"; lacks "AAAAC3Nz"; lacks "atlasadmin"; lacks "I2Nsb3Vk"
grep -qx "has_changes=true" "${WORK}/gh_output3" || note "outputs not written for a compliant plan"
done_case

run_case "plan-summary: no-change plan still evaluated against planned values" 0 ci/plan-summary.sh \
  PATH="${M2PATH}" PLAN_SCENARIO=nochanges -- "${PLANF}"
has "No changes."; has "Policy checks: 9 passed"; done_case

while IFS='|' read -r scen expect; do
  rm -f "${WORK}/gh_output_p"
  run_case "plan-summary policy: '${scen}' fails closed -> exit 1, no outputs, not offered for approval" 1 ci/plan-summary.sh \
    PATH="${M2PATH}" PLAN_SCENARIO="${scen}" GITHUB_OUTPUT="${WORK}/gh_output_p" -- "${PLANF}"
  has "POLICY FAILED"; has "${expect}"; lacks "203\\.0\\.113"; lacks "192\\.0\\.2\\.44"; lacks "Policy checks: 9 passed"
  [[ ! -s "${WORK}/gh_output_p" ]] || note "plan outputs written despite policy failure"
  done_case
done <<'CASES'
open-ssh|\| Inbound allow rules use single /32 sources only.*\| FAIL \| 1 source\(s\) are internet-wide
internet-http|\| Inbound allow rules use single /32 sources only.*\| FAIL \|
wide-range|wider than a single IPv4 /32
temp-rule|\| No temporary test rule in the deployed configuration \| FAIL \|
no-deny|\| Explicit inbound Internet deny \| FAIL \|
password-enabled|\| Password authentication disabled \| FAIL \|
wrong-size|\| VM size is the approved small size \| FAIL \| `Standard_D4s_v5`
unknown-size|\| VM size is the approved small size \| UNEVALUABLE \|
unknown-source|\| UNEVALUABLE \| value `source of rule Allow-SSH-From-Admin`
no-shutdown|\| Daily auto-shutdown at the approved UK time \| FAIL \|
wrong-shutdown|enabled at 2300 GMT Standard Time
implicit-outbound|\| No implicit outbound access \| FAIL \|
no-planned-values|\| planned_values present \| UNEVALUABLE \|
CASES

run_case "plan-summary: unreadable plan -> exit 2" 2 ci/plan-summary.sh PATH="${M2PATH}" PLAN_SCENARIO=showfail -- "${PLANF}"
has "terraform show -json' failed"; done_case

SAN_IN="ip 52.142.2.255 and 10.20.1.0/24,192.0.2.1; id=/subscriptions/${S}/x; ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAhnnlI7ScyqxeIK1AysQ0aqybx6fYKZbROGFSh78TQ k; SHA256:D8rWZiIazcn092zI1UywMNAkRyQlBttDbQUwOnmkD+4; nginx 1.30.2; https://a/b?sv=1&sig=abc%2Fdef"
cases=$((cases + 1)); current_ok=true; NAME="sanitize: masks IPs, GUIDs, keys, fingerprints, SAS signatures; keeps versions"
OUT="$(printf '%s\n' "${SAN_IN}" | "${ROOT}/scripts/ci/sanitize.sh")"
has "ip <ip> and <ip>,<ip>;"; has "/subscriptions/<guid>/x"; has "ssh-ed25519 <public-key> k"; has "SHA256:<fingerprint>"
has "nginx 1.30.2"; has "sig=<redacted>"; lacks "52\\.142"; lacks "${S}"; done_case

run_case "temp-access add: exactly one /32 on TCP 22 and 80 -> exit 0" 0 ci/temp-access.sh PATH="${M2PATH}" -- add 198.51.100.7/32
log_has "network nsg rule create .*--name Allow-CI-Runner-Temporary --priority 130 .*--access Allow --protocol Tcp --source-address-prefixes 198.51.100.7/32 .*--destination-port-ranges 22 80"
done_case

for bad in 0.0.0.0/0 198.51.100.0/24 0.0.0.0/32 "*" ""; do
  run_case "temp-access add: refuses '${bad}' -> exit 2, no Azure call" 2 ci/temp-access.sh PATH="${M2PATH}" -- add "${bad}"
  has "refusing temporary access"; log_lacks "^az "; done_case
done

run_case "temp-access remove: rule confirmed absent -> exit 0" 0 ci/temp-access.sh PATH="${M2PATH}" RULE_M2=absent -- remove
has "confirmed absent"; log_has "network nsg rule delete"; done_case

run_case "temp-access remove: NSG already gone -> exit 0" 0 ci/temp-access.sh PATH="${M2PATH}" NSG_M2=notfound -- remove
has "no temporary rule can remain"; done_case

run_case "temp-access remove: rule still present -> exit 1" 1 ci/temp-access.sh PATH="${M2PATH}" RULE_M2=present -- remove
has "FAIL: Allow-CI-Runner-Temporary still exists"; done_case

run_case "temp-access remove: cannot confirm absence -> inconclusive exit 2, never 'removed'" 2 ci/temp-access.sh PATH="${M2PATH}" RULE_M2=error -- remove
has "INCONCLUSIVE"; lacks "confirmed absent"; done_case

run_case "temp-access remove: NSG read error -> inconclusive exit 2" 2 ci/temp-access.sh PATH="${M2PATH}" NSG_M2=error -- remove
has "INCONCLUSIVE: cannot read NSG"; done_case

run_case "runner-ip: two services agree -> prints one /32" 0 ci/runner-ip.sh PATH="${M2PATH}"
has "^198\\.51\\.100\\.7/32$"; done_case

run_case "runner-ip: services disagree -> exit 2, no address" 2 ci/runner-ip.sh PATH="${M2PATH}" CURL_IP1=198.51.100.7 CURL_IP2=198.51.100.8
has "disagree"; lacks "/32"; done_case

run_case "runner-ip: private address -> exit 2" 2 ci/runner-ip.sh PATH="${M2PATH}" CURL_IP1=10.1.2.3
has "not a public unicast address"; done_case

run_case "runner-ip: lookup failure -> exit 2" 2 ci/runner-ip.sh PATH="${M2PATH}" CURL_CONTROL=fail
has "could not determine public IPv4"; done_case

run_case "wait-for-health: /health 200 -> exit 0" 0 ci/wait-for-health.sh PATH="${M2PATH}" MAX_SECONDS=30
has "Web service healthy"; lacks "203\\.0\\.113"; done_case
