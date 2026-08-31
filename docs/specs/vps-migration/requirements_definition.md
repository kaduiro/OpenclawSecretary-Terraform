# VPS移行要件定義書

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: インフラ移行要件定義
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: VPS構築設計の要求正本

## 2. 目的

GCP compute/DBからVPSへ移行し、費用の予測性を高めながら、既存のAPI、DB migration、暗号化、監査、非同期処理を継続する。Pilotでは大幅な削減を前提にせず、重大な前提変更時に危険な構成を停止してArchitectureを再評価できるようにする。

## 3. 対象範囲

### 3.1 スコープ

VPS resource、OS、container、network、PostgreSQL、backup、認証境界、秘密情報、監視、CI/CD、移行と復旧を対象とする。

### 3.2 本版対象外

業務機能追加、画面変更、OpenAPI変更、全DB schemaの再設計、AI model変更は対象外とする。

## 4. 前提

- CHK-GOAL-001によりVPSは現時点の第一選択として確定済みである。DEC-007の発動時はFail Closedで再評価する。
- `CHK-SCOPE-001`によりGCP外部APIは段階的に残せる。
- CHK-OPS-001により12GB単一VPSを初期基準案とする。
- `CHK-EXT-001`、`CHK-SEC-001`、`CHK-IMPL-001`、`CHK-IMPL-002`、`CHK-APPROVAL-001`を設計・検証へ反映する。

## 5. 用語定義

| 用語 | 定義 |
|---|---|
| 実行基盤 | API、Gateway、Auth Bootstrap、worker、PostgreSQLを稼働させるVPS |
| KEK | データ暗号化鍵を暗号化する鍵 |
| RPO | 障害時に失うことを許容するデータ時間 |
| RTO | `process_flow_design.md` §5.3で定義する測定起点から復旧完了までの許容時間 |
| off-site backup | 実行VPSと障害領域が異なる保存先のbackup |

## 6. 利用者と権限

| ロール | 権限 | 制約 |
|---|---|---|
| 利用者 | Gateway経由で業務APIを利用 | DB、管理port、内部endpointへ到達不可 |
| 運用者 | deploy、監視確認、backup復元、鍵rotation | Tailscale/WireGuardとSSH公開鍵を必須とする |
| CI/CD | image発行、Terraform plan、承認後deploy | production秘密値の読み取りを禁止する |
| migration実行者 | DDLとmigration履歴更新 | runtime DB roleを兼任しない |
| runtime | 業務DML | DDLを拒否する |

## 7. 機能要件

