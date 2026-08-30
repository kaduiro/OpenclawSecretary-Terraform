# Infrastructure Use Case List: OpenclawSecretary

作成日: 2026-06-25 | ステータス: DRAFT

| UC | Terraform Responsibility |
|---|---|
| INF-UC-001 | 1 ユーザー用 GCP project / environment を初期化する |
| INF-UC-002 | Gateway と private API の Cloud Run service を作成・更新する |
| INF-UC-003 | Cloud SQL PostgreSQL + pgvector を private connectivity で構成する |
| INF-UC-004 | Secret Manager resource と最小権限 IAM binding を管理する |
| INF-UC-005 | Scheduler job で Gmail polling / retention を起動する |
| INF-UC-006 | Cloud Tasks queue で Calendar operation worker を起動する |
| INF-UC-007 | DwD `signJwt` custom role と audit log を構成する |
| INF-UC-008 | IAP / Gateway access を管理する |
| INF-UC-009 | legacy gcloud resource を Terraform import する |
| INF-UC-010 | plan review で意図しない destroy / public exposure を防ぐ |
