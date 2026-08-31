# VPS移行の共通理解確認

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: 共通理解確認
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: GCPからVPSへ移行する要件定義前の認識合わせ結果

## 2. 目的

VPSを現時点の第一選択Architectureとして記録し、確定事項、構築時に検証する事項、重大な前提変更時の再評価条件を分離する。

## 3. 対象範囲

### 3.1 対象

VPS採用、GCPとの費用比較、VPS上の実行基盤、DB、認証、秘密情報、非同期処理、監視、バックアップ、CI/CD、移行方式を対象とする。

### 3.2 対象外

OpenAPI、業務ロジック、画面仕様、既存DB全体の論理設計変更は対象外とする。

## 4. 前提

| 前提ID | 内容 | 根拠 | 確認状態 |
|---|---|---|---|
| PRE-001 | 実行基盤はVPSとし、GCPのCloud RunとCloud SQLを移行先にしない | ユーザー指示 | 確認済み |
| PRE-002 | VPSは現時点の第一選択であり、通常の実装期間中は根拠なく再選定しない。重大な前提変更時はFail Closedで再評価する | ユーザー指示と2026-08-31の是正判断 | 確認済み |
| PRE-003 | PostgreSQL 15、pgvector、既存migrationを継続する | 現行Back実装 | 確認済み |
| PRE-004 | 初期負荷は2ユーザー、1日30メールを基準にする | 現行Pilot設定 | 確認済み |
| PRE-005 | VPS事業者の基準案はConoHa VPS Ver.3.0とする | 国内配置、料金、公開API、Terraform providerの存在 | agent採用案 |
| PRE-006 | 権威DNSはCloudflare DNSとし、Cloudflare Terraform Providerで管理する | ConoHa Terraform ProviderにDNS resourceがなく、Cloudflare ProviderにはDNS record resourceがある | 採用決定 |

## 5. 本文

### 5.1 確認対象

| 確認カテゴリ | 既存情報から判断できる事項 | ユーザー確認が必要な事項 |
|---|---|---|
| 目的・成功条件 | GCPの固定費とマネージド料金を削減し、VPS上で再現可能に運用する | なし |
| 対象範囲 | Cloud Run、Cloud SQL、IAP、KMS、Secret Manager、Scheduler、Tasks、監視の置換が必要 | なし |
| データ所有 | DB schemaとmigrationはBackが正本 | なし |
| 外部連携 | Gmail PushはGoogle Pub/Subに依存する | 完全廃止時の許容遅延は構築前ベンチマークで決める |
| セキュリティ | refresh tokenと暗号鍵を同一DBへ平文保存できない | 鍵管理方式はセキュリティ試験で確定する |
| 運用・障害 | 単一VPSは単一障害点になる | 本番のRTO/RPOは運用試験後に最終承認する |
| 実装制約 | ConoHa Terraform Providerはベータ版で、対応resourceはVPS Instance、SSH鍵、Volume、Security Group、Security Group Ruleに限られる | provider固定版の受入試験が必要 |
| DNS管理 | ConoHa Terraform ProviderはDNS resourceを持たない | Cloudflare DNSのzone/recordをCloudflare Terraform Providerで管理する |

### 5.2 問い

| 確認ID | 論点 | 影響度 | 推奨回答 | 推奨理由 | 別案・トレードオフ | ユーザー回答 | 採用判断 | 影響するREQ・UC・設計文書 |
|---|---|---|---|---|---|---|---|---|
| CHK-GOAL-001 | 実行基盤をGCPかVPSのどちらにするか | High | VPS | 将来のProduction費用、固定費の予測性、Docker/PostgreSQLの可搬性を重視できる | Pilot削減は0〜1,700円/月にとどまり、VPSは可用性と運用責任で不利になる | VPSを採用し、重大な前提変更時はFail Closedで再評価する | VPSを現時点の第一選択とし、不可逆には固定しない | REQ-INF-001、REQ-GOV-001、UC-INF-001、UC-OPS-006、全設計文書 |
| CHK-SCOPE-001 | GCPを完全廃止するか | Middle | 移行初期はPub/SubとAI/DLPの外部API利用を許可する | Gmail Pushを維持しながら段階移行できる | 完全廃止はpolling遅延とBack改修が増える | VPS採用のみ確定 | GCP compute/DBは廃止し、外部APIは段階判定する | REQ-EXT-001、UC-MIG-001 |
| CHK-OPS-001 | 初期本番を単一VPSか2台にするか | Middle | 初期は12GB単一VPS、復元試験後に2台化判定 | 現行負荷に対して費用を抑えられる | 2台構成は停止時間を短縮するが月額と運用が増える | 指定なし | 単一VPSを基準案とし、RTO試験で昇格する | REQ-OPS-003、UC-OPS-004 |
| CHK-EXT-001 | Gmail Pushを維持するか | Middle | Pub/Subを暫定維持する | メール受信遅延を増やさず移行できる | pollingのみならGCP依存を減らせる | 指定なし | 暫定維持を基準案とする | REQ-EXT-001、UC-EXT-001 |
| CHK-SEC-001 | refresh tokenの保存方式 | Middle | 暗号化DB列とDB外KEKを使う | 動的なユーザー秘密情報をGit管理から分離できる | 外部Vaultは分離性が上がるが費用と構成が増える | 指定なし | 暗号化DB列を基準案とし、脅威試験で確定する | REQ-SEC-002、UC-SEC-001 |
| CHK-IMPL-001 | VPS事業者 | Middle | ConoHa VPS Ver.3.0 | 国内、低価格、APIとTerraform providerがある | さくらのクラウドはTerraform成熟度が高いが月額が上がる | 指定なし | ConoHaを基準案とする | REQ-INF-002、UC-INF-001 |
| CHK-IMPL-002 | DNSのIaC管理方式 | Middle | Cloudflare DNSをCloudflare Terraform Providerで管理する | ConoHa Terraform ProviderにはDNS resourceがなく、Cloudflare側はzone/recordの差分管理が可能 | ConoHa DNS API専用scriptはstate、plan、drift検知を別実装する必要がある | 指定なし | Cloudflare DNSを採用し、ConoHa Providerの管理対象からDNSを除外する | REQ-INF-004、UC-INF-001、UC-MIG-001 |
| CHK-APPROVAL-001 | 実装タスク化の開始条件 | Low | 本文書群のレビュー後に開始する | 未承認のRTO、鍵管理、provider制約を実装へ混入させない | 即時実装は手戻りの可能性が増える | 2026-08-30に「次の工程のタスク分解へ進めて」と指示 | 要件レビューゲート通過とし、`implementation_tasks.md`を作成する | 全REQ、RTM、実装タスク |

