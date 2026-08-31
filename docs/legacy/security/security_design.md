# セキュリティ設計書（Terraform / Infrastructure）

作成日: 2026-06-25 | ステータス: DRAFT

この文書は OpenclawSecretary-Terraform が保持するインフラセキュリティの正本である。Google ID token 検証、PII 匿名化、approvalToken、アプリケーションログの出力制御などは `OpenclawSecretary-Back/docs/security/security_design.md` を正本とする。

## 目的

- Cloud Run、IAM、Secret Manager、Cloud SQL、Cloud Scheduler、Cloud Tasks、Cloud Logging / Audit Logs のセキュリティ境界を定義する。
- Terraform state / plan / apply に secret を混入させない運用方針を定義する。
- gcloud 手順から Terraform 管理へ移行する際の ownership と legacy procedure の扱いを定義する。

## 対象範囲

- Cloud Run service と invoker IAM
- IAP / Gateway / private API の境界
- service account と IAM binding
- Secret Manager resource と access policy
- Cloud SQL network / backup / retention
- Cloud Scheduler / Cloud Tasks OIDC 呼び出し設定
- Domain-wide Delegation 用 `signJwt` 権限
- Cloud Logging / Cloud Audit Logs
- Terraform state、import、plan、apply

## Cloud Run 境界

| service | 公開境界 | IAM 方針 |
|---|---|---|
| Gateway | HUD からの入口。IAP で保護する | IAP access を持つユーザーのみ入口に到達可能にする |
| private API | Gateway / Scheduler / Tasks からのみ呼ばれる内部 API | `--no-allow-unauthenticated` を維持し、invoker は必要な service account に限定する |

ユーザーに private API の `roles/run.invoker` を直接付与しない。HUD の認可は Gateway とバックエンドアプリケーションの Google ID token 検証で扱う。

## IAM principal

| principal | 用途 | 最小権限 |
|---|---|---|
| API service account | private API 実行 | 対象 secret の `secretAccessor`、refresh token secret の `secretVersionAdder`、必要な Cloud SQL 接続権限 |
| Gateway service account | Gateway 実行、private API 呼び出し | private API の `roles/run.invoker` |
| Scheduler service account | retention などの定期内部 endpoint 呼び出し | private API の `roles/run.invoker` |
| Tasks service account | 非同期内部 endpoint 呼び出し | private API の `roles/run.invoker` |
| DwD service account | Calendar Domain-wide Delegation の署名対象 | key を発行しない。API service account からの `signJwt` 対象に限定する |

広い `roles/iam.serviceAccountTokenCreator` は付与しない。DwD は `iam.serviceAccounts.signJwt` のみを含む custom role を対象 DwD service account に限定して付与する。

## Secret Manager

Terraform は secret resource、replication policy、IAM binding を管理する。ただし secret value は Terraform state に入れない。

| secret | 管理範囲 | value 管理 |
|---|---|---|
| `openclaw-{user_id}-gmail-refresh-token` | resource と IAM binding | アプリケーションが version 追加する。Terraform は値を持たない |
| `openclaw-{user_id}-oauth-client-secret` | resource と IAM binding | 手動登録または安全な bootstrap 手順で投入する |
| `openclaw-{user_id}-gemini-api-key` | resource と IAM binding | 手動登録または安全な bootstrap 手順で投入する |

禁止事項:

- `secret_data` を Terraform code、tfvars、state、plan artifact に入れない。
- service account key JSON を発行・保存・配布しない。
- secret accessor を project-wide に広げない。

## Cloud SQL

MVP は 1 ユーザー = 1 Cloud SQL instance を前提にし、共有 DB / RLS に依存しない。

| 項目 | インフラ方針 |
|---|---|
| network | private IP または許可済み connector 経由に限定する |
| public access | 不要な public IP / authorized networks を付与しない |
| backup | 自動 backup を有効化し、保持期間と復元手順を docs 化する |
| encryption | GCP managed encryption を既定とし、CMEK 要否は別途判断する |
| access | アプリケーション service account に必要最小接続権限を付与する |

