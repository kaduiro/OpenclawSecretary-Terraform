# VPSセキュリティ設計書

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: セキュリティ設計
- 版数: 1.0
- 最終更新日: 2026-08-30
- 位置づけ: GCP managed securityをVPSで代替する統制の正本

## 2. 目的

VPS移行によって利用者側へ移るOS、network、credential、鍵、backup、監査の責任と検証方法を定義する。

## 3. 対象範囲

### 3.1 対象

認証、認可、tenant分離、データ分類、secret、通信、監査、運用アクセス、supply chainを対象とする。

### 3.2 対象外

Googleアカウント自体の組織ポリシーと端末MDMは対象外とする。

## 4. 前提

CHK-SEC-001、CHK-IMPL-002、REQ-INF-004、REQ-NET-001、REQ-NET-002、REQ-SEC-001、REQ-SEC-002、REQ-REL-001を前提とする。

## 5. 本文

### 5.1 認証

- browserはGoogle Workspace OIDCを使用する。
- issuer、audience、署名、expiry、nonce、state、PKCE、email、hosted domainを検証する。
- Electron handoffは一回限り、5分以内、hash保存、redeem後即時無効化とする。
- public endpointはGatewayとAuth Bootstrapの許可routeだけとする。

### 5.2 認可

- OIDC通過だけで業務resourceを許可せず、既存active user、membership、business unit条件を実行する。
- internal jobは用途別tokenとnetwork境界を併用する。
- runtime DB role、migration role、backup role、monitoring roleを分離する。
- CI/CDはproduction secret本文を読み取れず、host上の復号操作だけを起動できる構成にする。

### 5.3 テナント分離

- 既存のbusiness unit境界とcaller-relative DTOを維持する。
- backup、log、metricsへraw claimant IDとメール本文を出力しない。
- DB restore先はproduction networkへ自動接続せず、隔離stagingで検査する。

### 5.4 データ分類

| 分類 | 例 | 保存 | log | backup |
|---|---|---|---|---|
| Secret | refresh token、OAuth client secret、KEK、job token | 暗号化またはtmpfs | 禁止 | client-side暗号化 |
| PII | email address、本文、calendar情報 | envelope暗号化または業務DB | 本文禁止 | 暗号化 |
| 内部 | resource ID、構成、metrics | repositoryまたは監視 | 許可 | 許可 |
| 公開 | health status、公開URL | 制約なし | 許可 | 対象外 |

### 5.5 秘密情報管理

#### 配備用秘密情報

- SOPS/age暗号化fileをprivate repositoryへ置く。
- age private keyはroot所有、mode 0400、DB volumeと別pathに置く。
- deploy時に`/run/secrets/openclaw`へ復号し、tmpfs以外へ書かない。
- Composeはfile mountでsecretを渡し、environment dumpへ表示しない。

#### Cloudflare DNS認証情報

- Cloudflare API tokenは対象zoneのDNS read/editだけを許可し、account全体へ作用するGlobal API Keyを使用しない。
- productionとstagingのtokenを分離し、CIでは対応するGitHub Environmentから短時間だけ注入する。
- token本文をTerraform variable fileとstateへ保存せず、plan artifactとprovider debug logへの出力を禁止する。
- token rotation後は旧tokenを無効化し、DNSのread、plan、限定的なrecord更新、rollbackを確認する。

#### 動的refresh token

- ユーザーごとにDEKを生成し、AES-256-GCMで暗号化する。
- DEKを版付きKEKでwrapし、credential envelopeへ保存する。
- AADにattendee_ref、用途、envelope versionを含める。
- KEK rotationは新規暗号化を新keyVersionへ切り替え、既存行をbatch再暗号化し、復号確認後に旧鍵を廃止する。
- DB dumpだけでrefresh tokenを復号できないことを検証する。

### 5.6 通信保護

- Internet通信はTLS 1.2以上とし、Caddyが自動更新する。
- HSTS、`X-Content-Type-Options`、frame制約、referrer制約を設定する。
- PostgreSQLはDocker data networkまたはprivate networkだけで接続する。
- Node間DB replicationを導入する場合はprivate networkとTLS client証明書を併用する。
- outbound先をGoogle API、GHCR、Object Storage、監視先へ棚卸しする。

