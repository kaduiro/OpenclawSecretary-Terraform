# HUD 認証本番設計修正後の見通し整理

作成日: 2026-06-09
対象: OpenclawSecretaryHUD / OpenclawSecretaryAndo の HUD 認証・Gateway・GCP 更新工程
目的: 2026-06-09 の本番設計修正後に「何が変わったか」「次に何をするか」「まだ実施しないこと」を事務的に整理する。

---

## 0. 結論

次に進める工程は **HUD Phase 0/1** である。

具体的には、`clawd-on-desk` 側で Gateway URL 設定、Google ログイン開始、loopback handoff、ID-token-only TokenManager、claims / `sub` 表示、mock/stub handoff client までを進める。

まだ実施しない工程は、backend confidential exchange の実デプロイ、Secret Manager への Gmail refresh token 保存確認、`poll-gmail` 再開である。これらは Phase 2 / TASK-004 以降で実施する。

---

## 1. 今回の更新で変わったこと

| 項目 | 旧前提 | 現行方針 | 実務上の影響 |
|---|---|---|---|
| OAuth token exchange | HUD が Google token endpoint で code exchange する | Gateway / private API が backend confidential exchange を行う | HUD で `client_secret` を使わない。`client_secret is missing` は GCP更新不足ではなく旧実装経路が残っているサイン |
| refresh token | HUD が取得して backend へ送る | backend が Secret Manager に保存し、HUD へ返さない | HUD は refresh token を保存・送信・ログ出力しない |
| API契約 | `POST /v1/auth/bootstrap {refreshToken}` | OpenAPI v1.4.0 の `/v1/auth/start`, `/v1/auth/callback`, `/internal/auth/oauth-sessions`, `/internal/auth/oauth-exchange`, `/v1/auth/id-token/refresh` | 旧 bootstrap endpoint は廃止 / superseded |
| HUD接続先 | `openclaw-api` direct URL も候補 | `openclaw-hud-gateway` URL のみ | HUD設定に private `openclaw-api` direct URL を入れない。既存キー名 `cloudRunUrl` は互換名としてのみ使う |
| `ALLOWED_SUBJECT` | 作業者 token や local PKCE token から推測し得た | Gateway/backend verified handoff claims の `sub` を正本にする | `gcloud auth print-identity-token` から取得しない |
| IAP token | 未確定 | まず同一 Google OAuth ID token を `Proxy-Authorization` と `Authorization` に入れる | Phase 2 実機で IAP が拒否した場合だけ `IAP_CLIENT_ID` 分離へ切り替える |
| Gateway境界 | 省略可能に見える箇所があった | Gateway は必須 | Gateway は inbound `X-Serverless-Authorization` を破棄し、backend 用 token を gateway SA で新規生成する |
| Cloud Run invoker | HUD利用者 / Workspace domain へ direct invoker 付与の余地があった | `openclaw-api` invoker は gateway SA / Scheduler SA / Tasks SA のみ | HUD利用者や Workspace domain に `openclaw-api` の `roles/run.invoker` を直接付与しない |
| health確認 | direct `/v1/health` を正式確認に使う余地があった | HUD正式確認は Gateway 経由の認証済み `GET /v1/health` のみ | direct `/v1/health` は未認証403境界確認に限定 |
| `poll-gmail` | bootstrap 実装後に再開 | backend exchange で refresh token Secret version 作成後に再開 | refresh token 登録前は再開しない |

---

## 2. 現在の到達点

| 領域 | 状態 |
|---|---|
| 仕様方針 | 内容承認済み。`oauth-confidential-exchange-design-proposal.md` は APPROVED |
| 形式ゲート | Phase A 完了。`validate_spec_docs.py` は現リポジトリに存在しないため、HUD `format_gate_resolution.md` の代替承認基準で整理済み |
| OpenAPI | Ando `openapi.yaml` は v1.4.0 に更新済み |
| HUD実装 | Phase B 実装済み。mock Gateway handoff / ID-token-only TokenManager / token 非露出は単体確認済み。実 Electron UI 手動確認は未実施 |
| Gateway / backend実装 | Phase 2 前ゲート。TASK-004 として実装・デプロイが必要 |
| GCP更新 | 既存 project は作り直さない。差分適用で追従する |
| Gmail polling | refresh token 登録前のため再開しない |

---

## 3. 今後の工程

### Phase A: 仕様形式整理（完了）

目的: 正式な APPROVED 化の前提整理。

実施済み内容:

- `validate_spec_docs.py` の形式ゲート62件の扱いを整理済み。
- `validation_report.md` の旧履歴行は履歴として残し、現行正本ではないことを維持済み。
- 仕様本文の正本を Gateway OAuth handoff / backend confidential exchange として維持済み。
- HUD 承認対象成果物のステータスを `APPROVED` に更新済み。

完了条件:

- `format_gate_resolution.md` により形式ゲートの扱いが決まり、HUD 承認対象成果物は正式 APPROVED 化済み。

### Phase B: HUD Phase 0/1（実装済み / 手動UI確認待ち）

目的: 実 backend に依存せず、HUD 側の認証入口と token 管理境界を完成させる。

実装済み内容:

- OpenClaw 設定画面に Gateway URL、組織ドメイン、OAuth Client ID を保存する。
- `cloudRunUrl` は互換キーとして使うが、表示上は Gateway URL とする。
- Google ログインボタンは Gateway `/v1/auth/start` を開く。
- HUD local loopback で handoff を受ける。
- TokenManager は短命 ID token のみをメモリ保持する。
- renderer / IPC / prefs に ID token、refresh token、access token、authorization code、`code_verifier`、OAuth client secret を出さない。
- handoff claims の `sub` を表示し、`ALLOWED_SUBJECT` 候補として確認できるようにする。
- 実 backend exchange ではなく mock/stub handoff client で動作確認する。

確認状況:

- mock Gateway によりログイン開始から loopback handoff 反映までの main-process state は確認済み。
- handoff claims の `sub` は取得でき、`ALLOWED_SUBJECT` 候補として表示可能。
- renderer IPC / prefs へ ID token、refresh token、access token、authorization code、`code_verifier`、OAuth client secret を出さない実装に更新済み。
- 実 Electron 設定画面での手動 UI 確認は未実施。

### Phase C: backend / Gateway Phase 2 前ゲート

目的: 実API連携に必要な backend confidential exchange と Gateway を用意する。

実施内容:

- `GET /v1/auth/start` を実装する。
- `GET /v1/auth/callback` を実装する。
- `POST /internal/auth/oauth-sessions` を実装する。
- `POST /internal/auth/oauth-exchange` を実装する。
- `POST /v1/auth/id-token/refresh` を実装する。
- OAuth client secret は Secret Manager から読む。
- state / `code_verifier` は backend の短期 auth session に保存する。
- Gmail refresh token は Secret Manager に保存する。
- HUD へ返すのは短命 ID token、expiresAt、sanitized claims、bootstrap state のみとする。
- Gateway は inbound `X-Serverless-Authorization` を backend へ転送しない。
- Gateway は gateway SA で backend 用 `X-Serverless-Authorization` を新規生成する。

完了条件:

- OpenAPI v1.4.0 に沿って実装・デプロイ済み。
- HUD が refresh token / access token / code / `code_verifier` を受け取らない。
- Gateway 経由の認証済み `GET /v1/health` が成功する。

### Phase D: GCP 差分適用

目的: 既存 GCP project を作り直さず、現行設計に追従させる。

実施内容:

- `openclaw-api` は `--no-allow-unauthenticated` を維持する。
- `openclaw-hud-gateway` を Cloud Run service としてデプロイし、IAP を有効化する。
- IAP `programmaticClients` に `GOOGLE_CLIENT_ID` を設定する。
- HUD利用者または管理 group には Gateway の IAP access を付与する。
- `openclaw-api` の `roles/run.invoker` は gateway SA / Scheduler SA / Tasks SA のみに付与する。
- `ALLOWED_SUBJECT` は Gateway/backend verified handoff claims の `sub` を設定する。
- direct `/livez` / `/readyz` smoke test は Scheduler SA impersonation に限定する。
- direct `/v1/health` は未認証403境界確認に限定する。

完了条件:

- HUD利用者や Workspace domain に `openclaw-api` direct invoker が付与されていない。
- Gateway 経由の認証済み `/v1/health` が OpenAPI v1.4.0 の `HealthResponse` を返す。
- IAP が同一 ID token を拒否する場合のみ `IAP_CLIENT_ID` 分離判断に進む。

### Phase E: refresh token 登録後の運用再開

目的: Gmail polling を安全に再開する。

実施内容:

- Gateway/backend exchange 完了後、`openclaw-ando-gmail-refresh-token` の Secret version が作成されたことを確認する。
- `POST /internal/poll-gmail` を Scheduler SA token で手動確認する。
- token 欠落ではない状態まで進んだことを確認する。
- `poll-gmail` Scheduler を再開する。
- Cloud Logging に token / secret / PII が出ていないことを確認する。

