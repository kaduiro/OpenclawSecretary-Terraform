# Phase 0/1 完了後のインフラアーキテクチャ更新工程

作成日: 2026-06-09
対象: `clawd-on-desk` の Phase 0/1 実装完了後に、OpenClaw HUD 実API連携へ進むための GCP / backend / gateway 更新工程
前提: HUD 側では Gateway URL 設定、Gateway OAuth start、loopback handoff、ID token claims 表示、`sub` 取得、mock/stub handoff client まで完了している
参照正本: `gcp-setup.md` v1.1（更新日: 2026-06-08）、`gcp-required-steps-after-hud-auth-update.md`、HUD auth API approval 仕様群

---

## 0. 本書の位置づけ

`gcp-setup.md` は複数回のレビューにより、旧来の「HUD から `openclaw-api` へ直接到達する」前提ではなく、現行の「private `openclaw-api` + IAP 保護 `openclaw-hud-gateway` + header 分離」構成へ更新済みである。

本書は `gcp-setup.md` を置き換えるものではない。Phase 0/1 実装が完了した現在の状態から、更新済みの GCP setup 正本に追従するために必要なインフラ設計変更だけを抜き出し、次工程で実行・確認すべき内容を明確化する。

文書ごとの役割は以下で固定する。

| 文書 | 役割 | 本書での扱い |
|---|---|---|
| `gcp-setup.md` | GCP 初回構築から最終チェックまでを含む正本 Runbook | 現行インフラ構成の上位正本として参照する |
| `gcp-required-steps-after-hud-auth-update.md` | 既存 GCP 環境へ差分適用する具体コマンド | 実行コマンドの参照先とする |
| 本書 | Phase 0/1 完了後に必要なインフラ設計変更の整理 | 実行前の判断表、実行順、完了条件を管理する |
| HUD auth API approval 仕様群 | HUD 側の認証・API・承認フロー仕様 | Phase 2 開始条件と UI/API 契約の参照先とする |

このため、本書で明確にする内容は以下に限定する。

- `gcp-setup.md` 更新後の正本構成に追従するため、既存 GCP 環境で追加・変更する内容。
- Phase 0/1 完了済みの HUD 実装を前提に、Phase 2 実API連携へ進むための infra / backend / gateway のゲート。
- 作り直し不要な GCP リソースと、変更が必要な IAM / Cloud Run / IAP / Secret / Scheduler / Tasks 境界。

本書で扱わない内容:

- GCP project、Cloud SQL、OAuth client、Artifact Registry の再作成。
- `clawd-on-desk` Phase 0/1 実装そのものの再設計。
- backend 実装コードの詳細設計。ただし、インフラ更新の前提になる実装ゲートは明記する。

---

## 1. 結論

次工程の最適解は、既存 GCP project を作り直さず、private `openclaw-api` の前段に IAP 保護された `openclaw-hud-gateway` を追加し、Phase 2 実API連携に必要な認証境界を完成させることである。

採用する正本構成:

- HUD の本番接続先は `openclaw-hud-gateway` の URL のみとする。
- `openclaw-api` は `--no-allow-unauthenticated` を維持し、HUD から直接呼ばせない。
- HUD は `Proxy-Authorization` と `Authorization` を分離して gateway に送る。
- gateway は inbound `X-Serverless-Authorization` を破棄し、backend 用 `X-Serverless-Authorization` を gateway service account で新規生成する。
- `openclaw-api` の `roles/run.invoker` は gateway SA / Scheduler SA / Tasks SA のみに付与する。
- OAuth client ID は `GOOGLE_CLIENT_ID` env var が正本であり、Secret Manager には保存しない。
- `ALLOWED_SUBJECT` は Gateway/backend が検証した HUD handoff claims の `sub` を正本とする。
- `poll-gmail` は backend confidential exchange による Gmail refresh token 保存完了まで pause を維持する。

採用しない構成:

- `openclaw-api` の `--allow-unauthenticated` 化
- HUD 利用者または Workspace domain への `openclaw-api` direct invoker 付与
- desktop への service account key 配布
- OAuth client ID を Secret Manager の正本として扱う構成
- direct `openclaw-api /v1/health` を HUD 正式確認に使う構成

---

## 2. 更新対象

| 領域 | 更新対象 | 目的 |
|---|---|---|
| GCP IAM | gateway SA / Scheduler SA / Tasks SA / IAP service agent / HUD利用者IAP access | 呼び出し元ごとの認可境界を固定する |
| Cloud Run | `openclaw-api` / `openclaw-hud-gateway` | private backend と IAP entrypoint を分離する |
| IAP | `programmaticClients` / IAP policy | Desktop OAuth client ID の programmatic access を許可する |
| backend env | `GOOGLE_CLIENT_ID` / `ALLOWED_DOMAIN` / `ALLOWED_SUBJECT` / OIDC SA emails | Google ID token と Scheduler/Tasks OIDC を検証する |
| backend API | `/v1/health` / `/v1/auth/start` / `/v1/auth/callback` / `/internal/auth/oauth-sessions` / `/internal/auth/oauth-exchange` / `/v1/auth/id-token/refresh` / auth middleware | Gateway OAuth handoff と backend confidential exchange を可能にする |
| Scheduler / Tasks | OIDC 発行元 service account | internal job と HUD gateway 経路を分離する |
| Secret Manager | OAuth client secret / Gmail refresh token / Gemini API key | Secret 境界を最小化する |

