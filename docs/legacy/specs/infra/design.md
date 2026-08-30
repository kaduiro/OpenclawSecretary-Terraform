# Infrastructure Design: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

## Components

| Component | Terraform Responsibility |
|---|---|
| Cloud Run Gateway | IAP 保護された HUD 入口、private API 呼び出し主体 |
| Cloud Run private API | Back application runtime、Gateway / Scheduler / Tasks からのみ invoked |
| Cloud SQL | PostgreSQL + pgvector、private connectivity、backup |
| Secret Manager | secret resource、replication、IAM binding |
| Cloud Scheduler | polling / retention job の定期起動 |
| Cloud Tasks | Calendar operation など非同期副作用処理 |
| IAM | service account、custom role、resource-level binding |
| IAP | Gateway の user-facing access control |
| Logging / Audit Logs | access、signJwt、secret access、request log の保持と検知 |

## Resource Ownership

- Terraform は resource と IAM を管理する。
- Secret value、OAuth client secret value、Gemini API key value は Terraform state に入れない。
- Google Workspace 管理コンソール上の DwD client 設定は Terraform 管理外の場合でも runbook で ownership を明記する。

## Network / Invocation Boundary

- HUD は Gateway URL のみを呼ぶ。
- Gateway は private API invoker を持つ service account で Back を呼ぶ。
- Scheduler / Tasks は専用 service account と OIDC audience で internal endpoint を呼ぶ。
- private API は direct user invoker を持たない。

## Terraform State Policy

- remote backend は versioning、encryption、access control を有効にする。
- import 済み resource は drift detection の対象にする。
- plan artifact を共有する場合は secret が含まれていないことを確認する。