Cloud SQL backup の暗号化、IAM、保持期間は Terraform 側で管理する。DB 内の PII マスク処理は Back 正本で扱う。

## Cloud Scheduler / Cloud Tasks

Cloud Scheduler と Cloud Tasks は OIDC token を付与して private API を呼び出す。

| resource | Terraform 管理項目 |
|---|---|
| Cloud Scheduler job | schedule、target URL、OIDC audience、service account email |
| Cloud Tasks queue | rate limit、retry config、OIDC audience、service account email |

アプリケーションが重複処理に耐える前提は置くが、承認系の task は原則 `maxAttempts=1` とする。定期 retention job は対象件数と失敗件数のみをログに出す設計とし、PII を含む payload を task / scheduler 設定に入れない。

## Domain-wide Delegation

DwD の infrastructure ownership は Terraform が持つ。

- DwD service account key JSON は発行しない。
- API service account に対象 DwD service account への `iam.serviceAccounts.signJwt` のみを付与する。
- Google Workspace 側の DwD client / scope 設定は手順書に記録し、Terraform 管理外の場合も ownership を明記する。
- `iamcredentials.googleapis.com` の audit log を有効化し、想定外 service account からの `signJwt` を検知対象にする。

## Cloud Logging / Audit Logs

| 対象 | 方針 |
|---|---|
| Secret Manager | Data Access audit log を有効化し、OpenClaw API service account 以外の access を検知対象にする |
| IAM Credentials API | `signJwt` 呼び出しを監査対象にする |
| Cloud Run | request log と application correlation id を突合可能にする |
| Cloud SQL | Data Access audit log は費用対効果を確認して有効化可否を決定する |

ログ sink、retention、alert policy は Terraform 管理対象とする。アプリケーションログの PII 出力制御は Back 正本で扱う。

## Terraform state / plan / apply

- 既存 gcloud 作成 resource は import-first で Terraform 管理へ移す。
- `terraform plan` で意図しない destroy / replace が出た場合は apply しない。
- state backend は access 制御、versioning、encryption を有効にする。
- plan artifact を共有する場合は secret が含まれていないことを確認する。
- tfvars に secret value を置かない。secret resource id、service account email、region などの非 secret のみを扱う。
- legacy gcloud 手順は `docs/legacy/` または migration docs に残し、Terraform 管理後の正本ではないことを明記する。

## STRIDE 脅威と対策

| 分類 | 脅威 | インフラ対策 |
|---|---|---|
| Spoofing | private API に任意 caller が到達する | Cloud Run invoker を Gateway / Scheduler / Tasks service account に限定する |
| Tampering | Terraform 外で IAM / service 設定が変更される | drift detection、plan review、import-first |
| Repudiation | secret access や signJwt の否認 | Secret Manager / IAM Credentials API の Data Access audit log |
| Information Disclosure | secret value が state / plan / log に混入する | secret value を Terraform 管理外にし、state access を制限する |
| Elevation of Privilege | 広すぎる service account 権限 | custom role、resource-level IAM、Token Creator の不使用 |
| Denial of Service | queue retry や scheduler による過剰呼び出し | rate limit、retry config、承認系 task の `maxAttempts=1` |

## 検証方法

- `terraform plan` に secret value、意図しない destroy / replace が出ないことを確認する。
- Cloud Run private API に `allUsers` / `allAuthenticatedUsers` invoker が付与されていないことを確認する。
- Gateway、Scheduler、Tasks 以外の principal に private API invoker がないことを確認する。
- Secret Manager の accessor / version adder が対象 service account と対象 secret に限定されていることを確認する。
- DwD service account に key が存在せず、`signJwt` custom role だけが付与されていることを確認する。
- Cloud Scheduler / Cloud Tasks の OIDC audience と service account email が設計値と一致することを確認する。
- Audit Logs が Secret Manager と IAM Credentials API で有効になっていることを確認する。

## 関連文書

- `OpenclawSecretary-Back/docs/security/security_design.md`
- `OpenclawSecretaryAndo/docs/MOVED.md`
