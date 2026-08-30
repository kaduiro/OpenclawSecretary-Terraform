# VPS移行DBカラム差分一覧

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: DBカラム差分一覧
- 版数: 1.0
- 最終更新日: 2026-08-30
- 位置づけ: VPS移行で追加・遷移する物理カラムの設計案

## 2. 目的

Secret Manager参照から暗号化DB保存へ移行するカラムとmigration履歴を追跡する。

## 3. 対象範囲

### 3.1 対象

`provider_credentials`と`schema_migrations`を対象とする。

### 3.2 対象外

変更しない業務tableのカラムはBackのmigrationを参照する。

## 4. 前提

REQ-SEC-002、REQ-DB-002、CHK-SEC-001を前提とする。

## 5. 本文

### 5.1 `public.provider_credentials`（provider認証情報）

#### カラム一覧

| 物理名 | 論理名 | 型 | PK | FK | その他制約 | 備考 |
|---|---|---|---|---|---|---|
| attendee_ref | 利用者参照 | UUID | Yes | users.attendee_ref | NOT NULL | 既存 |
| secret_resource_name | Secret Manager参照 | TEXT | No | No | 移行後nullable | 移行完了後に廃止候補 |
| credential_envelope | 暗号化refresh token | JSONB | No | No | envelopeキーCHECK | VPS移行で追加 |
| credential_status | credential状態 | TEXT | No | No | active/invalid/revoked | 既存 |
| updated_at | 更新日時 | TIMESTAMPTZ | No | No | NOT NULL | 既存 |

#### リレーション

| FK列 | 相手テーブル | 数的関係 | ON DELETE |
|---|---|---|---|
| attendee_ref | users.attendee_ref | 1対1 | RESTRICT |

#### 制約・インデックス

- 主キー`attendee_ref`を維持する。
- 移行中は`secret_resource_name IS NOT NULL OR credential_envelope IS NOT NULL`をCHECKする。
- 移行完了後は`credential_envelope IS NOT NULL`へ強化し、別migrationで旧列を削除する。
- 追加インデックスは作成しない。

### 5.2 `public.schema_migrations`（migration履歴）

#### カラム一覧

| 物理名 | 論理名 | 型 | PK | FK | その他制約 | 備考 |
|---|---|---|---|---|---|---|
| filename | migrationファイル名 | TEXT | Yes | No | NOT NULL | runnerが作成 |
| checksum | SHA-256 | TEXT | No | No | 適用後NOT NULL相当 | 改変検出 |
| applied_at | 適用日時 | TIMESTAMPTZ | No | No | NOT NULL | 監査 |

#### リレーション

他tableとの外部キーリレーションは持たない。

#### 制約・インデックス

- `filename`主キーだけを使用する。
- advisory lock名`openclaw.schema_migrations`を維持する。
- 適用済みchecksumが異なる場合はmigration全体を停止する。

## 6. 未確定事項

- `credential_envelope`のCHECK式は既存envelope実装との互換試験後に確定する。
- 旧`secret_resource_name`列の削除日は7日間のVPS安定運用後に判断する。

## 7. 関連文書

- `db_design_document.md`
- `er_diagram.md`
- `security_design.md`