---

## 3. 現在のインフラ設計変更に対応するために必要な内容

`gcp-setup.md` の更新内容に追従するため、次工程で必要な対応は以下で確定する。

| 領域 | 対応要否 | 必要な内容 | 完了判定 |
|---|---|---|---|
| GCP project | 不要 | 既存 project を継続利用する。作り直しはしない | project ID、billing、既存 Cloud SQL、既存 Artifact Registry をそのまま使う |
| OAuth 2.0 client | 不要 | 既存 Desktop OAuth client を継続利用する | HUD `oauthClientId`、Cloud Run `GOOGLE_CLIENT_ID`、IAP `programmaticClients` が同一 client ID を指す |
| `openclaw-api` 公開設定 | 必須 | `--no-allow-unauthenticated` を維持し、HUD から direct access させない | 未認証 direct `/v1/health` が Cloud Run platform 403 を返す |
| `openclaw-hud-gateway` | 必須 | HUD 本番 entrypoint として Cloud Run service を追加し、IAP で保護する | gateway 経由 `/v1/health` が backend `HealthResponse` を返す |
| gateway service account | 必須 | gateway 専用 SA を作成し、`openclaw-api` の `roles/run.invoker` を付与する | `openclaw-api` invoker に gateway SA が含まれる |
| IAP service agent | 必須 | IAP service agent を作成し、gateway の `roles/run.invoker` を付与する | gateway invoker に `service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com` が含まれる |
| IAP access policy | 必須 | HUD 利用者または管理 group に `roles/iap.httpsResourceAccessor` を付与する | HUD 利用者が IAP を通過でき、Workspace domain へ `openclaw-api` invoker を直接付与していない |
| IAP programmatic access | 必須 | `accessSettings.oauthSettings.programmaticClients` に `GOOGLE_CLIENT_ID` を追加する | `programmaticClients` に HUD の Desktop OAuth client ID が含まれる |
| HUD 認証 header | 必須 | HUD は同じ Google ID token を `Proxy-Authorization` と `Authorization` に分けて gateway へ送る | IAP と OpenClaw app auth の両方で同じ token claims を検証できる |
| gateway header 処理 | 必須 | inbound `X-Serverless-Authorization` を破棄し、backend 用 token を gateway SA で新規発行する | backend 呼び出しに `X-Serverless-Authorization: Bearer {gateway SA ID token}` が付与される |
| backend app auth | 必須 | `Authorization` の署名、`iss`、`aud=GOOGLE_CLIENT_ID`、`hd=ALLOWED_DOMAIN`、`sub=ALLOWED_SUBJECT` を検証する | Bearer payload decode のみの実装が残っていない |
| `GOOGLE_CLIENT_ID` | 必須 | OAuth client ID は非シークレット env var として扱う | `SECRET_OAUTH_CLIENT_ID` / `openclaw-oauth-client-id` を runtime 正本にしていない |
| `ALLOWED_SUBJECT` | 必須 | Gateway/backend が署名・`aud`・`hd` を検証した handoff claims の `sub` から確定する | `gcloud auth print-identity-token` 由来の `sub` を使っていない |
| `/v1/health` | 必須 | OpenAPI の新 `HealthResponse` に追従する | `status`、`revision`、`db.status`、`heartbeat.status`、`bootstrap.required` を返す |
| Gateway OAuth / backend exchange | 必須 | OpenAPI v1.4.0 の OAuth start/callback/internal exchange/id-token refresh を backend に実装する | backend が OAuth client secret で confidential exchange を行い、refresh token が Secret Manager に保存され、HUD には refresh token / access token / code / code_verifier が返らない |
| Scheduler / Tasks OIDC | 必須 | Scheduler SA / Tasks SA を発行元にし、`aud=CLOUD_RUN_URL` と SA email allowlist を検証する | internal job が専用 SA 経由で通り、Cloud Run 実行 SA と兼用していない |
| Secret Manager | 必須 | 保存対象を OAuth client secret、Gmail refresh token、Gemini API key に限定する | OAuth client ID、Google ID token、access token、approvalToken raw value、PII を保存していない |
| `poll-gmail` | 必須 | backend confidential exchange 完了まで pause を維持する | refresh token 登録前に `poll-gmail` が再開されていない |

上表のうち「必須」の項目が未完了の場合、Phase 2 実API連携へ進まない。

---

## 4. 工程一覧

