# HUD auth update 後の GCP 差分適用手順

作成日: 2026-06-07
対象: 旧 `gcp-setup.md` で「初回 OAuth フロー（HUD 側）」工程まで進めた既存 GCP 環境
目的: 今回の HUD / OpenClaw 認証設計更新後に、GCP 側で追加・更新が必要な工程を事務的に明確化する

---

## 0. 結論

GCP プロジェクトを最初から作り直す必要はない。

既存の GCP project、Cloud SQL、OAuth client、Artifact Registry、既存 Docker image は原則として継続利用する。必要なのは、`openclaw-api` の Cloud Run 認証境界、HUD 用 `openclaw-hud-gateway` / IAP programmatic access、環境変数、Secret 名、Cloud Scheduler / Cloud Tasks OIDC 発行元、health probe の差分適用である。

最適解は以下で固定する。

- `openclaw-api` は private Cloud Run service として `--no-allow-unauthenticated` を維持する。
- HUD 本番通信は `openclaw-hud-gateway` を唯一の entrypoint とし、IAP programmatic access で保護する。
- HUD は同じ Google OAuth ID token を `Proxy-Authorization`（IAP 通過）と `Authorization`（OpenClaw app 認証）に分けて送る。Phase 2 実機検証で IAP が拒否する場合のみ `IAP_CLIENT_ID` を追加して IAP 用 token と app 用 token を分離する。
- gateway は inbound `X-Serverless-Authorization` を backend へ転送せず、gateway service account で backend 用の `X-Serverless-Authorization` を新規生成する。
- `openclaw-api` の `roles/run.invoker` は gateway service account / Scheduler SA / Tasks SA のみに付与し、HUD 利用者・Workspace domain には直接付与しない。
- OAuth client ID は `GOOGLE_CLIENT_ID` env var が正本であり、Secret Manager には保存しない。legacy `openclaw-oauth-client-id` secret が残っている場合も照合専用に使う。
- direct `openclaw-api /v1/health` は未認証 403 境界確認に限定する。HUD 正式確認は必ず `openclaw-hud-gateway` 経由の `/v1/health` で行う。

---

## 1. 作業対象

### 再作成しないもの

- GCP project
- 有効化済み API
- Cloud SQL instance / database / migration 済み schema
- OAuth 2.0 client
- Artifact Registry repository
- 既存 Docker image
- Cloud Tasks queue 自体
- Cloud Scheduler job 自体

### 差分適用するもの

- Cloud Run service `openclaw-api`
- Cloud Run environment variables
- Cloud Run startup / liveness probe
- Secret Manager secret names
- Cloud Scheduler OIDC service account
- Cloud Tasks OIDC service account
- HUD Gateway service account
- IAP service agent / IAP access policy / programmaticClients
- Cloud Scheduler job OIDC issuer
- Cloud Tasks enqueue 時の OIDC issuer 設定
- `/v1/health` / `/livez` / `/readyz` の確認

---

## 2. 作業前提

以下を満たしていること。

- `gcloud` が使える
- `jq` が使える
- 作業者が対象 GCP project を操作できる
- 旧手順で Cloud Run / Cloud SQL / Secret Manager / Scheduler / Tasks のいずれかが作成済みである
- OAuth client ID が分かっている
- 組織ドメインが分かっている

`ALLOWED_SUBJECT` が未取得の場合、Cloud Run 更新前にセクション 4 を実施する。HUD 再実装が未完了で ID token を取得できない場合、Cloud Run 更新は保留し、セクション 3・5 の確認と service account / Secret の準備だけを先に進める。

---

## 3. 変数定義

