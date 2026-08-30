# VPS移行DB差分設計書

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: DB移行差分設計
- 版数: 1.0
- 最終更新日: 2026-08-30
- 位置づけ: Cloud SQLからVPS PostgreSQLへの物理移行とsecret保存差分

## 2. 目的

既存schemaを再定義せず、VPS移行で変更するDB実行環境、権限、backup、provider credential保存境界を定義する。

## 3. 対象範囲

### 3.1 対象

PostgreSQL 15、pgvector、role、migration、backup、`provider_credentials`の移行期間を対象とする。

### 3.2 対象外

既存業務tableの論理定義はBackの`migrations/`を正本とし、本書で複製しない。

## 4. 前提

- DB migrationはREQ-DB-002に従う。
- refresh tokenはREQ-SEC-002に従い、平文保存しない。
- 現行`provider_credentials.secret_resource_name`はGoogle Secret Manager resourceを参照する。

## 5. 本文

### 5.1 スキーマ構成

既存`public` schemaを維持する。`schema_migrations`はmigration runnerが所有する。VPS運用専用tableをTerraformから作成しない。

### 5.2 命名規則

- table、column、indexは既存snake_caseを維持する。
- 暗号化payloadは`*_envelope`、鍵版はenvelope内`keyVersion`を使う。
- 新migrationは既存最大番号の次の3桁番号で追加し、適用済みSQLを変更しない。

### 5.3 秘密情報の移行方式

移行期間は`provider_credentials`へ`credential_envelope JSONB`を追加し、`secret_resource_name`と並存させる。applicationはenvelopeを優先し、存在しない行のみSecret Manager参照を使う。全行の再暗号化と復号試験後にSecret Manager参照を廃止する。

envelopeは`version`、`algorithm`、`ciphertext`、`encryptedDek`、`nonce`、`tag`、`aadDigest`、`keyVersion`を必須とする。AADには`attendee_ref`とcredential用途を含める。

### 5.4 制約

- `provider_credentials`は移行完了まで`secret_resource_name`または`credential_envelope`の一方以上を必須とする。
- `credential_status`の既存CHECKを維持する。
- runtime roleは`schema_migrations`とDDLを更新できない。
- migration roleだけがDDLと`schema_migrations`を更新できる。

### 5.5 インデックス

VPS移行だけを理由に既存業務indexを変更しない。`provider_credentials`は`attendee_ref`主キー検索のため追加indexを作らない。outbox workerは既存`outbox_dispatch_idx`を使用する。

### 5.6 backupと削除

- WAL archiveの目標間隔を15分以内とする。
- base backupを日次、logical dumpを日次で取得する。
- 日次14世代、週次8世代、月次12世代をoff-siteへ保持する。
- backup削除はretention jobだけが実行し、production operatorの通常deploy権限から除外する。

## 6. 未確定事項

- `credential_envelope`追加migrationの物理番号は、Back側の最新migration番号を実装開始時に確認して決める。
- KEK backendと`encryptedDek`生成実装はsecurity設計の受入試験で確定する。

## 7. 関連文書

- `db_columns_list_with_relations.md`
- `er_diagram.md`
- `security_design.md`
- `../../../../OpenclawSecretary-Back/migrations/`
