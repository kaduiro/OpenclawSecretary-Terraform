# Infrastructure Requirements: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

この文書は Terraform repository のインフラ要件正本である。Back アプリケーション要件と Front HUD 要件はそれぞれ別 repository を正本とする。

## Scope

- Cloud Run Gateway / private API service
- Cloud SQL PostgreSQL + pgvector
- Secret Manager resource と IAM binding
- Cloud Scheduler / Cloud Tasks
- IAP / Gateway 境界
- service account、IAM role、DwD `signJwt` custom role
- Cloud Logging / Audit Logs / Monitoring
- Terraform state、import、plan、apply、legacy gcloud 手順の整理

## Functional Requirements

| ID | 要件 |
|---|---|
| INF-REQ-001 | Gateway は HUD からの入口として IAP 保護される |
| INF-REQ-002 | private API は unauthenticated invocation を許可しない |
| INF-REQ-003 | private API invoker は Gateway SA / Scheduler SA / Tasks SA に限定する |
| INF-REQ-004 | Cloud SQL は private access を前提にし、1 ユーザー 1 instance を MVP とする |
| INF-REQ-005 | Secret Manager は secret resource と IAM binding を Terraform 管理し、secret value は state に入れない |
| INF-REQ-006 | Scheduler / Tasks は OIDC token と専用 service account で private API を呼ぶ |
| INF-REQ-007 | Cloud Tasks の承認系 queue は retry による重複副作用を起こさない設定にする |
| INF-REQ-008 | DwD は service account key を発行せず、`iam.serviceAccounts.signJwt` に限定する |
| INF-REQ-009 | Secret Manager と IAM Credentials API の audit log を監査対象にする |
| INF-REQ-010 | 既存 gcloud resource は import-first で Terraform 管理へ移す |

## Non-Goals

- Back handler、DB query、AI/RAG、Google API client 実装
- HUD UI、Electron main / renderer 実装
- OpenAPI 正本の保持

## Acceptance Criteria

- Terraform plan に secret value が含まれない。
- private API に `allUsers` / `allAuthenticatedUsers` invoker が付かない。
- gcloud runbook は legacy と明記され、Terraform 正本と混同されない。