### 4.1 入力値を確定する

Phase 0/1 の成果から以下を確定する。

| 値 | 正本 | 注意 |
|---|---|---|
| `GOOGLE_CLIENT_ID` | Google OAuth desktop client ID | Secret Manager に保存しない |
| `ALLOWED_DOMAIN` | 対象 Workspace domain | 例: `master-key.biz` |
| `ALLOWED_SUBJECT` | Gateway/backend verified handoff claims の `sub` | `gcloud auth print-identity-token` から推測しない |
| `HUD_GATEWAY_SERVICE` | `openclaw-hud-gateway` | HUD 本番 entrypoint |
| `HUD_GATEWAY_SA_EMAIL` | `openclaw-hud-gateway@${PROJECT_ID}.iam.gserviceaccount.com` | backend Cloud Run IAM 通過用 |
| `SCHEDULER_SERVICE_ACCOUNT_EMAIL` | Scheduler OIDC 専用SA | Scheduler job 発行元 |
| `TASKS_SERVICE_ACCOUNT_EMAIL` | Tasks OIDC 専用SA | Cloud Tasks dispatch 発行元 |

完了条件:

- `ALLOWED_SUBJECT` が対象ユーザーの Google ID token `sub` と一致する。
- HUD 設定の `oauthClientId` と Cloud Run env `GOOGLE_CLIENT_ID` が一致する。
- legacy `openclaw-oauth-client-id` secret が存在しても照合専用であり、正本として参照していない。

### 4.2 `openclaw-api` の backend 実装差分を確定する

Cloud Run env だけを更新しても、backend が検証を実装していなければ Phase 2 へ進めない。

必要な実装:

- `GET /v1/health` が OpenAPI `HealthResponse` を返す。
- OpenAPI v1.4.0 の `/v1/auth/start`、`/v1/auth/callback`、`/internal/auth/oauth-sessions`、`/internal/auth/oauth-exchange`、`/v1/auth/id-token/refresh` が契約どおり実装される。
- `Authorization: Bearer {Google OAuth ID token}` の署名、`iss`、`aud=GOOGLE_CLIENT_ID`、`hd=ALLOWED_DOMAIN`、`sub=ALLOWED_SUBJECT` を検証する。
- Scheduler / Tasks OIDC では `aud=CLOUD_RUN_URL` と service account email allowlist を検証する。
- OAuth client ID は `GOOGLE_CLIENT_ID` env var から読み、`SECRET_OAUTH_CLIENT_ID` を必須にしない。
- refresh token は Secret Manager に保存し、レスポンス、ログ、DB、timeline events へ出さない。

完了条件:

- `/v1/health` が `status`、`revision`、`db.status`、`heartbeat.status`、`bootstrap.required`、`bootstrap.reason` を返す。
- backend confidential exchange が refresh token を Secret Manager に保存し、HUD へ短命 ID token / sanitized claims / bootstrap state だけを返す。
- token payload の decode のみで署名検証を省略していない。

### 4.3 `openclaw-hud-gateway` を実装・デプロイする

gateway は HUD 専用 entrypoint であり、単なる URL 転送ではなく認証境界を持つ。

必要な gateway 挙動:

- HUD から `Proxy-Authorization` と `Authorization` を受け取る。
- IAP 通過後、backend へ inbound `X-Serverless-Authorization` を転送しない。
- `openclaw-api` の Cloud Run URL を audience とする gateway service account ID token を発行する。
- backend 呼び出し時に `X-Serverless-Authorization: Bearer {gateway SA ID token}` を付与する。
- HUD 由来の `Authorization` は OpenClaw app auth 用として backend へ転送する。
- token、refresh token、approvalToken、PII を gateway log に出さない。

完了条件:

- `openclaw-hud-gateway` が Cloud Run service としてデプロイされている。
- IAP service agent に gateway の `roles/run.invoker` が付与されている。
- gateway service account に `openclaw-api` の `roles/run.invoker` が付与されている。
- gateway 経由 `/v1/health` で backend の `HealthResponse` を受け取れる。

### 4.4 IAP programmatic access を設定する

IAP は gateway の前段で HUD 利用者を認可する。

必要な設定:

- `iap.googleapis.com` を有効化する。
- IAP service agent を作成する。
- `openclaw-hud-gateway` に IAP を有効化する。
- HUD 利用者または管理 group に `roles/iap.httpsResourceAccessor` を付与する。
- IAP settings の `accessSettings.oauthSettings.programmaticClients` に `GOOGLE_CLIENT_ID` を追加する。

完了条件:

- IAP policy に HUD 利用者または管理 group が含まれる。
- `programmaticClients` に `GOOGLE_CLIENT_ID` が含まれる。
- HUD の同一 Google ID token を `Proxy-Authorization` と `Authorization` に入れた gateway `/v1/health` が通る。

分岐条件:

- 同一 Google ID token が IAP で拒否される場合のみ `IAP_CLIENT_ID` を追加し、HUD TokenManager を IAP 用 token と app 用 token の2スロットに分離する。
- Firebase Auth への切替、service account key 配布、`openclaw-api` 公開化は fallback としない。

### 4.5 `openclaw-api` の Cloud Run 設定を更新する

必要な設定:

- `--no-allow-unauthenticated`
- `--ingress=all`
- `--min-instances=1`
- `--max-instances=1`
- `--concurrency=1`
- `--memory=1Gi`
- `--timeout=120s`
- startup probe: `/livez`
- liveness probe: `/livez`
- env:
  - `GOOGLE_CLIENT_ID`
  - `ALLOWED_DOMAIN`
  - `ALLOWED_SUBJECT`
  - `SCHEDULER_SERVICE_ACCOUNT_EMAIL`
  - `TASKS_SERVICE_ACCOUNT_EMAIL`
  - `CLOUD_RUN_URL`
  - `SECRET_OAUTH_CLIENT_SECRET`
  - `SECRET_GMAIL_REFRESH_TOKEN`
  - `SECRET_GEMINI_API_KEY`

完了条件:

- `openclaw-api` direct 未認証 `/v1/health` が Cloud Run platform 403 を返す。
- `/livez` / `/readyz` の direct smoke test は Scheduler SA impersonation でのみ行える。
- HUD 利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` が直接付与されていない。

### 4.6 Scheduler / Tasks の OIDC 境界を更新する

必要な設定:

- Scheduler job は `SCHEDULER_SERVICE_ACCOUNT_EMAIL` で OIDC token を発行する。
- Cloud Tasks dispatch は `TASKS_SERVICE_ACCOUNT_EMAIL` で OIDC token を発行する。
- Scheduler SA / Tasks SA に `openclaw-api` の `roles/run.invoker` を付与する。
- OpenClaw app 側でも OIDC service account email allowlist を検証する。
- `poll-gmail` は backend confidential exchange 完了まで pause を維持する。

完了条件:

- `pii-retention` は Scheduler 経由で成功する。
- `calendar-ops` queue は `RUNNING` で `maxAttempts=1` を維持する。
- `poll-gmail` は refresh token 登録前に再開されていない。

### 4.7 Secret Manager 境界を確認する

保存する Secret:

- OAuth client secret
- Gmail refresh token
- Gemini API key

保存しないもの:

- OAuth client ID
- Google ID token
- access token
- approvalToken raw value
- Gmail / Calendar 本文や参加者PII

完了条件:

- `openclaw-{user_id}-oauth-client-secret` が存在する。
- `openclaw-{user_id}-gmail-refresh-token` が存在する。
- `openclaw-{user_id}-gemini-api-key` が存在する。
- OAuth client ID 用 legacy secret は存在しても照合専用であり、runtime の正本ではない。

### 4.8 必要コマンド一覧

この節は、現在のインフラ設計変更に対応するために実行するコマンドの一覧である。Cloud Shell または bash 前提で記載する。詳細な値移行や例外処理は `gcp-required-steps-after-hud-auth-update.md` を正とする。

実行順は以下で固定する。

| 順序 | 用途 | 実行タイミング |
|---|---|---|
| 1 | 変数定義・現状確認 | すぐ実行可 |
| 2 | IAP API / service account 作成 | すぐ実行可 |
| 3 | Secret Manager 正規化 | すぐ実行可 |
| 4 | IAM 境界設定 | すぐ実行可 |
| 5 | `openclaw-api` 再デプロイ | backend が `HealthResponse` / OpenAPI v1.4.0 OAuth endpoints / 署名検証に追従した image の用意後 |
| 6 | `openclaw-hud-gateway` デプロイ・IAP 有効化 | gateway image の用意後 |
| 7 | Scheduler / Tasks OIDC 更新 | `CLOUD_RUN_URL` 確定後 |
| 8 | 検証 | 各デプロイ後 |

#### 4.8.1 変数定義

```bash
export PROJECT_ID="openclaw-ando-prod"
export REGION="asia-northeast1"
export USER_ID="ando"
export SECRET_PREFIX="openclaw-${USER_ID}"
export SA_NAME="openclaw-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export REPO_NAME="openclaw"

gcloud config set project "${PROJECT_ID}"

export GOOGLE_CLIENT_ID="<Desktop OAuth client ID>"
export ALLOWED_DOMAIN="master-key.biz"
export ALLOWED_SUBJECT="<Gateway/backend verified handoff claims の sub>"

export SCHEDULER_SERVICE_ACCOUNT_EMAIL="openclaw-scheduler-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export TASKS_SERVICE_ACCOUNT_EMAIL="openclaw-tasks-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export HUD_GATEWAY_SERVICE="openclaw-hud-gateway"
export HUD_GATEWAY_SA_EMAIL="openclaw-hud-gateway@${PROJECT_ID}.iam.gserviceaccount.com"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
export IAP_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
export IAP_ACCESS_MEMBER="user:<HUD_USER_EMAIL>"