```bash
export PROJECT_ID="openclaw-ando-prod"
export REGION="asia-northeast1"
export SA_NAME="openclaw-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

export USER_ID="ando"
export SECRET_PREFIX="openclaw-${USER_ID}"

gcloud config set project "${PROJECT_ID}"

# OAuth client ID は非シークレット。Secret Manager ではなく、HUD 設定画面の oauthClientId と同じ値を明示する。
export GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:?Set Desktop OAuth client ID, e.g. 1234567890-xxxx.apps.googleusercontent.com}"

# 旧手順で openclaw-oauth-client-id secret が残っている場合は照合専用に使い、正本にはしない。
if gcloud secrets describe "openclaw-oauth-client-id" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  LEGACY_GOOGLE_CLIENT_ID="$(gcloud secrets versions access latest \
    --secret="openclaw-oauth-client-id" \
    --project="${PROJECT_ID}")"
  if [[ "${LEGACY_GOOGLE_CLIENT_ID}" != "${GOOGLE_CLIENT_ID}" ]]; then
    echo "legacy openclaw-oauth-client-id differs from GOOGLE_CLIENT_ID; do not use the legacy secret as source of truth" >&2
    exit 1
  fi
fi

export ALLOWED_DOMAIN="master-key.biz"

# 許可する Google user の sub。gcloud の作業者 token から推測しない。
# Cloud Run env に流し込む前に、セクション 4 の Gateway/backend verified handoff claims から取得した値を明示する。
export ALLOWED_SUBJECT="${ALLOWED_SUBJECT:?Set from Gateway/backend verified handoff claims in section 4}"

export SCHEDULER_SERVICE_ACCOUNT_EMAIL="openclaw-scheduler-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export TASKS_SERVICE_ACCOUNT_EMAIL="openclaw-tasks-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export HUD_GATEWAY_SERVICE="openclaw-hud-gateway"
export HUD_GATEWAY_SA_EMAIL="openclaw-hud-gateway@${PROJECT_ID}.iam.gserviceaccount.com"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
export IAP_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"
export IAP_ACCESS_MEMBER="${IAP_ACCESS_MEMBER:-user:<HUD_USER_EMAIL>}"

export CLOUD_SQL_INSTANCE="openclaw-db"
export CLOUD_SQL_CONNECTION_NAME="$(gcloud sql instances describe "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --format="value(connectionName)")"
```

`iap.googleapis.com` が未有効の場合は追加で有効化する。

```bash
gcloud services enable iap.googleapis.com --project="${PROJECT_ID}"
```

---

## 4. `ALLOWED_SUBJECT` の取得

`ALLOWED_SUBJECT` は許可する Google user の `sub` である。`gcloud auth print-identity-token` の作業者 token から推測せず、外部の token decode サイトへ ID token を貼り付けてはならない。

HUD から Gateway OAuth start を実行し、Gateway/private API が Google OAuth callback で confidential exchange と ID token claim 検証を完了した後の handoff claims から取得する。HUD は authorization code、`code_verifier`、Google token endpoint の token response、OAuth client secret、refresh token、access token を取得しない。

handoff で短命 ID token を受け取れる場合のみ、ローカルで claims を確認する。

```bash
export HUD_ID_TOKEN="${HUD_ID_TOKEN:?HUD_ID_TOKEN must be set from Gateway/backend handoff}"

python -c "import base64,json,os; t=os.environ['HUD_ID_TOKEN'].split('.')[1]; t += '=' * (-len(t) % 4); print(json.dumps(json.loads(base64.urlsafe_b64decode(t)), indent=2, ensure_ascii=False))"
```

出力を確認する。

- `aud` が `GOOGLE_CLIENT_ID` と一致する
- `hd` が `ALLOWED_DOMAIN` と一致する
- `sub` を `ALLOWED_SUBJECT` に設定する

```bash
export ALLOWED_SUBJECT="$(python3 -c 'import base64,json,os; t=os.environ["HUD_ID_TOKEN"].split(".")[1]; t += "=" * (-len(t) % 4); print(json.loads(base64.urlsafe_b64decode(t))["sub"])')"
```

