Status: DRAFT
Source: chat
Work item: design-method-and-algorithm
Upstream inputs: none
Last updated by: Codex

# Requirement

## Background

OpenClaw Ando は、Gmail 受信、AI 解析、HUD 承認、Calendar 操作、PII 保護、GCP インフラ運用をまたぐ業務システムである。

既存ドキュメントには API、DB、認証、処理フロー、デプロイ手順は定義されている。一方で、プロダクト全体に適用する開発手法、主要アルゴリズム、パッケージ境界、Terraform 化、リポジトリ分割方針は、実装判断に使える形で整理されていない。

今回の要件更新では、現行の `OpenclawSecretaryAndo` リポジトリを起点に、次の三分割を前提とした実装案へ進む。分割の目的は、バックエンド、フロントエンド、インフラの責務を分離し、各領域のレビュー範囲を小さくすることである。

| 分割先 | Repository name | 目的 |
|---|---|
| Backend repository | `OpenclawSecretary-Back` | OpenClaw API / Gateway / Gmail polling / Calendar worker / DB access を管理する |
| Frontend repository | `OpenclawSecretary-Front` | HUD / Electron / TokenManager / 承認カード UI を管理する |
| Terraform repository | `OpenclawSecretary-Terraform` | GCP リソース、IAM、Cloud Run、Cloud SQL、Secret Manager などを IaC として管理する |

2026-06-25 時点で、ローカルには `OpenclawSecretary-Back`、`OpenclawSecretary-Front`、`OpenclawSecretary-Terraform` の3ディレクトリが存在する。`OpenclawSecretary-Terraform` を正式表記とし、`Terafform` 表記は誤記として扱う。

本作業では、実装を始める前に、分割後も安全性、運用性、要件追跡性を維持するための要求を定義する。

## Problem

### 1. 業務判断の所在が分散している

現状は `api-server.js`、`gmail-poller.js`、`calendar-worker.js`、`auth-manager.js` に重要な業務判断が分散している。承認者バインド、トークン検証、Gmail 取り込み重複防止、Calendar 操作の失敗処理などは実装されているが、ドメイン概念・アルゴリズム・インフラ契約として再利用、検証、移管しやすい形には整理されていない。

### 2. リポジトリ間 contract が明確でない

HUD は既存の `clawd-on-desk` リポジトリに存在する。一方で、OpenAPI、認証境界、環境変数、secret 名、service account 名、DB migration、リリース順序が、backend / frontend / terraform の三者でどう同期されるべきかが明文化されていない。

### 3. Terraform 化しないまま分割すると運用差分が残る

現行の `infra/cloud-run/` は gcloud ベースの手順であり、既存 GCP リソースとの差分追跡には限界がある。Terraform 化せずに三分割すると、IAM、Cloud Run、IAP、Cloud Scheduler、Cloud Tasks、Secret Manager、Cloud SQL の設定差分が追跡しづらくなる。

### 4. 重すぎる設計手法は MVP に合わない

全面的な DDD レイヤードアーキテクチャ、CQRS、イベントソーシング、汎用 workflow engine を導入すると、MVP の単一ユーザー・Cloud Run 単一プロジェクト構成に対して過剰設計になる可能性が高い。

そのため、既存構成を尊重しながら、境界づけられたコンテキスト、ユビキタス言語、純粋関数化できるアルゴリズム、パッケージ境界、Terraform 管理対象だけを段階的に導入する必要がある。

## Scope

### 1. 三分割後のリポジトリ責務

| Repository | Owns | Does not own |
|---|---|---|
| `OpenclawSecretary-Back` | OpenClaw API、Gateway、Gmail polling、Calendar worker、auth、DB access、DB migration、backend tests、backend runtime docs | HUD の表示体験、Terraform state、GCP リソース作成の正本 |
| `OpenclawSecretary-Front` | HUD / Electron、TokenManager、API client adapter、承認カード表示、ローカル安全ストレージ、frontend tests | Gmail / Calendar の副作用実行、refresh token、DB access、Secret Manager access |
| `OpenclawSecretary-Terraform` | GCP APIs、Cloud Run、IAM、IAP、Cloud SQL、Secret Manager、Artifact Registry、Cloud Scheduler、Cloud Tasks、service accounts、state / import / plan 運用 | アプリケーション業務ロジック、HUD UI、DB migration SQL の実行ロジック |

