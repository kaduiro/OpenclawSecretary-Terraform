# VPS向けIaCパッケージ構成設計書

## 1. 文書概要

- 対象システム: OpenClaw Secretary
- 文書種別: IaCパッケージ構成設計
- 版数: 1.0
- 最終更新日: 2026-08-30
- 位置づけ: Terraform、Ansible、Docker Compose、CI/CDの配置方針

## 2. 目的

VPS resource、host構成、service構成、運用scriptの所有境界を分け、stagingとproductionを同じ構造で再現する。

## 3. 対象範囲

### 3.1 対象

Terraform modules、envs、state、Ansible role、Compose、policy、runbook、CI/CDを対象とする。

### 3.2 対象外

BackとFrontのapplication package構成は各repositoryの正本へ委ねる。

## 4. 前提

CHK-GOAL-001、CHK-IMPL-001、CHK-IMPL-002、REQ-INF-002、REQ-INF-003、REQ-INF-004、REQ-REL-001を前提とする。

## 5. 本文

### 5.1 決定事項サマリー

- 現行GCP HCLを直ちに削除せず、`gcp-legacy/`へ移す作業はcutover後に行う。
- 新規VPS IaCは`vps/`配下に作り、rootのGCP stateと混在させない。
- ConoHa Terraform Providerは対応5種のVPS resourceだけを所有し、Cloudflare Terraform ProviderはDNSを所有する。
- AnsibleはOS、Composeはserviceを所有する。
- secret値をTerraform variable、state、Ansible inventory、Compose YAMLへ保存しない。

### 5.2 最小構成

```text
vps/
  terraform/
  ansible/
  compose/
  policies/
  tools/
  runbooks/
```

### 5.3 全体ディレクトリ構成

```text
OpenclawSecretary-Terraform/
  vps/
    terraform/
      versions.tf
      providers.tf
      modules/
        conohavps/
          server/
          ssh-key/
          volume/
          security-group/
        cloudflare/
          dns/
      envs/
        shared-edge/
          backend.tf
          main.tf
          variables.tf
          terraform.tfvars.example
        staging/
          backend.tf
          main.tf
          variables.tf
          terraform.tfvars.example
        production/
          backend.tf
          main.tf
          variables.tf
          terraform.tfvars.example
      tests/
      registers/
        external_resources.md
    ansible/
      ansible.cfg
      inventories/
        staging/
        production/
      roles/
        base/
        ssh_hardening/
        firewall/
        docker/
        overlay_network/
        observability/
        backup/
      playbooks/
        bootstrap.yml
        configure.yml
        patch.yml
        recover.yml
    compose/
      compose.yaml
      compose.staging.yaml
      compose.production.yaml
      caddy/
      postgres/
      systemd/
    policies/
      conftest/
      trivy/
    tools/
      verify-provider.ps1
      verify-ports.ps1
      verify-backup.ps1
      release.ps1
      rollback.ps1
    runbooks/
      bootstrap.md
      release.md
      restore.md
      incident.md
      cutover.md
```

### 5.4 レイヤー構成

| レイヤー | ツール | 所有対象 | 禁止対象 |
|---|---|---|---|
| ConoHa resource | Terraform + ConoHa Provider | VPS Instance、SSH鍵、Volume、Security Group、Security Group Rule | DNS、OS package、container、secret値 |
| edge resource | Terraform + Cloudflare Provider | DNS zone、DNS record | ConoHa VPS、OS package、container、secret値 |
| external resource | 管理台帳・専用手順 | off-site Object Storageなど採用provider未確定の資源 | ConoHa module内の暗黙API呼出し |
| host | Ansible | user、SSH、firewall、Docker、timer、監視 | VPS作成、DB schema |
| service | Docker Compose | container、network、volume mount、health | cloud resource、host user |
| application | Back/Front repository | image、migration、API、worker | Terraform state、host設定 |
| operation | runbook/tools | deploy、restore、cutover、検証 | 業務仕様 |

### 5.5 modules構成

| module | resource | 出力 | lifecycle guard |
|---|---|---|---|
| conohavps/server | VPS Instance | server ID、public IP | production destroyを承認必須化 |
| conohavps/ssh-key | SSH鍵 | key ID | private keyをstateへ格納しない |
| conohavps/volume | boot/data Volume | volume ID | DB data volumeのprevent destroy相当 |
| conohavps/security-group | Security Group、Security Group Rule | group ID | productionのpublic 22/5432を拒否 |
| cloudflare/dns | zone参照、A/AAAA/CNAME record、TTL | FQDN、record ID | zone import必須、cutover前TTL上限300秒 |

ConoHa Provider moduleには上記5種以外を置かない。特にDNSをConoHa APIの`local-exec`で隠蔽せず、Cloudflare Providerの専用stateへ分離する。off-site Object Storageなどproviderを確定していない外部resourceはmodule内で暗黙に作成せず、`registers/external_resources.md`へ所有者、provider、resource ID、作成日時、設定checksum、復旧手順を記録する。

### 5.6 envs構成

- stagingとproductionでmoduleを共用し、値だけを分ける。
- production variablesはGitHub Environmentの非secret値とSOPS暗号化fileから生成する。
- `terraform.tfvars.example`に実ID、IP allowlist、credentialを記載しない。
- production applyはGitHub Environment承認とconcurrency groupを必須とする。

### 5.7 state分割

| state | 対象 | backend key | apply権限 |
|---|---|---|---|
| bootstrap | remote state保存先とCI identity | `bootstrap/terraform.tfstate` | 初期管理者 |
| shared-edge | Cloudflare DNS zone/record | `shared/edge.tfstate` | 承認済みCI/CD |
| staging | staging VPS一式 | `staging/openclaw.tfstate` | CI/CD |
| production | production VPS一式 | `production/openclaw.tfstate` | 承認済みCI/CD |

state backendはVPS本体と異なる保存先へ置き、versioning、encryption、public access拒否を有効にする。S3 lockfile互換性を競合試験し、失敗した場合はHCP Terraformまたは同等のlocking backendへ切り替える。

### 5.8 CI/CD構成

| workflow | trigger | 主な検証 | 書込権限 |
|---|---|---|---|
| `vps-validate.yml` | pull request | fmt、validate、test、TFLint、Trivy、Ansible lint、Compose config | なし |
| `vps-plan.yml` | 手動/staging branch | provider auth、plan、destroy検知 | plan artifactのみ |
| `image-release.yml` | tag | build、test、SBOM、scan、Cosign、GHCR push | registry |
| `vps-deploy.yml` | 手動 | signature、backup、migration、smoke、rollback | staging/production host |
| `dr-test.yml` | 月次 | clean restore、RPO/RTO、report | isolated staging |

### 5.9 package間契約

- Terraform outputからAnsible inventoryを生成し、手編集しない。
- AnsibleはCompose release directoryとsystemd unitまでを管理する。
- ComposeはGHCR digestをrelease manifestから受け取る。
- Backはnormal PostgreSQL接続、OIDC identity、secret provider、queue providerのinterfaceを提供する。
- Terraform repositoryはDB migration SQLを所有しない。

## 6. 未確定事項

- ConoHa Provider betaとCloudflare Providerのversion pinは段階0の試験時に確定する。
- state backendのlock互換性は実Object Storageで確認する。
- `*.ps1`とcross-platform scriptの実装言語はCI runnerと運用端末に合わせて実装タスク化時に決める。

## 7. 関連文書

- `infra_architecture_design.md`
- `security_design.md`
- `process_flow_design.md`
- `rtm.md`
