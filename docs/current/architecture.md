# Current Infrastructure Architecture

更新日: 2026-07-21
契約正本: `OpenclawSecretary-Back/docs/`

> **移行元資料:** 2026-08-30にVPS採用が最終決定されました。本書はGCP移行元の現状確認とrollback参照に限定します。目標構成の正本は`../specs/vps-migration/infra_architecture_design.md`です。

## 境界

- Gateway は IAP で保護し、IAP access は明示した user/group/domain/serviceAccount に限定する。
- Electron の programmatic access 用 OAuth client ID は project-level IAP settings に登録する。
- Auth Bootstrap だけを未認証で到達可能にし、redeem route 以外は Back の application authorization で拒否する。
- API は非公開とし、Gateway、Bootstrap、Scheduler、Tasks、Admin の用途別 service account だけを invoker にする。
- runtime と migration は別 service account、別 IAM database user、別 DB role を使用する。

## Production Guards

- Cloud SQL は REGIONAL、PITR と backup retention を有効にし、Terraform と API の deletion protection を設定する。
- API、Gateway、Auth Bootstrapは最低一instanceを維持する。
- image は同一 GCP project の Artifact Registry digest だけを受理する。
- Terraform CIはplanの前に全imageのkeyless signatureとHIGH/CRITICAL vulnerabilityを検証する。
- notification channelを必須とし、5xx、auth-bootstrap deny、Cloud SQL CPU、Calendar queue depth、background job failureを監視する。

## Open Remediation

| ID | 現行との差 | 完了条件 |
|---|---|---|
| `CR-INF-HA-001` | production guardは実装済みだが実環境のHA確認がない | stagingでfailover、PITR/restore、削除拒否、revision切替を通す |
| `CR-INF-OBS-001` | Gateway/API availabilityとrequest latency alertが未定義 | uptimeまたはmetric absenceとlatency SLO alertをHCL化し発火確認する |
| `CR-INF-SUPPLY-001` | consumer側のcosign verifyはあるが、Back側のpush/SBOM/provenance/sign producerがない | 4 imageをtrusted workflowで発行し、未署名image拒否を確認する |
| `CR-INF-IAP-001` | IAP programmatic clientとpublic principal guardは静的検証のみ | stagingでpositive/negative accessを確認する |

## Pilot Profile

- 対象負荷は初期2ユーザー、1日30メールとする。
- Cloud SQLは`db-g1-small`/ZONAL、Cloud RunはAPI/Gateway/Auth Bootstrapすべてminimum instance 0、maximum instance 2とする。
- Gmail `users.watch` → Pub/Sub authenticated push → private APIを主経路とし、watchは日次更新、フォールバックpollingは1時間周期とする。
- AI有効時はruntime SAへVertex AI/DLP権限を付与し、BackのDLP匿名化、Flash-Lite優先、Flash条件昇格、日次request上限を使用する。
- Billing budgetは月額7,000円を既定とする。通知はresourceを停止しないため、費用超過の強制防止にはならない。
- PilotのZONAL/scale-to-zeroは停止時間とcold startを許容する評価用設定であり、production guardへ持ち込まない。

## Release Gate

`terraform fmt -check -recursive`、`validate`、`test`、Back contract digest、docs check、TFLint、Trivy config scan を通すだけでは production 適用を許可しません。staging で次を確認します。

1. IAP browser login と programmatic token の成功、public principal と未登録 client の拒否。
2. Auth Bootstrap から redeem 以外を呼べないこと。
3. runtime identity の DDL 拒否と migration identity の適用成功。
4. failover、PITR、backup restore、deletion protection。
5. 実装済みalertと追加するavailability/latency alertの発火、通知、復旧通知。
6. Back producerが署名したdigest、cosign検証対象、Terraform plan対象の一致。