Gateway/backend handoff が未完了で verified claims を取得できない場合、このセクション以降の Cloud Run env 更新は実施しない。GCP project の作り直しは不要である。

---

## 5. 現状確認

読み取りのみで現状を確認する。

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

---

## 6. 専用 OIDC service account の作成

Cloud Run 実行 service account と、Scheduler / Tasks の OIDC 発行元 service account を分離する。

```bash
export SCHEDULER_SA_NAME="openclaw-scheduler-invoker"
export TASKS_SA_NAME="openclaw-tasks-invoker"
export HUD_GATEWAY_SA_NAME="openclaw-hud-gateway"

gcloud iam service-accounts describe "${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "${SCHEDULER_SA_NAME}" \
  --display-name="OpenClaw Scheduler OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts describe "${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "${TASKS_SA_NAME}" \
  --display-name="OpenClaw Tasks OIDC Invoker" \
  --project="${PROJECT_ID}"

gcloud iam service-accounts describe "${HUD_GATEWAY_SA_EMAIL}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 || \
gcloud iam service-accounts create "${HUD_GATEWAY_SA_NAME}" \
  --display-name="OpenClaw HUD Gateway Service Account" \
  --project="${PROJECT_ID}"
```

Scheduler job 作成者が Scheduler OIDC SA を job に関連付けられるようにする。

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
```

OpenClaw 実行SAが Cloud Tasks enqueue 時に Tasks OIDC SA を指定できるようにする。

```bash
gcloud iam service-accounts add-iam-policy-binding "${TASKS_SERVICE_ACCOUNT_EMAIL}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"
```

これらの OIDC 発行元 service account には Cloud Run service の `roles/run.invoker` を付与する。あわせて OpenClaw アプリケーション側の `SCHEDULER_SERVICE_ACCOUNT_EMAIL` / `TASKS_SERVICE_ACCOUNT_EMAIL` allowlist でも検証する。

HUD 実 API 連携では、HUD 利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` を直接付与しない。IAP 保護された `openclaw-hud-gateway` を作成し、`openclaw-api` の `roles/run.invoker` は gateway service account / Scheduler SA / Tasks SA のみに付与する。HUD 利用者は gateway の IAP access（`roles/iap.httpsResourceAccessor`）で認可する。

---

## 6-1. HUD Gateway / IAP programmatic access 差分

```bash
gcloud beta services identity create \
  --service=iap.googleapis.com \
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

# gateway service は実装 image デプロイ後に IAP を有効化する。
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

# iap-settings.yaml の accessSettings.oauthSettings.programmaticClients に
# ${GOOGLE_CLIENT_ID} を追加してから反映する。
gcloud beta iap settings set iap-settings.yaml \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --resource-type=cloud-run \
  --service="${HUD_GATEWAY_SERVICE}"
```

期待値:

- `openclaw-api` の invoker に gateway service account / Scheduler SA / Tasks SA が含まれ、HUD 利用者は含まれない
- `openclaw-hud-gateway` の invoker に IAP service agent が含まれる
- IAP policy に `${IAP_ACCESS_MEMBER}` の `roles/iap.httpsResourceAccessor` が含まれる
- IAP settings の `programmaticClients` に `${GOOGLE_CLIENT_ID}` が含まれる
- OAuth scope は `openid email gmail.readonly gmail.compose calendar.events` の5スコープである

---

## 7. Secret Manager 名の正規化

正本の Secret 名は `openclaw-{user_id}-...` 形式である。

```bash
export OAUTH_CLIENT_SECRET_NAME="${SECRET_PREFIX}-oauth-client-secret"
export GMAIL_REFRESH_SECRET_NAME="${SECRET_PREFIX}-gmail-refresh-token"
export GEMINI_API_KEY_SECRET_NAME="${SECRET_PREFIX}-gemini-api-key"

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
```