### 5.3 決定事項

| 決定ID | 決定内容 | 根拠 | 影響範囲 | 確認ID |
|---|---|---|---|---|
| DEC-001 | VPSを現時点の第一選択実行基盤として採用する | ユーザー決定と費用・可搬性比較 | IaC、実行、DB、運用 | CHK-GOAL-001 |
| DEC-002 | GCP Terraformは移行完了まで読み取り可能な移行元として保持する | rollbackと構成比較に必要 | Terraform repository | CHK-SCOPE-001 |
| DEC-003 | アプリはDocker Compose、ホスト構成はAnsible、VPS資源はTerraformで管理する | 責務を分離できる | package、CI/CD | CHK-IMPL-001 |
| DEC-004 | DB migrationの正本はBackの`migrations/`に維持する | 既存のチェックサムとlockを継続できる | DB、release | CHK-OPS-001 |
| DEC-005 | ConoHa Providerは対応する5種のVPS資源だけを管理し、DNSはCloudflare Providerへ分離する | Providerの実対応範囲とTerraformによる差分管理を両立する | IaC、DNS、cutover | CHK-IMPL-001、CHK-IMPL-002 |
| DEC-006 | 要件レビューゲートを通過し、実装タスク分解へ進む | ユーザー指示 | implementation_tasks、RTM、validation | CHK-APPROVAL-001 |
| DEC-007 | 法令、契約、重大事故、RPO/RTO、Provider、運用人員、総保有コストの重大変化時はProduction変更と危険な外部Actionを停止し、VPS維持だけに結論を固定せずArchitectureを再評価する | Fail Closedと実証主義を維持するため | Governance、Incident、費用、移行 | CHK-GOAL-001、CHK-OPS-001 |

### 5.4 未解決事項

| 未解決ID | 内容 | 影響度 | 保留理由 | 仮置き判断 | 次の確認方法 | 関連確認ID |
|---|---|---|---|---|---|---|
| OPEN-001 | 単一VPSでの実測メモリ上限 | Middle | 実コンテナ負荷の測定前 | 12GBを開始サイズとする | 72時間負荷試験 | CHK-OPS-001 |
| OPEN-002 | ConoHa Terraform Providerの本番利用可否 | Middle | providerがベータ版 | 版を固定し、VPS Instance、SSH鍵、Volume、Security Group、Security Group Ruleだけを管理する。DNSは明示的に対象外とし、Cloudflare Providerへ分離する | disposable環境で5種resourceの作成・変更・再作成試験とCloudflare DNS recordのimport・変更・復旧試験 | CHK-IMPL-001、CHK-IMPL-002 |
| OPEN-003 | refresh token用KEKの最終保管先 | Middle | 復旧と侵害耐性の比較が未実施 | root専用SOPS/age鍵を使う | key rotationとbackup restore試験 | CHK-SEC-001 |
| OPEN-004 | Pub/Subを廃止できるpolling周期 | Low | Google API quotaと遅延の測定前 | PilotはPub/Subを残す | stagingで1時間pollingを計測 | CHK-EXT-001 |

## 6. 未確定事項

VPSの現時点での採用とCloudflare DNS採用そのものは未確定事項に含めない。ただしDEC-007の発動条件を満たした場合は、未確定事項ではなく正式なArchitecture再評価として別ADRで扱う。OPEN-001からOPEN-004は、VPS内の実装方式を確定する受入試験項目として扱う。

## 7. 関連文書

- `vps_gcp_comparison.md`
- `requirements_definition.md`
- `infra_architecture_design.md`
- `security_design.md`
- `rtm.md`
