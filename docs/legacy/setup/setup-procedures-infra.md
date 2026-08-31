# Legacy Infrastructure Setup Procedures

この文書は `OpenclawSecretaryAndo/docs/setup/setup-procedures.md` から章単位で抽出した legacy procedure である。現行 Cloud Run / Terraform 分割後の正本ではない。

Terraform 側では Google Cloud Console、Gemini API key、セキュリティ検証など、インフラ移行前の旧手順を参照用に保持する。

---

## TASK-002: Google Cloud Console 設定

**目的**: Gmail API / Google Calendar API の OAuth 2.0 クライアント ID を取得する

### 手順

1. [Google Cloud Console](https://console.cloud.google.com/) にアクセスし、MASTERkey Google Workspace アカウントでログイン
2. 新規プロジェクトを作成（例: `masterkey-ai-secretary`）または既存プロジェクトを選択
3. **APIを有効化**（この2つのみ）
   - 左メニュー「APIとサービス」→「ライブラリ」
   - `Gmail API` → 「有効にする」
   - `Google Calendar API` → 「有効にする」
4. **OAuth 同意画面の設定**
   - 「APIとサービス」→「OAuth 同意画面」
   - User Type: **内部**（Google Workspace 組織内のみ）
   - アプリ名: `MASTERkey AI Secretary`
   - スコープを追加（以下4つのみ）:
     - `openid`
     - `https://www.googleapis.com/auth/gmail.readonly`
     - `https://www.googleapis.com/auth/gmail.compose`
     - `https://www.googleapis.com/auth/calendar.events`
   - **注意**: `gmail.send` は含めない（RC-AUTH-003 CLOSED）。`calendar.readonly` は不要（`calendar.events` で代替）。`openid` と `email` は Gateway/backend handoff の Google ID token claims 検証に必須
5. **OAuth 2.0 クライアント ID を作成**
   - 「認証情報」→「認証情報を作成」→「OAuth クライアント ID」
   - アプリケーションの種類: **デスクトップアプリ**
   - 名前: `ai-secretary-desktop`
   - 「作成」後、「JSONをダウンロード」
6. **client_id / client_secret の扱い**
   - `client_id` は非シークレットとして HUD 設定画面の `oauthClientId` と Cloud Run env `GOOGLE_CLIENT_ID` に設定する。
   - `client_secret` は HUD やローカル `.env` に保存せず、OpenClaw backend 用 Secret Manager secret（例: `openclaw-ando-oauth-client-secret`）にのみ保存する。
   - ダウンロードした `client_secret_*.json` は値確認後に安全な場所で管理し、リポジトリ配下へコピーしない。
7. **.env に記録する場合**（ローカル確認用。secret は含めない）
   ```
   GOOGLE_CLIENT_ID=（credentials.json の client_id）
   ALLOWED_DOMAIN=（組織ドメイン例: company.com）
   ```

7. **Cloud Run 環境変数を設定する**（Cloud Run サービスがデプロイ済みの場合）

   ```bash
   # GOOGLE_CLIENT_ID は credentials.json の client_id 値（非シークレット・env var で管理）
   # ALLOWED_SUBJECT は Gateway/backend verified handoff claims の sub から取得する
   gcloud run services update openclaw-{user_id} \
     --set-env-vars "GOOGLE_CLIENT_ID=$(jq -r .installed.client_id ~/Downloads/client_secret_*.json),ALLOWED_DOMAIN=company.com,ALLOWED_SUBJECT=<handoff-claims-sub>" \
     --region asia-northeast1
   ```

   または `.env` に記録しておき TASK-007 で Cloud Run deploy 時に `--set-env-vars` に指定する:

   ```
   GOOGLE_CLIENT_ID=（credentials.json の client_id）
   ALLOWED_DOMAIN=（組織ドメイン例: company.com）
   ```

### 完了確認

- [ ] OAuth client JSON がリポジトリ配下に保存されていない
- [ ] `git status` で `client_secret_*.json` や credentials ファイルが表示されない
- [ ] 有効化 API が Gmail API と Google Calendar API の2つのみ
- [ ] OAuth scope が `openid`, `gmail.readonly`, `gmail.compose`, `calendar.events` の4つのみ（`gmail.send` は含まない）
- [ ] OAuth クライアントの種別が「デスクトップアプリ」になっている
- [ ] `GOOGLE_CLIENT_ID`、`ALLOWED_DOMAIN`、Gateway/backend verified handoff claims 由来の `ALLOWED_SUBJECT` を Cloud Run に設定済み
- [ ] OAuth `client_secret` は Secret Manager に保存され、HUD / local `.env` / renderer に保存されていない

---


---

## TASK-004: Gemini API キー取得

**目的**: AI 分析・返信生成に使う Gemini API キーを発行する

### 手順

1. [Google AI Studio](https://aistudio.google.com/) にアクセス（個人 Google アカウントで可）
2. 「Get API key」→「Create API key in new project」
3. 発行された `AIza...` キーをコピー
4. **.env に追記**
   ```
   GEMINI_API_KEY=AIza（取得したキー）
   ```
5. **動作確認**
   ```bash
   curl -s \
     "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"contents":[{"parts":[{"text":"Hello"}]}]}' \
     | grep '"text"'
   ```

### 完了確認

- [ ] レスポンスに `"text"` フィールドが含まれる
- [ ] .env の `GEMINI_API_KEY` にハードコードなし

---


---

## TASK-018: セキュリティコントロール検証

**目的**: 全構築完了後にセキュリティチェックリストを実施する

### チェックリスト

`docs/security_checklist.md` を作成し以下を記録する:

| # | 確認項目 | 確認方法 | 結果 |
|---|---------|---------|------|
| 1 | .env に全クレデンシャルが集約されソースコードに平文なし | `grep -r "GEMINI_API_KEY\|xoxb-\|AIza" scripts/ workspace/` | PASS/FAIL |
| 2 | .env が .gitignore に記載されている | `cat .gitignore \| grep .env` | PASS/FAIL |
| 3 | Gmail OAuth scope が5つのみ | Google Cloud Console で確認 | PASS/FAIL |
| 4 | Slack Bot Token Scope が3つのみ | api.slack.com で確認 | PASS/FAIL |
| 5 | Signing Secret 検証コードが存在する | `grep -r "SLACK_SIGNING_SECRET\|HMAC" scripts/` | PASS/FAIL |
| 6 | Obsidian の自動クラウド同期が無効 | Obsidian 設定で確認 | PASS/FAIL |
| 7 | ChromaDB がローカルパスに保存 | `ls C:/chroma_db/` | PASS/FAIL |
| 8 | 全 API 通信が HTTPS | URLに `https://` が含まれることをコードで確認 | PASS/FAIL |

### 完了確認

- [ ] 全8項目が PASS

---


---

## TASK-019: エンドツーエンドテスト（SLO 検証）

**目的**: 実際のメール3件で全 SLO を検証する

### テスト手順

1. **テストメールを3種類送信**（`115akkun@gmail.com` 宛に別アカウントから送信）
   - メール①: 通常の問い合わせ（例: 「派遣スタッフの交通費について教えてください」）
   - メール②: 日程調整（例: 「来週月曜日14時にお打ち合わせをお願いできますか」）
   - メール③: 長文の求人問い合わせ（200文字以上）
2. **SLO 計測**（`workspace/outputs/timelines/` のログと Slack タイムスタンプで確認）
3. **結果を `docs/e2e_test_results.md` に記録**

### チェックリスト

| # | 確認項目 | 期待値 | 結果 |
|---|---------|-------|------|
| 1 | SLI-01: Gmail受信 → Slack DM 通知（メール①②③） | 3件とも 180秒以内 | PASS/FAIL |
| 2 | SLI-02: Slack 承認 → Gmail 送信 | 15秒以内 | PASS/FAIL |
| 3 | SLI-02: Slack 承認 → Calendar 更新（メール②） | 15秒以内 | PASS/FAIL |
| 4 | 拒否操作後に Gmail が送信されない | 送信なし | PASS/FAIL |
| 5 | 無操作でも Gmail が送信されない | 送信なし | PASS/FAIL |
| 6 | 承認なしで Calendar が更新されない | 更新なし | PASS/FAIL |
| 7 | FAQ が Obsidian vault に正しく保存される | ファイル存在 | PASS/FAIL |
| 8 | タイムラインに全イベントが記録されている | 全件記録 | PASS/FAIL |

### 完了確認

- [ ] 全8項目が PASS

---


---

## 実装推奨順序まとめ

```
並行グループ1（依存なし）:
  TASK-002  Google Cloud Console
  TASK-003  Slack App
  TASK-004  Gemini API キー
  TASK-005  ChromaDB
  TASK-006  Obsidian Vault

↓ 完了後

並行グループ2:
  TASK-007  Gmail ポーリング ← TASK-002完了後
  TASK-009  FAQ インデクサー ← TASK-005/006完了後
  TASK-011  Slack Adapter  ← TASK-003完了後

↓ 完了後

並行グループ3:
  TASK-008  AI 分析       ← TASK-007/004完了後
  TASK-010  RAG 返信生成  ← TASK-008/009完了後
  TASK-012  Slack 通知    ← TASK-010/011完了後

↓ 完了後

並行グループ4:
  TASK-013  承認ハンドラー ← TASK-011/012完了後
  TASK-014  タイムライン   ← TASK-007/008完了後
  TASK-015  FAQ 提案       ← TASK-013/006完了後
  TASK-016  カレンダー     ← TASK-008/002完了後

↓ 完了後

TASK-017  カレンダー承認 ← TASK-016/011完了後

↓ 全 TASK 完了後

TASK-018  セキュリティ検証
TASK-019  E2E テスト
```