旧 Secret があり、新 Secret への値移行が未完了の場合のみ、値を新 Secret へコピーする。値は標準出力へ表示しない。移行済みの Secret に対してこのコピー手順を再実行すると、新しい Secret version が追加されるため、重複作成を避ける。

```bash
gcloud secrets describe "openclaw-oauth-client-secret" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 && \
gcloud secrets versions access latest \
  --secret="openclaw-oauth-client-secret" \
  --project="${PROJECT_ID}" | \
gcloud secrets versions add "${OAUTH_CLIENT_SECRET_NAME}" \
  --data-file=- \
  --project="${PROJECT_ID}"

gcloud secrets describe "openclaw-gemini-api-key" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 && \
gcloud secrets versions access latest \
  --secret="openclaw-gemini-api-key" \
  --project="${PROJECT_ID}" | \
gcloud secrets versions add "${GEMINI_API_KEY_SECRET_NAME}" \
  --data-file=- \
  --project="${PROJECT_ID}"

gcloud secrets describe "openclaw-gmail-refresh-token" \
  --project="${PROJECT_ID}" >/dev/null 2>&1 && \
gcloud secrets versions access latest \
  --secret="openclaw-gmail-refresh-token" \
  --project="${PROJECT_ID}" | \
gcloud secrets versions add "${GMAIL_REFRESH_SECRET_NAME}" \
  --data-file=- \
  --project="${PROJECT_ID}"
```

旧 Secret はこの工程では削除しない。新 Secret への参照が backend 実装・運用で確認できてから別途削除を判断する。

---

## 8. refresh token Secret への `secretVersionAdder` 付与

```bash
gcloud secrets add-iam-policy-binding "${GMAIL_REFRESH_SECRET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretVersionAdder" \
  --project="${PROJECT_ID}"
```

---

## 9. Cloud Run service の差分デプロイ

既存 Cloud Run service の image を再利用して、新しい認証境界と env vars を反映する。

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
```

Cloud Run URL を取得し、env var として追加する。

```bash
export CLOUD_RUN_URL="$(gcloud run services describe openclaw-api \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"

gcloud run services update openclaw-api \
  --region="${REGION}" \
  --update-env-vars="CLOUD_RUN_URL=${CLOUD_RUN_URL}" \
  --project="${PROJECT_ID}"
```

---

## 10. Cloud Tasks queue の確認・更新

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
```

---

## 11. Cloud Scheduler job の OIDC 発行元更新

```bash
if gcloud scheduler jobs describe poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud scheduler jobs update http poll-gmail \
    --location="${REGION}" \
    --schedule="* * * * *" \
    --uri="${CLOUD_RUN_URL}/internal/poll-gmail" \
    --http-method=POST \
    --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
    --oidc-token-audience="${CLOUD_RUN_URL}" \
    --project="${PROJECT_ID}"
else
  gcloud scheduler jobs create http poll-gmail \
    --location="${REGION}" \
    --schedule="* * * * *" \
    --uri="${CLOUD_RUN_URL}/internal/poll-gmail" \
    --http-method=POST \
    --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
    --oidc-token-audience="${CLOUD_RUN_URL}" \
    --project="${PROJECT_ID}"
fi

if gcloud scheduler jobs describe pii-retention \
  --location="${REGION}" \
  --project="${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud scheduler jobs update http pii-retention \
    --location="${REGION}" \
    --schedule="0 18 * * *" \
    --time-zone="UTC" \
    --uri="${CLOUD_RUN_URL}/internal/retention/pii-mask" \
    --http-method=POST \
    --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
    --oidc-token-audience="${CLOUD_RUN_URL}" \
    --project="${PROJECT_ID}"
else
  gcloud scheduler jobs create http pii-retention \
    --location="${REGION}" \
    --schedule="0 18 * * *" \
    --time-zone="UTC" \
    --uri="${CLOUD_RUN_URL}/internal/retention/pii-mask" \
    --http-method=POST \
    --oidc-service-account-email="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
    --oidc-token-audience="${CLOUD_RUN_URL}" \
    --project="${PROJECT_ID}"
fi
```

