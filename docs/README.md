# OpenclawSecretary-Terraform Docs

更新日: 2026-08-30

## インフラ方針の最終決定

実行基盤はVPSを採用します。この判断は最終決定であり、GCPのCloud Run / Cloud SQLを目標構成へ戻しません。

- `specs/vps-migration/vps_gcp_comparison.md`: VPS・GCP比較と採用判断の正本
- `specs/vps-migration/shared_understanding.md`: 確定事項と検証事項
- `specs/vps-migration/requirements_definition.md`: VPS移行要件
- `specs/vps-migration/infra_architecture_design.md`: VPS目標構成
- `specs/vps-migration/package_structure_design.md`: Terraform / Ansible / Docker Compose構成
- `specs/vps-migration/security_design.md`: VPSへ移るセキュリティ責任と統制
- `specs/vps-migration/process_flow_design.md`: 構築、release、復旧、cutoverフロー
- `specs/vps-migration/rtm.md`: 要件と検証の追跡
- `specs/vps-migration/implementation_tasks.md`: 段階別の実装タスク、依存関係、完了条件、production移行gate

`current/architecture.md`とrootのGCP HCLは移行元の現状資料です。VPS cutover完了まではrollbackと差分確認のため保持し、VPSの目標判断と矛盾する場合は`specs/vps-migration/`を優先します。

API、application security、認証・認可、DB application contract の正本は `OpenclawSecretary-Back/docs/` です。Terraform repository の移行元文書は次です。

- `current/architecture.md`: GCP移行元 infrastructure 境界とrelease gate
- root `README.md`: bootstrap、validation、外部入力
- `.tf`、`tests/production_guards.tftest.hcl`: resource と強制条件の実行可能な正本

`legacy/` は過去の検討・手順資料です。現行 HCL、Back 正本、`contracts/back-contract.lock.json` と矛盾する場合は使用しません。手動 `gcloud` 手順を現行運用へ戻す場合は、先に Terraform 管理との ownership と drift 対策を明示します。

既存GCP構成の指摘ID、severity、status、受入条件はBackの`docs/reviews/review-register.md`で管理します。VPS移行の確認ID、要件ID、UC IDは`specs/vps-migration/`で管理し、指摘IDとは混在させません。GCP HCLの事実は`current/architecture.md`、VPSの目標は`specs/vps-migration/infra_architecture_design.md`に分離します。