| REQ-ID | 内容 | 優先度 | 根拠 | 検証方法 | 関連UC |
|---|---|---|---|---|---|
| REQ-INF-001 | API、Gateway、Auth Bootstrap、worker、DBをVPS上で起動できる | Must | CHK-GOAL-001 | staging起動試験 | UC-INF-001 |
| REQ-INF-002 | ConoHa Terraform ProviderでVPS Instance、SSH鍵、Volume、Security Group、Security Group RuleをTerraform管理する | Must | CHK-IMPL-001、DEC-005 | plan/apply/drift試験 | UC-INF-001 |
| REQ-INF-003 | OSとDocker設定をAnsible管理し、手動変更を検出する | Must | 再現性 | clean host再構築試験 | UC-INF-002 |
| REQ-INF-004 | DNS zoneとrecordをCloudflare Terraform Providerで管理し、ConoHa Terraform Providerの管理対象に含めない | Must | CHK-IMPL-002、DEC-005 | import/plan/apply/drift/rollback試験 | UC-INF-001、UC-MIG-001 |
| REQ-DB-001 | PostgreSQL 15とpgvectorを稼働させる | Must | 既存契約 | migrationとextension確認 | UC-DB-001 |
| REQ-DB-002 | Backの連番migration、advisory lock、checksumを継続する | Must | DEC-004 | 空DB、再実行、改変拒否試験 | UC-DB-001 |
| REQ-NET-001 | public ingressをTCP 80/443に限定し、DB portを公開しない | Must | 攻撃面削減 | 外部port scan | UC-SEC-002 |
| REQ-NET-002 | 運用SSHはprivate overlay network経由に限定する | Must | CHK-OPS-001 | public SSH拒否試験 | UC-OPS-001 |
| REQ-SEC-001 | deploy秘密値をSOPS/ageで暗号化し、実行時はtmpfsへ展開する | Must | CHK-SEC-001 | disk/commit scan | UC-SEC-001 |
| REQ-SEC-002 | refresh tokenを暗号化して保存し、KEKをDB外に置く | Must | CHK-SEC-001 | DB dump秘密値検査、復号認可試験 | UC-SEC-001 |
| REQ-EXT-001 | Gmail Pushは移行中Pub/Subを維持し、pollingをfallbackにする | Should | CHK-EXT-001 | push停止・polling回復試験 | UC-EXT-001 |
| REQ-JOB-001 | SchedulerとCloud TasksをtimerとDB outbox workerへ置換する | Must | GCP compute依存解消 | retry、lease、dead-letter試験 | UC-JOB-001 |
| REQ-OPS-001 | 5xx、latency、disk、memory、DB、backup、証明書期限を監視する | Must | 運用継続 | alert発火・復旧通知試験 | UC-OPS-002 |
| REQ-OPS-002 | DBの連続WAL archiveと日次backupをoff-siteへ保存する | Must | データ保護 | restore試験 | UC-OPS-003 |
| REQ-OPS-003 | 初期目標をRPO 15分、RTO 4時間とし、`process_flow_design.md` §5.3の起点・終点で測定して、超過時は2台化する | Should | CHK-OPS-001 | 障害復旧訓練 | UC-OPS-004 |
| REQ-REL-001 | imageをdigest固定し、SBOM、脆弱性scan、Cosign署名を検証する | Must | supply chain | 未署名image拒否試験 | UC-REL-001 |
| REQ-REL-002 | migration前backup、health check、旧digestへのrollbackをrelease手順に含める | Must | 復旧性 | release rehearsal | UC-REL-002 |
| REQ-COST-001 | VPS・backup・外部APIの月額を別項目で記録し、予算7,000円超過を通知する | Should | 費用目的 | 月次請求照合 | UC-OPS-005 |
| REQ-MIG-001 | GCPとVPSを並行稼働し、cutover後7日間はGCPをrollback先として保持する | Must | 移行リスク低減 | cutover rehearsal | UC-MIG-001 |
| REQ-GOV-001 | 法令、契約、重大なセキュリティ事故、RPO/RTO未達、Provider継続性、運用人員または3か月実測の総保有コストに重大な変化が発生した場合、影響するProduction変更と危険な外部Actionを停止し、VPS増強、複数台化、事業者変更、Database分離、Managed PostgreSQL、Cloud移行を含むArchitecture再評価を開始する | Must | DEC-007 | tabletop、Incident演習、Architecture Decision Review | UC-OPS-006 |

## 8. 非機能要件

### 8.1 認証・認可

Google Workspace OIDCのemail、hosted domain、nonce、state、PKCEを検証し、内部endpointはpublic routeへ公開しない。

### 8.2 データ分離

既存business unit境界を維持し、VPS移行によってtenant条件を削除しない。

### 8.3 データ整合性

DB cutoverは書き込み停止、最終dump/restore、sequence確認、checksum確認を一つの変更窓で実施する。

### 8.4 監査性・追跡性

deploy digest、migration filename/checksum、operator、開始終了時刻、backup ID、restore結果を90日保持する。

### 8.5 運用性

clean VPSから2時間以内にOS、Docker、設定、imageを再構築できる自動化を目標とする。

### 8.6 セキュリティ

root password loginを無効化し、SSH公開鍵、MFA付き管理overlay、default deny firewallを使用する。

### 8.7 性能・拡張性

72時間のPilot負荷でmemory使用率80%未満、disk使用率70%未満、API p95 2秒未満を合格条件とする。

## 9. 本文

Must要件はVPS production cutover前にすべて検証する。Should要件が未達の場合は、期限、所有者、影響、暫定統制をrelease記録へ残す。REQ-GOV-001の発動中は、再評価Decisionが閉じるまでProduction変更と危険な外部Actionを再開しない。

## 10. 未確定事項

- RPO 15分とRTO 4時間は構築案の初期値であり、利用部門の業務許容時間レビューを要する。目標値を確定するときは、`process_flow_design.md` §5.3の測定起点・終点も同時に承認する。
- ConoHa Terraform Providerの対象は公式に対応する5種resourceへ限定済みである。本番利用可否は固定版の受入試験後に確定する。
- Pub/Sub廃止日はpolling quota試験後に決める。
- 総保有コストへ算入する運用人件費は、月次運用時間を3か月測定して確定する。

## 11. 関連文書

- `shared_understanding.md`
- `UseCase_List.md`
- `infra_architecture_design.md`
- `security_design.md`
- `rtm.md`