### 1.1 初期ローカル状態

| Repository | 2026-06-25 local state | 初期対応方針 |
|---|---|---|
| `OpenclawSecretary-Back` | git repo。README のみ確認済み | 現行 `OpenclawSecretaryAndo` の backend runtime files を移管候補とする |
| `OpenclawSecretary-Front` | git repo。`docs/specs/openclaw-hud-auth-api-approval/` を確認済み | 既存 frontend 仕様を維持し、HUD 実装移管は別設計で扱う |
| `OpenclawSecretary-Terraform` | 空ディレクトリ。git repo 未確認 | Terraform scaffold と import 方針を初期設計対象とする |

### 2. リポジトリ間 contract

次の contract を、どの repository が正本を持つかまで定義する。

| Contract | 初期方針 |
|---|---|
| OpenAPI | backend repo を正本候補とし、frontend は生成 client または同期ファイルで利用する |
| Auth flow | backend / frontend の共同 contract として、ADR と security design に明記する |
| Environment variables | backend repo に runtime contract、terraform repo に deployment contract を置く |
| Secret names | terraform repo が resource 名を管理し、backend repo が参照名を定義する |
| Cloud Run service names | terraform repo が正本を持つ |
| Service account names | terraform repo が正本を持つ |
| Artifact image tags | backend CI / deploy flow と terraform apply flow の連携点として定義する |
| DB migration | 初期案では backend repo 所有とし、Terraform は DB インスタンスまでを管理する |

### 3. 開発手法

採用候補は「軽量 DDD + 必要箇所だけの ports/adapters 境界」とする。

| 方針 | 採用判断 |
|---|---|
| 軽量 DDD | 採用候補。境界づけられたコンテキストとユビキタス言語を整理する |
| ports/adapters | 部分採用候補。Google API、DB、Secret Manager の外側だけ境界化する |
| フル DDD レイヤード | MVP では不採用候補。現行規模に対して重い |
| CQRS | MVP では不採用候補。読み書きモデルを分ける必要性がまだ低い |
| Event sourcing | MVP では不採用候補。`timeline_events` の監査追記で足りる |
| 汎用 workflow engine | MVP では不採用候補。Cloud Scheduler / Cloud Tasks / DB 状態管理で足りる |

### 4. 境界づけられたコンテキスト

| Context | 主な責務 | 既存の関係先 |
|---|---|---|
| Mail Intake | Gmail 取得、重複排除、初期 DB 保存 | `gmail-poller.js`, `emails` |
| Mail Decision | AI 分析、カテゴリ、緊急度、返信要否、返信案 | `gmail-poller.js`, Gemini API |
| Approval | approvalToken、cardVersion、承認者バインド、単回使用 | `api-server.js`, `auth-manager.js`, `emails`, `calendar_proposals` |
| Scheduling | Calendar proposal、operation、部分失敗、手動補正要通知 | `calendar-worker.js`, `calendar_proposals`, `calendar_operations` |
| Knowledge | FAQ、RAG、送信済み返信 embedding | `faq_entries`, `sent_reply_embeddings` |
| Identity & Secret | OAuth、ID token、refresh token、Secret Manager、DwD | `auth-manager.js`, Secret Manager |
| Operations | health check、event inbox、retention、logging、rate limit | `api-server.js`, `event_inbox`, `timeline_events` |
| Infrastructure | Cloud Run、Cloud SQL、IAM、IAP、Scheduler、Tasks | `infra/cloud-run/*`, future Terraform repo |

### 5. アルゴリズム catalog

各アルゴリズムについて、目的、入力、出力、不変条件、失敗時動作を整理する。

