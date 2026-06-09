# QuickSuite Desktop SSO 部署指南

> 目标读者：第一次拿到这个包，要在自己的 AWS 账号里完整跑一遍。
> 假设你**懂基本 AWS 概念**（VPC / 子网 / IAM / Route53 / CloudFormation）但**没接触过 Keycloak / IdC 集成**。
>
> 全程预计：第一次 1.5–2 小时（Managed AD CFN ~30 分钟自己跑，CloudFront ~10 分钟）。

---

## 目录

1. [先确认我能用这套方案吗](#1-先确认我能用这套方案吗)
2. [准备前置资源](#2-准备前置资源)
3. [填 .env](#3-填-env)
4. [Phase 1：跑基础设施 deploy-infra.sh](#4-phase-1跑基础设施-deploy-infrash)
5. [Phase 2：在 Keycloak Admin UI 建 realm](#5-phase-2在-keycloak-admin-ui-建-realm)
6. [Phase 3：在 IdC 控制台建 SAML 应用](#6-phase-3在-idc-控制台建-saml-应用)
7. [Phase 4：跑 configure-keycloak.sh](#7-phase-4跑-configure-keycloaksh)
8. [Phase 5：在 Quick 控制台建 Extension Access](#8-phase-5在-quick-控制台建-extension-access)
9. [Phase 6：装 Quick Desktop 端到端验证](#9-phase-6装-quick-desktop-端到端验证)
10. [常见故障](#10-常见故障)
11. [清理 / 卸载](#11-清理--卸载)

---

## 1. 先确认我能用这套方案吗

✅ 适用场景：
- AWS 账号在 us-east-1，且 Quick / IdC 都准备装在 us-east-1
- 已经有 Amazon Quick 订阅，且 Quick 的 `AuthenticationType = IAM_IDENTITY_CENTER`
- 想给最终用户用 Amazon Quick **Desktop** 客户端做 SSO（不是 Web 端，Web 端原生 IdC 即可）
- 用户来源在 IdC 内置 directory（不是必须，但本指南按这个场景写）

❌ 不适用：
- Quick 是 IAM federation 或本地账号 backed —— 本部署链路依赖 IdC 的 SAML application；如果 Quick 是别的 identity type，请先重新订阅成 IdC backed
- 你的账号不是 AWS Organization master / delegated admin —— Managed AD 必须在 master 或 delegated admin
- 你的 region 不是 us-east-1 —— Quick Desktop 只支持 us-east-1

### 快速自检

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. Quick 是 IdC backed？
aws quicksight describe-account-subscription \
  --aws-account-id "$AWS_ACCOUNT_ID" --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,AccountSubscriptionStatus]' --output table
# 期望：IAM_IDENTITY_CENTER / ACCOUNT_CREATED

# 2. IdC 实例存在？
aws sso-admin list-instances --region us-east-1 --output table
# 应该有 1 条记录

# 3. 账号在 Org master？
aws organizations describe-organization \
  --query 'Organization.[MasterAccountId,Id]' --output text
# 第 1 个值应该等于 $AWS_ACCOUNT_ID
```

3 项都满足才往下走。

---

## 2. 准备前置资源

下面这些资源**不是本部署包创建**，是必须**事先准备好**的。

### 2.1 工具

```bash
# 工作机本地需要
aws --version    # AWS CLI v2
python3 --version    # ≥ 3.8（脚本用）
curl --version
```

### 2.2 Service Quota（重要，别忘）

CloudFront origin-facing prefix list 当前有 ~45 条 entry，单条 SG ingress 引用按 entry 数计入配额。
默认 60/SG，加上其它规则容易超。**先提工单提到 200**：

```
Service: VPC
Quota:   L-0EA8095F  (Inbound or outbound rules per security group)
请求值:  200
```

提交后通常 1-3 个工作日批。批了再继续。

### 2.3 网络（VPC + 子网）

需要：
- 1 个 VPC，带 NAT Gateway（私有子网能出公网拉镜像）
- ≥ 2 个**私有子网**，不同 AZ（Aurora 跨 AZ）
- ≥ 2 个**公有子网**，不同 AZ（ALB 跨 AZ）
- ECS task 子网（私有）的 AZ 必须**至少一个**和公有子网 AZ 重合

最常见的坑：你有 1a/1b 私有子网，但 ALB 在 1a/1c → ECS 子网必须选 1a 那个，**不能选 1b**。

### 2.4 域名 + ACM 证书

- 域名（`example.com` 之类）已托管在 Route53 公网 hosted zone
- 决定两个域名：
  - `KEYCLOAK_DOMAIN`（用户访问）：例 `keycloak.example.com`
  - `ORIGIN_ALIAS_NAME`（CloudFront 回源用）：例 `kc-origin.example.com`
- ACM 证书（**必须在 us-east-1**）覆盖上面两个域名 —— 最简单做一张通配 `*.example.com`

```bash
# 申请通配证书（之后 DNS 验证）
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region us-east-1
# 跟随 ACM 控制台说明完成 DNS 验证，等到 Status=ISSUED
```

### 2.5 Quick subscription 可用

如果还没订阅 Quick，先去 https://aws.amazon.com/quick/ 订阅 Enterprise edition，
home region 选 us-east-1，identity 选 IAM Identity Center。

---

## 3. 填 .env

```bash
cp .env.example .env
chmod 600 .env       # 含密码，限制权限
vim .env             # 把所有空值填上（看下面对照表）
```

| 变量 | 怎么得到 |
|---|---|
| `AWS_ACCOUNT_ID` | `aws sts get-caller-identity --query Account --output text` |
| `VPC_ID` | 控制台 / `aws ec2 describe-vpcs` |
| `PRIVATE_SUBNET_1` / `PRIVATE_SUBNET_2` | 两个不同 AZ 的私有子网 |
| `PUBLIC_SUBNET_1` / `PUBLIC_SUBNET_2` | 两个不同 AZ 的公有子网 |
| `ECS_SUBNET` | 私有子网中和某个公有子网 AZ 相同的那个 |
| `AD_DOMAIN_NAME` / `AD_SHORT_NAME` | 自取，例 `corp.example.com` / `CORP` |
| `AD_ADMIN_PASSWORD` | 自设，强密码 |
| `ROUTE53_HOSTED_ZONE_ID` | 控制台或 `aws route53 list-hosted-zones` |
| `KEYCLOAK_DOMAIN` | 自取，例 `keycloak.example.com` |
| `ORIGIN_ALIAS_NAME` | 自取，例 `kc-origin.example.com` |
| `CERTIFICATE_ARN` | ACM 控制台 / `aws acm list-certificates --region us-east-1` |
| `KEYCLOAK_ADMIN_PASSWORD` | 自设，强密码 |
| `DB_MASTER_PASSWORD` | 自设，强密码 |
| `IDC_INSTANCE_ARN` / `IDC_IDENTITY_STORE_ID` | `aws sso-admin list-instances --region us-east-1` |
| `QUICK_NAMESPACE` | `aws quicksight describe-account-subscription --aws-account-id $AWS_ACCOUNT_ID --region us-east-1 --query 'AccountInfo.AccountName' --output text` |
| `QUICK_AUTHENTICATION_TYPE` | 同上一行查 `.AuthenticationType`，应该是 `IAM_IDENTITY_CENTER` |

剩下没列出来的（`KEYCLOAK_REALM`、`KEYCLOAK_OIDC_CLIENT_ID`、`KEYCLOAK_IDP_ALIAS`、`ALB_INGRESS_PREFIX_LIST_ID` 等）保持默认就行。

`IDC_SAML_APPLICATION_ARN`、`AD_DIRECTORY_ID`、`AD_DNS_IP_*`、`ALB_DNS_NAME` 等部署期回填，**先留空**。

---

## 4. Phase 1：跑基础设施 deploy-infra.sh

```bash
./deploy-infra.sh
```

这一步会：
1. **Pre-flight 检查**：CLI / 账号 / region / ACM 证书 / Route53 zone
2. **CFN 部署 `quicksuite-managed-ad`**（**Managed AD 首次创建 ~30 分钟**，等就行）
3. **CFN 部署 `quicksuite-keycloak`**（ECS + Aurora + ALB，~10 分钟）
4. **CFN 部署 `quicksuite-keycloak-cf`**（CloudFront + 内部 alias 记录，~5–10 分钟）
5. **更新 Route53**：`KEYCLOAK_DOMAIN` 指向 CloudFront
6. **轮询健康检查**：等 `https://<KEYCLOAK_DOMAIN>/realms/master` 返回 200

期间 `deploy-infra.sh` 会把 AD DNS IP / ALB DNS / CloudFront 域名等回填进 `.env`。

成功后能看到：

```
Infra deploy complete.
 Useful endpoints:
   Admin UI       : https://keycloak.example.com/admin
   OIDC discovery : https://keycloak.example.com/realms/quicksuite/.well-known/openid-configuration
   ALB DNS        : keycloak-alb-xxx.us-east-1.elb.amazonaws.com
   CloudFront     : dxxxxxx.cloudfront.net (id Exxxxxx)
```

测一下浏览器能不能打开 `https://<KEYCLOAK_DOMAIN>/admin`，能看到 Keycloak 登录页就 OK。

> Keycloak 首次启动要跑 Liquibase migration（Aurora 建 schema），ALB target 健康检查可能要 5–10 分钟才转绿。
> 用 `aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg --region us-east-1 --query 'TargetGroups[0].TargetGroupArn' --output text) --region us-east-1` 观察。

---

## 5. Phase 2：在 Keycloak Admin UI 建 realm

`configure-keycloak.sh` 要在 realm 已存在的前提下跑，所以这一步必须手动建一次。

详细步骤见 **[03-keycloak-realm-config.md](./03-keycloak-realm-config.md) §1**。

简版：浏览器打开 `https://<KEYCLOAK_DOMAIN>/admin`，用 `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` 登录，左上角下拉 → **Create Realm**，realm name 填 `quicksuite`（如果 `.env` 里改了，按 `.env` 的值），创建。

---

## 6. Phase 3：在 IdC 控制台建 SAML 应用

详细步骤见 **[04-identity-center-setup.md](./04-identity-center-setup.md)**。

简版：
1. IdC console → **Applications → Customer managed → Add application**
2. **I have an application I want to set up** → **SAML 2.0**
3. Display name: `Amazon Quick Desktop via Keycloak`
4. **Download** IdC SAML metadata，存为 `idc-saml-metadata.xml`，放在本目录
5. **Application metadata → Manually type your metadata values**：
   - ACS URL: `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/broker/<KEYCLOAK_IDP_ALIAS>/endpoint`
   - SAML audience: `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>`
6. Submit
7. **Edit attribute mappings**：Subject = `${user:email}`（format `emailAddress`），加 `email`/`firstName`/`lastName`
8. **Assign users and groups**：把要用 Quick Desktop 的真实用户加进来

---

## 7. Phase 4：跑 configure-keycloak.sh

回 shell：

```bash
ls -la idc-saml-metadata.xml    # 确认 metadata 存在
./configure-keycloak.sh
```

脚本会幂等地建：
- SAML Identity Provider（从 metadata 导入）
- 3 个 SAML attribute mapper
- OIDC public client（PKCE S256，redirect_uri=localhost:18080）
- 把 default scopes / optional scopes 配好

跑完跑验证：

```bash
./verify-oidc.sh
```

期望最后看到：
```
OK — Keycloak side looks good.
```

如果失败：
- `[3]` 客户端检查 fail → `configure-keycloak.sh` 没建对，重跑
- `[4]` SAML IdP 检查 fail → `idc-saml-metadata.xml` 不对，回 Phase 3 重新下载

---

## 8. Phase 5：在 Quick 控制台建 Extension Access

详细步骤见 **[05-quick-extension-access.md](./05-quick-extension-access.md)**。

⚠️ **保存前再核一遍**，控制台明确说创建后不可编辑。

简版：Quick 管理控制台 → **Permissions → Extension access → Add extension access** → **Desktop application for Quick**：

| 字段 | 值（替换 `<...>` 为 .env 实际值） |
|---|---|
| Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
| Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
| Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
| JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
| Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>` |

然后 **Connect apps and data → Extensions → Add extension** 把这条 Extension Access 关联上。

---

## 9. Phase 6：装 Quick Desktop 端到端验证

1. https://aws.amazon.com/quick/download/ 下载 Quick Desktop
2. 装好打开 → **Enterprise login**
3. 输入 Quick 账号名（即 `QUICK_NAMESPACE`）
4. 浏览器跳到 Keycloak 登录页 → 看到 **Sign in with AWS IAM Identity Center** 按钮
5. 点按钮 → 跳到 IdC 登录页 → 用 Phase 3 §3 assign 过的用户登录
6. 一路 302 回 Desktop，进 Quick 主界面

✅ 看到 Quick 主界面 = SSO 链路打通。

---

## 10. 常见故障

| 现象 | 大概率原因 / 排查 |
|---|---|
| `deploy-infra.sh` Phase 1 报 ACM 证书不对 | 证书不在 us-east-1 / 不覆盖 KEYCLOAK_DOMAIN 或 ORIGIN_ALIAS_NAME |
| `deploy-infra.sh` Phase 1 报子网不对 | ECS_SUBNET 的 AZ 不在 PUBLIC_SUBNET_1/2 的 AZ 里 |
| Keycloak Admin UI 502 / 504 | ECS task 还在跑 Liquibase（首次部署 5-10 分钟），看 `aws elbv2 describe-target-health` |
| Keycloak 登录页没显示 SAML 按钮 | `configure-keycloak.sh` 没跑 / 跑失败，看 `./inspect-keycloak.sh` 输出里 `[7] SAML IdP` 段 |
| 点 SAML 按钮报 "Invalid SAML Response" | IdC ACS URL 路径里的 alias 和 `KEYCLOAK_IDP_ALIAS` 不一致 |
| IdC 登录后 Keycloak 报 "Could not find email address" | IdC application 的 attribute mapping 没配 email，或 Format 写错 |
| Keycloak 重定向回 Desktop 但 Desktop 报 `redirect_mismatch` | OIDC client redirect URI 不是精确的 `http://localhost:18080`（不能加路径斜杠） |
| Desktop 报 "User not found" | Quick 内 user 的 email 和登录的 IdC user email 不一致（注意大小写） |
| Desktop 提示 token 过期太快 | `offline_access` 没在 Quick Extension Access 的 scope 里，或 Keycloak client 没配为 Optional Client Scope |

每一条详细排查在对应的 `0[345]-*.md` 文件最后的 **故障排查** 段。

---

## 11. 清理 / 卸载

按**反序**删 stack：

```bash
# 1. Quick 控制台 → Extension access / Extensions：手动删
# 2. IdC 控制台 → Applications → Customer managed → 删 SAML application
# 3. Route53 hosted zone：手动删 KEYCLOAK_DOMAIN 的 A 记录
# 4. CFN stacks（顺序很重要：CF → Keycloak → AD）
aws cloudformation delete-stack --stack-name quicksuite-keycloak-cf --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak-cf --region us-east-1

aws cloudformation delete-stack --stack-name quicksuite-keycloak --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak --region us-east-1
# Aurora 默认 DeletionPolicy=Snapshot，会留一个 final snapshot；不需要的话事后手动删

aws cloudformation delete-stack --stack-name quicksuite-managed-ad --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-managed-ad --region us-east-1

# 5. 还原 VPC DHCP options（CFN stack 删的时候已经回滚 association，但 DHCP options set 本身可能要手删）
# 6. ACM 证书：如果不再用了手动删
```

> 注意：删 IdC SAML application 不会影响 IdC 内置 directory 的用户和其他 application 的 assignment，
> 这套架构本来就刻意不动 IdC identity source。