Gmail refresh token がまだ登録されていない場合、`poll-gmail` は再開しない。Gateway/backend confidential exchange 実装前は、ログ増加を防ぐため停止する。

```bash
if ! gcloud secrets versions list "${GMAIL_REFRESH_SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --format="value(name)" | grep -q .; then
  gcloud scheduler jobs pause poll-gmail \
    --location="${REGION}" \
    --project="${PROJECT_ID}"
fi
```

---

## 12. 検証

### 12-1. Cloud Run 設定確認

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
```

確認値:

- `ingressService` は `all`
- `minScale` は `1`
- `maxScale` は `1`
- `containerConcurrency` は `1`
- `env` に `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、`ALLOWED_SUBJECT`、`SCHEDULER_SERVICE_ACCOUNT_EMAIL`、`TASKS_SERVICE_ACCOUNT_EMAIL`、`CLOUD_RUN_URL`、`SECRET_GMAIL_REFRESH_TOKEN` が含まれる
- `startupProbe.httpGet.path` は `/livez`
- `livenessProbe.httpGet.path` は `/livez`

### 12-2. probe 確認

`openclaw-api` の direct smoke test は、正式 invoker である Scheduler SA を impersonate して行う。作業者 user や Workspace domain に `openclaw-api` の `roles/run.invoker` を付与してはならない。impersonation に必要な場合だけ、作業者に対象 service account の `roles/iam.serviceAccountTokenCreator` を一時付与する。

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

期待値:

- `/livez` は 200
- `/readyz` は準備完了時 200
- token、secret 名、PII、raw error は返らない

### 12-3. 未認証アクセス境界の確認

```bash
curl -i "${CLOUD_RUN_URL}/v1/health"
```

期待値:

- 現行組織ポリシーでは `allUsers` 公開を使わないため、Cloud Run platform 403 が返る。アプリケーション認証の 401/403 は、正式手順では `openclaw-hud-gateway` 経由の認証付き `/v1/health` で確認する。

### 12-4. HUD Gateway 経由の認証済み `/v1/health` 確認

Gateway/backend handoff の短命 ID token が取得できる状態になってから実施する。

```bash
export TOKEN="${HUD_ID_TOKEN:?HUD_ID_TOKEN must be set from Gateway/backend handoff}"
export HUD_GATEWAY_URL="$(gcloud run services describe "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"

curl -s \
  -H "Proxy-Authorization: Bearer ${TOKEN}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "${HUD_GATEWAY_URL}/v1/health" | jq .
```

期待値:

- `status` は `ok`
- `revision` が返る
- `db.status` は `ok`
- `db.latencyMs` が返る
- `heartbeat.status` は `ok`
- `heartbeat.checkedAt` が返る
- `bootstrap.required` / `bootstrap.reason` が返る

IAP 403 の場合は `roles/iap.httpsResourceAccessor` と `programmaticClients` を確認する。backend 401/403 の場合は `GOOGLE_CLIENT_ID` / `ALLOWED_DOMAIN` / `ALLOWED_SUBJECT` と ID token claims を確認する。`openclaw-api` 直接 URL への HUD token 送信は正式確認に使わない。

backend confidential exchange / `/v1/auth/id-token/refresh` が未実装の間は、Secret Manager refresh token 登録を前提にした検証は実施しない。HUD / Gateway / API の handoff 実装後は、別紙 `hud-auth-post-implementation-operations.md` に従って refresh token 登録と `poll-gmail` 再開を確認する。

### 12-5. Scheduler / Tasks 確認

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

確認値:

- Scheduler job の `serviceAccountEmail` は `SCHEDULER_SERVICE_ACCOUNT_EMAIL`
- Scheduler job の `audience` は `CLOUD_RUN_URL`
- Cloud Tasks queue の `maxAttempts` は `1`

