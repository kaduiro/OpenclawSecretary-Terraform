# VPS・GCP比較および採用判断

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: 比較・意思決定記録
- 版数: 1.1
- 最終更新日: 2026-08-31
- 位置づけ: VPS採用判断の根拠を保存する正本

## 2. 目的

GCPとVPSのランニングコスト、運用責任、可用性、移行工数を同一条件で比較し、VPSを現時点の第一選択Architectureとして記録する。根拠のない再選定を防ぎつつ、重大な前提変更時にはFail Closedで再評価できる境界も定義する。

## 3. 対象範囲

### 3.1 対象

現行Pilot、現行production guard、単一VPS、2台VPS構成を比較する。

### 3.2 対象外

Gemini、DLP、ドメイン、GitHub有料枠のように両構成で同量発生する外部利用料と、移行の一時的な人件費は月額比較から除く。

## 4. 前提

- GCPは東京リージョン、月730時間、1 USDを160円として概算する。
- Pilotは2ユーザー、1日30メール、Cloud SQL `db-g1-small`、ZONAL、Cloud Run最小0とする。
- GCP productionはCloud SQL `db-custom-1-3840`、REGIONAL、3サービス最小1とする。
- VPS基準案はConoHa VPS Ver.3.0、100GB NVMeとする。
- 権威DNSはCloudflare DNSを使用し、Cloudflare Terraform Providerで管理する。ConoHa Terraform ProviderへDNS管理を期待しない。
- 料金は契約時点の公式見積で再確認し、本文の値を請求保証として使わない。

## 5. 本文

### 5.1 比較結果

| 観点 | GCP | VPS | 判断 |
|---|---|---|---|
| Pilot月額 | 4,500〜7,000円 | 12GB単一台で5,300〜7,000円 | 大差はないが固定額の予測性でVPS |
| production月額 | 32,000〜42,000円 | 単一台6,000〜8,000円、2台11,000〜16,000円 | VPS |
| スケール | 自動 | サイズ変更または増設 | 現行負荷ではVPSで許容 |
| DB運用 | HA、PITR、patchをマネージド提供 | backup、restore、patchを自主管理 | 工数を受容してVPS |
| 認証・鍵 | IAP、IAM、KMS、Secret Manager | OIDC、SOPS/age、アプリ暗号化へ置換 | 設計変更を受容してVPS |
| 障害責任 | Googleと利用者で分担 | OSより上を利用者が担当 | runbookと訓練を必須化 |
| ロックイン | GCP resourceへの依存が強い | Docker/PostgreSQL中心 | VPS |

### 5.2 月額試算

| 構成 | compute/DB | backup・保管 | 周辺基盤 | 合計 |
|---|---:|---:|---:|---:|
| GCP Pilot | 4,100〜5,000円 | 200〜500円 | 200〜1,500円 | 4,500〜7,000円 |
| VPS 4GB単一台 | 2,189〜2,408円 | 908円〜 | 0〜500円 | 3,100〜4,500円 |
| VPS 12GB単一台 | 4,389〜4,828円 | 908円〜 | 0〜500円 | 5,300〜7,000円 |
| GCP production | 27,000円〜 | 1,000円〜 | 4,000〜12,000円 | 32,000〜42,000円 |
| VPS 12GB 2台 | 8,778〜9,656円 | 1,271円〜 | 1,210〜5,000円 | 11,000〜16,000円 |

Cloud SQL共有コアの公式表には`db-g1-small`が0.035 USD/時、HAが0.07 USD/時と記載され、共有コアはSLA対象外とされる。Cloud Runはリクエスト課金で最小インスタンス0の場合に低負荷の費用を抑えられる。一方、最小インスタンスを設定するとidle時間も課金対象になる。

ConoHaは公開料金で4GB、12GB、100GB自動backup、Object Storageを個別に提示している。契約期間とキャンペーンで価格が変わるため、CIで価格を取得せず、月次の運用レビューで公式料金を確認する。DNSの月額はCloudflareの契約planとdomain費用として別管理し、上表のVPS compute/DB比較には含めない。

### 5.3 費用差

- Pilotの12GB VPSはGCP Pilotと同水準であり、削減額は0〜1,700円/月を見込む。
- 単一VPSとGCP productionの差は24,000〜36,000円/月を見込む。ただし可用性は同等ではない。
- 2台VPSとGCP productionの差は16,000〜31,000円/月を見込む。DB自動failoverと運用人件費を含めると差は縮小する。
- 年間インフラ請求差は、2台VPS対GCP productionで192,000〜372,000円を見込む。

### 5.4 最終決定

VPSを現時点の第一選択Architectureとして採用する。通常の実装期間中は、根拠のない再比較・再選定を行わない。GCPは移行元および移行期間中の外部APIとして扱い、Cloud RunとCloud SQLを既定の最終実行基盤にしない。

### 5.5 判断の効力

次のいずれかが発生した場合は、影響するProduction変更と危険な外部Actionを停止し、Architecture再評価を開始する。

1. 新しい法令、契約、Data所在要件を現行VPS構成で満たせない。
2. 重大なセキュリティ事故により、現行構成の継続が安全と立証できない。
3. 正本で定めるRPO/RTOを満たせず、承認された是正期限内に回復できない。
4. Providerの廃止、重大なService劣化またはSupport終了が発生する。
5. Patch、Backup、Restore、監視、Incident対応を担う運用人員を確保できない。
6. 3か月の実測総保有コストが、同等要件を満たすManaged ServiceまたはCloud案以上になる。

再評価では、VPSの増強、複数台化、VPS事業者変更、Database分離、Managed PostgreSQL、Cloud基盤への移行を選択肢から除外しない。再評価完了前に危険な構成を継続してはならない。Architecture変更は別ADR、移行計画、Rollback計画、承認Evidenceを必要とする。

### 5.6 再評価時の総保有コスト

総保有コストには、VPS料金だけでなく、Backup・Object Storage、監視、Security Service、外部API、運用作業時間、Restore訓練、Incident対応を含める。Pilotの削減見込みが0〜1,700円/月にとどまることを隠さず、Production想定の削減額と可用性差を分けて評価する。

## 6. 未確定事項

- 契約開始日のVPS実額は申込直前に再計算する。
- Gemini、DLP、Pub/Subを継続した場合の従量費は実測後に別予算へ分離する。
- 人件費を含む総保有コストは、月次運用時間を3か月計測して追加する。

## 7. 関連文書

- [Cloud SQL料金](https://cloud.google.com/sql/pricing?hl=ja)
- [Cloud Run料金](https://cloud.google.com/run/pricing)
- [ConoHa VPS料金](https://vps.conoha.jp/pricing/)
- [ConoHa Terraform provider](https://doc.conoha.jp/reference/terraform/terraform-conoha-vps-provider/)
- [Cloudflare Terraform Provider](https://developers.cloudflare.com/terraform/)
- [Cloudflare DNS record resource](https://developers.cloudflare.com/api/terraform/resources/dns/subresources/records/)
- `shared_understanding.md`
- `infra_architecture_design.md`
