# huggingface-s3-model-registry

A reusable model distribution pipeline: models are pulled from Hugging Face
and mirrored into a versioned, encrypted S3 bucket, so downstream services
(EKS / vLLM / RAG / ML) load from your own controlled registry instead of
depending on Hugging Face during every scale-out. That makes model startup
reproducible and removes a live external dependency from the inference
hot path.

```
Hugging Face
     │
     ▼
GitHub Actions
     │
     ├── uses HF_TOKEN
     ├── authenticates to AWS with OIDC
     ▼
Python sync app (src/sync_models.py)
     │
     ▼
Amazon S3  (huggingface-model-registry-<account>-<region>)
     │
     ├── inference/
     ├── embedding/
     ├── reranker/
     └── classifier/
     │
     ▼
EKS / vLLM / RAG / ML services
```

## Repo structure

```
huggingface-s3-model-registry/
├── terraform/          # S3 bucket, IAM roles, GitHub OIDC provider
│   ├── main.tf
│   ├── s3.tf
│   ├── iam.tf
│   ├── oidc.tf
│   └── variables.tf
├── src/
│   ├── sync_models.py  # download from HF, validate, upload to S3
│   └── requirements.txt
├── models/
│   └── registry.yaml   # which models to sync, and their type
└── .github/workflows/
    ├── terraform-plan.yml    # PR: read-only plan + PR comment
    ├── terraform-apply.yml   # push to main: apply infra changes
    └── sync-models.yml       # push / daily / manual: sync models to S3
```

Responsibilities stay separated on purpose:

| Layer | Owns |
|---|---|
| Terraform | S3 bucket, encryption, versioning, lifecycle, IAM, OIDC |
| GitHub Actions | CI/CD orchestration, scheduling, secrets |
| Python (`sync_models.py`) | Download from Hugging Face, validate, sync to S3 |

## Credentials

- **AWS** — GitHub OIDC only. No AWS access key/secret is stored in GitHub.
  Three roles are provisioned by Terraform (`terraform/iam.tf`):
  - `gha-huggingface-registry-plan` — read-only, assumable from any branch/PR
  - `gha-huggingface-registry-apply` — write, assumable only from `main`
  - `gha-huggingface-registry-sync` — S3 object read/write, assumable only from `main`
- **Hugging Face** — a single repo secret, `HF_TOKEN`, scoped to the
  `sync-models` job's model-sync step (not exported globally).

## Setup

1. **Add the Hugging Face token as a repo secret**
   `GitHub → Settings → Secrets and variables → Actions → New repository secret`
   Name: `HF_TOKEN`

2. **Bootstrap OIDC + IAM** (one-time, requires admin AWS credentials locally —
   this is the chicken-and-egg step, since the CI roles can't create themselves):
   ```bash
   cd terraform
   terraform init
   terraform apply \
     -var="aws_account_id=<ACCOUNT_ID>" \
     -var="aws_region=us-east-1" \
     -var="github_org=<YOUR_GH_ORG>"
   ```
   Note the `gha_plan_role_arn`, `gha_apply_role_arn`, `gha_sync_role_arn`,
   and `bucket_name` outputs.

3. **Set repo variables** (`Settings → Secrets and variables → Actions → Variables`):
   - `AWS_REGION`
   - `AWS_ACCOUNT_ID`
   - `AWS_PLAN_ROLE_ARN`
   - `AWS_APPLY_ROLE_ARN`
   - `AWS_SYNC_ROLE_ARN`
   - `MODEL_REGISTRY_BUCKET`

4. **Edit `models/registry.yaml`** to list the models you want mirrored, then
   push to `main` (or run `sync-models` via `workflow_dispatch`).

## `models/registry.yaml`

```yaml
models:
  - id: meta-llama/Llama-3.1-8B-Instruct
    type: inference

  - id: BAAI/bge-base-en-v1.5
    type: embedding

  - id: BAAI/bge-reranker-v2-m3
    type: reranker
```

`type` must be one of `inference`, `embedding`, `reranker`, `classifier`.
Optional per-model fields: `revision` (pin for reproducibility, default
`main`), `allow_patterns` / `ignore_patterns` (glob lists forwarded to
`huggingface_hub.snapshot_download`, e.g. to skip duplicate `.bin` weights
when `.safetensors` are present).

## Running the sync locally

```bash
pip install -r src/requirements.txt
export HF_TOKEN=hf_xxx
aws sso login --profile your-profile   # or any other way to get AWS creds locally

python src/sync_models.py \
  --bucket huggingface-model-registry-<account>-<region> \
  --dry-run              # drop --dry-run to actually upload
```

Useful flags: `--only <model-id>` (repeatable) to sync a single model,
`--workers N` for concurrency, `--registry <path>` for a different
registry file.

`sync_models.py` validates each download (required config files present,
no zero-byte files) before uploading, and skips files whose size/md5
already match what's in S3, so re-runs are cheap.

## Consuming from S3

Attach the `registry-read` IAM role (or copy its policy — see
`terraform/iam.tf`) to the IRSA/service role your EKS pods, vLLM
replicas, or RAG ingestion jobs run as, then read directly from
`s3://<bucket>/<type>/<model-id>/...` — no Hugging Face network access
required at inference time.
# huggingface-s3-model-registry
