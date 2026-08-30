# GCP プロジェクト初期設定 Runbook

作成日: 2026-06-04 | 更新日: 2026-06-09 | バージョン: 1.2
対応タスク: TASK-001
依拠要件: REQ-AUTH-001, REQ-AUTH-002, REQ-AUTH-003, REQ-AUTH-004, REQ-ARCH-001, REQ-STORE-001, REQ-STORE-003, REQ-SEC-001, REQ-SEC-002, REQ-SEC-003, REQ-CRED-001, REQ-CRED-002, REQ-CRED-003, REQ-OPS-001, REQ-OPS-002, REQ-OPS-003, REQ-DEPLOY-004, REQ-COMPLY-001
参照正本（分割後）: `docs/specs/infra/requirements_definition.md`, `docs/specs/infra/design.md`, `docs/specs/infra/infra_architecture_design.md`, `docs/security/security_design.md`, `OpenclawSecretary-Back/docs/api/openapi.yaml`

---

## 方針: 1ユーザー 1GCPプロジェクト

本システムは **1ユーザー = 1GCPプロジェクト = 1Cloud SQLインスタンス** を原則とする。
同一プロジェクト内への複数ユーザー収容、shared schema / tenant_id / RLS による分離は採用しない（REQ-ARCH-001）。

---

## この Runbook の最適解

openclawmaildraft（現行 `gmail-ai-secretary` 仕様）の要件定義・設計を踏まえ、MVP の最適構成を以下で固定する。

| 領域 | 採用する構成 | 採用理由 / 拒否する構成 |
|---|---|---|
| テナント分離 | 1ユーザー = 1GCPプロジェクト = 1 backend Cloud Run service（`openclaw-api`） + 1 HUD Gateway service（`openclaw-hud-gateway`） + 1Cloud SQL instance | PII/RAG/Secret の混在を構造的に排除する。MVPでは shared schema、tenant_id、RLS、共有Cloud SQLを採用しない |
| HUD → OpenClaw 認証 | 現行組織ポリシーでは `allUsers` 公開不可。`openclaw-api` は `--no-allow-unauthenticated` + `--ingress=all` を維持し、HUD は IAP 保護された `openclaw-hud-gateway` を経由する。`GOOGLE_CLIENT_ID` を IAP `programmaticClients` に allowlist し、HUD は同じ Google ID token を `Proxy-Authorization` と `Authorization` に分けて送る。HUD 利用者は IAP access、`openclaw-api` invoker は gateway service account / Scheduler SA / Tasks SA のみ、backend は `Authorization: Bearer {Google OAuth ID token}` を検証する | `--allow-unauthenticated` / `allUsers` 公開、HUD利用者への `openclaw-api` 直接 invoker 付与、SAキー配布を前提にしない |
| Scheduler / Tasks → OpenClaw 認証 | Scheduler / Tasks 専用 SA が OIDC token を発行し、Cloud Run IAM `roles/run.invoker` も付与する。`aud=CLOUD_RUN_URL` と SA email allowlist を OpenClaw 側で検証する | Cloud Run 実行SAを internal 呼び出し元に兼用しない。Scheduler/Tasks SA に broad role は付与しない |
| Cloud SQL 接続 | Cloud SQL for PostgreSQL + pgvector。Private IP only、Cloud SQL Connector for Node.js、IAM DB 認証、Cloud Run Direct VPC egress | public IP / authorized networks / DBパスワード常用 / Cloud SQL Auth Proxy sidecar は本番経路では採用しない |
| Secret 管理 | Secret Manager に refresh token、OAuth client secret、Gemini API key のみ保存。OAuth client ID は非シークレット env var `GOOGLE_CLIENT_ID` が正 | OAuth client ID を Secret として扱わない。Secret IAM は対象 secret 3件に限定し、project-level `secretAccessor` は付与しない |
| DwD | サービスアカウントキー JSON を発行せず、IAM Credentials API `signJwt` のみを custom role で許可 | `roles/iam.serviceAccountTokenCreator`、SAキーJSON保存、DwD scope への Gmail scope 追加は採用しない |
| Calendar 副作用 | HUD 承認後に Cloud Tasks へ一意 task を enqueue。queue は `maxAttempts=1` / `maxDispatchesPerSecond=1` / `maxConcurrentDispatches=1` | Cloud Tasks 自動リトライによる二重更新を防ぐ。worker は結果を DB/event inbox に保存した上で 2xx を返す |
| 承認 token / PII | approvalToken は平文を DB / event_inbox / log / renderer IPC に保存しない。DB は SHA-256 hash のみ。PII は90日で mask/clear、監査ログは非PII allowlistのみ | Gmail draftId、Calendar eventId、OAuth token、Secret値、メール本文、件名、参加者名・メール、既存予定名を HUD/API/ログへ出さない |

**デプロイ可否ゲート**: 上表の認証境界・Secret境界・Cloud Tasks OIDC発行元分離を実装が満たしていない revision は、本番デプロイ不可とする。環境変数だけを設定しても、OpenClaw 側が `aud` / `hd` / `sub` / Scheduler・Tasks SA email を検証していなければ要件適合とは見なさない。

---

## 前提条件

- `gcloud` CLI がインストールされていること（`gcloud --version` で確認）
- 課金アカウントが有効であること
- 作業者が GCP 組織の Project Creator 権限を持つこと
- Google Workspace 管理者アカウントがあること（DwD 設定用）
- VPC / Private Service Access を作成できる Compute Network Admin 相当の権限があること

---

## 1. GCP プロジェクト作成

```bash
# 変数定義（ユーザーごとに設定）
export PROJECT_ID="openclaw-<username>-prod"   # 例: openclaw-yamada-prod
export PROJECT_NAME="OpenClaw <username>"
export USER_ID="<google-sub-or-user-slug>"     # 例: Google user sub。Secret名・サービス名の安定識別子
export SECRET_PREFIX="openclaw-${USER_ID}"
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX"  # gcloud billing accounts list で確認
export REGION="asia-northeast1"             # Cloud Run と Cloud SQL を同一リージョンに配置（REQ-STORE-001）
export VPC_NETWORK="openclaw-vpc"
export VPC_SUBNET="openclaw-${REGION}"
export VPC_SUBNET_RANGE="10.10.0.0/24"
export PRIVATE_SERVICE_RANGE="google-managed-services-${VPC_NETWORK}"

# プロジェクト作成
gcloud projects create "${PROJECT_ID}" \
  --name="${PROJECT_NAME}"

# デフォルトプロジェクト設定
gcloud config set project "${PROJECT_ID}"

# 課金アカウントの紐付け
gcloud billing projects link "${PROJECT_ID}" \
  --billing-account="${BILLING_ACCOUNT_ID}"
```

---

## 2. 必要な API の有効化

```bash
gcloud services enable \
  gmail.googleapis.com \
  calendar-json.googleapis.com \
  run.googleapis.com \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  secretmanager.googleapis.com \
  cloudscheduler.googleapis.com \
  cloudtasks.googleapis.com \
  artifactregistry.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"
```

有効化される API の用途:

| API | 用途 |
|---|---|
| `gmail.googleapis.com` | Gmail メール取得・送信 |
| `calendar-json.googleapis.com` | Google Calendar 読み書き |
| `run.googleapis.com` | Cloud Run コンテナ実行 |
| `compute.googleapis.com` | VPC / subnet / private services access 前提リソース |
| `sqladmin.googleapis.com` | Cloud SQL インスタンス管理 |
| `servicenetworking.googleapis.com` | Cloud SQL Private IP 用 Private Service Access |
| `secretmanager.googleapis.com` | シークレット管理（認証情報・APIキー） |
| `cloudscheduler.googleapis.com` | Gmail polling・retention job の定期実行 |
| `cloudtasks.googleapis.com` | Calendar 書き込みの非同期タスク管理 |
| `artifactregistry.googleapis.com` | Cloud Run 用 Docker image repository |
| `iamcredentials.googleapis.com` | DwD 用 IAM Credentials API（signJwt） |
| `iam.googleapis.com` | サービスアカウント・ロール管理 |
| `iap.googleapis.com` | HUD Gateway の Identity-Aware Proxy / programmatic access |
| `logging.googleapis.com` | Cloud Logging への構造化ログ出力 |

