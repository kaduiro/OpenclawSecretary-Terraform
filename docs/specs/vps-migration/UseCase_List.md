# VPSインフラユースケース一覧

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: 運用ユースケース一覧
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: VPS構築・運用・移行で実行する行動の一覧

## 2. 目的

構築、配備、DB、秘密情報、監視、復旧、移行を操作単位で識別する。

## 3. 対象範囲

### 3.1 対象

VPSのライフサイクルとproduction運用を対象とする。

### 3.2 対象外

メール返信、予定調整、FAQ管理の業務ユースケースはBackの正本へ委ねる。

## 4. 前提

VPSはCHK-GOAL-001で現時点の第一選択として確定し、初期構成はCHK-OPS-001の単一12GB案を使う。DNSはCHK-IMPL-002によりCloudflare Providerで管理する。DEC-007の発動時はUC-OPS-006を実行する。

## 5. カテゴリ別サマリー

| 区分 | カテゴリ | 件数 |
|---|---|---:|
| 構築 | resource・OS | 2 |
| DB | migration | 1 |
| セキュリティ | secret・network | 2 |
| 外部連携 | Gmail Push | 1 |
| 自動処理 | timer・queue | 1 |
| 運用 | 監視・backup・復旧・費用・Architecture再評価 | 5 |
| release | deploy・rollback | 2 |
| 移行 | cutover | 1 |

## 6. 本文

| No | UC ID | ユースケース | 主体 | 種別 | 概要 |
|---:|---|---|---|---|---|
| 1 | UC-INF-001 | VPS・DNS resourceを作成する | インフラ管理者 | 通常 | Terraform plan承認後にConoHa Providerで対応5種のVPS資源を、Cloudflare ProviderでDNS zone/recordを管理する |
| 2 | UC-INF-002 | OSを再現する | インフラ管理者 | 自動/監査 | Ansibleでuser、SSH、firewall、Docker、時刻同期、監視を構成する |
| 3 | UC-DB-001 | DB migrationを適用する | migration実行者 | 通常 | advisory lockとchecksumを使って未適用SQLをtransaction適用する |
| 4 | UC-SEC-001 | secretと鍵を配備・rotationする | セキュリティ管理者 | 自動/監査 | SOPS/ageを復号しtmpfsへ配置し、旧鍵を段階廃止する |
| 5 | UC-SEC-002 | public到達範囲を検査する | セキュリティ管理者 | 制約/例外 | 80/443以外、DB、管理endpointがInternetから拒否されることを確認する |
| 6 | UC-EXT-001 | Gmail通知を受信する | system | 自動/監査 | Pub/Sub pushを受け、停止時はpollingで未処理メールを回収する |
| 7 | UC-JOB-001 | 定期処理と非同期処理を実行する | system | 自動/監査 | timerが内部endpointを起動し、workerがoutboxをleaseして再試行する |
| 8 | UC-OPS-001 | private管理経路へ接続する | 運用者 | 制約/例外 | overlay networkとSSH公開鍵を通過した端末だけが管理接続する |
| 9 | UC-OPS-002 | 異常を検知して通知する | system | 自動/監査 | availability、latency、resource、DB、backup、証明書を検査する |
| 10 | UC-OPS-003 | DB backupから復元する | 運用者 | 通常 | 新規PostgreSQLへbase backupとWALを適用し整合性を検証する |
| 11 | UC-OPS-004 | VPS障害から復旧する | 運用者 | 制約/例外 | TerraformとAnsibleで代替serverを作り、DBとserviceを復元する |
| 12 | UC-OPS-005 | 月額費用を確認する | 運用者 | 自動/監査 | VPS、storage、GCP外部APIの請求を別々に記録する |
| 13 | UC-REL-001 | 署名済みimageを配備する | CI/CD | 通常 | digest、SBOM、scan、Cosign検証後にpullする |
| 14 | UC-REL-002 | releaseをrollbackする | 運用者 | 制約/例外 | schema互換を確認し、旧digestへ戻してhealth checkする |
| 15 | UC-MIG-001 | GCPからVPSへcutoverする | 移行責任者 | 通常 | 並行検証、書込停止、最終同期、Cloudflare DNS切替、7日監視を実施する |
| 16 | UC-OPS-006 | Architectureを再評価する | Architecture Owner | 制約/例外 | 発動条件をEvidenceで確認し、危険な変更を停止した上で、VPS維持・増強、DB分離、Managed Service、Cloud移行を比較して別ADRで決定する |

## 7. 未確定事項

- UC-OPS-004の合格時間はRTOレビューで確定し、測定は`process_flow_design.md` §5.3の正本定義に従う。
- UC-EXT-001のPub/Sub廃止条件はpolling実測後に確定する。

## 8. 関連文書

- `requirements_definition.md`
- `process_flow_design.md`
- `rtm.md`
