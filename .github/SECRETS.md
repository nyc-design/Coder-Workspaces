# Workflow secrets — managed in GCP Secret Manager

All workflow secrets that previously lived in GitHub Actions secrets have been
migrated to **GCP Secret Manager** for centralization. Workflows authenticate
to GCP via **Workload Identity Federation (WIF)** — no long-lived service
account keys in GitHub.

## What's where

### Nothing in GitHub Actions

The WIF provider URI and service account email are hardcoded directly in the
workflow YAMLs (they're identifiers, not secrets). External nyc-design repos
that call `coder-workspace-launch.yaml` need only `permissions: id-token: write`
on the calling job — no Variables, no GCP setup of their own.

Current hardcoded values (verify match your `gcloud` setup output if you
re-run setup):

```
workload_identity_provider: projects/547043252101/locations/global/workloadIdentityPools/github/providers/this-repo
service_account: coder-gha-secrets@coder-nt.iam.gserviceaccount.com
```

### GCP Secret Manager (project: `coder-nt`)

| Secret | Used by |
|---|---|
| `CODER_URL` | All Coder-API workflows |
| `CODER_SESSION_TOKEN` | All Coder-API workflows |
| `SIDECAR_SHARED_API_KEY` | `update-coder-agents-config.yaml` |
| `CONTEXT7_API_KEY` | `update-coder-agents-config.yaml` |
| `GH_PAT_FOR_MCP` | `update-coder-agents-config.yaml` (mapped to env `GITHUB_PAT` in YAML substitution) |
| `GCP_PROJECT` | `coder-workspace-launch.yaml` |

Plus the workspace-side secrets unchanged: `GH_PAT`, `DOCKER_CONFIG`,
`SIGNOZ_URL`, `SIGNOZ_API_KEY`, `HAPI_CLI_API_TOKEN`, etc.

## One-time WIF setup

Run these `gcloud` commands once to create the WIF pool, OIDC provider, service
account, and IAM bindings. After this, GitHub Actions can mint short-lived GCP
credentials on every workflow run with no key material stored anywhere.

```bash
# Configuration ─────────────────────────────────────────────────────────────
GCP_PROJECT=coder-nt
GITHUB_REPO=nyc-design/Coder-Workspaces

SA_NAME=coder-gha-secrets                       # service account name
POOL_NAME=github                                # WIF pool name
PROVIDER_NAME=this-repo                         # OIDC provider name within the pool

SA_EMAIL=${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com

# 1. Service account that workflows will impersonate ───────────────────────
gcloud iam service-accounts create $SA_NAME \
  --display-name="GitHub Actions secret accessor for Coder" \
  --project=$GCP_PROJECT

# Grant Secret Manager read on the project (or per-secret for tighter scope)
gcloud projects add-iam-policy-binding $GCP_PROJECT \
  --member=serviceAccount:$SA_EMAIL \
  --role=roles/secretmanager.secretAccessor

# Workspace-launch workflow also creates Coder workspaces — grant whatever
# Coder-side perms its session token already has, no extra GCP role needed
# beyond secret access. If you ever switch to direct GCE start/stop calls
# from the workflow (vs going through Coder API), grant compute.instanceAdmin
# on the relevant project here.

# 2. Workload identity pool ────────────────────────────────────────────────
gcloud iam workload-identity-pools create $POOL_NAME \
  --location=global \
  --display-name="GitHub Actions" \
  --project=$GCP_PROJECT

POOL_ID=$(gcloud iam workload-identity-pools describe $POOL_NAME \
  --location=global --project=$GCP_PROJECT --format="value(name)")

# 3. OIDC provider for github.com ──────────────────────────────────────────
gcloud iam workload-identity-pools providers create-oidc $PROVIDER_NAME \
  --location=global \
  --workload-identity-pool=$POOL_NAME \
  --display-name="github.com OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository_owner=='nyc-design'" \
  --project=$GCP_PROJECT

PROVIDER_ID=$(gcloud iam workload-identity-pools providers describe $PROVIDER_NAME \
  --workload-identity-pool=$POOL_NAME \
  --location=global \
  --project=$GCP_PROJECT \
  --format="value(name)")

# 4. Bind the SA to ALL nyc-design repos (broad principalSet) ───────────
# This is broader than just Coder-Workspaces because the externally-callable
# coder-workspace-launch.yaml workflow needs to work when invoked by reusable-
# workflow callers from other nyc-design repos. The OIDC token GitHub mints
# carries the *caller's* repo claim, not Coder-Workspaces, so the binding
# must accept any nyc-design repo. The attribute-condition on the OIDC
# provider (step 3) already filters to repository_owner=='nyc-design', so
# only your own repos can mint matching tokens.
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.repository_owner/nyc-design" \
  --project=$GCP_PROJECT

# 5. Output the values that need to be hardcoded into the workflow YAMLs ──
echo
echo "Hardcoded values to verify in workflow YAMLs:"
echo "  workload_identity_provider: ${PROVIDER_ID}"
echo "  service_account: ${SA_EMAIL}"
```

These are already filled in — current values in the workflow YAMLs:

```
workload_identity_provider: projects/547043252101/locations/global/workloadIdentityPools/github/providers/this-repo
service_account: coder-gha-secrets@coder-nt.iam.gserviceaccount.com
```

If you re-run the setup script and get different values (e.g. you delete and
recreate the pool), update the four workflow YAMLs to match:
- `.github/workflows/update-coder-templates.yaml`
- `.github/workflows/update-coder-agents-config.yaml`
- `.github/workflows/coder-workspace-launch.yaml`

After WIF setup, make sure the GCP secrets in the table above all exist in
`coder-nt`. Add any missing ones manually:

```bash
# Add a new secret + first version
echo -n "<value>" | gcloud secrets create SIDECAR_SHARED_API_KEY \
  --replication-policy=automatic \
  --data-file=- --project=coder-nt

# Update an existing secret to a new version
echo -n "<new-value>" | gcloud secrets versions add SIDECAR_SHARED_API_KEY \
  --data-file=- --project=coder-nt
```

## After migration: remove old GitHub Actions secrets

Once the workflows run green with WIF, these GitHub Actions **secrets** can be
deleted (they're now in GCP Secret Manager):

- `CODER_URL`
- `CODER_SESSION_TOKEN`
- `GCP_PROJECT`
- `SIDECAR_SHARED_API_KEY` (if it was added)
- `CONTEXT7_API_KEY` (if it was added)
- `GH_PAT_FOR_MCP` (if it was added)

Build workflows (`build-base-dev.yaml`, etc.) still use only `GITHUB_TOKEN`
which is auto-provided by GitHub — no migration needed there.

## External callers of `coder-workspace-launch.yaml`

External nyc-design repos can invoke this reusable workflow with **zero GCP
or secret setup on their end**. The wrapper YAML (`coder-workspace-launch-wrapper.yaml`)
already does this — drop a copy of it into any nyc-design repo:

```yaml
name: Launch Coder Workspace

on:
  workflow_dispatch:
    inputs:
      mode:
        description: "Who is the workspace for?"
        type: choice
        options: [self, agent]
        default: agent

permissions:
  contents: read
  id-token: write   # required so GitHub mints the OIDC token for WIF

jobs:
  launch:
    permissions:
      contents: read
      id-token: write
    uses: nyc-design/Coder-Workspaces/.github/workflows/coder-workspace-launch.yaml@main
    with:
      mode: ${{ inputs.mode }}
```

That's it. No secrets, no Variables, no gcloud anywhere on the calling repo.
Run "Launch Coder Workspace" from the Actions tab and it'll create
`{REPO_NAME}-Agents` from the `project-workspace` template.

How it works under the hood: the called workflow has the WIF provider + SA email
hardcoded (non-secret identifiers), and the WIF binding allows any nyc-design repo.
The caller's OIDC token includes its own repo claim, the binding accepts it, GCP
returns short-lived access tokens for the SA, Secret Manager fetches happen,
workflow runs.

Why this works:
- The WIF binding is to `attribute.repository_owner=nyc-design` — any of your
  repos satisfies it.
- The attribute-condition on the OIDC provider also filters to
  `repository_owner=='nyc-design'` — non-nyc-design repos can't mint tokens
  that satisfy it.
- The workflow YAML has WIF identifiers literal-coded (provider URI + SA
  email), so it doesn't rely on the caller having any Variables set.

Non-nyc-design external callers (if you ever have them) would need their own
WIF binding added — narrow that case via a per-repo principalSet binding.
