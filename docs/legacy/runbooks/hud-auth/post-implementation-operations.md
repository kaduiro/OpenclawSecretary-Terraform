# HUD 認証実装後の運用・検証手順

作成日: 2026-06-08
更新日: 2026-06-11
対象: `clawd-on-desk` の Gateway OAuth handoff / backend confidential exchange 実装が完了した後に実施する GCP 側の残作業
目的: Gmail refresh token 登録後に `poll-gmail` を安全に再開し、OpenClaw の定期処理と HUD 連携を検証する。

---

## 0. 現在の到達点

2026-06-11 時点で、以下は完了済み。

- Cloud Run `openclaw-api` は起動済み。
- `/livez` は `200`。
- `/readyz` は `200`。
- Cloud SQL 接続は正常。
- Cloud Tasks queue `calendar-ops` は `RUNNING`。
- `pii-retention` は Scheduler 経由で `200`。
- `poll-gmail` は Gmail refresh token 未登録のため一時停止済み。
- Cloud Run は以下の Secret 名・env var を参照する設定になっている。
  - `GOOGLE_CLIENT_ID=598108671830-0om1spa9a7vdhtg5p599cqhgnqi9l2l4.apps.googleusercontent.com`（Web OAuth client ID）
  - `SECRET_OAUTH_CLIENT_SECRET=openclaw-ando-oauth-client-secret`
  - `SECRET_GMAIL_REFRESH_TOKEN=openclaw-ando-gmail-refresh-token`
  - `SECRET_GEMINI_API_KEY=openclaw-ando-gemini-api-key`
- `openclaw-hud-gateway` は IAP 保護された Cloud Run service として稼働済み。
- IAP `programmaticClients` は Web OAuth client ID に更新済み。
- Gateway OAuth callback redirect URI は以下で登録済み。
  - `https://openclaw-hud-gateway-utxdh4fdia-an.a.run.app/v1/auth/callback`
- Gateway/backend handoff token の claims は以下で確認済み。
  - `sub=117315801613785339993`
  - `email=info@master-key.biz`
  - `hd=master-key.biz`
  - `aud=598108671830-0om1spa9a7vdhtg5p599cqhgnqi9l2l4.apps.googleusercontent.com`
- 実際の handoff `idToken` で Gateway 経由 `GET /v1/health` が `200 OK`。
  - backend revision: `openclaw-api-00018-brf`
  - `db.status=ok`
  - `bootstrap.required=false`
- `openclaw-api` direct `/v1/health` は未認証 `403` の境界確認済み。
- `openclaw-api` の direct invoker は gateway SA / Scheduler SA / Tasks SA のみに限定済み。

残っている主作業は、露出した OAuth client secret の再生成、Secret Manager version の整理、`openclaw-ando-gmail-refresh-token` の enabled version 確認、`poll-gmail` の手動検証と再開である。

---

## 0.1 次に実行する順序

以下の順で進める。secret 値、refresh token、handoff token はチャット・ログ・docs に貼らない。

1. Google Cloud Console で Web OAuth client `OpneclawAndoRedirectURI` の client secret を再生成する。
2. 再生成した client secret を Secret Manager `openclaw-ando-oauth-client-secret` に new version として追加する。
3. チャットに露出した旧 secret version を disable する。
4. ローカルの `.tmp/handoff.json` と `client_secret_*.json` を削除する。
5. `client_secret_*.json` が Git index に入っていないことを確認する。
6. `openclaw-ando-gmail-refresh-token` に enabled Secret version があることを確認する。
7. Scheduler SA impersonation で `POST /internal/poll-gmail` を手動実行する。
8. Cloud Logging で `/internal/poll-gmail` の結果を確認する。
9. token 欠落ではない状態で処理が進むことを確認できたら `poll-gmail` Scheduler を resume する。
10. HUD 実アプリで Gateway URL / Web OAuth client ID を使い、health / events / pending mail / ack を確認する。
11. 検証だけで止める場合は `poll-gmail` を paused に戻し、Cloud SQL 停止を検討する。

---

## 1. HUD 実装完了条件

この手順に入る前に、以下が実装済みであること。

