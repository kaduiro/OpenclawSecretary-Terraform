# Infrastructure Test Plan: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

## Static Checks

- `terraform fmt -check`
- `terraform validate`
- `terraform plan` に secret value が含まれていないこと
- plan に意図しない destroy / replace がないこと

## Security Checks

- private API に `allUsers` / `allAuthenticatedUsers` invoker がない
- private API invoker が Gateway SA / Scheduler SA / Tasks SA に限定されている
- Secret Manager accessor / version adder が対象 secret と対象 service account に限定されている
- DwD service account key が 0 件である
- `signJwt` custom role が対象 service account にだけ付与されている

## Runtime Verification

- Gateway 経由の `/v1/health` が成功する
- private API direct call が user credential で失敗する
- Scheduler / Tasks OIDC call が Back の allowlist と一致する
- Secret Manager / IAM Credentials API の audit log が記録される

## Acceptance

- gcloud legacy 手順を使わずに再現可能な Terraform plan がある。
- state / plan / logs に secret value が混入しない。
- Back / Front の contract を壊す resource name / env var 変更がない。