export CLOUD_SQL_INSTANCE="openclaw-db"
export CLOUD_SQL_CONNECTION_NAME="$(gcloud sql instances describe "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --format="value(connectionName)")"

export OAUTH_CLIENT_SECRET_NAME="${SECRET_PREFIX}-oauth-client-secret"
export GMAIL_REFRESH_SECRET_NAME="${SECRET_PREFIX}-gmail-refresh-token"
export GEMINI_API_KEY_SECRET_NAME="${SECRET_PREFIX}-gemini-api-key"
```

`ALLOWED_SUBJECT` が未確定の場合は、HUD から Gateway OAuth start を実行し、Gateway/private API が Google OAuth callback で confidential exchange と ID token claim 検証を完了した後の handoff claims から取得する。

ここでいう「HUD handoff claims」とは、`openclaw-hud-gateway` / private `openclaw-api` が Google ID token の署名、`aud`、`hd`、`iss`、`exp` を検証した後、HUD loopback へ返す sanitized claims である。HUD は authorization code、`code_verifier`、Google token endpoint の token response、OAuth client secret、refresh token、access token を取得しない。

取得手順:

1. HUD 設定で `Gateway URL`、`organizationDomain`、`oauthClientId` を設定する。
2. HUD の Google ログイン操作で `openclaw-hud-gateway /v1/auth/start` をブラウザで開く。
3. Gateway/private API が state / `code_verifier` を短期 auth session に保存し、Google OAuth authorization URL を生成する。
4. 対象 Google Workspace ユーザーが Google の画面で同意する。
5. Google は authorization code と state を Gateway `/v1/auth/callback` に返す。
6. private API が Secret Manager の OAuth client secret を使って confidential exchange を行い、ID token claims を検証する。
7. private API が Gmail refresh token を Secret Manager に保存し、Gateway が HUD loopback に短命 ID token、sanitized claims、bootstrap state を handoff する。
8. HUD の claims 表示または local debug log に出る `sub` を `ALLOWED_SUBJECT` として Cloud Run env に設定する。token 本文は保存・貼り付けしない。

確認する値:

- `aud`: HUD 設定の `oauthClientId` と Cloud Run env `GOOGLE_CLIENT_ID` に一致する。Cloud Run URL ではない。
- `hd`: `ALLOWED_DOMAIN` に一致する。MVP では `master-key.biz`。
- `sub`: 対象 Google user の安定識別子であり、`ALLOWED_SUBJECT` に設定する。
- `iss`: `https://accounts.google.com` または `accounts.google.com`。
- `exp`: 期限切れでない。

使用してはいけない値:

- `gcloud auth print-identity-token` の token。これは作業者または service account の smoke test 用 token であり、HUD ユーザーの Gateway/backend verified handoff claims ではない。
- Google ID token を外部の JWT decode サイトに貼り付けて取得した値。
- `email` claim。メールアドレスは変更され得るため、許可ユーザーの正本には `sub` を使う。
- OAuth `access_token`。Google API 呼び出し用であり、OpenClaw app auth の本人識別正本にはしない。
- OAuth `refresh_token`。更新用 secret であり、Bearer 認証や `ALLOWED_SUBJECT` 取得には使わない。

取り扱い:

- handoff ID token は一時的な確認値であり、Secret Manager、DB、ログ、ドキュメントに保存しない。
- HUD 本実装では TokenManager が `/v1/auth/id-token/refresh` で期限前更新し、renderer process へ token を渡さない。
- gateway 経由の正式確認では同じ handoff ID token を `Proxy-Authorization` と `Authorization` に分けて送る。

```bash
export HUD_ID_TOKEN="<Gateway/backend handoff で取得した短命 Google ID token>"

python -c "import base64,json,os; t=os.environ['HUD_ID_TOKEN'].split('.')[1]; t += '=' * (-len(t) % 4); print(json.dumps(json.loads(base64.urlsafe_b64decode(t)), indent=2, ensure_ascii=False))"

export ALLOWED_SUBJECT="$(python3 -c 'import base64,json,os; t=os.environ["HUD_ID_TOKEN"].split(".")[1]; t += "=" * (-len(t) % 4); print(json.loads(base64.urlsafe_b64decode(t))["sub"])')"
```

確認する claim:

- `aud == GOOGLE_CLIENT_ID`
- `hd == ALLOWED_DOMAIN`
- `sub == ALLOWED_SUBJECT`

#### 4.8.2 現状確認

