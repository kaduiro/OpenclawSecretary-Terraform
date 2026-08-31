# Infrastructure Process Flow: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

## Flow 1: Terraform Import / Migration

1. 既存 gcloud resource を棚卸しする。
2. Terraform resource 定義を作成する。
3. `terraform import` で既存 resource を state に取り込む。
4. `terraform plan` で差分が意図したものだけか確認する。
5. destroy / replace が意図せず出る場合は apply しない。

## Flow 2: Cloud Run Deployment Boundary

1. Gateway service と private API service を定義する。
2. private API は unauthenticated invocation を無効にする。
3. Gateway SA、Scheduler SA、Tasks SA だけに private API invoker を付与する。
4. HUD user には Gateway / IAP への access だけを付与する。

## Flow 3: Scheduler / Tasks OIDC

1. 専用 service account を作成する。
2. Scheduler job / Tasks queue に OIDC audience と service account email を設定する。
3. Back 側が同じ audience / service account allowlist を検証できるよう outputs / env を渡す。

## Flow 4: Secret Manager

1. secret resource と IAM binding を Terraform 管理する。
2. secret value は手動または安全な bootstrap で投入する。
3. API SA に対象 secret の accessor / version adder を最小権限で付与する。

## Flow 5: Audit / Monitoring

1. Secret Manager Data Access audit log を有効にする。
2. IAM Credentials API `signJwt` を監査対象にする。
3. Cloud Run request log と Back correlation id を突合可能にする。
