# OpenclawSecretary-Terraform

OpenclawSecretary-Terraform は、OpenClaw Secretary の GCP resource と権限境界を再現可能に管理する infrastructure repository です。アプリケーション契約は `OpenclawSecretary-Back` の OpenAPI、`src/config.js`、security/design docs を必ず正とします。

## 実装範囲

- IAP 保護 Gateway、redeem 専用 auth-bootstrap、非公開 API の Cloud Run
- IAP programmatic client と、明示した user/group/domain/serviceAccount だけの access member
- Gateway / Bootstrap / Scheduler / Tasks / Admin / Runtime / Migration の分離 service account と限定 invoker
- private IP Cloud SQL PostgreSQL 15、PITR、backup、production REGIONAL HA、API deletion protection
- Secret Manager、KMS、refresh token 用の条件付き IAM
- Back 正本の Scheduler jobs と Calendar Cloud Tasks queue
- Gmail `users.watch`用Pub/Sub topic、認証済みpush subscription、日次watch更新
- Vertex AI/DLP実行権限、JPY Billing budget、Pilot用費用guard
- migration Cloud Run Job、Audit Logs、5xx/auth-bootstrap deny/Cloud SQL CPU/Calendar queue/background failure alerts
- production image の同一 project Artifact Registry digest 制約、Terraform plan前の署名・脆弱性検証

この環境は Back の複数 users / business units を収容する「1組織・1環境」です。旧文書にある「1ユーザー・1サービス」は採用しません。

Terraform は OpenAPI、Back domain logic、DB query、Front HUD を保持しません。private API に public principal を付与せず、direct invoker は用途別 service account に限定します。secret value と service account key JSON は Terraform に保存しません。

## Bootstrap

1. `bootstrap/state` stack を local state で apply し、root 用 GCS backend を作成して state を移行する。
2. `terraform.tfvars.example` を基に secret 値を含まない tfvars を作り、`deploy_services=false` で apply する。
3. OAuth client secret の Secret Manager version を安全な運用経路で追加する。
4. 承認済み operator が `tools/bootstrap-db-roles.sql` を実行し、runtime/migration IAM DB user へ初期権限を付与する。
5. migration Job を実行し、`tools/grant-runtime-db-roles.sql` で runtime DML 権限を確定する。
6. migration 成功後に `deploy_services=true` で apply する。
7. IAP OAuth client ID を programmatic client として登録した状態で、Gateway URL と Auth Bootstrap URL を Front に設定する。

```powershell
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
node tools/check-back-contract.mjs ..\OpenclawSecretary-Back
node tools/check-current-docs.mjs
```

本番 state は `bootstrap/state` が作る versioning、uniform access、public access prevention 設定済みGCS backendに保存します。Cloud SQL REGIONAL、API/Gateway/Auth Bootstrapの`min_instances >= 1`、同一project Artifact Registryのdigest image、notification channelを必須とします。

## 低コストPilot

2ユーザー、1日30メールの初期利用では`pilot.tfvars.example`を基に、Cloud SQL `db-g1-small`/ZONAL、全Cloud Run minimum instance 0、maximum instance 2を使用します。Gmail Pushを主経路とし、フォールバックpollingは1時間、watch更新は日次です。月額予算は既定7,000円で、50/75/90/100%の実績額と100%予測額を通知します。

```powershell
terraform plan -var-file=pilot.tfvars
```

`billing_account_id`には実際の請求先IDが必要です。Billing budgetは通知のみでresourceを停止しないため、Backの日次Gemini request上限とCloud Run最大instance guardを併用します。Pilot設定は可用性を下げるためproductionへ転用できず、`checks.tf`がREGIONAL/minimum instance条件を別に強制します。

## 現在のレビューゲート

状態と受入条件の正本はBackの`docs/reviews/review-register.md`です。2026-07-21時点でproduction判定は`BLOCKED`です。

| ID | Terraform/CIの未完了 | 対策 |
|---|---|---|
| `CR-INF-HA-001` | production minimum instance guardは実装済みだが実環境の可用性確認がない | stagingでfailover、PITR/restore、削除拒否、revision切替を確認する |
| `CR-INF-OBS-001` | Gateway/API availabilityとrequest latency alertがない | uptime/absenceとlatency SLO alertを追加する |
| `CR-INF-SUPPLY-001` | Terraformはcosignを検証するが、Backにimage push/sign producerがない | Back release workflowで4 imageのdigest、SBOM、provenance、signatureを発行する |
| `CR-INF-IAP-001` | programmatic client/IAP拒否の実環境確認がない | stagingで登録client成功、未登録client/public principal拒否を確認する |
| `CR-INF-STATE-001` | state migrationと同時実行lockが未確認 | 実bucketでversion復元と競合testを行う |

## 未充足の外部入力

署名済みcontainer image digest、cosign identity/issuer、notification channel、billing account ID、state bucket/CI principal、初回DB grant operatorは環境ごとの外部入力です。加えてBack側にimage署名producer workflowが必要です。Calendar OAuth scopeはBackの現実装が`openid email gmail.modify`のみなので、Calendarを有効化する前にBack側のscopeと再同意処理を修正する必要があります。
