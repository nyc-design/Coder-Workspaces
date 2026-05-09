# Workflow secrets — managed in GCP Secret Manager

All workflow secrets that previously lived in GitHub Actions secrets have been
migrated to **GCP Secret Manager** for centralization. Workflows authenticate
to GCP via **Workload Identity Federation (WIF)** — no long-lived service
account keys in GitHub.

## What's where

### GitHub repo Variables (NOT secrets — public-ish config)

| Name | Value |
|---|---|
| `GCP_WIF_PROVIDER` | Full WIF provider resource name (see setup below) |
| `GCP_WIF_SERVICE_ACCOUNT` | Email of the GCP service account workflows impersonate |

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

# 4. Bind the SA to the WIF pool, scoped to this specific repo ─────────────
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_ID}/attribute.repository/${GITHUB_REPO}" \
  --project=$GCP_PROJECT

# 5. Output values for GitHub repo Variables ──────────────────────────────
echo
echo "Set these as repo Variables (Settings → Secrets and variables → Actions → Variables):"
echo "  GCP_WIF_PROVIDER=${PROVIDER_ID}"
echo "  GCP_WIF_SERVICE_ACCOUNT=${SA_EMAIL}"
```

After running:

1. Go to GitHub → Settings → Secrets and variables → Actions → **Variables** tab.
2. Add `GCP_WIF_PROVIDER` and `GCP_WIF_SERVICE_ACCOUNT` from the script's output.
3. Make sure the GCP secrets in the table above all exist in `coder-nt`. Add
   any missing ones (`SIDECAR_SHARED_API_KEY`, `GH_PAT_FOR_MCP`, `GCP_PROJECT`)
   manually:
   ```bash
   echo -n "<value>" | gcloud secrets create SIDECAR_SHARED_API_KEY \
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

The previous version of `coder-workspace-launch.yaml` accepted `secrets:
inherit` from external repos that called it via `workflow_call`. After this
migration, the called workflow auths to GCP itself instead. External callers
need to:

1. Set up their own WIF pool/provider in their repo OR add their repo to the
   existing pool's principalSet (step 4 above, with `GITHUB_REPO=other-org/repo`).
2. Add the same `GCP_WIF_PROVIDER` + `GCP_WIF_SERVICE_ACCOUNT` Variables in
   their repo.
3. Pass `permissions: id-token: write` through to the called workflow (the
   `coder-workspace-launch-wrapper.yaml` shows the pattern).

If you don't have external callers, this is moot.