完了条件:

- `poll-gmail` が 200 または次の実設定不足エラーまで進む。
- Gmail refresh token 未登録による停止状態ではない。

---

## 4. 直近でやること

優先順は以下。

1. HUD Phase 0/1 を完了する。
2. HUD handoff claims から `sub` を取得し、`ALLOWED_SUBJECT` 候補を確定する。
3. backend / Gateway TASK-004 の実装範囲を OpenAPI v1.4.0 に沿って切る。
4. Gateway / IAP / Cloud Run invoker の GCP 差分を適用する。
5. Gateway 経由の `/v1/health` を確認する。
6. Secret Manager refresh token 登録後に `poll-gmail` を再開する。

---

## 5. まだやらないこと

- `POST /v1/auth/bootstrap {refreshToken}` を実装しない。
- HUD で Google token endpoint へ直接 token exchange しない。
- HUD に OAuth client secret を保存しない。
- HUD に refresh token / access token / authorization code / `code_verifier` を保持しない。
- `gcloud auth print-identity-token` の作業者 token から `ALLOWED_SUBJECT` を推測しない。
- HUD設定に private `openclaw-api` direct URL を入れない。
- HUD利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` を直接付与しない。
- direct `/v1/health` を HUD 正式確認に使わない。
- Gmail refresh token 登録前に `poll-gmail` を再開しない。

---

## 6. よくある迷いどころ

| 状況 | 判断 |
|---|---|
| Googleログインで `client_secret is missing` が出る | HUD が旧 local token exchange 経路を通っている可能性が高い。GCP更新不足ではなく、Gateway OAuth handoff 実装へ戻す |
| Gateway `/v1/health` が IAP 403 | IAP access / `programmaticClients` / `Proxy-Authorization` を確認する。同一 token が拒否される場合だけ `IAP_CLIENT_ID` 分離を検討する |
| Gateway `/v1/health` が backend 401/403 | `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、`ALLOWED_SUBJECT` と handoff claims を確認する |
| direct `openclaw-api /v1/health` が 403 | 期待どおり。正式確認は Gateway 経由で行う |
| `ALLOWED_SUBJECT` が分からない | Gateway/backend verified handoff claims の `sub` を取得する。作業者 token や外部JWTサイトは使わない |
| `poll-gmail` を再開してよいか迷う | `openclaw-ando-gmail-refresh-token` に enabled Secret version ができるまで再開しない |

---

## 7. 参照する文書

| 用途 | 文書 |
|---|---|
| 全体方針 | `OpenclawSecretaryHUD/docs/specs/openclaw-hud-auth-api-approval/oauth-confidential-exchange-design-proposal.md` |
| HUD実装計画 | `OpenclawSecretaryHUD/docs/specs/openclaw-hud-auth-api-approval/implementation_plan.md` |
| HUDタスク | `OpenclawSecretaryHUD/docs/specs/openclaw-hud-auth-api-approval/implementation_tasks.md` |
| Ando OpenAPI契約 | `OpenclawSecretary-Back/docs/api/openapi.yaml` |
| GCP初回 legacy Runbook | `docs/legacy/gcloud/gcp-setup.md` |
| 既存GCP差分適用 legacy | `docs/legacy/gcloud/gcp-required-steps-after-hud-auth-update.md` |
| Phase 0/1後のインフラ工程 | `docs/runbooks/infra-architecture-update-after-phase01.md` |
| refresh token登録後の運用 | `docs/runbooks/hud-auth/post-implementation-operations.md` |

---

## 8. 完了定義

この見通し上の一連の作業は、以下を満たした時点で完了とする。

- HUD が Gateway URL だけを接続先として保存している。
- HUD が Gateway OAuth handoff で短命 ID token と sanitized claims を受け取る。
- HUD が refresh token / access token / authorization code / `code_verifier` / OAuth client secret を取得していない。
- `ALLOWED_SUBJECT` が Gateway/backend verified handoff claims の `sub` で設定されている。
- `openclaw-api` direct invoker が gateway SA / Scheduler SA / Tasks SA のみに限定されている。
- Gateway 経由の認証済み `/v1/health` が成功している。
- backend confidential exchange により Gmail refresh token が Secret Manager に保存されている。
- `poll-gmail` が refresh token 登録後に再開されている。
