# VPS移行RTM

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: RTM
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: 確認事項、要件、ユースケース、設計、検証の追跡表

## 2. 目的

VPS移行のMust/Should要件に実行主体と合否判定を割り当てる。

## 3. 対象範囲

### 3.1 対象

本specの全REQ-ID、UC-ID、CHK-IDを対象とする。

### 3.2 対象外

Backの業務要件とFrontの画面要件は各repositoryのRTMへ委ねる。

## 4. 前提

VPSは現時点の第一選択として確定済みであり、状態「設計済み」は実装完了を意味しない。REQ-GOV-001の発動時はArchitectureを再評価する。

## 5. 本文

| 確認ID | REQ-ID | 要件概要 | 優先度 | UC-ID | 処理フロー | DB/データ | インフラ | セキュリティ | 検証方法 | 状態 |
|---|---|---|---|---|---|---|---|---|---|---|
| CHK-GOAL-001 | REQ-INF-001 | serviceをVPSで起動 | Must | UC-INF-001 | 初期構築 | PostgreSQL | VPS、Compose | private network | staging起動 | 設計済み |
| CHK-IMPL-001 | REQ-INF-002 | ConoHa対応5種をTerraform管理 | Must | UC-INF-001 | 初期構築 | ConoHa state | ConoHa modules | secret値をstateから除外 | plan/apply/drift | 設計済み |
| CHK-IMPL-001 | REQ-INF-003 | OSをAnsible管理 | Must | UC-INF-002 | 初期構築 | なし | Ansible roles | SSH hardening | clean host再構築 | 設計済み |
| CHK-IMPL-002 | REQ-INF-004 | Cloudflare DNSをTerraform管理 | Must | UC-INF-001、UC-MIG-001 | 初期構築、cutover | DNS state | Cloudflare Provider | zone限定API token、変更監査 | import/plan/apply/drift/rollback | 設計済み |
| CHK-OPS-001 | REQ-DB-001 | PostgreSQL 15とpgvector | Must | UC-DB-001 | application release | 業務schema | DB container/volume | role分離 | extension確認 | 設計済み |
| CHK-OPS-001 | REQ-DB-002 | migration継続 | Must | UC-DB-001 | application release | schema_migrations | migration container | checksum、lock | 空DB・再実行 | 設計済み |
| CHK-SEC-001 | REQ-NET-001 | 80/443以外を非公開 | Must | UC-SEC-002 | 初期構築 | DB port | security group、firewall | default deny | external port scan | 設計済み |
| CHK-OPS-001 | REQ-NET-002 | SSHをoverlay限定 | Must | UC-OPS-001 | 初期構築 | operator log | overlay network | MFA、公開鍵 | public SSH拒否 | 設計済み |
| CHK-SEC-001 | REQ-SEC-001 | deploy secretをSOPS/age管理 | Must | UC-SEC-001 | application release | tmpfs secret | Ansible、Compose | root 0400 | disk/commit scan | 設計済み |
| CHK-SEC-001 | REQ-SEC-002 | refresh token暗号化 | Must | UC-SEC-001 | application release | provider_credentials | API crypto provider | DB外KEK、AAD | dump秘密値検査 | 設計済み |
| CHK-EXT-001 | REQ-EXT-001 | Pub/Subとpolling fallback | Should | UC-EXT-001 | cutover | mailbox_poll_state | Pub/Sub endpoint、timer | push token検証 | push停止試験 | 設計済み |
| CHK-SCOPE-001 | REQ-JOB-001 | timerとoutbox worker | Must | UC-JOB-001 | application release | outbox_events | systemd、worker | job token、private route | retry/dead-letter | 設計済み |
| CHK-OPS-001 | REQ-OPS-001 | metrics/log/alert | Must | UC-OPS-002 | 初期構築 | redacted log | exporter、外部監視 | PII禁止 | alert発火復旧 | 設計済み |
| CHK-OPS-001 | REQ-OPS-002 | off-site backup | Must | UC-OPS-003 | DB backup復元 | WAL、base backup | Object Storage | client-side暗号化 | 月次restore | 設計済み |
| CHK-OPS-001 | REQ-OPS-003 | RPO 15分、RTO 4時間 | Should | UC-OPS-004 | DB backup復元 | restore DB、RTO測定記録 | Terraform、Ansible | 隔離restore | `process_flow_design.md` §5.3の起点・終点によるDR訓練 | 仮置き |
| CHK-APPROVAL-001 | REQ-REL-001 | 署名済みdigest | Must | UC-REL-001 | application release | release ledger | GHCR、GitHub Actions | Cosign、SBOM | 未署名拒否 | 設計済み |
| CHK-APPROVAL-001 | REQ-REL-002 | backupとrollback | Must | UC-REL-002 | application release | backup ID、migration | deploy workflow | 承認gate | release rehearsal | 設計済み |
| CHK-OPS-001 | REQ-COST-001 | 月額7,000円通知 | Should | UC-OPS-005 | 月次運用 | 請求記録 | provider請求、予算表 | 請求権限分離 | 請求照合 | 設計済み |
| CHK-SCOPE-001、CHK-IMPL-002 | REQ-MIG-001 | 並行稼働と7日rollback | Must | UC-MIG-001 | cutover | export/restore | GCP、VPS、Cloudflare DNS | 書込停止、DNS変更監査 | rehearsal | 設計済み |
| CHK-GOAL-001、CHK-OPS-001、CHK-SEC-001 | REQ-GOV-001 | 重大な前提変更時のProduction変更・危険な外部Action停止とArchitecture再評価 | Must | UC-OPS-006 | Architecture再評価 | Risk、費用、Decision Evidence | VPS、Managed DB、Cloud候補 | 外部Action停止、独立Review | tabletop、Incident演習、Decision Review | 設計済み |