---

## 3. サービスアカウント作成と IAM 権限付与

### 3-1. OpenClaw 用サービスアカウントの作成

```bash
export SA_NAME="openclaw-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="OpenClaw Cloud Run Service Account" \
  --project="${PROJECT_ID}"
```

### 3-2. 標準ロールの付与

```bash
# Cloud SQL IAM 認証で接続（キーファイル不要）
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/cloudsql.client"

# Cloud Logging への構造化ログ書き込み
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/logging.logWriter"
```

> Secret Manager の `secretAccessor` は project-level では付与しない。セクション 7 で対象 secret を作成した後、3件の secret にだけ resource-level IAM binding を付与する。

### 3-3. internal endpoint 呼び出し専用サービスアカウントの作成

Cloud Scheduler / Cloud Tasks は Cloud Run 実行サービスアカウントとは別の OIDC 発行元サービスアカウントを使用する。
OpenClaw アプリケーションは Scheduler / Tasks の2つのメールアドレスを internal allowlist として検証し、HUD Gateway service account は `openclaw-api` 呼び出し用 invoker として分離する。

```bash
export SCHEDULER_SA_NAME="openclaw-scheduler-invoker"
export TASKS_SA_NAME="openclaw-tasks-invoker"
export HUD_GATEWAY_SA_NAME="openclaw-hud-gateway"
export SCHEDULER_SA_EMAIL="${SCHEDULER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export TASKS_SA_EMAIL="${TASKS_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export HUD_GATEWAY_SA_EMAIL="${HUD_GATEWAY_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${SCHEDULER_SA_NAME}" \
  --display-name="OpenClaw Scheduler OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts create "${TASKS_SA_NAME}" \
  --display-name="OpenClaw Tasks OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts create "${HUD_GATEWAY_SA_NAME}" \
  --display-name="OpenClaw HUD Gateway Service Account" \
  --project="${PROJECT_ID}"

# Scheduler job 作成者が Scheduler OIDC SA を job に関連付けられるようにする
export DEPLOYER_ACCOUNT="$(gcloud config get-value account)"
if [[ "${DEPLOYER_ACCOUNT}" == *".gserviceaccount.com" ]]; then
  export DEPLOYER_MEMBER="serviceAccount:${DEPLOYER_ACCOUNT}"
else
  export DEPLOYER_MEMBER="user:${DEPLOYER_ACCOUNT}"
fi

gcloud iam service-accounts add-iam-policy-binding "${SCHEDULER_SA_EMAIL}" \
  --member="${DEPLOYER_MEMBER}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

# OpenClaw 実行SAが Cloud Tasks enqueue 時に Tasks OIDC SA を指定できるようにする
gcloud iam service-accounts add-iam-policy-binding "${TASKS_SA_EMAIL}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"
```

> 現行組織ポリシーでは Cloud Run の `allUsers` 公開が禁止されている。
> Scheduler / Tasks 専用 SA には Cloud Run `roles/run.invoker` も付与する。
> そのうえで、OpenClaw アプリケーション側でも OIDC token の `aud` と SA email を検証する。

### 3-4. Secret Manager IAM 付与方針

Secret Manager IAM は secret 作成前に付与できないため、実行コマンドはセクション 7 に集約する。

- `roles/secretmanager.secretAccessor`: `openclaw-{user_id}-gmail-refresh-token`、`openclaw-{user_id}-oauth-client-secret`、`openclaw-{user_id}-gemini-api-key` の3件だけ
- `roles/secretmanager.secretVersionAdder`: `openclaw-{user_id}-gmail-refresh-token` だけ
- 禁止: project-level の `roles/secretmanager.secretAccessor` / `roles/secretmanager.admin`

この分離により、Gmail refresh token rotation だけは実行時に書き込み可能にしつつ、OAuth client secret と Gemini API key は読み取り専用に固定する（REQ-CRED-001/002）。

### 3-5. DwD 用カスタムロールの作成と付与

DwD（Domain-wide Delegation）は IAM Credentials API の `signJwt` のみを使用する。
サービスアカウントキー JSON ファイルは作成しない（REQ-CRED-002）。

```bash
# カスタムロール定義ファイルの作成
cat > /tmp/dwd-sign-jwt-role.yaml << 'EOF'
title: "OpenClaw DwD signJwt"
description: "Allows signJwt via IAM Credentials API for Domain-wide Delegation"
stage: "GA"
includedPermissions:
  - iam.serviceAccounts.signJwt
EOF

# カスタムロールの作成
gcloud iam roles create openclaw_dwd_sign_jwt \
  --project="${PROJECT_ID}" \
  --file=/tmp/dwd-sign-jwt-role.yaml

# OpenClaw SA に付与（自分自身への signJwt 権限）
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${PROJECT_ID}/roles/openclaw_dwd_sign_jwt" \
  --project="${PROJECT_ID}"
```

---

## 4. OAuth 2.0 クライアントの作成（インストール済みアプリ・PKCE）

HUD（Electron デスクトップアプリ）は **インストール済みアプリ** タイプの OAuth クライアントを使用する。
PKCE（Proof Key for Code Exchange）を適用する。ただし本番では HUD が Google token endpoint で認可コードを交換しない。`openclaw-hud-gateway` 経由の private `openclaw-api` が Secret Manager の OAuth client secret を使って confidential exchange を行う。

### 手順