### 5.7 監査証跡

| 事象 | 必須項目 | 保持 |
|---|---|---:|
| SSH/sudo | operator、source、command、時刻 | 90日 |
| release | git SHA、image digest、signature、operator、結果 | 1年 |
| migration | filename、checksum、開始終了、結果 | 無期限DB履歴 |
| backup/restore | backup ID、checksum、`process_flow_design.md` §5.3に基づくRTO起点候補・採用起点・終点・RPO/RTO、operator | 1年 |
| auth failure | reason code、route、correlation ID | 90日 |
| secret rotation | old/new keyVersion、件数、結果 | 1年 |
| DNS change | zone/record ID、before/after、plan、operator、時刻、結果 | 1年 |

Secret本文、access token、refresh token、OAuth code、メール本文を監査logへ保存しない。

### 5.8 運用アクセス

- operator accountにMFAを要求する。
- SSH password、root login、共用鍵を禁止する。
- production接続はoverlay network経由とし、public 22を閉じる。
- break-glassはVPS control panel consoleだけとし、実行後24時間以内にcredentialをrotationする。
- 退職・役割変更時は24時間以内にSSH key、overlay membership、VPS console権限を削除する。

### 5.9 脅威と対策

| 脅威ID | 分類 | 対象 | 脅威 | 対策 | 検証方法 | 関連REQ |
|---|---|---|---|---|---|---|
| THR-001 | なりすまし | OIDC | forged ID token | issuer/audience/nonce/domain検証 | token negative test | REQ-SEC-001 |
| THR-002 | 改ざん | image | registry image差替え | digest固定、Cosign、provenance | 未署名拒否 | REQ-REL-001 |
| THR-003 | 否認 | deploy | operator不明 | Environment承認とrelease ledger | audit review | REQ-REL-002 |
| THR-004 | 情報漏えい | refresh token | DB dump流出 | envelope暗号化、DB外KEK | dump秘密値検査 | REQ-SEC-002 |
| THR-005 | 情報漏えい | network | DB/SSH公開 | security group、firewall、overlay | external port scan | REQ-NET-001 |
| THR-006 | サービス不能 | 単一VPS | host停止 | off-site backup、IaC再構築、外部監視 | DR訓練 | REQ-OPS-003 |
| THR-007 | 権限昇格 | container | Docker socket悪用 | socket非mount、non-root、cap drop | container policy scan | REQ-INF-003 |
| THR-008 | 改ざん | backup | backup破損 | checksum、immutable retention、別障害領域 | restore訓練 | REQ-OPS-002 |
| THR-009 | 情報漏えい | log | PII/token出力 | structured redaction、禁止field test | log scan | REQ-OPS-001 |
| THR-010 | サービス不能 | queue | retry storm | lease、backoff、上限、dead-letter | fault injection | REQ-JOB-001 |
| THR-011 | 改ざん・サービス不能 | DNS | record改ざん、誤更新、token漏えい | Cloudflareのzone限定token、Terraform plan承認、変更監査、旧値rollback | 権限negative test、record rollback | REQ-INF-004 |

### 5.10 セキュリティ対策の検証

- 毎pull requestでsecret scan、dependency scan、image scan、IaC scanを行う。
- 毎releaseでOIDC negative test、public port scan、runtime DDL拒否、未署名image拒否を行う。
- 毎月backup restore、四半期ごとにcredential rotation、半年ごとにbreak-glass訓練を行う。
- critical脆弱性は72時間以内にpatchまたは外部到達遮断を行う。

## 6. 未確定事項

- host保管KEKの侵害リスクを許容できない場合は、外部Vault/KMSを追加する。
- overlay network製品はMFAとCIの短期credential試験後に確定する。
- WAFは初期必須にせず、Internet攻撃件数とrate limit実測で導入判定する。

## 7. 関連文書

- `requirements_definition.md`
- `infra_architecture_design.md`
- `db_design_document.md`
- `rtm.md`