### 5.1 追加ユースケース追跡

| 確認ID | REQ-ID | 要件概要 | 優先度 | UC-ID | 処理フロー | DB/データ | インフラ | セキュリティ | 検証方法 | 状態 |
|---|---|---|---|---|---|---|---|---|---|---|
| CHK-OPS-001 | REQ-OPS-002 | backup異常検知 | Must | UC-OPS-003 | DB backup復元 | backup catalog | external monitor | checksum | stale backup alert | 設計済み |
| CHK-OPS-001 | REQ-OPS-003 | host障害復旧 | Should | UC-OPS-004 | DB backup復元 | restore DB | replacement VPS | private access | §5.3の起点・終点で4時間計測 | 仮置き |
| CHK-APPROVAL-001 | REQ-REL-002 | 旧digest復帰 | Must | UC-REL-002 | application release | schema互換 | Compose | operator承認 | rollback smoke | 設計済み |

### 5.2 実装タスク追跡

| REQ-ID | 実装タスク | 受入タスク | 実装状態 |
|---|---|---|---|
| REQ-INF-001 | TASK-INF-001、TASK-INF-004、TASK-APP-001、TASK-AUTH-001 | TASK-VAL-001、TASK-MIG-001 | 未着手 |
| REQ-INF-002 | TASK-BASE-001、TASK-BASE-002、TASK-BASE-003、TASK-INF-001 | TASK-VAL-001 | 未着手 |
| REQ-INF-003 | TASK-INF-003、TASK-INF-004 | TASK-VAL-001 | 未着手 |
| REQ-INF-004 | TASK-BASE-004、TASK-INF-002 | TASK-VAL-001、TASK-VAL-006 | 未着手 |
| REQ-DB-001 | TASK-DB-001、TASK-APP-001 | TASK-VAL-001 | 未着手 |
| REQ-DB-002 | TASK-DB-002 | TASK-VAL-001、TASK-VAL-005 | 未着手 |
| REQ-NET-001 | TASK-NET-001 | TASK-VAL-002 | 未着手 |
| REQ-NET-002 | TASK-NET-001 | TASK-VAL-002 | 未着手 |
| REQ-SEC-001 | TASK-AUTH-001、TASK-SEC-001 | TASK-VAL-002 | 未着手 |
| REQ-SEC-002 | TASK-SEC-002、TASK-DB-002 | TASK-VAL-002、TASK-VAL-004 | 未着手 |
| REQ-EXT-001 | TASK-EXT-001 | TASK-VAL-006、TASK-MIG-002 | 未着手 |
| REQ-JOB-001 | TASK-JOB-001、TASK-JOB-002 | TASK-VAL-005 | 未着手 |
| REQ-OPS-001 | TASK-OPS-002 | TASK-VAL-002、TASK-MIG-003 | 未着手 |
| REQ-OPS-002 | TASK-BASE-005、TASK-OPS-001 | TASK-VAL-004、TASK-MIG-003 | 未着手 |
| REQ-OPS-003 | TASK-OPS-002 | TASK-VAL-003、TASK-VAL-004、TASK-MIG-003 | 未着手 |
| REQ-REL-001 | TASK-REL-001 | TASK-VAL-002 | 未着手 |
| REQ-REL-002 | TASK-REL-002、TASK-DOC-001 | TASK-VAL-005 | 未着手 |
| REQ-COST-001 | TASK-OPS-003 | TASK-MIG-003、TASK-MIG-004 | 未着手 |
| REQ-MIG-001 | TASK-INF-002、TASK-DOC-001、TASK-MIG-001、TASK-MIG-002、TASK-MIG-003、TASK-MIG-004 | TASK-VAL-006 | 未着手 |
| REQ-GOV-001 | TASK-OPS-003、TASK-DOC-001、TASK-MIG-003、TASK-MIG-004 | TASK-VAL-004、TASK-VAL-006 | 未着手 |

## 6. 未確定事項

- 状態「仮置き」のRPO/RTO目標値は利用部門レビューとDR計測後に確定する。RTOの測定起点・終点は`process_flow_design.md` §5.3を正本とし、目標値と同時に承認する。
- 実装完了後、状態を「検証済み」へ更新し、証跡URLまたはartifact IDを追加する。

## 7. 関連文書

- `shared_understanding.md`
- `requirements_definition.md`
- `UseCase_List.md`
- `process_flow_design.md`
- `infra_architecture_design.md`
- `security_design.md`
- `implementation_tasks.md`