1. [Google Cloud Console](https://console.cloud.google.com) > **API とサービス** > **認証情報** に移動
2. **認証情報を作成** > **OAuth クライアント ID** を選択
3. アプリケーションの種類: **デスクトップアプリ**（インストール済みアプリ）
4. 名前: `OpenClaw HUD`
5. 作成後、`client_id` は HUD 設定画面の `oauthClientId` と Cloud Run 環境変数 `GOOGLE_CLIENT_ID` に設定する。`client_secret` のみ Secret Manager に保存する（セクション 7 参照）

> Note: PKCE では `code_challenge_method=S256` を使用する。`code_verifier` と `code_challenge` は Gateway/private API の短期 auth session で生成・保持し、HUD には露出しない。

---

### 4-1. `ALLOWED_SUBJECT` の取得

`ALLOWED_SUBJECT` は対象ユーザーの Google `sub` を固定するために必要である。正本は Gateway/backend confidential exchange 後に backend が検証した ID token claims、または同じ handoff payload の sanitized claims とする。`gcloud auth print-identity-token` の作業者 token から推測してはならない。ID token を外部の token decode サイトへ貼り付けてはならない。

```bash
# 一時PKCE helper または HUD 開発版で取得した Google ID token を設定する
export HUD_ID_TOKEN="<GOOGLE_ID_TOKEN_FROM_LOCAL_PKCE_FLOW>"

python -c "import base64,json,os; t=os.environ['HUD_ID_TOKEN'].split('.')[1]; t += '=' * (-len(t) % 4); print(json.dumps(json.loads(base64.urlsafe_b64decode(t)), indent=2, ensure_ascii=False))"
```

出力の以下を確認する。

- `aud` が HUD 設定画面の `oauthClientId` および Cloud Run env var `GOOGLE_CLIENT_ID` と一致する
- `hd` が `ALLOWED_DOMAIN` と一致する
- Gateway/backend verified claims の `sub` を `ALLOWED_SUBJECT` に設定する

```bash
export ALLOWED_SUBJECT="<decoded-sub>"
```

---

## 5. OAuth スコープ設定（Gmail・Calendar）

以下の **5スコープ** のみに制限する。追加スコープは要件変更時にのみ審査後追加する。

| スコープ | 用途 |
|---|---|
| `https://www.googleapis.com/auth/gmail.readonly` | Gmail メール受信・分析 |
| `https://www.googleapis.com/auth/gmail.compose` | 返信下書き作成・送信 |
| `https://www.googleapis.com/auth/calendar.events` | Calendar 予定の読み書き（DwD 経由） |
| `openid` | Google ID token 取得 |
| `email` | ID token の email claim 取得（IAP programmatic access / 監査 / HUD 表示） |

### OAuth 同意画面の設定

```
アプリ名: OpenClaw AI Secretary
ユーザーサポートメール: <管理者メール>
承認済みドメイン: <組織ドメイン>
スコープ: 上記 5スコープ
```

---

## 6. Google Workspace Internal アプリ設定（審査不要）

Google Workspace **組織内部** のアプリとして設定することで、OAuth 審査（Google によるアプリ検証）が不要になる。

1. OAuth 同意画面の **ユーザーの種類** を **内部** に設定
2. 対象ユーザー: 組織ドメイン（例: `example.com`）のアカウントのみ
3. **注意**: External に変更すると審査が必要になるため、変更しないこと

---

## 7. Secret Manager シークレットの初期作成

```bash
export OAUTH_CLIENT_SECRET_NAME="${SECRET_PREFIX}-oauth-client-secret"
export GMAIL_REFRESH_SECRET_NAME="${SECRET_PREFIX}-gmail-refresh-token"
export GEMINI_API_KEY_SECRET_NAME="${SECRET_PREFIX}-gemini-api-key"

# Gmail OAuth client_secret
gcloud secrets create "${OAUTH_CLIENT_SECRET_NAME}" \
  --replication-policy="automatic" \
  --project="${PROJECT_ID}"

# Gmail refresh token（OpenClaw が自動更新して書き込む）
gcloud secrets create "${GMAIL_REFRESH_SECRET_NAME}" \
  --replication-policy="automatic" \
  --project="${PROJECT_ID}"

# Gemini API キー
gcloud secrets create "${GEMINI_API_KEY_SECRET_NAME}" \
  --replication-policy="automatic" \
  --project="${PROJECT_ID}"

# シークレット値の設定（初回のみ手動）
# OAuth client ID は非シークレットのため Secret Manager には保存しない。
# HUD 設定画面の oauthClientId と Cloud Run env var GOOGLE_CLIENT_ID に同じ値を設定する。

echo -n "<YOUR_CLIENT_SECRET>" | \
  gcloud secrets versions add "${OAUTH_CLIENT_SECRET_NAME}" \
  --data-file=- --project="${PROJECT_ID}"

echo -n "<YOUR_GEMINI_API_KEY>" | \
  gcloud secrets versions add "${GEMINI_API_KEY_SECRET_NAME}" \
  --data-file=- --project="${PROJECT_ID}"

# 実行サービスアカウントへ secret 単位で読み取り権限を付与する。
# project-level secretAccessor は付与しない。
for SECRET_NAME in \
  "${OAUTH_CLIENT_SECRET_NAME}" \
  "${GMAIL_REFRESH_SECRET_NAME}" \
  "${GEMINI_API_KEY_SECRET_NAME}"; do
  gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --project="${PROJECT_ID}"
done

# Gmail refresh token rotation 用。書き込み権限は refresh token secret のみに限定する。
gcloud secrets add-iam-policy-binding "${GMAIL_REFRESH_SECRET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretVersionAdder" \
  --project="${PROJECT_ID}"
```

> Note: `${GMAIL_REFRESH_SECRET_NAME}` は初回 OAuth フロー完了後に OpenClaw が自動書き込みする。手動での初期値設定は不要。
> 設計正本では OAuth client ID は `GOOGLE_CLIENT_ID` env var を正とする。現行実装が `SECRET_OAUTH_CLIENT_ID` / `openclaw-oauth-client-id` を要求する revision は、設計適合版へ修正してから本番デプロイする。既存の legacy client ID secret が残っている場合も正本にはせず、`GOOGLE_CLIENT_ID` との照合専用に使い、修正完了後に削除する。

---

## 8. Cloud Run HTTPS / HUD Gateway / 認証境界

現行組織ポリシーでは `allUsers` 公開が禁止されているため、`openclaw-api` は `--no-allow-unauthenticated` + `--ingress=all` とする。HUD（Electron）の本番 entrypoint は IAP 保護された `openclaw-hud-gateway` とし、HUD 利用者には IAP access（`roles/iap.httpsResourceAccessor`）を付与する。`openclaw-api` の `roles/run.invoker` は gateway service account / Scheduler SA / Tasks SA のみに付与する。

HUD は `GOOGLE_CLIENT_ID` を IAP settings の `accessSettings.oauthSettings.programmaticClients` に allowlist し、gateway へ同じ Google OAuth ID token を `Proxy-Authorization: Bearer {Google OAuth ID token}` と `Authorization: Bearer {Google OAuth ID token}` に分けて送信する。gateway は IAP 由来の inbound `X-Serverless-Authorization` を backend へ転送せず、`openclaw-api` へ新規生成した `X-Serverless-Authorization: Bearer {gateway service account ID token}` と `Authorization: Bearer {Google OAuth ID token}` を分けて転送する。OpenClaw アプリケーション側は `Authorization` の `iss` / `aud=GOOGLE_CLIENT_ID` / `hd=ALLOWED_DOMAIN` / `sub=ALLOWED_SUBJECT` を検証する。

Cloud Scheduler / Cloud Tasks は Cloud Run service URL を audience とする OIDC token を送信する。Cloud Run IAM `roles/run.invoker` と、OpenClaw アプリケーション側の service account email allowlist の両方で検証する。

> `--allow-unauthenticated` / `allUsers` は使用しない。未認証リクエストは Cloud Run platform 403 になる。

---

## 9. dwdAllowlistEmails の設定

DwD（Domain-wide Delegation）で Calendar 書き込みを許可するユーザーのリストを `settings` テーブルに初期設定する（RC-DWD-001）。

アプリケーション起動後、以下のいずれかの手順で設定する:

1. backend/admin 設定面または管理CLIから `GET/PUT /v1/settings` を使って `dwdAllowlistEmails` に対象メールアドレスを追加する
2. または、`migrations/002_initial_settings.sql` の `dwdAllowlistEmails` を更新してから migration を実行する

HUD MVP のローカル設定画面は Gateway URL・組織ドメイン・OAuth client ID だけを扱い、OpenClaw の `GET/PUT /v1/settings` は呼び出さない。

**Fail-closed 動作**: `dwdAllowlistEmails` が空配列または未設定の場合、DwD 参加者書き込みは全スキップされる（REQ-AUTH-002）。

---

## 10. Domain-wide Delegation 設定手順

DwD により OpenClaw（サービスアカウント）が組織ユーザーの代わりに Calendar を操作する。

### 10-1. サービスアカウントの一意 ID（Client ID）を取得

```bash
gcloud iam service-accounts describe "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --format="value(uniqueId)"
```

出力された数値（例: `123456789012345678901`）を次のステップで使用する。

### 10-2. Google Workspace 管理コンソールで DwD を設定

1. [Google Workspace 管理コンソール](https://admin.google.com) に管理者でログイン
2. **セキュリティ** > **アクセスとデータ管理** > **APIの制御** > **ドメイン全体の委任** に移動
3. **新しく追加** をクリック
4. **クライアント ID**: 10-1 で取得した数値を入力
5. **OAuth スコープ**: 以下を入力（カンマ区切り）

```
https://www.googleapis.com/auth/calendar.events
```

6. **承認** をクリック

> Note: `gmail.readonly` と `gmail.compose` は HUD ユーザー自身の OAuth フローで取得するため、DwD スコープには含めない。DwD は Calendar 書き込み専用。

### 10-3. DwD の動作確認

```bash
# ユーザー管理のサービスアカウントキーが存在しないことを確認する。
gcloud iam service-accounts keys list \
  --iam-account="${SA_EMAIL}" \
  --managed-by=user \
  --project="${PROJECT_ID}"

# 期待値: ユーザー管理キーが 0 件。
# DwD の実動作は、デプロイ後に OpenClaw の auth-manager.js が IAM Credentials API signJwt を呼び、
# Cloud Audit Logs に signJwt 呼び出しが残ることで確認する。
```

---

## 10-4. デプロイ前実装ゲート

以下が満たされていない revision は、GCP リソース作成済みでも本番デプロイ不可とする。これは環境構築の問題ではなく、要件・設計への適合条件である。

- HUD向け `/v1/*` は Google 署名済み ID token を検証し、`iss`、`exp`、`aud == GOOGLE_CLIENT_ID`、`hd == ALLOWED_DOMAIN`、`sub == ALLOWED_SUBJECT` を必ず確認する。JWT payload の Base64 decode のみで署名検証を省略する実装は不可。
- `/internal/*` は Scheduler / Tasks OIDC token を検証し、`aud == CLOUD_RUN_URL` と `email == SCHEDULER_SERVICE_ACCOUNT_EMAIL` または `TASKS_SERVICE_ACCOUNT_EMAIL` を endpoint ごとに照合する。`.gserviceaccount.com` suffix のみで許可しない。
- Cloud Tasks enqueue 時の OIDC `serviceAccountEmail` は `TASKS_SERVICE_ACCOUNT_EMAIL` を使う。Cloud Run 実行SA（`SERVICE_ACCOUNT_EMAIL`）を Cloud Tasks 発行元に流用しない。
- OAuth client ID は `GOOGLE_CLIENT_ID` env var を正とし、Gmail OAuth client 作成時は `GOOGLE_CLIENT_ID` と OAuth client secret を使う。`SECRET_OAUTH_CLIENT_ID` を必須とする旧実装は修正してからデプロイする。
- Cloud SQL Connector は private IP 経路を使うため、`getOptions({ instanceConnectionName, authType: 'IAM', ipType: 'PRIVATE' })` 相当の設定になっていること。
- OpenClaw の HTTPS response、event_inbox、Cloud Logging、renderer IPC に `accessToken`、`refreshToken`、`approvalToken`（renderer IPC）、Gmail draftId、Calendar eventId、Secret値、Secret名、raw exception、メール本文、件名、参加者名・メールアドレスを出力しない。

---

## フェーズ 2: アプリケーションデプロイ

セクション 1〜10 の GCP 初期設定が完了したら、以下の手順でアプリケーションをビルド・デプロイする。
セクション 8 の方針に従い、`openclaw-api` は `--no-allow-unauthenticated` / `--ingress=all` でデプロイする。未認証呼び出しは Cloud Run IAM で拒否し、gateway / Scheduler / Tasks から Cloud Run を通過した呼び出しに対して OpenClaw アプリケーション側の ID/OIDC token 検証を行う。HUD 実 API 連携は `openclaw-hud-gateway` のデプロイと IAP programmatic access 設定後に実施する。

---

## 11. VPC / Private Service Access / Cloud SQL インスタンス作成

```bash
export CLOUD_SQL_INSTANCE="openclaw-db"

# VPC 作成（初回のみ）
gcloud compute networks describe "${VPC_NETWORK}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud compute networks create "${VPC_NETWORK}" \
  --subnet-mode=custom \
  --project="${PROJECT_ID}"

# Cloud Run Direct VPC egress 用 subnet 作成（Cloud Run と同一 region）
gcloud compute networks subnets describe "${VPC_SUBNET}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud compute networks subnets create "${VPC_SUBNET}" \
  --network="${VPC_NETWORK}" \
  --range="${VPC_SUBNET_RANGE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

# Cloud SQL Private IP 用の Private Service Access range を確保
gcloud compute addresses describe "${PRIVATE_SERVICE_RANGE}" \
  --global \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud compute addresses create "${PRIVATE_SERVICE_RANGE}" \
  --global \
  --purpose=VPC_PEERING \
  --prefix-length=16 \
  --description="Private Service Access range for OpenClaw Cloud SQL" \
  --network="${VPC_NETWORK}" \
  --project="${PROJECT_ID}"

# Private Service Access 接続。既存接続がある場合は再作成しない。
if ! gcloud services vpc-peerings list \
  --network="${VPC_NETWORK}" \
  --project="${PROJECT_ID}" \
  --format="value(service)" | grep -q '^servicenetworking.googleapis.com$'; then
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${PRIVATE_SERVICE_RANGE}" \
    --network="${VPC_NETWORK}" \
    --project="${PROJECT_ID}"
fi

# インスタンス作成（Private IP only + IAM 認証）
gcloud sql instances describe "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud beta sql instances create "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --network="projects/${PROJECT_ID}/global/networks/${VPC_NETWORK}" \
  --no-assign-ip \
  --allocated-ip-range-name="${PRIVATE_SERVICE_RANGE}" \
  --enable-google-private-path \
  --database-version=POSTGRES_15 \
  --region="${REGION}" \
  --tier=db-f1-micro \
  --storage-size=10GB \
  --storage-type=SSD \
  --no-storage-auto-increase \
  --database-flags=cloudsql.iam_authentication=on

# データベース作成
gcloud sql databases describe openclaw_db \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud sql databases create openclaw_db \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}"

# サービスアカウント用 IAM データベースユーザー作成
# Cloud SQL for PostgreSQL では SA メールアドレスから `.gserviceaccount.com` を除いた DB ユーザー名を使う
export DB_IAM_USER="${SA_EMAIL%.gserviceaccount.com}"
gcloud sql users describe "${DB_IAM_USER}" \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud sql users create "${DB_IAM_USER}" \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --type=CLOUD_IAM_SERVICE_ACCOUNT \
  --project="${PROJECT_ID}"

# 接続名を変数にセット（以降の手順で使用）
export CLOUD_SQL_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${CLOUD_SQL_INSTANCE}"
```

> 本番経路は Cloud SQL Connector for Node.js + `ipType='PRIVATE'` + Cloud Run Direct VPC egress とする。
> Cloud SQL Auth Proxy はセクション 12 の一時 migration VM 用に限定し、Cloud Run 本番コンテナの sidecar としては使わない。

---

## 12. DB スキーマ適用（マイグレーション実行）

Cloud SQL は private IP only のため、Cloud Shell から直接 Cloud SQL Auth Proxy を起動しても到達できない。
同一 VPC / subnet 上に一時 migration VM を作成し、Cloud SQL Auth Proxy の `--private-ip` 経由でマイグレーション SQL を適用する。完了後、migration VM は削除する。

### 手順

```bash
# ── ローカル端末または Cloud Shell で実行: migration VM 作成まで ──

# 1. 必要な変数を確認（Cloud Shell を開き直した場合は再設定）
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export REGION="${REGION:-asia-northeast1}"
export VPC_NETWORK="${VPC_NETWORK:-openclaw-vpc}"
export VPC_SUBNET="${VPC_SUBNET:-openclaw-${REGION}}"
export CLOUD_SQL_INSTANCE="${CLOUD_SQL_INSTANCE:-openclaw-db}"
export SA_NAME="${SA_NAME:-openclaw-sa}"
export SA_EMAIL="${SA_EMAIL:-${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"
export DB_IAM_USER="${DB_IAM_USER:-${SA_EMAIL%.gserviceaccount.com}}"
export MIGRATION_ZONE="${MIGRATION_ZONE:-${REGION}-a}"
export MIGRATION_VM="${MIGRATION_VM:-openclaw-migration}"
export CLOUD_SQL_CONNECTION_NAME="$(gcloud sql instances describe "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --format="value(connectionName)")"

test -n "${CLOUD_SQL_CONNECTION_NAME}" || {
  echo "CLOUD_SQL_CONNECTION_NAME が空です。Cloud SQL インスタンス名と PROJECT_ID を確認してください。"
  exit 1
}

echo "Cloud SQL connection: ${CLOUD_SQL_CONNECTION_NAME}"

# 2. openclaw_db データベースを確認し、未作成なら作成
gcloud sql databases describe openclaw_db \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud sql databases create openclaw_db \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}"

# 3. postgres ユーザーのパスワードを設定（初回または再設定時）
export DB_ADMIN_PASSWORD="$(openssl rand -base64 32)"
gcloud sql users set-password postgres \
  --instance="${CLOUD_SQL_INSTANCE}" \
  --password="${DB_ADMIN_PASSWORD}" \
  --project="${PROJECT_ID}"

test -n "${DB_ADMIN_PASSWORD}" || {
  echo "DB_ADMIN_PASSWORD が空です。postgres ユーザーのパスワード設定をやり直してください。"
  exit 1
}

# 4. migration VM を同一 VPC / subnet に作成
gcloud compute instances describe "${MIGRATION_VM}" \
  --zone="${MIGRATION_ZONE}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud compute instances create "${MIGRATION_VM}" \
  --zone="${MIGRATION_ZONE}" \
  --machine-type=e2-micro \
  --network="${VPC_NETWORK}" \
  --subnet="${VPC_SUBNET}" \
  --service-account="${SA_EMAIL}" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --image-family=debian-12 \
  --image-project=debian-cloud \
  --boot-disk-size=10GB \
  --project="${PROJECT_ID}"

cat <<EOF
次の値を migration VM 内で使います。値をチケット・ログ・チャットへ貼らないでください。
PROJECT_ID=${PROJECT_ID}
CLOUD_SQL_CONNECTION_NAME=${CLOUD_SQL_CONNECTION_NAME}
DB_IAM_USER=${DB_IAM_USER}
DB_ADMIN_PASSWORD=<直前に生成した値を手元で保持>
EOF

# 5. migration VM に SSH
gcloud compute ssh "${MIGRATION_VM}" \
  --zone="${MIGRATION_ZONE}" \
  --project="${PROJECT_ID}"

# ── 以降は migration VM 内で実行 ──

export PROJECT_ID="<PROJECT_ID>"
export CLOUD_SQL_CONNECTION_NAME="<PROJECT_ID>:<REGION>:openclaw-db"
export DB_IAM_USER="<openclaw-sa@PROJECT_ID.iam から .gserviceaccount.com を除いたDBユーザー名>"
export DB_ADMIN_PASSWORD="<ローカル側で生成した値>"

sudo apt-get update
sudo apt-get install -y postgresql-client curl git

# 6. Cloud SQL Auth Proxy v2 をダウンロード
curl -fsSL -o cloud-sql-proxy \
  "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.9.0/cloud-sql-proxy.linux.amd64"
chmod +x cloud-sql-proxy

# 7. Proxy をバックグラウンドで起動（private IP / port 5432）
./cloud-sql-proxy "${CLOUD_SQL_CONNECTION_NAME}" --private-ip --port 5432 &
PROXY_PID=$!
sleep 3

# 8. リポジトリを migration VM にクローンまたはアップロード
#
# Public repo の場合は HTTPS が最短:
git clone https://github.com/kaduiro/OpenclawSecretaryAndo.git OpenclawSecretaryAndo
#
# Private repo を SSH で clone する場合:
# - Cloud Shell の SSH 公開鍵を GitHub に登録してから実行する
# - 未登録のままだと `Permission denied (publickey).` で失敗する
# ssh-keygen -t ed25519 -C "$(gcloud config get-value account)" -f ~/.ssh/id_ed25519 -N ""
# cat ~/.ssh/id_ed25519.pub
#   -> 表示された公開鍵を GitHub Settings > SSH and GPG keys > New SSH key に登録
# ssh -T git@github.com
# git clone git@github.com:kaduiro/OpenclawSecretaryAndo.git OpenclawSecretaryAndo

# 9. マイグレーション実行（postgres ユーザーで接続）
#    Auth Proxy は Cloud SQL インスタンスへの接続を認証する。
#    PostgreSQL の postgres ユーザー認証には、上で設定した DB パスワードを使う。
PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -w \
  "host=127.0.0.1 port=5432 dbname=openclaw_db user=postgres sslmode=disable" \
  -f OpenclawSecretaryAndo/migrations/001_initial_schema.sql \
  -f OpenclawSecretaryAndo/migrations/002_initial_settings.sql

# 10. IAM DB ユーザーに必要な権限を付与
#     DB_IAM_USER はセクション 11 で作成済みであること。
PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -w \
  "host=127.0.0.1 port=5432 dbname=openclaw_db user=postgres sslmode=disable" <<SQL
GRANT CONNECT ON DATABASE openclaw_db TO "${DB_IAM_USER}";
GRANT USAGE ON SCHEMA public TO "${DB_IAM_USER}";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${DB_IAM_USER}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${DB_IAM_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_IAM_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${DB_IAM_USER}";
SQL

# 11. Proxy を停止し、SSH から抜ける
kill "${PROXY_PID}"
exit

# ── ローカル端末または Cloud Shell に戻って実行: migration VM 削除 ──
gcloud compute instances delete "${MIGRATION_VM}" \
  --zone="${MIGRATION_ZONE}" \
  --project="${PROJECT_ID}"
```

> **確認**: マイグレーション後、以下で 9 テーブルが作成されていることを確認する。
> ```sql
> SELECT table_name FROM information_schema.tables
> WHERE table_schema = 'public' ORDER BY table_name;
> ```
> 期待される出力: `calendar_operation_results`, `calendar_operations`, `calendar_proposals`,
> `emails`, `event_inbox`, `faq_entries`, `sent_reply_embeddings`, `settings`, `timeline_events`

---

## 13. Artifact Registry リポジトリ作成

```bash
# リポジトリ作成（初回のみ）
gcloud artifacts repositories describe openclaw \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud artifacts repositories create openclaw \
  --repository-format=docker \
  --location="${REGION}" \
  --description="OpenClaw API container images" \
  --project="${PROJECT_ID}"

# Docker 認証設定
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
```

---

## 14. Docker イメージビルド & プッシュ

```bash
# リポジトリルートで実行
cd /path/to/OpenclawSecretaryAndo

# イメージタグ（git short SHA 推奨）
export IMAGE_TAG="$(git rev-parse --short HEAD)"
export IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/openclaw/openclaw-api:${IMAGE_TAG}"

# ビルド & プッシュ
docker build -t "${IMAGE}" .
PUSH_OK=0
for attempt in 1 2 3; do
  if docker push "${IMAGE}"; then
    PUSH_OK=1
    break
  fi
  echo "docker push failed; retrying (${attempt}/3)..." >&2
  sleep 10
done
test "${PUSH_OK}" = "1" || {
  echo "docker push failed. Cloud Build fallback を使ってください。" >&2
  exit 1
}

echo "イメージ: ${IMAGE}"

# push されたイメージを確認
gcloud artifacts docker images describe "${IMAGE}" \
  --project="${PROJECT_ID}"

# docker push がネットワークエラーで繰り返し失敗する場合は Cloud Build を使う
# 実行ユーザーには `cloudbuild.builds.create` 権限（例: roles/cloudbuild.builds.editor）が必要
# gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
#   --member="user:$(gcloud config get-value account)" \
#   --role="roles/cloudbuild.builds.editor"
# gcloud services enable cloudbuild.googleapis.com --project="${PROJECT_ID}"
# gcloud builds submit --tag "${IMAGE}" . --project="${PROJECT_ID}"
```

---

## 15. Cloud Run デプロイ

```bash
export CLOUD_TASKS_QUEUE="projects/${PROJECT_ID}/locations/${REGION}/queues/calendar-ops"
export DB_IAM_USER="${SA_EMAIL%.gserviceaccount.com}"
export GOOGLE_CLIENT_ID="1234567890-xxxx.apps.googleusercontent.com"  # OAuth client ID（非シークレット）
export ALLOWED_DOMAIN="example.com"                                  # Google Workspace 組織ドメイン
# MVP必須: 許可する Google user sub を設定（同一ドメイン内の別ユーザーを 403 で拒否）
export ALLOWED_SUBJECT="109876543210987654321"                       # 許可するGoogle user sub（MVP必須）
export SCHEDULER_SERVICE_ACCOUNT_EMAIL="${SCHEDULER_SERVICE_ACCOUNT_EMAIL:-openclaw-scheduler-invoker@${PROJECT_ID}.iam.gserviceaccount.com}"  # Scheduler OIDC 発行元 allowlist
export TASKS_SERVICE_ACCOUNT_EMAIL="${TASKS_SERVICE_ACCOUNT_EMAIL:-openclaw-tasks-invoker@${PROJECT_ID}.iam.gserviceaccount.com}"              # Tasks OIDC 発行元 allowlist
export OAUTH_CLIENT_SECRET_NAME="${OAUTH_CLIENT_SECRET_NAME:-${SECRET_PREFIX}-oauth-client-secret}"
export GMAIL_REFRESH_SECRET_NAME="${GMAIL_REFRESH_SECRET_NAME:-${SECRET_PREFIX}-gmail-refresh-token}"
export GEMINI_API_KEY_SECRET_NAME="${GEMINI_API_KEY_SECRET_NAME:-${SECRET_PREFIX}-gemini-api-key}"

if [[ -z "${GOOGLE_CLIENT_ID}" || -z "${ALLOWED_DOMAIN}" || -z "${ALLOWED_SUBJECT}" || -z "${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" || -z "${TASKS_SERVICE_ACCOUNT_EMAIL}" || -z "${VPC_NETWORK}" || -z "${VPC_SUBNET}" ]]; then
  echo "GOOGLE_CLIENT_ID, ALLOWED_DOMAIN, ALLOWED_SUBJECT, SCHEDULER_SERVICE_ACCOUNT_EMAIL, TASKS_SERVICE_ACCOUNT_EMAIL, VPC_NETWORK, and VPC_SUBNET are required" >&2
  exit 1
fi

# deploy 前に、指定したイメージが Artifact Registry に存在することを確認
gcloud artifacts docker images describe "${IMAGE}" \
  --project="${PROJECT_ID}"

# 初回デプロイ（CLOUD_RUN_URL は取得後に追加）
gcloud run deploy openclaw-api \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --no-allow-unauthenticated \
  --ingress=all \
  --network="${VPC_NETWORK}" \
  --subnet="${VPC_SUBNET}" \
  --vpc-egress=private-ranges-only \
  --service-account="${SA_EMAIL}" \
  --set-env-vars="\
GCP_PROJECT_ID=${PROJECT_ID},\
CLOUD_SQL_CONNECTION_NAME=${CLOUD_SQL_CONNECTION_NAME},\
DB_NAME=openclaw_db,\
DB_USER=${DB_IAM_USER},\
SERVICE_ACCOUNT_EMAIL=${SA_EMAIL},\
CLOUD_TASKS_QUEUE=${CLOUD_TASKS_QUEUE},\
SECRET_OAUTH_CLIENT_SECRET=${OAUTH_CLIENT_SECRET_NAME},\
SECRET_GMAIL_REFRESH_TOKEN=${GMAIL_REFRESH_SECRET_NAME},\
SECRET_GEMINI_API_KEY=${GEMINI_API_KEY_SECRET_NAME},\
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID},\
ALLOWED_DOMAIN=${ALLOWED_DOMAIN},\
ALLOWED_SUBJECT=${ALLOWED_SUBJECT},\
SCHEDULER_SERVICE_ACCOUNT_EMAIL=${SCHEDULER_SERVICE_ACCOUNT_EMAIL},\
TASKS_SERVICE_ACCOUNT_EMAIL=${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --min-instances=1 \
  --max-instances=1 \
  --concurrency=1 \
  --cpu=1 \
  --memory=1Gi \
  --timeout=120s \
  --startup-probe="httpGet.path=/livez,initialDelaySeconds=0,failureThreshold=3,timeoutSeconds=2,periodSeconds=5" \
  --liveness-probe="httpGet.path=/livez,initialDelaySeconds=10,failureThreshold=3,timeoutSeconds=2,periodSeconds=30" \
  --project="${PROJECT_ID}"

# デプロイ完了後に URL を取得し、環境変数として追加
export CLOUD_RUN_URL=$(gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo "Cloud Run URL: ${CLOUD_RUN_URL}"

gcloud run services update openclaw-api \
  --region="${REGION}" \
  --update-env-vars="CLOUD_RUN_URL=${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"
```

Cloud Run 呼び出し権限を付与する。HUD 利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` は付与しない。HUD 利用者は `openclaw-hud-gateway` の IAP で認可し、`openclaw-api` は gateway service account / Scheduler SA / Tasks SA だけを invoker とする。

```bash
# HUD Gateway から openclaw-api を呼ぶ service account
export HUD_GATEWAY_SA_EMAIL="${HUD_GATEWAY_SA_EMAIL:-openclaw-hud-gateway@${PROJECT_ID}.iam.gserviceaccount.com}"

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

### 15-1. HUD Gateway / IAP programmatic access 設定

`openclaw-hud-gateway` は HUD 専用 entrypoint として IAP で保護する。`openclaw-api` の `roles/run.invoker` は gateway service account / Scheduler SA / Tasks SA のみに付与し、HUD 利用者・Workspace domain には直接付与しない。

```bash
export HUD_GATEWAY_SERVICE="openclaw-hud-gateway"
export HUD_GATEWAY_IMAGE="${HUD_GATEWAY_IMAGE:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/openclaw-hud-gateway:latest}"
export HUD_GATEWAY_SA_EMAIL="${HUD_GATEWAY_SA_EMAIL:-openclaw-hud-gateway@${PROJECT_ID}.iam.gserviceaccount.com}"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
export IAP_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
export IAP_ACCESS_MEMBER="${IAP_ACCESS_MEMBER:-user:<HUD_USER_EMAIL>}"

# 初回のみ。既存の場合は重複作成されない。
gcloud beta services identity create \
  --service=iap.googleapis.com \
  --project="${PROJECT_ID}"

# gateway 実装 image が用意できたら deploy する。
gcloud run deploy "${HUD_GATEWAY_SERVICE}" \
  --image="${HUD_GATEWAY_IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --no-allow-unauthenticated \
  --ingress=all \
  --service-account="${HUD_GATEWAY_SA_EMAIL}" \
  --set-env-vars="OPENCLAW_API_URL=${CLOUD_RUN_URL}" \
  --iap \
  --project="${PROJECT_ID}"

# 既存 gateway service に後から IAP を有効化する場合。
gcloud run services update "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --iap \
  --project="${PROJECT_ID}"

# IAP が gateway service を起動できるようにする。
gcloud run services add-iam-policy-binding "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --member="serviceAccount:${IAP_SERVICE_AGENT}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}"

# HUD 利用者または管理 group に IAP access を付与する。
gcloud iap web add-iam-policy-binding \
  --member="${IAP_ACCESS_MEMBER}" \
  --role="roles/iap.httpsResourceAccessor" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  --project="${PROJECT_ID}"

# IAP programmatic access: HUD の Desktop OAuth client ID を allowlist する。
gcloud beta iap settings get \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}" \
  > iap-settings.yaml

# iap-settings.yaml の accessSettings.oauthSettings.programmaticClients に
# ${GOOGLE_CLIENT_ID} を追加してから反映する。
gcloud beta iap settings set iap-settings.yaml \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}"

gcloud run services describe "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"
```

`iap-settings.yaml` の最小差分:

```yaml
accessSettings:
  oauthSettings:
    programmaticClients:
      - <GOOGLE_CLIENT_ID の実値>
```

gateway 実装は、HUD からの `Proxy-Authorization` と `Authorization` を受け、backend 転送前に inbound `X-Serverless-Authorization` を破棄する。backend 呼び出し時は gateway service account で `aud=${CLOUD_RUN_URL}` の ID token を新規発行し、`X-Serverless-Authorization` に設定する。

> **ロールアウト確認**: デプロイ後、リビジョンが `SERVING` 状態であることを確認する。
> ```bash
> gcloud run revisions list \
>   --service=openclaw-api \
>   --region="${REGION}" \
>   --project="${PROJECT_ID}"
> ```

---

## 16. Cloud Run 認証境界の確認（セクション 8 の方針）

Cloud Run サービスが HTTPS で到達可能で、Cloud Run IAM により保護されていることを確認する。

```bash
gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)"
```

Cloud Run の公開・スケーリング・プローブ・環境変数を確認する。

```bash
gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '{
    ingressTemplate: .spec.template.metadata.annotations["run.googleapis.com/ingress"],
    ingressService: .metadata.annotations["run.googleapis.com/ingress"],
    vpcNetworkInterfaces: .spec.template.metadata.annotations["run.googleapis.com/network-interfaces"],
    vpcConnector: .spec.template.metadata.annotations["run.googleapis.com/vpc-access-connector"],
    vpcEgress: .spec.template.metadata.annotations["run.googleapis.com/vpc-access-egress"],
    minScale: .spec.template.metadata.annotations["autoscaling.knative.dev/minScale"],
    maxScale: .spec.template.metadata.annotations["autoscaling.knative.dev/maxScale"],
    containerConcurrency: .spec.template.spec.containerConcurrency,
    serviceAccountName: .spec.template.spec.serviceAccountName,
    env: [.spec.template.spec.containers[0].env[]?.name],
    startupProbe: .spec.template.spec.containers[0].startupProbe,
    livenessProbe: .spec.template.spec.containers[0].livenessProbe
  }'
```

期待値:

- `ingressService` は `all`
- VPC access に `VPC_NETWORK` / `VPC_SUBNET` が設定され、egress は `private-ranges-only`
- `minScale` と `maxScale` は `1`
- `containerConcurrency` は `1`
- `env` に `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、`ALLOWED_SUBJECT`、`SCHEDULER_SERVICE_ACCOUNT_EMAIL`、`TASKS_SERVICE_ACCOUNT_EMAIL`、`SECRET_OAUTH_CLIENT_SECRET`、`SECRET_GMAIL_REFRESH_TOKEN`、`SECRET_GEMINI_API_KEY`、`CLOUD_RUN_URL` が含まれる
- `startupProbe.httpGet.path` は `/livez`
- `livenessProbe.httpGet.path` は `/livez`

IAM policy を確認し、gateway service account・Scheduler/Tasks 専用SAに `roles/run.invoker` が付与されていることを確認する。HUD利用者・組織ドメインには `openclaw-api` の `roles/run.invoker` を直接付与しない。
現行組織ポリシーでは `allUsers` 付与は失敗するため、`--allow-unauthenticated` を前提にしない。

```bash
gcloud run services get-iam-policy openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud run services get-iam-policy "${HUD_GATEWAY_SERVICE:-openclaw-hud-gateway}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud iap web get-iam-policy \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE:-openclaw-hud-gateway}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings // []'

gcloud beta iap settings get \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE:-openclaw-hud-gateway}" \
  --format=json | jq '.accessSettings.oauthSettings.programmaticClients // []'
```

期待値:

- `openclaw-api` の invoker は gateway service account / Scheduler SA / Tasks SA に限定される
- `openclaw-hud-gateway` の invoker に `service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com` が含まれる
- IAP policy に HUD 利用者または管理 group の `roles/iap.httpsResourceAccessor` が含まれる
- IAP settings の `programmaticClients` に `${GOOGLE_CLIENT_ID}` が含まれる

未認証リクエストは Cloud Run platform で 403 になることを確認する。

```bash
curl -i "${CLOUD_RUN_URL}/v1/health"
```

期待値:

- HTTP status は Cloud Run platform の `403 Forbidden`
- 認証付き疎通確認は smoke test 限定で `Authorization: Bearer $(gcloud auth print-identity-token --audiences="${CLOUD_RUN_URL}")` を付けて実行する。HUD 本番経路は `openclaw-hud-gateway` 経由で確認する

---

## 17. Cloud Tasks キュー設定

Calendar 書き込みの冪等・単回実行を保証するキューを作成する（REQ-DEPLOY-004）。

```bash
# キュー作成
gcloud tasks queues create calendar-ops \
  --location="${REGION}" \
  --max-dispatches-per-second=1 \
  --max-concurrent-dispatches=1 \
  --max-attempts=1 \
  --project="${PROJECT_ID}"

# 設定確認（maxAttempts=1 であることを必ず確認）
gcloud tasks queues describe calendar-ops \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

> **重要**: `maxAttempts=1` は二重実行防止の絶対制約（REQ-DEPLOY-004）。
> 出力の `retryConfig.maxAttempts` が `1` であることを目視確認すること。
> OpenClaw が Calendar operation task を enqueue する際は、HTTP target の OIDC token に
> `serviceAccountEmail=${TASKS_SERVICE_ACCOUNT_EMAIL}`、`audience=${CLOUD_RUN_URL}` を設定する。
> OpenClaw 認証ミドルウェアは `TASKS_SERVICE_ACCOUNT_EMAIL` と token の email claim を照合する。

---

## 18. Cloud Scheduler ジョブ設定

```bash
export SCHEDULER_SA="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}"

# Gmail polling（60秒間隔）
gcloud scheduler jobs create http poll-gmail \
  --location="${REGION}" \
  --schedule="* * * * *" \
  --uri="${CLOUD_RUN_URL}/internal/poll-gmail" \
  --http-method=POST \
  --oidc-service-account-email="${SCHEDULER_SA}" \
  --oidc-token-audience="${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"

# PII retention job（毎日 03:00 JST = 18:00 UTC）
gcloud scheduler jobs create http pii-retention \
  --location="${REGION}" \
  --schedule="0 18 * * *" \
  --time-zone="UTC" \
  --uri="${CLOUD_RUN_URL}/internal/retention/pii-mask" \
  --http-method=POST \
  --oidc-service-account-email="${SCHEDULER_SA}" \
  --oidc-token-audience="${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"

# ジョブ一覧確認
gcloud scheduler jobs list \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# Gmail refresh token 保存前は poll-gmail を停止する
gcloud scheduler jobs pause poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

> **注意**: `poll-gmail` は作成直後から 60秒ごとに実行される。
> Gmail refresh token が Secret Manager に登録されるまでは 500 になるため、初回 OAuth フロー完了まで pause のままにする。

---

## 19. 初回 OAuth フロー（HUD 側）

HUD（Electron アプリ）を起動し、Gateway OAuth start / loopback handoff フローを完了させる。

> **実装状況**: 2026-06-08 時点の `clawd-on-desk` には、Google ログイン UI、
> Gateway OAuth handoff、backend confidential exchange、refresh token を Secret Manager に保存する導線は Phase 2 前ゲートとして実装・検証する。
> このセクションは HUD 実装完了後の手順であり、未実装状態では実行できない。
> 通常経路は、HUD が Gateway OAuth start を開き、Gateway/private API が confidential exchange を完了して OpenClaw が refresh token を Secret Manager に保存する。
> API 契約は OpenAPI v1.4.0 の `/v1/auth/start`、`/v1/auth/callback`、`/internal/auth/oauth-sessions`、`/internal/auth/oauth-exchange`、`/v1/auth/id-token/refresh` で確定済み。HUD から `{ refreshToken }` を送る旧 `POST /v1/auth/bootstrap` 契約は廃止済み。
> 暫定/緊急対応としてのみ、管理者が OAuth refresh token を取得し、
> `${GMAIL_REFRESH_SECRET_NAME}` に Secret Manager で手動登録する。

1. HUD を起動する
2. 認証画面で組織アカウント（`@<ORG_DOMAIN>`）でログイン
3. 5スコープ（`openid`, `email`, `gmail.readonly`, `gmail.compose`, `calendar.events`）を承認
4. 認証完了後、HUD が bootstrap endpoint を呼び出し、OpenClaw が Secret Manager に保存する

```bash
# refresh token が Secret Manager に書き込まれたことを確認
gcloud secrets versions list "${GMAIL_REFRESH_SECRET_NAME}" \
  --project="${PROJECT_ID}"
```

---

## 20. デプロイ後動作確認

### ヘルスチェック

```bash
# Cloud Run IAM 保護下の疎通確認（openclaw-api 直接 smoke test）
TOKEN="$(gcloud auth print-identity-token --audiences="${CLOUD_RUN_URL}")"

curl -i -H "Authorization: Bearer ${TOKEN}" \
  "${CLOUD_RUN_URL}/livez"

curl -i -H "Authorization: Bearer ${TOKEN}" \
  "${CLOUD_RUN_URL}/readyz"
```

HUD正式確認は、`openclaw-hud-gateway` と IAP programmatic access の実装完了後に gateway 経由で実施する。現行組織ポリシーでは `openclaw-api` 直接呼び出しには Cloud Run IAM を通過する token が必要であるため、未認証 curl では 403 になる。`gcloud auth print-identity-token` は smoke test 用であり、HUD 本番認証や `ALLOWED_SUBJECT` 取得の代替にしない。

```bash
export HUD_ID_TOKEN="${HUD_ID_TOKEN:?HUD_ID_TOKEN must be set from gateway/backend verified HUD handoff}"
export HUD_GATEWAY_URL="$(gcloud run services describe "${HUD_GATEWAY_SERVICE:-openclaw-hud-gateway}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"

curl -s \
  -H "Proxy-Authorization: Bearer ${HUD_ID_TOKEN}" \
  -H "Authorization: Bearer ${HUD_ID_TOKEN}" \
  "${HUD_GATEWAY_URL}/v1/health" | jq .
```

gateway 経由 `/v1/health` で期待されるレスポンス:

```json
{
  "status": "ok",
  "timestamp": "2026-06-08T...",
  "revision": "<revision-id>",
  "db": {
    "status": "ok",
    "latencyMs": 25
  },
  "heartbeat": {
    "status": "ok",
    "checkedAt": "2026-06-08T..."
  },
  "bootstrap": {
    "required": false,
    "reason": null
  }
}
```

### Cloud Tasks キュー確認

```bash
gcloud tasks queues describe calendar-ops \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="json" | jq '.retryConfig'
```

`maxAttempts: 1` であることを確認する。

### Cloud Scheduler 手動実行テスト

```bash
# PII retention を手動で 1 回実行
gcloud scheduler jobs run pii-retention \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

# 実行ログ確認
gcloud logging read '
resource.type="cloud_run_revision"
resource.labels.service_name="openclaw-api"
httpRequest.requestUrl:"/internal/retention/pii-mask"
' \
  --project="${PROJECT_ID}" \
  --limit=10 \
  --format="table(timestamp,httpRequest.requestMethod,httpRequest.requestUrl,httpRequest.status)"
```

`poll-gmail` は Gmail refresh token 登録後にのみ resume / 手動実行する。詳細は `docs/deployment/hud-auth-post-implementation-operations.md` を参照する。

---

## 完了チェックリスト

### フェーズ 1: GCP 初期設定（セクション 1〜10）

- [ ] GCP プロジェクトが 1ユーザー 1プロジェクト方針で作成されている
- [ ] Gmail API、Google Calendar API、Cloud Run、Compute Engine、Cloud SQL、Service Networking、Secret Manager、Cloud Scheduler、Cloud Tasks、Artifact Registry、IAM Credentials API、IAP API が有効化されている
- [ ] VPC、subnet、Private Service Access range、servicenetworking peering が作成されている
- [ ] OpenClaw 用サービスアカウント（`openclaw-sa`）が作成されている
- [ ] Cloud Scheduler / Cloud Tasks OIDC 発行元専用サービスアカウント（`openclaw-scheduler-invoker` / `openclaw-tasks-invoker`）と HUD Gateway service account（`openclaw-hud-gateway`）が作成されている
- [ ] `roles/cloudsql.client` が付与されている
- [ ] `roles/secretmanager.secretAccessor` が対象3シークレット（refresh token / OAuth client secret / Gemini API key）のみに付与されている
- [ ] `roles/secretmanager.secretVersionAdder` が Gmail refresh token シークレットのみに付与されている
- [ ] project-level の `roles/secretmanager.secretAccessor` / `roles/secretmanager.admin` を OpenClaw 実行SAに付与していない
- [ ] `roles/logging.logWriter` が付与されている
- [ ] Scheduler job 作成者が `openclaw-scheduler-invoker` に対する `roles/iam.serviceAccountUser` を持っている
- [ ] OpenClaw 実行SAが `openclaw-tasks-invoker` に対する `roles/iam.serviceAccountUser` を持っている
- [ ] DwD 用カスタムロール（`iam.serviceAccounts.signJwt` のみ）が作成・付与されている
- [ ] デプロイ対象 revision が 10-4 の実装ゲート（ID token署名検証、`aud/hd/sub` 検証、internal OIDC allowlist、Tasks SA分離、`ipType='PRIVATE'`）を満たしている
- [ ] OAuth 2.0 クライアント（インストール済みアプリ・PKCE）が作成されている
- [ ] Gateway/backend verified handoff claims の `aud`・`hd`・`sub` を確認して `ALLOWED_SUBJECT` を取得している
- [ ] OAuth スコープが 5スコープ（openid, email, gmail.readonly, gmail.compose, calendar.events）に制限されている
- [ ] Google Workspace Internal アプリとして設定されている（審査不要）
- [ ] Secret Manager シークレット（client_secret, refresh_token, gemini-api-key）が初期作成されている。OAuth client ID は Secret Manager に保存せず、HUD `oauthClientId` と Cloud Run `GOOGLE_CLIENT_ID` env var に設定する
- [ ] `dwdAllowlistEmails` の設定方法（backend/admin 設定面、管理CLI、または migration 初期値）を確認している
- [ ] DwD が Google Workspace 管理コンソールで設定されている（スコープ: calendar.events）

### フェーズ 2: デプロイ（セクション 11〜20）

- [ ] Cloud SQL インスタンス（`openclaw-db`）が `POSTGRES_15`・IAM 認証有効・Private IP only（public IPなし）で作成されている
- [ ] `openclaw_db` データベースが作成されている
- [ ] SA 用 IAM データベースユーザーが作成され、テーブルへの権限が付与されている
- [ ] 一時 migration VM から Cloud SQL Auth Proxy `--private-ip` で `migrations/001_initial_schema.sql` および `002_initial_settings.sql` が適用され、9テーブルが存在する
- [ ] migration VM が削除されている
- [ ] Artifact Registry リポジトリ（`openclaw`）が作成されている
- [ ] Docker イメージがビルド・プッシュされている
- [ ] Cloud Run サービス（`openclaw-api`）が `--no-allow-unauthenticated` / `--ingress=all` でデプロイされている
- [ ] Cloud Run サービスに Direct VPC egress（`VPC_NETWORK` / `VPC_SUBNET` / `private-ranges-only`）が設定されている
- [ ] `CLOUD_RUN_URL` が環境変数として Cloud Run サービスに設定されている
- [ ] `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、`ALLOWED_SUBJECT`、`SCHEDULER_SERVICE_ACCOUNT_EMAIL`、`TASKS_SERVICE_ACCOUNT_EMAIL`、`SECRET_OAUTH_CLIENT_SECRET`、`SECRET_GMAIL_REFRESH_TOKEN`、`SECRET_GEMINI_API_KEY` が Cloud Run 環境変数として設定されている
- [ ] Cloud Run サービスが `--max-instances=1`・`--concurrency=1`・`--memory=1Gi`・`--timeout=120s` でデプロイされている
- [ ] Cloud Run startup probe と liveness probe が `/livez` を呼び出している
- [ ] `openclaw-api` は `--no-allow-unauthenticated` でデプロイされ、gateway service account / Scheduler SA / Tasks SA のみに `roles/run.invoker` が付与されている
- [ ] `openclaw-hud-gateway` は IAP 有効化済みで、IAP service agent（`service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com`）に gateway の `roles/run.invoker` が付与されている
- [ ] HUD 利用者または管理 group には `openclaw-hud-gateway` の IAP access（`roles/iap.httpsResourceAccessor`）が付与され、`openclaw-api` の `roles/run.invoker` は直接付与されていない
- [ ] IAP settings の `accessSettings.oauthSettings.programmaticClients` に `${GOOGLE_CLIENT_ID}` が含まれている
- [ ] gateway 実装が inbound `X-Serverless-Authorization` を backend へ転送せず、backend 用 `X-Serverless-Authorization` を gateway service account で新規生成する
- [ ] 未認証の `GET /v1/health` は Cloud Run platform 403 を返している
- [ ] Cloud Tasks キュー（`calendar-ops`）が `maxAttempts=1`・`maxDispatchesPerSecond=1` で作成されている
- [ ] Cloud Scheduler / Cloud Tasks の OIDC 発行元に、Cloud Run 実行SAとは別の専用SA（`openclaw-scheduler-invoker` / `openclaw-tasks-invoker`）を使用している
- [ ] Cloud Scheduler ジョブ（`poll-gmail`・`pii-retention`）が作成されている
- [ ] refresh token 未登録時は `poll-gmail` が pause されている
- [ ] 初回 Gateway/backend confidential exchange が完了し、refresh token が Secret Manager に保存された後に `poll-gmail` を resume している
- [ ] HUD Gateway 経由の認証付き `GET /v1/health` が OpenAPI v1.4.0 の HealthResponse（`status`、`timestamp`、`revision`、`db.status`、`db.latencyMs`、`heartbeat.status`、`heartbeat.checkedAt`、`bootstrap.required`、`bootstrap.reason`）を返している