| Algorithm | 説明対象 |
|---|---|
| Gmail polling / 重複排除 | Gmail message ID、`ON CONFLICT`、advisory lock、処理スキップ条件 |
| AI 解析 JSON 化 | 単一プロンプト、カテゴリ、緊急度、要約、返信要否、予定調整判定 |
| 緊急度正規化 / 表示順 | 緊急度降順、同一緊急度内 FIFO、HUD カード優先度 |
| approvalToken 検証 | 生成、SHA-256 hash、承認者 subject hash、cardVersion、単回使用 |
| Calendar 候補 / 操作 | proposal、selectedSlot、operation_id、Cloud Tasks、部分失敗記録 |
| token bucket rate limit | read / write / internal の endpoint group と `429` 応答 |
| PostgreSQL advisory lock | Gmail polling、Calendar operation、PII retention の namespace 分離 |
| PII retention / audit allowlist | 90日マスク、event_inbox cleanup、ログ・監査 detail の allowlist |

### 6. パッケージ方針

次の判断軸を定義する。

- backend repo 内の module boundary。
- frontend repo の API client / contract 取り込み方式。
- 共有 contract を npm package、生成物、Git submodule / subtree、CI artifact、または同期ファイルとして扱うか。
- lockfile、Node.js version、test command、release artifact の責務。
- `src/domain/` に抽出する場合の対象条件。

### 7. Terraform 化の範囲と移行方針

Terraform 化では、既存 GCP リソースを production-like state として扱う。

- 原則として import-first で移行する。
- 意図しない destroy / recreate を禁止する。
- plan / apply gate を必須にする。
- state 管理方式を決める。
- secret 値を Terraform state に保存しない。
- IAM は最小権限を維持する。

### 8. 実装時の反映先

- `docs/overview/technical-deep-dive.md`
- `docs/overview/adr.md`
- `docs/specs/gmail-ai-secretary/*`
- 必要なら `src/domain/` 配下の純粋関数モジュール
- 影響範囲に応じた `node --test` テスト
- 将来の Terraform repository 初期構成

## Non-Goals

- この要件ドラフト承認前に、実際のリポジトリ分割、ファイル移動、GCP リソース変更、Terraform apply は行わない。
- 既存 API、DB スキーマ、Cloud Run 2サービス境界をこの作業だけで大きく変更しない。
- `api-server.js` を全面的にレイヤー分割しない。
- OpenClaw workflow engine や外部ワークフローエンジンを導入しない。
- ML モデルの学習、プロンプト大改修、RAG 基盤の刷新は含めない。
- HUD UI の見た目刷新や Electron 全体の再設計は含めない。
- Terraform state に secret 値、OAuth client secret、Gmail refresh token、Gemini API key を保存しない。

## Users / Actors

| Actor | 読みたい情報 |
|---|---|
| バックエンド開発者 | 業務ルール、API、DB migration、アルゴリズムの所在 |
| HUD / Electron 開発者 | HUD が持ってよい責務、持ってはいけない secret / token / backend 直アクセス |
| インフラ / Terraform 管理者 | 既存 GCP リソースを破壊しない import、plan、apply 方針 |
| 運用担当者 | 障害時にどの判断が自動化され、どこから手動確認が必要か |
| 将来の実装エージェント | backend / frontend / terraform の各 repository で着手できる task 境界 |

## User Stories

| Role | Story |
|---|---|
| Backend developer | I want the product's domain boundaries documented, so that I can place new behavior without mixing authentication, approval, scheduling, persistence, and infrastructure logic. |
| Frontend developer | I want the API contract and token responsibilities documented, so that HUD changes do not bypass the gateway or leak approval tokens. |
| Infrastructure maintainer | I want Terraform ownership and import policy documented, so that existing GCP resources can be managed without accidental replacement. |
| Maintainer | I want the key algorithms explained with inputs, outputs, invariants, and failure behavior, so that I can review changes without reverse engineering the whole codebase. |
| Product owner | I want the design method to be proportional to the MVP, so that the project gains clarity without unnecessary architecture overhead. |
| Implementation agent | I want package and repository boundaries identified, so that tasks can be executed independently in the correct repository. |

## Acceptance Criteria

### Repository Split

- [ ] The requirements define the target three-repository split for backend, frontend, and Terraform.
- [ ] The repository names are fixed as `OpenclawSecretary-Back`, `OpenclawSecretary-Front`, and `OpenclawSecretary-Terraform`.
- [ ] The requirements define ownership of source code, docs, tests, migration files, and deploy artifacts.
- [ ] A later basic-design artifact can map current files in this repository to the target repositories without inventing new scope.

