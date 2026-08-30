# VPS移行設計検証報告

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: 設計文書検証報告
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: 文書構成と既存実装との整合性検査記録

## 2. 目的

VPS移行文書がレビュー可能な構成を持ち、既存GCP依存とDB migrationを見落としていないことを確認する。

## 3. 対象範囲

### 3.1 対象

`docs/specs/vps-migration/`の文書と、現行Terraform、BackのGCP import、migration runner、実装タスク追跡を対象とする。

### 3.2 対象外

実VPS、実DNS、実backup、実providerに対する動作試験は対象外とする。

## 4. 前提

本報告の合格は設計文書の静的検査であり、production release許可を意味しない。

## 5. 本文

### 5.1 静的確認対象

| 確認 | 対象 | 期待結果 |
|---|---|---|
| 必須文書 | spec-driven-dev標準文書 | 全文書あり |
| 共通見出し | 各文書 | 文書概要、目的、対象範囲、前提、本文、未確定事項、関連文書あり |
| 追跡 | CHK、REQ、UC、RTM | 相互参照あり |
| フロー | process_flow_design | Mermaidと正常系・例外系あり |
| DB差分 | DB文書3点 | migrationとcredential差分あり |
| インフラ | architecture/package | provider責務境界、network、operation、CI/CD、stateあり |
| security | security_design | STRIDE、secret、audit、testあり |
| 実装タスク | implementation_tasks | 全REQ、UC、依存、完了条件、検証方法、production gateあり |

### 5.2 既存実装確認

- Backは`@google-cloud/kms`、`secret-manager`、`tasks`、Cloud SQL Connector、IAP検証へ依存するため、VPS移行をTerraform差替えだけで完了できない。
- Backはruntime、gateway、auth-bootstrap、migrationのDocker targetを持つため、container実行方式は再利用できる。
- migration runnerはadvisory lock、SHA-256 checksum、transactionを持つため継続可能である。
- Gmail PushはPub/Sub、Calendar非同期処理はCloud Tasks、定期処理はCloud Schedulerへ依存するため、段階移行が必要である。

### 5.3 Provider公式仕様確認

- [ConoHa Terraform Provider公式ドキュメント](https://doc.conoha.jp/reference/terraform/terraform-conoha-vps-provider/)を確認した。Provider 0.1.0はベータ版であり、対応resourceはVPS Instance、SSH鍵、Volume、Security Group、Security Group Ruleの5種である。DNS resourceとdata sourceはない。
- DNSをConoHa Providerの管理対象から除外し、[Cloudflare Terraform Provider公式ドキュメント](https://developers.cloudflare.com/terraform/)および[DNS record resource](https://developers.cloudflare.com/api/terraform/resources/dns/subresources/records/)に基づき、`cloudflare_dns_record`でzone/recordを管理する設計へ修正した。
- ConoHa側5種とCloudflare DNSはstateを分離し、段階0でそれぞれのimport、差分、変更、rollbackを検証する。
- RTOの測定起点・終点は`process_flow_design.md` §5.3だけに定義し、他文書はその正本を参照する形へ修正した。

### 5.4 未実施検証

| 検証ID | 内容 | 実施段階 |
|---|---|---|
| VAL-VPS-001 | ConoHa Terraform provider create/change/destroy/import | 段階0 |
| VAL-VPS-002 | 12GB VPS 72時間負荷 | 段階1〜2 |
| VAL-VPS-003 | refresh token rotationとdump秘密値検査 | 段階3 |
| VAL-VPS-004 | Pub/Sub停止からpolling回復 | 段階4 |
| VAL-VPS-005 | 未署名image拒否、rollback | 段階5 |
| VAL-VPS-006 | clean restoreのRPO/RTO | 段階2、月次 |
| VAL-VPS-007 | GCPからVPSへのcutover rehearsal | 段階6 |
| VAL-VPS-008 | Cloudflare DNS zone/recordのimport、plan、変更、drift検知、旧値rollback | 段階0、段階6 |
| VAL-VPS-009 | RTO起点候補・採用起点・終点の記録と計算 | 段階2、月次 |
| VAL-VPS-010 | DEC-007発動時のProduction変更・危険な外部Action停止とArchitecture再評価 | 段階3、Incident後 |

### 5.5 自動検査結果

2026-08-31に`validate_spec_docs.py --strict`を再実行し、必須文書、必須見出し、確認ID・REQ-ID・UC-IDの参照、Mermaid図、RTM列、日本語見出し、曖昧語の検査に合格した。実装タスク検査では、定義タスク35件、未定義TASK参照0件、REQ coverage 20/20、UC coverage 16/16を確認した。

VPSを不可逆に固定する記述を削除し、DEC-007、REQ-GOV-001、UC-OPS-006、Architecture再評価フロー、RTM、既存Taskへの接続を同じ変更単位で追加した。実VPS、DNS、Backup、Provider、Productionに対する試験は実施していない。

## 6. 未確定事項

実環境検証はVPS契約とcredential発行後に実施する。CHK-APPROVAL-001の承認に基づき`implementation_tasks.md`を作成済みであり、次の開始点はTASK-BASE-001である。

## 7. 関連文書

- `infra_architecture_design.md`
- `security_design.md`
- `rtm.md`
- `implementation_tasks.md`