```bash
gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '{
    url: .status.url,
    image: .spec.template.spec.containers[0].image,
    serviceAccountName: .spec.template.spec.serviceAccountName,
    env: [.spec.template.spec.containers[0].env[]?.name],
    containerConcurrency: .spec.template.spec.containerConcurrency,
    minScale: .spec.template.metadata.annotations["autoscaling.knative.dev/minScale"],
    maxScale: .spec.template.metadata.annotations["autoscaling.knative.dev/maxScale"]
  }'

gcloud secrets list --project="${PROJECT_ID}" --format="value(name)"

gcloud iam service-accounts list \
  --project="${PROJECT_ID}" \
  --format="value(email)"

gcloud tasks queues describe calendar-ops \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.retryConfig'

gcloud scheduler jobs list \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

#### 4.8.3 IAP API と service account 作成

```bash
gcloud services enable iap.googleapis.com --project="${PROJECT_ID}"

gcloud beta services identity create \
  --service=iap.googleapis.com \
  --project="${PROJECT_ID}"

gcloud iam service-accounts describe "${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "openclaw-scheduler-invoker" \
  --display-name="OpenClaw Scheduler OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts describe "${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "openclaw-tasks-invoker" \
  --display-name="OpenClaw Tasks OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts describe "${HUD_GATEWAY_SA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "openclaw-hud-gateway" \
  --display-name="OpenClaw HUD Gateway Service Account" \
  --project="${PROJECT_ID}"
```

#### 4.8.4 Secret Manager 正規化

```bash
for SECRET_NAME in \
  "${OAUTH_CLIENT_SECRET_NAME}" \
  "${GMAIL_REFRESH_SECRET_NAME}" \
  "${GEMINI_API_KEY_SECRET_NAME}"
do
  gcloud secrets describe "${SECRET_NAME}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1 || \
  gcloud secrets create "${SECRET_NAME}" \
    --replication-policy="automatic" \
    --project="${PROJECT_ID}"
done

gcloud secrets add-iam-policy-binding "${GMAIL_REFRESH_SECRET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretVersionAdder" \
  --project="${PROJECT_ID}"
```

旧 Secret から値を移す必要がある場合のみ、`gcp-required-steps-after-hud-auth-update.md` の Secret コピー手順を実行する。OAuth client ID は Secret Manager へ保存しない。

#### 4.8.5 IAM 境界設定

```bash
export DEPLOYER_ACCOUNT="$(gcloud config get-value account)"
if [[ "${DEPLOYER_ACCOUNT}" == *".gserviceaccount.com" ]]; then
  export DEPLOYER_MEMBER="serviceAccount:${DEPLOYER_ACCOUNT}"
else
  export DEPLOYER_MEMBER="user:${DEPLOYER_ACCOUNT}"
fi

gcloud iam service-accounts add-iam-policy-binding "${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --member="${DEPLOYER_MEMBER}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts add-iam-policy-binding "${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding openclaw-api \
  --region="${REGION}" \
  --member="serviceAccount:${HUD_GATEWAY_SA_EMAIL}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding openclaw-api \
  --region="${REGION}" \
  --member="serviceAccount:${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding openclaw-api \
  --region="${REGION}" \
  --member="serviceAccount:${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"
```

HUD 利用者、Workspace domain、`allUsers` に `openclaw-api` の `roles/run.invoker` を付与しない。

#### 4.8.6 `openclaw-api` 差分デプロイ

backend 実装が OpenAPI `HealthResponse`、OpenAPI v1.4.0 OAuth endpoints、Google ID token 署名検証、Scheduler / Tasks OIDC allowlist に追従した image を用意してから実行する。

既存 image を再利用する場合:

```bash
export IMAGE="$(gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(spec.template.spec.containers[0].image)")"

export CLOUD_TASKS_QUEUE="projects/${PROJECT_ID}/locations/${REGION}/queues/calendar-ops"
export DB_IAM_USER="${SA_EMAIL%.gserviceaccount.com}"

gcloud run deploy openclaw-api \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --no-allow-unauthenticated \
  --ingress=all \
  --service-account="${SA_EMAIL}" \
  --set-env-vars="\
GCP_PROJECT_ID=${PROJECT_ID},\
CLOUD_SQL_CONNECTION_NAME=${CLOUD_SQL_CONNECTION_NAME},\
DB_NAME=openclaw_db,\
DB_USER=${DB_IAM_USER},\
SERVICE_ACCOUNT_EMAIL=${SA_EMAIL},\
CLOUD_TASKS_QUEUE=${CLOUD_TASKS_QUEUE},\
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID},\
ALLOWED_DOMAIN=${ALLOWED_DOMAIN},\
ALLOWED_SUBJECT=${ALLOWED_SUBJECT},\
SCHEDULER_SERVICE_ACCOUNT_EMAIL=${SCHEDULER_SERVICE_ACCOUNT_EMAIL},\
TASKS_SERVICE_ACCOUNT_EMAIL=${TASKS_SERVICE_ACCOUNT_EMAIL},\
SECRET_OAUTH_CLIENT_SECRET=${OAUTH_CLIENT_SECRET_NAME},\
SECRET_GMAIL_REFRESH_TOKEN=${GMAIL_REFRESH_SECRET_NAME},\
SECRET_GEMINI_API_KEY=${GEMINI_API_KEY_SECRET_NAME}" \
  --add-cloudsql-instances="${CLOUD_SQL_CONNECTION_NAME}" \
  --min-instances=1 \
  --max-instances=1 \
  --concurrency=1 \
  --cpu=1 \
  --memory=1Gi \
  --timeout=120s \
  --startup-probe="httpGet.path=/livez,initialDelaySeconds=0,failureThreshold=3,timeoutSeconds=2,periodSeconds=5" \
  --liveness-probe="httpGet.path=/livez,initialDelaySeconds=10,failureThreshold=3,timeoutSeconds=2,periodSeconds=30" \
  --project="${PROJECT_ID}"