- `clawd-on-desk` から `openclaw-hud-gateway /v1/auth/start` の Google ログインを開始できる。
- 認証対象アカウントは組織ドメイン `master-key.biz` のユーザーに制限されている。
- OAuth scope は以下のみを要求する。
  - `openid`
  - `email`
  - `https://www.googleapis.com/auth/gmail.readonly`
  - `https://www.googleapis.com/auth/gmail.compose`
  - `https://www.googleapis.com/auth/calendar.events`
- 初回または refresh token 欠落時は backend が `prompt=consent` を付与できる。
- OAuth authorization code と `code_verifier` は Gateway/private API の短期 auth session と callback 内で処理され、HUD に露出しない。
- OpenClaw API は Secret Manager の OAuth client secret で confidential exchange を行い、refresh token を Secret Manager の `openclaw-ando-gmail-refresh-token` に保存できる。
- HUD renderer に OAuth token、refresh token、Secret 値を渡さない。

未実装の場合、`poll-gmail` は再開しない。

---

## 2. Cloud Shell 変数の再設定

Cloud Shell を開き直すと `export` は消えるため、作業前に毎回実行する。

```bash
export PROJECT_ID="openclaw-ando-prod"
export REGION="asia-northeast1"

export CLOUD_RUN_SERVICE="openclaw-api"
export CLOUD_RUN_URL="$(gcloud run services describe "${CLOUD_RUN_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"
export HUD_GATEWAY_SERVICE="openclaw-hud-gateway"
export HUD_GATEWAY_URL="$(gcloud run services describe "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"
export IAP_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"

export SA_NAME="openclaw-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export DB_IAM_USER="${SA_EMAIL%.gserviceaccount.com}"

export CLOUD_SQL_INSTANCE="openclaw-db"
export CLOUD_SQL_CONNECTION_NAME="$(gcloud sql instances describe "${CLOUD_SQL_INSTANCE}" \
  --project="${PROJECT_ID}" \
  --format="value(connectionName)")"

export SECRET_PREFIX="openclaw-ando"
export OAUTH_CLIENT_SECRET_NAME="${SECRET_PREFIX}-oauth-client-secret"
export GMAIL_REFRESH_SECRET_NAME="${SECRET_PREFIX}-gmail-refresh-token"
export GEMINI_API_KEY_SECRET_NAME="${SECRET_PREFIX}-gemini-api-key"

export SCHEDULER_SERVICE_ACCOUNT_EMAIL="openclaw-scheduler-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export TASKS_SERVICE_ACCOUNT_EMAIL="openclaw-tasks-invoker@${PROJECT_ID}.iam.gserviceaccount.com"
export CLOUD_TASKS_QUEUE="projects/${PROJECT_ID}/locations/${REGION}/queues/calendar-ops"
```

確認:

```bash
printf 'PROJECT_ID=%s\nREGION=%s\nCLOUD_RUN_URL=%s\nHUD_GATEWAY_URL=%s\nGMAIL_REFRESH_SECRET_NAME=%s\n' \
  "${PROJECT_ID}" \
  "${REGION}" \
  "${CLOUD_RUN_URL}" \
  "${HUD_GATEWAY_URL}" \
  "${GMAIL_REFRESH_SECRET_NAME}"
```

---

## 3. 事前確認

Cloud Run と DB 接続が維持されていることを確認する。

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

- `/livez` が `HTTP/2 200`
- `/readyz` が `HTTP/2 200`

現在の組織ポリシーでは `allUsers` 公開は不可。direct probe は正式 invoker である Scheduler SA impersonation の smoke test に限定し、HUD 利用者や Workspace domain に `openclaw-api` の direct invoker を付与しない。

---

## 4. 認証方式の確認

現在の `openclaw-api` は unauthenticated 公開ではなく、Cloud Run IAM で保護されている。HUD 本番経路は IAP 保護された `openclaw-hud-gateway` を経由し、gateway service account が `openclaw-api` を呼び出す。

確認:

```bash
gcloud run services get-iam-policy "${CLOUD_RUN_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings[] | select(.role=="roles/run.invoker")'

gcloud run services get-iam-policy "${HUD_GATEWAY_SERVICE}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format=json | jq '.bindings[] | select(.role=="roles/run.invoker")'

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

最低限、以下が含まれていること。

- `serviceAccount:openclaw-hud-gateway@openclaw-ando-prod.iam.gserviceaccount.com`（実際の gateway SA 名に読み替え）
- `serviceAccount:openclaw-scheduler-invoker@openclaw-ando-prod.iam.gserviceaccount.com`
- `serviceAccount:openclaw-tasks-invoker@openclaw-ando-prod.iam.gserviceaccount.com`
- `openclaw-hud-gateway` の invoker に `service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com`
- IAP policy に HUD 利用者または管理 group の `roles/iap.httpsResourceAccessor`
- IAP settings の `programmaticClients` に `GOOGLE_CLIENT_ID`

HUD 利用者または Workspace domain に `openclaw-api` の `roles/run.invoker` を直接付与しない。HUD 実装側は `openclaw-hud-gateway` へ同じ Google ID token を `Proxy-Authorization`（IAP programmatic access）と `Authorization`（OpenClaw app auth）に分けて送信し、gateway が inbound `X-Serverless-Authorization` を破棄してから backend へ新規生成した `X-Serverless-Authorization` と `Authorization` を分けて転送する方式になっている必要がある。
Cloud Run を `allUsers` 公開に切り替える方針は、現行組織ポリシーでは使用しない。

Gateway/backend handoff の短命 ID token が取得できる場合は、本番経路で `/v1/health` を確認する。

```bash
export HUD_ID_TOKEN="${HUD_ID_TOKEN:?HUD_ID_TOKEN must be set from Gateway/backend handoff}"

curl -s \
  -H "Proxy-Authorization: Bearer ${HUD_ID_TOKEN}" \
  -H "Authorization: Bearer ${HUD_ID_TOKEN}" \
  "${HUD_GATEWAY_URL}/v1/health" | jq .
```

IAP 403 の場合は IAP access / `programmaticClients`、backend 401/403 の場合は `GOOGLE_CLIENT_ID` / `ALLOWED_DOMAIN` / `ALLOWED_SUBJECT` を確認する。

---

## 5. backend confidential exchange による refresh token 登録

HUD から Gateway OAuth ログインを実施する。

作業内容:

1. `clawd-on-desk` を起動する。
2. OpenClaw / Gmail 連携のログイン操作を開始する。
3. `@master-key.biz` の対象アカウントでログインする。
4. 要求 scope が `openid`, `email`, `gmail.readonly`, `gmail.compose`, `calendar.events` の5つであることを確認する。
5. 初回同意または token 欠落時は `prompt=consent` が付与されていることを確認する。
6. Google callback 後、Gateway/private API が confidential exchange を実行する。
7. API が Secret Manager に refresh token version を追加し、HUD へ短命 ID token / sanitized claims / bootstrap state だけを handoff する。

完了確認:

```bash
gcloud secrets versions list "${GMAIL_REFRESH_SECRET_NAME}" \
  --project="${PROJECT_ID}"
```

期待値:

- `Listed 0 items.` ではない。
- `STATE: enabled` の version が存在する。

refresh token 値を Cloud Shell、ログ、画面に表示しない。

---

## 6. backend exchange 後の Cloud Run 確認

Secret version 作成後、Gmail access token 取得経路を確認する。

```bash
export SCHEDULER_TOKEN="$(gcloud auth print-identity-token \
  --impersonate-service-account="${SCHEDULER_SERVICE_ACCOUNT_EMAIL}" \
  --audiences="${CLOUD_RUN_URL}" \
  --include-email)"

curl -i -X POST \
  -H "Authorization: Bearer ${SCHEDULER_TOKEN}" \
  "${CLOUD_RUN_URL}/internal/poll-gmail"
```

期待値:

- refresh token 未登録による `NOT_FOUND` が出ない。
- HTTP `200`、または Gmail/Gemini 側の具体的な設定不足エラーに進む。

詳細ログ:

```bash
gcloud logging read '
resource.type="cloud_run_revision"
resource.labels.service_name="openclaw-api"
(jsonPayload.component="auth-manager" OR jsonPayload.component="gmail-poller" OR jsonPayload.component="api-server")
' \
  --project="${PROJECT_ID}" \
  --limit=50 \
  --format="table(timestamp,severity,jsonPayload.component,jsonPayload.message,jsonPayload.correlationId)"
