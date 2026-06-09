# 部署指南

中文 | [English](DEPLOYMENT.md)

从一个干净的 AWS 账号一步步部署 QuickSuite Desktop SSO + Keycloak 的完整手册。整体大约 1.5–2.5 小时，其中绝大部分是等 Managed AD CloudFormation stack 第一次创建。

> 子步骤手册（`03-...md` / `04a-...md` / `04b-...md` / `05-...md`）目前是英文版，作为本文档的实现细节参考。

## 目录

1. [选场景](#1-选场景)
2. [前置资源](#2-前置资源)
3. [配置 `.env`](#3-配置-env)
4. [Phase 1 — 部署基础设施](#4-phase-1--部署基础设施)
5. [Phase 2 — 初始化 Keycloak realm](#5-phase-2--初始化-keycloak-realm)
6. [Phase 3 — 配置身份后端](#6-phase-3--配置身份后端)
7. [Phase 4 — 串联 Keycloak](#7-phase-4--串联-keycloak)
8. [Phase 5 — 在 Quick 控制台注册 Extension Access](#8-phase-5--在-quick-控制台注册-extension-access)
9. [Phase 6 — Quick Desktop 端到端测试](#9-phase-6--quick-desktop-端到端测试)
10. [故障排查](#10-故障排查)
11. [清理](#11-清理)

---

## 1. 选场景

| | 场景 1 (`SCENARIO=idc`) | 场景 2 (`SCENARIO=ad`) |
|---|---|---|
| Quick 账号 identity type | IAM Identity Center | Active Directory |
| 用户 / 组定义在哪 | IdC 内置 directory | AWS Managed Microsoft AD |
| 密码权威 | IdC | AD |
| Keycloak 角色 | OIDC ↔ SAML identity broker | OIDC + LDAP federation 到 AD |
| 是否需要 Managed AD | 可选（不部署省 ~$88/月） | **必需** |
| 月成本（基线） | ≈ $193 | ≈ $280（Standard AD） |
| 适合 | 已经把 IdC 当 workforce SSO 入口 | AD 已经是 single source of truth |

### 不适用本部署包的情况

- AWS region 不是 `us-east-1`（CloudFront ACM + Quick Desktop 限制）
- 账号不在 AWS Organizations master 或 delegated admin（场景 2 必需）
- 场景 1 — 现有 Quick 账号不是 IdC backed
- 场景 2 — 现有 Quick 账号不是 AD backed（且无法 unsubscribe 重订阅）

```bash
# 自检
aws sso-admin list-instances --region us-east-1
aws quicksight describe-account-subscription \
  --aws-account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,AccountSubscriptionStatus]' --output table
```

---

## 2. 前置资源

### 本地工具链

| 工具 | 最低版本 | 用在哪 |
|------|---------|--------|
| `bash` | 3.2+（macOS / Linux 自带） | 所有脚本（`#!/usr/bin/env bash` shebang） |
| `python3` | 3.8+ | 脚本内联 JSON 解析（含 f-string） |
| `aws`（AWS CLI v2） | 2.15+ | 需要 `ds-data` 与较新的 `sso-admin` 子命令 |
| `curl` | 任意现代版本 | 调 Keycloak Admin REST 和 OIDC discovery |
| `git` | 任意 | clone 仓库 |
| **AWS Session Manager 插件** | 最新 | `aws ecs execute-command` 必需，`verify-ldap.sh` / `inspect-ad.sh` 用 |

`sed` / `awk` / `grep` / `tr` / `base64` / `find` 都是 macOS / Linux 自带的 coreutils。Windows 用户必须在 **WSL2** 或 Linux 虚拟机里跑 —— 原生 CMD / PowerShell 不解析 bash shebang。

安装 Session Manager 插件：

```bash
# macOS（Homebrew）
brew install --cask session-manager-plugin

# Ubuntu / Debian
curl -L "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
  -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb

# 自检
session-manager-plugin --version
```

跑任何脚本前先配置 AWS CLI 默认凭据：

```bash
aws configure              # 交互式
# 或者用环境变量：AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
aws sts get-caller-identity   # 确认是正确的账号
```

### AWS IAM 权限

部署会跨多个服务。最简单的做法是用 `AdministratorAccess`。对权限更严的环境，至少要：

| 服务 | 用途 |
|------|------|
| **CloudFormation** | `cloudformation:*` 部署 / 更新 / 删除三套 stack |
| **IAM** | 创建并 pass role 给 ECS task / RDS monitoring / Directory Service。`iam:CreateServiceLinkedRole`（ECS / DirectoryService / RDS） |
| **EC2 / VPC** | 读 VPC + 子网、管理 security group、管理 `AWS::EC2::DHCPOptions`（`01-managed-ad.yaml` 用） |
| **ECS** | `ecs:*` 作用于 cluster `keycloak-cluster`；**`ecs:ExecuteCommand`** 给 `verify-ldap.sh` / `inspect-ad.sh` |
| **RDS** | Aurora Serverless v2 cluster + instances + final snapshot |
| **Directory Service + Directory Service Data** | `ds:CreateMicrosoftAD`、`ds:DescribeDirectories`、`ds:ResetUserPassword`、`ds:EnableDirectoryDataAccess`；场景 2 还需要 `ds-data:*` |
| **Secrets Manager** | 创建 / 读取 3 个 secret（AD admin、Keycloak admin、Aurora master） |
| **Route 53** | hosted zone 上的 `ChangeResourceRecordSets` 与 `GetHostedZone` |
| **ACM** | 仅 `acm:DescribeCertificate`（证书本身预先存在 `us-east-1`） |
| **CloudFront** | 管理一个 distribution |
| **Cloud Map（Service Discovery）** | Keycloak Infinispan JGroups 用的 private namespace + service |
| **CloudWatch Logs** | 创建 / 写入日志组 `/ecs/keycloak` + Container Insights |
| **STS / Organizations** | `sts:GetCallerIdentity`、`organizations:DescribeOrganization`（pre-flight） |
| **IAM Identity Center** | `sso-admin:*` + `identitystore:*` —— 场景 1 only（Customer Managed SAML application） |
| **Amazon Quick（QuickSight）** | `quicksight:DescribeAccountSubscription`（pre-flight）；订阅、Extension Access 等操作需要 Quick Web 控制台的管理员级权限 |

场景 2 必须在 **AWS Organizations master account** 或 Directory Service **delegated administrator** 账号下跑 —— Managed AD 仅允许从这两类账号注入 IAM Identity Center。

### 服务配额

CloudFront origin-facing 托管 prefix list 单条引用按 list 当前 entry 数（~45）计入 SG 配额。默认 60/SG 不够，**先提工单调高**：

```
Service: VPC
Quota:   L-0EA8095F (Inbound or outbound rules per security group)
请求值:  200
```

通常 1–3 工作日批。

### 网络

| 资源 | 要求 |
|------|------|
| VPC | 已存在，含 NAT Gateway（私有子网能出公网拉镜像） |
| 私有子网 | ≥ 2 个，跨 AZ（Aurora 子网组要求） |
| 公有子网 | ≥ 2 个，跨 AZ（ALB 跨 AZ） |
| ECS task 子网 | 私有子网中 AZ 必须**至少**和某个公有子网重合，否则 ALB target 会被标 `unused` |

### 域名 + ACM 证书

- 已有 Route 53 公网 hosted zone
- 准备两个域名：
  - `KEYCLOAK_DOMAIN`：用户访问入口，例 `keycloak.example.com`
  - `ORIGIN_ALIAS_NAME`：CloudFront 回源 SNI 用，例 `kc-origin.example.com`
- ACM 证书（**必须 us-east-1**）覆盖以上两个域名 —— 最简单做一张通配 `*.example.com`：

```bash
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region us-east-1
# 控制台完成 DNS 验证，等到 Status=ISSUED
```

### Amazon Quick 订阅

如果还没订阅 Quick，去 <https://aws.amazon.com/quick/> 订阅 Enterprise edition，home region 选 `us-east-1`。订阅时 identity 选错没关系 —— 后续按场景重新订阅时会改正。

---

## 3. 配置 `.env`

```bash
git clone https://github.com/dzkd2007/keycloaks-Quick-Desktop-SSO.git
cd keycloaks-Quick-Desktop-SSO
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

`.env` 是所有脚本和 CFN 命令的唯一真相源。文件已加进 `.gitignore`。

按场景分的差异变量：

| 变量 | 场景 1 | 场景 2 |
|------|--------|--------|
| `SCENARIO` | `idc` | `ad` |
| `IDC_INSTANCE_ARN` / `IDC_IDENTITY_STORE_ID` | 必填 | 留空 |
| `AD_TEST_USER_EMAIL` / `AD_TEST_USER_PASSWORD` | 留空 | 必填 |
| `QUICK_AUTHENTICATION_TYPE` | `IAM_IDENTITY_CENTER` | `ACTIVE_DIRECTORY` |

`AD_DIRECTORY_ID`、`AD_DNS_IP_*`、`ALB_DNS_NAME`、`CLOUDFRONT_*`、`IDC_SAML_APPLICATION_ARN` 都是部署期回填，**先留空**。

---

## 4. Phase 1 — 部署基础设施

```bash
./deploy-infra.sh
```

orchestrator 跑 5 个阶段：

| 阶段 | 内容 | 时长 |
|------|------|------|
| Pre-flight | CLI / region / ACM / Route 53 检查 | 几秒 |
| CFN | `quicksuite-managed-ad`（`01-managed-ad.yaml`） | 首次 ≈ 30 分钟 |
| CFN | `quicksuite-keycloak`（`02-keycloak-infra.yaml`） | ≈ 10 分钟 |
| CFN | `quicksuite-keycloak-cf`（`02b-cloudfront.yaml`） | ≈ 5–10 分钟 |
| Route 53 | UPSERT alias，`KEYCLOAK_DOMAIN` → CloudFront | 几秒 |
| Healthcheck | 轮询 `https://<KEYCLOAK_DOMAIN>/realms/master/.well-known/openid-configuration` | 最多 10 分钟 |

> 场景 1 如果想完全跳过 Managed AD（省 ~$88/月），用 `aws cloudformation deploy` 单独部 `02-keycloak-infra.yaml` 和 `02b-cloudfront.yaml`，`ManagedADDnsIp1/2` 给 dummy 值（LDAP federation 不在 Desktop SSO 链路上，不会被用到）。

跑完会输出一段 summary，列出 Keycloak admin URL、OIDC discovery URL、ALB / CloudFront ID。打开 admin URL 应该能看到 Keycloak 登录页。

> 首次启动 Keycloak 跑 Liquibase migration，ALB target health 5–10 分钟才转 `healthy`。可以这样观察：
>
> ```bash
> aws elbv2 describe-target-health --region us-east-1 \
>   --target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg \
>     --region us-east-1 --query 'TargetGroups[0].TargetGroupArn' --output text)
> ```

---

## 5. Phase 2 — 初始化 Keycloak realm

`configure-keycloak.sh` 要求 realm 已存在，所以先手动建一次：

1. 打开 `https://<KEYCLOAK_DOMAIN>/admin`
2. 用 `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` 登录
3. 左上角 realm 下拉 → **Create Realm**
4. **Realm name** 填 `KEYCLOAK_REALM` 的值（默认 `quicksuite`）→ Create

按 [`03-keycloak-realm-config.md`](03-keycloak-realm-config.md) §1 应用推荐的 Realm settings。

**场景 2 还要做**：在该 realm 里加 LDAP federation —— 见 [`03-keycloak-realm-config.md`](03-keycloak-realm-config.md) §2。场景 1 可跳过，或为后续其他应用预先配上。

---

## 6. Phase 3 — 配置身份后端

| 场景 | 文档 |
|------|------|
| `idc` | [`04a-identity-center-setup.md`](04a-identity-center-setup.md) — 在 IAM Identity Center 创建 Customer Managed SAML 2.0 application 并下载 metadata。 |
| `ad`  | [`04b-ad-quick-setup.md`](04b-ad-quick-setup.md) — 用 Directory Service Data API 建 AD 组和测试用户，然后取消 Quick 订阅、改用 **Active Directory** identity 重新订阅。 |

场景 1 把下载的 SAML metadata 存为 `idc-saml-metadata.xml` 放在仓库根 —— `configure-keycloak.sh` 从这里读。

场景 2 重订阅完成后，更新 `.env` 里的 `QUICK_NAMESPACE`，并把 `QUICK_AUTHENTICATION_TYPE` 改成 `ACTIVE_DIRECTORY`。

---

## 7. Phase 4 — 串联 Keycloak

```bash
./configure-keycloak.sh
```

脚本读 `.env` 里的 `SCENARIO`，幂等。

| 动作 | 场景 1 (`idc`) | 场景 2 (`ad`) |
|------|:--:|:--:|
| 从 `idc-saml-metadata.xml` 创建 SAML IdP `iam-identity-center` | ✅ | — |
| 加 SAML attribute mappers (`email`、`firstName`、`lastName`) | ✅ | — |
| 禁用已有的 SAML IdP | — | ✅ |
| 创建 / 更新 OIDC public client `amazon-quick-desktop` | ✅ | ✅ |
| 配上 PKCE S256、redirect URI `http://localhost:18080`、scopes | ✅ | ✅ |

跑完做自检：

```bash
./verify-oidc.sh
```

期望最后看到 `OK — Keycloak side looks good.`。

场景 2 还可以跑端到端 OIDC password grant 测：

```bash
./test-keycloak-ldap-login.sh
```

脚本临时打开 OIDC client 的 `directAccessGrantsEnabled`，用 `quicktest1` 跑 password grant，解 `id_token` 检查 `email` / `given_name` / `family_name` 三个 claim 是否齐全，退出前自动恢复。期望输出 `PASS — Keycloak LDAP federation works for quicktest1 and id_token contains email.`。

---

## 8. Phase 5 — 在 Quick 控制台注册 Extension Access

详见 [`05-quick-extension-access.md`](05-quick-extension-access.md)。两个场景填一样的 OIDC endpoints（共享同一个 Keycloak realm + OIDC client）。

在 Amazon Quick 管理控制台：

1. **Permissions → Extension access → Add extension access**
2. 选 **Desktop application for Quick** → **Next**
3. 填以下 OIDC 字段并 **Add**：

   | 字段 | 值 |
   |---|---|
   | Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
   | Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
   | Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
   | JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
   | Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>`（默认 `amazon-quick-desktop`） |

4. **Connect apps and data → Extensions → Add extension** → 选刚创建的 Extension Access → Create

> Issuer URL **不要带** `/.well-known/openid-configuration` 后缀；Quick 控制台说创建后不可编辑，**保存前再核一遍**。

---

## 9. Phase 6 — Quick Desktop 端到端测试

1. <https://aws.amazon.com/quick/download/> 下载 Quick Desktop（macOS 12+ / Windows 10+）。
2. 启动应用，选 **Enterprise login**。
3. 输入 Quick 账号名（`QUICK_NAMESPACE`）。
4. 浏览器跳到 Keycloak 登录页：

   | 场景 | 期望看到 |
   |---|---|
   | 1 (`idc`) | 一个 **Sign in with AWS IAM Identity Center** 按钮，点了跳 IdC 登录 |
   | 2 (`ad`) | 标准 username + password 表单，输 AD 用户名（如 `quicktest1`）+ 密码 |

5. 登录成功后浏览器 302 回 `http://localhost:18080?code=...`，Desktop 用 PKCE 换 token，按 `email` claim 匹配 Quick 用户，进入 Quick 主界面。

---

## 10. 故障排查

### 通用

| 现象 | 可能原因 |
|------|---------|
| `deploy-infra.sh` 报 ACM 证书不对 | 证书不在 us-east-1 / 不覆盖 `KEYCLOAK_DOMAIN` 或 `ORIGIN_ALIAS_NAME` |
| `deploy-infra.sh` 报子网不对 | `ECS_SUBNET` 的 AZ 不在 `PUBLIC_SUBNET_1/2` 的 AZ 里 |
| Keycloak admin UI 502 / 504 | ECS task 还在跑 Liquibase migration（首次 5–10 分钟） |
| Quick Desktop `redirect_mismatch` | OIDC client 的 redirect URI 必须**精确**等于 `http://localhost:18080` |
| Quick Desktop "User not found" | `id_token.email` 与 Quick 内 user 不匹配（注意大小写） |
| Session 过期太快 | Quick Extension Access 的 scope 缺 `offline_access` |

### 场景 1 — IdC

| 现象 | 排查 |
|------|------|
| 登录页没有 SAML 按钮 | 确认 `SCENARIO=idc`，metadata 文件存在，且 `configure-keycloak.sh` 跑成功 |
| IdC 登录后报 "Invalid SAML Response" | IdC ACS URL 路径里的 alias 与 `KEYCLOAK_IDP_ALIAS` 不一致 |
| Keycloak 报 "Could not find email address" | IdC application 的 attribute mapping 缺 `email`，或 Format 写错 |

### 场景 2 — AD

| 现象 | 排查 |
|------|------|
| Keycloak 登录页还显示 SAML 按钮 | 重跑 `SCENARIO=ad ./configure-keycloak.sh`，或在 Identity providers 里手动禁用 |
| AD 用户登 Keycloak 报 invalid credentials | 密码错（特殊字符在某些 form 出问题）；LDAP federation 没配；用 `./inspect-keycloak-ldap.sh` 排查 |
| Quick Desktop 拿到 token 后 user not found | AD 的 `mail` ≠ Quick 内 user email；`aws ds-data describe-user` 看 mail，不一致就修 |
| `ad-setup-quick.sh` 创建数字命名的 group | 脚本被改成 `GROUPS=(...)` —— `GROUPS` 是 bash 内置只读变量，必须改名（如 `QUICK_GROUPS`） |
| Quick 订阅时 group 下拉 "No options" | 框里输 `quick` 触发模糊匹配，不要输占位符 |

每个 sub-doc 末尾都有针对性排查段落。

---

## 11. 清理

控制台手动操作先做，再倒序删 CFN：

```bash
# 1. Quick 控制台 — 删 Extension 和 Extension Access
# 2. 场景 1：IdC 控制台 → Applications → Customer managed → 删 SAML application
#    场景 2：可选清理 AD 测试用户/组（aws ds-data delete-*）
# 3. Route 53 — 删 KEYCLOAK_DOMAIN 的 A-alias 记录
# 4. CFN stacks（倒序）
aws cloudformation delete-stack --stack-name quicksuite-keycloak-cf --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak-cf --region us-east-1

aws cloudformation delete-stack --stack-name quicksuite-keycloak --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak --region us-east-1
# Aurora 是 DeletionPolicy: Snapshot，会留 final snapshot

aws cloudformation delete-stack --stack-name quicksuite-managed-ad --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-managed-ad --region us-east-1
# 5. 可选：删除不再使用的 ACM 证书
```

Route 53 hosted zone、VPC、NAT Gateway、Quick 订阅本来就不是模板创建的，本步骤不动。