export CLOUD_RUN_URL="$(gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"

gcloud run services update openclaw-api \
  --region="${REGION}" \
  --update-env-vars="CLOUD_RUN_URL=${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"
```

#### 4.8.7 `openclaw-hud-gateway` デプロイと IAP 設定

gateway image が用意できてから実行する。

```bash
export HUD_GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/openclaw-hud-gateway:latest"

gcloud run deploy "${HUD_GATEWAY_SERVICE}" \
  --image="${HUD_GATEWAY_IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --no-allow-unauthenticated \
  --ingress=all \
  --service-account="${HUD_GATEWAY_SA_EMAIL}" \
  --set-env-vars="BACKEND_URL=${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"

gcloud run services update "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --iap \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --member="serviceAccount:${IAP_SERVICE_AGENT}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

gcloud iap web add-iam-policy-binding \
  --member="${IAP_ACCESS_MEMBER}" \
  --role="roles/iap.httpsResourceAccessor" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  --project="${PROJECT_ID}"

gcloud beta iap settings get \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  > iap-settings.yaml
```

`iap-settings.yaml` の `accessSettings.oauthSettings.programmaticClients` に `${GOOGLE_CLIENT_ID}` を追加してから反映する。

```bash
gcloud beta iap settings set iap-settings.yaml \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}"

export HUD_GATEWAY_URL="$(gcloud run services describe "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"
```

#### 4.8.8 Cloud Tasks / Scheduler 更新

```bash
gcloud tasks queues describe calendar-ops \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud tasks queues create calendar-ops \
  --location="${REGION}" \
  --max-dispatches-per-second=1 \
  --max-concurrent-dispatches=1 \
  --max-attempts=1 \
  --project="${PROJECT_ID}"

gcloud tasks queues update calendar-ops \
  --location="${REGION}" \
  --max-dispatches-per-second=1 \
  --max-concurrent-dispatches=1 \
  --max-attempts=1 \
  --project="${PROJECT_ID}"

gcloud scheduler jobs update http poll-gmail \
  --location="${REGION}" \
  --schedule="* * * * *" \
  --uri="${CLOUD_RUN_URL}/internal/poll-gmail" \
  --http-method=POST \
  --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --oidc-token-audience="${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"

gcloud scheduler jobs update http pii-retention \
  --location="${REGION}" \
  --schedule="0 18 * * *" \
  --time-zone="UTC" \
  --uri="${CLOUD_RUN_URL}/internal/retention/pii-mask" \
  --http-method=POST \
  --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --oidc-token-audience="${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"

gcloud scheduler jobs pause poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

`poll-gmail` は backend confidential exchange による refresh token 保存完了まで pause のままにする。

#### 4.8.9 検証コマンド

```bash
gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '{
    url: .status.url,
    ingressTemplate: .spec.template.metadata.annotations["run.googleapis.com/ingress"],
    ingressService: .metadata.annotations["run.googleapis.com/ingress"],
    minScale: .spec.template.metadata.annotations["autoscaling.knative.dev/minScale"],
    maxScale: .spec.template.metadata.annotations["autoscaling.knative.dev/maxScale"],
    containerConcurrency: .spec.template.spec.containerConcurrency,
    serviceAccountName: .spec.template.spec.serviceAccountName,
    env: [.spec.template.spec.containers[0].env[]?.name],
    startupProbe: .spec.template.spec.containers[0].startupProbe,
    livenessProbe: .spec.template.spec.containers[0].livenessProbe
  }'

gcloud run services get-iam-policy openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud run services get-iam-policy "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud iap web get-iam-policy \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud beta iap settings get \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  --format=json | jq '.accessSettings.oauthSettings.programmaticClients // []'
```

direct `openclaw-api` の境界確認:

```bash
curl -i "${CLOUD_RUN_URL}/v1/health"
```

期待値は Cloud Run platform 403。

probe 確認:

```bash
PROBE_TOKEN="$(gcloud auth print-identity-token \
  --impersonate-service-account="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --audiences="${CLOUD_RUN_URL}" \
  --include-email)"

curl -i \
  -H "Authorization: Bearer ${PROBE_TOKEN}" \
  "${CLOUD_RUN_URL}/livez"

curl -i \
  -H "Authorization: Bearer ${PROBE_TOKEN}" \
  "${CLOUD_RUN_URL}/readyz"
```