```

`Secret ... not found or has no versions` が残る場合は、Cloud Run の `SECRET_GMAIL_REFRESH_TOKEN` または Secret version 作成を再確認する。

---

## 7. `poll-gmail` Scheduler 再開

手動 `POST /internal/poll-gmail` が token 欠落以外の状態まで進んだら、Scheduler を再開する。

```bash
gcloud scheduler jobs resume poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

手動実行:

```bash
gcloud scheduler jobs run poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}"

sleep 5

gcloud scheduler jobs describe poll-gmail \
  --location="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="yaml(lastAttemptTime,status)"
```

Cloud Run request log:

```bash
gcloud logging read '
resource.type="cloud_run_revision"
resource.labels.service_name="openclaw-api"
httpRequest.requestUrl:"/internal/poll-gmail"
' \
  --project="${PROJECT_ID}" \
  --limit=10 \
  --format="table(timestamp,httpRequest.requestMethod,httpRequest.requestUrl,httpRequest.status)"
```

期待値:

- Scheduler `status` が空 `{}`、またはエラーがない。
- Cloud Run request log の `/internal/poll-gmail` が `200`。

---

## 8. DB / event 確認

Gmail polling 後、必要に応じて DB を確認する。

Cloud SQL Proxy 起動:

```bash
~/cloud-sql-proxy "${CLOUD_SQL_CONNECTION_NAME}" --port 5432 > /tmp/cloud-sql-proxy.log 2>&1 &
PROXY_PID=$!
sleep 3
cat /tmp/cloud-sql-proxy.log
```

DB admin password が Cloud Shell 変数に無い場合:

```bash
read -s -p "DB admin password: " DB_ADMIN_PASSWORD
echo
export DB_ADMIN_PASSWORD
```

件数確認:

```bash
PGPASSWORD="${DB_ADMIN_PASSWORD}" psql -w \
  "host=127.0.0.1 port=5432 dbname=openclaw_db user=postgres sslmode=disable" <<SQL
SELECT COUNT(*) AS emails_count FROM emails;
SELECT type, COUNT(*) FROM event_inbox GROUP BY type ORDER BY type;
SQL
```

終了:

```bash
kill "${PROXY_PID}"
```

---

## 9. HUD 表示・操作確認

HUD 側で以下を確認する。

- 接続状態が online になる。
- `GET /v1/health` 相当の heartbeat が成功する。
- `GET /v1/events` で未 ACK event を取得できる。
- `GET /v1/mail/pending` で承認待ちメールを表示できる。
- 表示後に `POST /v1/events/{eventId}/ack` が実行される。
- 承認・拒否ボタンは二重押下できない。
- OAuth token、refresh token、Secret 値、Gmail draftId、Calendar eventId が renderer に露出しない。

失敗時は Cloud Run request log と `X-Request-Id` を突き合わせる。

---

## 10. 完了条件

以下を満たしたら、HUD 実装後の GCP 側残作業は完了とする。

- `openclaw-ando-gmail-refresh-token` に enabled version がある。
- `/livez` が `200`。
- `/readyz` が `200`。
- `pii-retention` Scheduler 実行が `200`。
- `poll-gmail` Scheduler 実行が token 欠落以外の状態で成功する。
- `poll-gmail` が resume 済み。
- HUD が IAP 保護された `openclaw-hud-gateway` 経由で OpenClaw API に接続できる。
- HUD が承認カード、イベント ACK、接続状態を扱える。
- refresh token や OAuth token がログ・renderer・Cloud SQL に露出していない。

---

## 11. 禁止事項

- refresh token をチャット、ログ、Issue、ドキュメントに貼り付けない。
- refresh token を renderer に渡さない。
- `poll-gmail` を refresh token version 0 件のまま resume しない。
- Cloud Run を組織ポリシーに反して `allUsers` 公開しようとしない。
- Cloud SQL Proxy を作業後に起動したまま放置しない。
- Cloud Shell の `export` が永続化される前提で作業しない。