---

## 13. 作業完了条件

- [ ] `ALLOWED_SUBJECT` を取得済み
- [ ] Scheduler / Tasks 専用 OIDC service account が存在する
- [ ] HUD Gateway service account が存在する
- [ ] `roles/iam.serviceAccountUser` が必要な主体に付与済み
- [ ] `openclaw-{user_id}-oauth-client-secret` が存在する
- [ ] `openclaw-{user_id}-gmail-refresh-token` が存在する
- [ ] `openclaw-{user_id}-gemini-api-key` が存在する
- [ ] OAuth client ID は Secret Manager ではなく `GOOGLE_CLIENT_ID` env var と HUD `oauthClientId` に設定されている
- [ ] legacy `openclaw-oauth-client-id` secret が残っている場合、`GOOGLE_CLIENT_ID` との照合専用であり正本として参照していない
- [ ] Cloud Run が `--no-allow-unauthenticated` / `--ingress=all` で更新済み
- [ ] `openclaw-hud-gateway` / IAP programmatic access が設定済み
- [ ] gateway service account / Scheduler SA / Tasks SA に `openclaw-api` の `roles/run.invoker` が付与済み
- [ ] IAP service agent に `openclaw-hud-gateway` の `roles/run.invoker` が付与済み
- [ ] HUD 利用者または管理 group に `openclaw-hud-gateway` の `roles/iap.httpsResourceAccessor` が付与済み
- [ ] IAP settings の `programmaticClients` に `GOOGLE_CLIENT_ID` が含まれる
- [ ] OAuth scope が `email` を含む5スコープである
- [ ] HUD 利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` が直接付与されていない
- [ ] Cloud Run env vars が正本値に更新済み
- [ ] Cloud Run startup probe が `/livez`
- [ ] Cloud Run liveness probe が `/livez`
- [ ] 未認証 `/v1/health` が Cloud Run platform 403 を返す
- [ ] HUD Gateway 経由の認証済み `/v1/health` が OpenAPI `HealthResponse` を返す
- [ ] Scheduler job が `SCHEDULER_SERVICE_ACCOUNT_EMAIL` で OIDC token を発行する
- [ ] Cloud Tasks queue が `maxAttempts=1`

---

## 14. 中断条件

以下の場合は作業を止める。

- `ALLOWED_SUBJECT` が取得できない
- OAuth client ID と ID token の `aud` が一致しない
- ID token の `hd` が `ALLOWED_DOMAIN` と一致しない
- HUD Gateway 経由の認証付き `curl ${HUD_GATEWAY_URL}/v1/health` が IAP 403、Cloud Run platform 403、または backend app 認証 401/403 を返す
- Cloud Run env vars に `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、`ALLOWED_SUBJECT` が設定できない
- `/readyz` が継続して 503 を返す

中断時も GCP project の作り直しは不要である。該当セクションの前提値を修正して再実行する。

---

## 15. 次の工程

この差分適用が完了したら、HUD 再実装側で以下を進める。

Phase 0/1 実装が完了している場合は、先に `infra-architecture-update-after-phase01.md` でインフラアーキテクチャ更新工程と Phase 2 開始条件を確認する。

1. Gateway OAuth start / loopback handoff / ID-token-only TokenManager 実装
2. backend 側 `access_type=offline` / 条件付き `prompt=consent`
3. backend confidential exchange / Secret Manager refresh token 保存 / `/v1/auth/id-token/refresh` 実装
4. HUD Gateway 経由の認証済み `GET /v1/health`
5. `hud-auth-post-implementation-operations.md` に従う refresh token 登録・`poll-gmail` 再開

HUD が未完成の場合、GCP 側は `pii-retention` 成功と `poll-gmail` pause までを完了状態とし、Gmail refresh token 登録と `poll-gmail` 再開は HUD 実装完了後に実施する。
