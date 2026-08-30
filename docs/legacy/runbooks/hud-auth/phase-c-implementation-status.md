# HUD Auth Phase C Implementation Status

作成日: 2026-06-09
更新日: 2026-06-11

## 現在の状態

Phase C の backend / Gateway 実装はコード上完了した。

2026-06-11 時点で Phase D の GCP 差分適用も実機確認済み。`openclaw-api` は private Cloud Run のまま維持し、IAP 保護された `openclaw-hud-gateway` 経由で、実際の OAuth handoff token による `GET /v1/health` が `200 OK` を返すことを確認した。

残作業は、露出した OAuth client secret の再生成、ローカル secret/token ファイルの整理、Gmail polling 再開前の Secret version 確認、`poll-gmail` の手動検証と Scheduler resume である。

## 実装済み

- backend `POST /internal/auth/oauth-sessions`
- backend `POST /internal/auth/oauth-exchange`
- backend `POST /v1/auth/id-token/refresh`
- gateway `GET /v1/auth/start`
- gateway `GET /v1/auth/callback`
- gateway `/v1/*` relay
- backend Google ID token verification
  - `aud = GOOGLE_CLIENT_ID`
  - `hd = ALLOWED_DOMAIN`
  - `sub = ALLOWED_SUBJECT`
- OAuth client secret の Secret Manager 読み込み
- backend 短期 auth session への `state` / `code_verifier` 保存
- Gmail refresh token の Secret Manager 保存
- HUD handoff / refresh response の token 境界
  - HUD に返す: `idToken`, `expiresAt`, sanitized `claims`, `bootstrap`
  - HUD に返さない: refresh token, access token, authorization code, `code_verifier`, OAuth client secret
- gateway header 境界
  - inbound `X-Serverless-Authorization` は破棄
  - backend 用 `X-Serverless-Authorization` は gateway service account の ID token で新規生成
- deploy script の gateway/API 同一 image 起動切替
  - API: `OPENCLAW_SERVER_ROLE=api`
  - Gateway: `OPENCLAW_SERVER_ROLE=gateway`

## 追加された主要ファイル

- `src/gateway-server.js`
- `src/launch-server.js`
- `test/auth-manager.test.js`
- `test/gateway-server.test.js`

## 更新された主要ファイル

- `src/auth-manager.js`
- `src/api-server.js`
- `src/config.js`
- `infra/cloud-run/deploy.sh`
- `Dockerfile`
- `package.json`

## 検証済み

- `npm test`
- `node --check src/auth-manager.js`
- `node --check src/api-server.js`
- `node --check src/gateway-server.js`
- `node --check src/launch-server.js`
- `bash -n infra/cloud-run/deploy.sh`

## 2026-06-11 GCP 実機確認結果

- `openclaw-api` は `--no-allow-unauthenticated` / private Cloud Run として維持。
- `openclaw-hud-gateway` は Cloud Run service として稼働し、IAP 保護あり。
- OAuth client は Desktop client から Web application client へ切替済み。
  - Web client ID: `598108671830-0om1spa9a7vdhtg5p599cqhgnqi9l2l4.apps.googleusercontent.com`
  - redirect URI: `https://openclaw-hud-gateway-utxdh4fdia-an.a.run.app/v1/auth/callback`
- IAP `programmaticClients` は Web client ID に更新済み。
- `openclaw-api` env `GOOGLE_CLIENT_ID` は Web client ID に更新済み。
- `openclaw-api` env `OAUTH_REDIRECT_URI` は Gateway callback URI に更新済み。
- OAuth client secret は Secret Manager `openclaw-ando-oauth-client-secret` に version 追加済み。
- `openclaw-api` service account に Secret Manager 権限を付与済み。
  - `openclaw-ando-oauth-client-secret`: `roles/secretmanager.secretAccessor`
  - `openclaw-ando-gmail-refresh-token`: `roles/secretmanager.secretAccessor`
  - `openclaw-ando-gmail-refresh-token`: `roles/secretmanager.secretVersionAdder`
  - `openclaw-ando-gemini-api-key`: `roles/secretmanager.secretAccessor`
- `openclaw-api` direct invoker は gateway SA / Scheduler SA / Tasks SA のみに限定済み。
- direct `openclaw-api /v1/health` は未認証 `403` を確認済み。
- Scheduler SA impersonation による direct `/livez` は `200` を確認済み。
- Scheduler SA impersonation による direct `/readyz` は Cloud SQL / DB grants 適用後に `200` を確認済み。
- Gateway/backend verified handoff claims:
  - `sub`: `117315801613785339993`
  - `email`: `info@master-key.biz`
  - `hd`: `master-key.biz`
  - `aud`: `598108671830-0om1spa9a7vdhtg5p599cqhgnqi9l2l4.apps.googleusercontent.com`
- 実際の handoff `idToken` を `Proxy-Authorization` と `Authorization` に入れた Gateway 経由 `GET /v1/health` が成功。
  - response: `HTTP/1.1 200 OK`
  - request id: `56113e57-7df3-464b-938d-4982c9570e0d`
  - backend revision: `openclaw-api-00018-brf`
  - response body summary: `status=ok`, `db.status=ok`, `bootstrap.required=false`
- `gcloud auth print-identity-token` の token は正式な Gateway/IAP 検証には使わない。正式確認は Gateway/backend handoff token で行う。
- Gateway OAuth callback の redirect 先が Cloud Run HTTPS URL になったため、OAuth client は Web application 型が必要。Desktop client は Cloud Run Gateway callback の `redirect_uri` と一致できず `redirect_uri_mismatch` になる。

## 未完了 / 次工程

- チャットに露出した OAuth client secret を再生成し、Secret Manager に新 version として追加する。
- 露出済み Secret Manager version を disable する。
- ローカル `.tmp/handoff.json` と `client_secret_*.json` を削除または Git 管理外にする。
- `openclaw-ando-gmail-refresh-token` に enabled Secret version があることを確認する。
- Scheduler SA token で `POST /internal/poll-gmail` を手動実行し、refresh token 欠落以外の状態まで進むことを確認する。
- 問題なければ `poll-gmail` Scheduler を resume する。
- Cloud Logging に OAuth token / refresh token / client secret / PII が出ていないことを確認する。
- 検証停止期間は Cloud SQL `activationPolicy` と Scheduler 状態を見直し、不要な課金を避ける。

## 次に行うこと

1. OAuth client secret を再生成する。
2. 新 secret を `openclaw-ando-oauth-client-secret` に version 追加する。
3. 露出済み secret version を disable する。
4. ローカルの handoff token / OAuth client secret JSON を削除し、Git index から外す。
5. `openclaw-ando-gmail-refresh-token` の enabled version を確認する。
6. `POST /internal/poll-gmail` を Scheduler SA impersonation で手動実行する。
7. `poll-gmail` のログを確認し、token 欠落ではない状態で進むことを確認する。
8. 問題なければ `poll-gmail` Scheduler を resume する。
9. HUD 実アプリで Gateway URL / Web OAuth client ID の設定を確認し、表示・ACK・メール pending 取得を検証する。
10. 運用を続けない場合は Scheduler pause と Cloud SQL 停止を判断する。
