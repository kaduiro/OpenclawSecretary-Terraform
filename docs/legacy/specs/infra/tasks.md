# Infrastructure Tasks: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

## Phase 1: Terraform Foundation

- remote state backend を決める。
- provider、project、region、environment variables を整理する。
- 既存 gcloud resource の import mapping を作る。

## Phase 2: Runtime Resources

- Cloud Run Gateway / private API を Terraform 化する。
- Cloud SQL、VPC / private connectivity、backup を Terraform 化する。
- Secret Manager resource と IAM binding を Terraform 化する。

## Phase 3: Invocation / Security

- Gateway / Scheduler / Tasks service account を作成する。
- private API invoker を最小化する。
- DwD `signJwt` custom role と audit log を構成する。
- IAP access と programmatic client 設定手順を runbook 化する。

## Phase 4: Jobs / Operations

- Cloud Scheduler job を Terraform 化する。
- Cloud Tasks queue と retry config を Terraform 化する。
- Monitoring / Logging / Audit Logs を Terraform 化する。

## Phase 5: Migration Cleanup

- `docs/legacy/gcloud/` の手順を legacy として固定する。
- Terraform import 後の drift を確認する。
- Back / Front に渡す outputs / env var を docs 化する。