### Cross-Repository Contracts

- [ ] The requirements identify all cross-repository contracts that must remain synchronized.
- [ ] The contract list includes OpenAPI, auth flow, environment variables, secret names, Cloud Run service names, service accounts, artifact tags, and DB migration responsibility.

### Design Method

- [ ] A design-method document or technical-deep-dive section states the selected development approach and why it is optimal for the current product phase.
- [ ] The selected approach explicitly rejects or defers full layered DDD, CQRS, event sourcing, and generalized workflow engines for the MVP.
- [ ] Bounded contexts and key domain terms are listed in Japanese and mapped to existing source files, DB tables, API surfaces, and Terraform-managed resources.

### Algorithm Catalog

- [ ] The algorithm catalog describes each algorithm's purpose, inputs, outputs, invariants, and failure behavior.
- [ ] Existing absolute constraints remain explicit: email send only after HUD approval, calendar write only after HUD proposal approval, no plaintext approvalToken in DB/logs, no refresh_token in HUD, and no direct HUD access to `openclaw-api`.

### Package And Terraform Strategy

- [ ] Package strategy is defined for backend modules, frontend API client / contract handling, shared contract distribution, lockfiles, Node.js version, and test commands.
- [ ] Terraform scope is defined with a no-unplanned-destroy rule, import-first migration policy, state backend decision, plan / apply gate, and secret-value exclusion.

### Documentation And Implementation Readiness

- [ ] `docs/overview/adr.md` records the architecture decision for lightweight DDD, algorithm cataloging, repository split, package boundary, and Terraform ownership.
- [ ] If code is changed later, pure domain logic is extracted only where it reduces risk or improves testability, and the extracted functions are covered by `node --test`.
- [ ] If only documents are changed, the implementation output clearly states that this work is documentation / design-contract only.

## Constraints

### Runtime

- The current backend runtime is Node.js / Express on Cloud Run with PostgreSQL Cloud SQL.
- The current frontend / HUD implementation is expected to remain in the existing `clawd-on-desk` lineage unless explicitly renamed.
- The MVP is single-tenant / single-primary-user oriented; architecture must not assume broad multi-tenant scaling.

### Security

- Current Cloud Run gateway/backend security boundary must remain intact.
- HUD must connect only to `openclaw-hud-gateway`; direct access to `openclaw-api` remains forbidden.
- PII and secret material must not be added to logs, event payloads, Terraform state, generated docs, or broad in-memory caches.

### Infrastructure

- Terraform migration must treat live GCP resources as existing production-like state.
- Terraform migration must avoid destructive replacement unless explicitly approved.
- Implementation should preserve existing operational simplicity unless a stronger invariant is required.

### Documentation

- Existing documentation is primarily Japanese and should remain readable by handoff engineers.
- Requirements should be specific enough for `basic-design.md` to proceed without redefining scope.

## Open Questions

### Must Resolve Before Basic Design Approval

- OPEN QUESTION: DB migration は backend repository 所有のままにするか、Terraform repository へ移すか。推奨初期案は backend repository 所有。
- OPEN QUESTION: Terraform state backend は GCS bucket を bootstrap 手順で作成するか、既存プロジェクト内に手動作成するか。
- OPEN QUESTION: 既存 GCP リソースはすべて Terraform import 前提でよいか。新規作成・再作成が許可されるリソースがあるか。

### May Resolve During Detail Design

- OPEN QUESTION: OpenAPI と生成 client の共有方法は、npm package、生成物のコミット、Git submodule / subtree、CI artifact のどれにするか。
- OPEN QUESTION: 今回の初回実装は docs / design-contract のみとするか、低リスクな `src/domain/` 純粋関数抽出まで含めるか。
- OPEN QUESTION: Calendar 候補生成は現行 MVP の「本文に明示された日時を提示」に固定するか、将来仕様として空き時間探索アルゴリズムも同時に定義するか。
- OPEN QUESTION: 新しい設計手法・リポジトリ分割・Terraform 方針を `docs/overview/technical-deep-dive.md` に統合するか、`docs/overview/design-method-and-algorithms.md` として独立させるか。