gateway 経由の正式確認:

```bash
export TOKEN="${HUD_ID_TOKEN:?Set from Gateway/backend handoff}"

curl -s \
  -H "Proxy-Authorization: Bearer ${TOKEN}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${HUD_GATEWAY_URL}/v1/health" | jq .
```

Scheduler / Tasks 確認:

```bash
gcloud scheduler jobs describe poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.httpTarget.oidcToken'

gcloud scheduler jobs describe pii-retention \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.httpTarget.oidcToken'

gcloud tasks queues describe calendar-ops \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.retryConfig'
```

#### 4.8.10 実行しないコマンド

以下は現行設計では実行しない。

```bash
gcloud projects create ...
gcloud run deploy openclaw-api --allow-unauthenticated ...
gcloud run services add-iam-policy-binding openclaw-api --member="allUsers" --role="roles/run.invoker" ...
gcloud run services add-iam-policy-binding openclaw-api --member="domain:<workspace-domain>" --role="roles/run.invoker" ...
gcloud iam service-accounts keys create ...
```

---

## 5. 検証順序

1. `ALLOWED_SUBJECT` を Gateway/backend verified handoff claims から取得する。
2. `openclaw-api` の env と IAM を更新する。
3. Scheduler SA impersonation で `/livez` / `/readyz` を確認する。
4. 未認証 direct `/v1/health` が Cloud Run platform 403 になることを確認する。
5. `openclaw-hud-gateway` をデプロイし、IAP を有効化する。
6. IAP `programmaticClients` に `GOOGLE_CLIENT_ID` を追加する。
7. HUD ID token で gateway 経由 `/v1/health` を確認する。
8. gateway log / backend log に token、secret、PII が出ていないことを確認する。
9. backend confidential exchange 実装後、Secret Manager への refresh token 登録を確認する。
10. refresh token 登録後、`hud-auth-post-implementation-operations.md` に従って `poll-gmail` を再開する。

---

## 6. Phase 2 開始条件

以下がすべて満たされた場合のみ、Phase 2 実API連携へ進む。

- `ALLOWED_SUBJECT` が Gateway/backend verified handoff claims の `sub` で確定している。
- `openclaw-api` は private のまま運用されている。
- `openclaw-hud-gateway` がデプロイ済みで IAP が有効である。
- HUD 利用者または管理 group に gateway の IAP access が付与されている。
- `GOOGLE_CLIENT_ID` が IAP `programmaticClients` に含まれる。
- gateway SA / Scheduler SA / Tasks SA のみが `openclaw-api` invoker である。
- gateway が inbound `X-Serverless-Authorization` を破棄し、backend 用 ID token を新規生成している。
- gateway 経由 `/v1/health` が OpenAPI `HealthResponse` を返す。
- backend confidential exchange / `/v1/auth/id-token/refresh` が実装・デプロイ済みである。
- backend TASK-014 の Test-Ref / remaining `TBD` が解消されている。
- Phase A により、spec-driven-dev の形式ゲート不在時の代替承認基準が整理済みである。

---

## 7. 中断条件

以下の場合は作業を止め、該当設定または実装を修正する。

- `ALLOWED_SUBJECT` が Gateway/backend verified handoff claims 由来でない。
- `openclaw-api` に HUD 利用者または Workspace domain の direct invoker が付与されている。
- `GOOGLE_CLIENT_ID` と HUD `oauthClientId` が一致しない。
- IAP `programmaticClients` に `GOOGLE_CLIENT_ID` が含まれていない。
- gateway が inbound `X-Serverless-Authorization` を backend へ転送している。
- direct `/v1/health` を正式 HUD 確認に使っている。
- token、refresh token、approvalToken raw value、PII がログに出ている。
- `poll-gmail` を refresh token 登録前に再開しようとしている。

---

## 8. 関連文書

| 文書 | 役割 |
|---|---|
| `hud-auth-redesign-current-outlook.md` | 今回の設計変更で何が変わったか、次に何をするか、まだ実施しないことの見通し整理 |
| `gcp-required-steps-after-hud-auth-update.md` | GCP 差分適用の具体コマンド |
| `gcp-setup.md` | 初回構築を含む GCP 全体手順 |
| `hud-auth-post-implementation-operations.md` | backend confidential exchange 実装後の refresh token 登録・`poll-gmail` 再開手順 |
| `OpenclawSecretaryHUD/docs/specs/openclaw-hud-auth-api-approval/implementation_plan.md` | HUD 実装フェーズと Phase 2 開始条件 |
| `OpenclawSecretaryHUD/docs/specs/openclaw-hud-auth-api-approval/authentication_decision.md` | Gateway / IAP 認証方式の正本判断 |
