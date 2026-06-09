# QuickSuite Desktop SSO 部署指南（双场景）

> 目标读者：第一次拿到这个包，要在自己的 AWS 账号里把 **Amazon Quick Desktop SSO**
> 跑通。假设懂基本 AWS 概念（VPC / 子网 / IAM / Route53 / CloudFormation / Console
> 操作）但**没接触过 Keycloak / IdC / Managed AD 集成**。
>
> 全程预计：1.5–2.5 小时。最大头是 Managed AD 首次创建 ~30 分钟。

## 目录

1. [先选场景](#1-先选场景)
2. [前置资源（两场景共用）](#2-前置资源两场景共用)
3. [填 .env](#3-填-env)
4. [Phase 1：跑基础设施 deploy-infra.sh](#4-phase-1跑基础设施-deploy-infrash)
5. [Phase 2：在 Keycloak Admin UI 建 realm](#5-phase-2在-keycloak-admin-ui-建-realm)
6. [Phase 3：身份后端配置（按场景分支）](#6-phase-3身份后端配置按场景分支)
7. [Phase 4：跑 configure-keycloak.sh](#7-phase-4跑-configure-keycloaksh)
8. [Phase 5：在 Quick 控制台建 Extension Access](#8-phase-5在-quick-控制台建-extension-access)
9. [Phase 6：装 Quick Desktop 端到端验证](#9-phase-6装-quick-desktop-端到端验证)
10. [常见故障](#10-常见故障)
11. [清理 / 卸载](#11-清理--卸载)

---

## 1. 先选场景

| | 场景 1 (`SCENARIO=idc`) | 场景 2 (`SCENARIO=ad`) |
|---|---|---|
| Quick 账号的 identity type | IAM Identity Center | Active Directory |
| 用户/组定义在哪 | IdC 内置 directory | AWS Managed Microsoft AD |
| 密码权威 | IdC | AD |
| Keycloak 角色 | OIDC↔SAML identity broker | OIDC + LDAP federation 到 AD |
| AD 是否必需 | **可选**（不要可省 ~$88/月） | **必需** |
| 月成本（基线） | ~$192 | ~$280（含 AD Standard） |
| 适合 | 已用 IdC 做 workforce SSO；想保留现有 IdC user/group | AD 已是 single source of truth；不想引入 IdC 这一层 |

### 不能用本部署包的情况

- AWS region 不是 us-east-1（CloudFront ACM + Quick Desktop 限制）
- 账号不在 AWS Organization master / delegated admin（场景 2 的 Managed AD 必须在）
- 场景 1：现有 Quick 账号不是 IdC backed
- 场景 2：现有 Quick 账号不是 AD backed（或愿意 unsubscribe 重订阅）

```bash
# 自检：IdC 是否启用、Quick 是否已订阅
aws sso-admin list-instances --region us-east-1
aws quicksight describe-account-subscription \
  --aws-account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,AccountSubscriptionStatus]' --output table
```

---

## 2. 前置资源（两场景共用）

### 2.1 工具

```bash
aws --version       # AWS CLI v2
python3 --version   # ≥ 3.8
curl --version
```

### 2.2 Service Quota（重要）

CloudFront origin-facing prefix list 引用按 list 的 entry 数计入 SG 配额。
默认 60/SG 容易超，**先提工单提到 200**：

```
Service: VPC
Quota:   L-0EA8095F  (Inbound or outbound rules per security group)
请求值:  200
```

通常 1-3 工作日批。批了再继续。

### 2.3 网络

- 已有 VPC，带 NAT Gateway（私有子网能出公网拉镜像）
- 私有子网 ≥ 2 个跨 AZ（Aurora 子网组要求）
- 公有子网 ≥ 2 个跨 AZ（ALB 跨 AZ）
- ECS task 子网（私有）的 AZ 必须**至少一个**和公有子网 AZ 重合

### 2.4 域名 + ACM 证书

- 域名（`example.com`）已托管在 Route53 公网 hosted zone
- 决定两个域名：
  - `KEYCLOAK_DOMAIN`：用户访问，例 `keycloak.example.com`
  - `ORIGIN_ALIAS_NAME`：CloudFront 回源 SNI 用，例 `kc-origin.example.com`
- ACM 证书（**必须 us-east-1**）覆盖上面两个域名 —— 最简单做一张通配 `*.example.com`

```bash
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region us-east-1
# 跟随控制台完成 DNS 验证，等 Status=ISSUED
```

### 2.5 Quick subscription

如果还没订阅 Quick，先去 https://aws.amazon.com/quick/ 订阅 Enterprise edition，
home region 选 us-east-1。**identity type 选错可以，反正后面按场景重订阅**。

---

## 3. 填 .env

```bash
cp .env.example .env
chmod 600 .env
vim .env
```

**每个变量怎么得到**见 `.env.example` 注释。两场景共用大部分变量，差异：

| 变量 | 场景 1 | 场景 2 |
|---|---|---|
| `SCENARIO` | `idc` | `ad` |
| `IDC_INSTANCE_ARN` / `IDC_IDENTITY_STORE_ID` | 必填 | 留空 |
| `AD_TEST_USER_EMAIL` / `AD_TEST_USER_PASSWORD` | 留空 | 必填（任意有效邮箱+强密码） |
| `QUICK_AUTHENTICATION_TYPE` | `IAM_IDENTITY_CENTER` | `ACTIVE_DIRECTORY` |

`AD_DIRECTORY_ID`、`AD_DNS_IP_*`、`ALB_DNS_NAME`、`CLOUDFRONT_*`、`IDC_SAML_APPLICATION_ARN`
都是部署期回填，**先留空**。

---

## 4. Phase 1：跑基础设施 deploy-infra.sh

```bash
./deploy-infra.sh
```

会做：
1. **Pre-flight 检查**（CLI / 账号 / region / ACM 证书 / Route53 zone）
2. **CFN 部署 `quicksuite-managed-ad`**（首次 ~30 分钟）
3. **CFN 部署 `quicksuite-keycloak`**（~10 分钟）
4. **CFN 部署 `quicksuite-keycloak-cf`**（~5–10 分钟）
5. **更新 Route53**：`KEYCLOAK_DOMAIN` 指向 CloudFront
6. **轮询健康检查**：等 Keycloak admin 端点 200

> 场景 1 如果你**不想花 Managed AD 的钱**：可以直接在 `01-managed-ad.yaml` 上手动跳过
> 部署，把 `02-keycloak-infra.yaml` 的 `ManagedADDnsIp1/2` 改成 dummy 值（如
> `10.0.0.1` / `10.0.0.2`），LDAP federation 不必跑通即可。但当前 `deploy-infra.sh`
> 默认部署所有 stack；要省 AD 钱就手工分步部 stack 2 / 2b。

成功后能打开 `https://<KEYCLOAK_DOMAIN>/admin` 看到 Keycloak 登录页。

> Keycloak 首次启动跑 Liquibase migration（5–10 分钟）。看 ALB target health：
> ```bash
> aws elbv2 describe-target-health --region us-east-1 \
>   --target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg --region us-east-1 \
>     --query 'TargetGroups[0].TargetGroupArn' --output text)
> ```

---

## 5. Phase 2：在 Keycloak Admin UI 建 realm

`configure-keycloak.sh` 要求 realm 已存在。手动建一次：

1. 浏览器打开 `https://<KEYCLOAK_DOMAIN>/admin`
2. 用 `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` 登录
3. 左上角下拉 → **Create Realm** → `quicksuite`（或 `.env` 里 KEYCLOAK_REALM 的值）→ Create

详细 Realm settings 见 `03-keycloak-realm-config.md` §1。

**场景 2 还要做**：在该 realm 里加 LDAP federation，详见 `03-keycloak-realm-config.md` §2。

---

## 6. Phase 3：身份后端配置（按场景分支）

### 场景 1（idc）：跟随 [04a-identity-center-setup.md](./04a-identity-center-setup.md)

简版：
1. IdC console → **Applications → Customer managed → Add application** → SAML 2.0
2. Display name: `Amazon Quick Desktop via Keycloak`
3. 下载 SAML metadata，存为 `idc-saml-metadata.xml` 放本目录
4. **Application metadata → Manually type**：
   - ACS URL: `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/broker/<KEYCLOAK_IDP_ALIAS>/endpoint`
   - SAML audience: `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>`
5. **Edit attribute mappings**：Subject = `${user:email}` (format `emailAddress`)，加 `email/firstName/lastName`
6. **Assigned users and groups** → 把测试用户加进来

### 场景 2（ad）：跟随 [04b-ad-quick-setup.md](./04b-ad-quick-setup.md)

简版：
1. 启用 ds-data API：`aws ds enable-directory-data-access --directory-id "$AD_DIRECTORY_ID" --region us-east-1`
2. 在 `.env` 里填好 `AD_TEST_USER_EMAIL` / `AD_TEST_USER_PASSWORD`
3. 跑 `./ad-setup-quick.sh` 建 3 个 group + 1 个测试用户
4. **取消现有 Quick 订阅**（控制台 Manage Quick → Account settings → Unsubscribe）
5. **重新订阅 Quick Enterprise**，identity 选 **Active Directory**，绑定：
   - Admin Pro → `quickadmins`
   - Author Pro → `quickauthors`
   - Reader Pro → `quickreaders`
6. 把新的 Quick `ACCOUNT_NAME` 写回 `.env` 的 `QUICK_NAMESPACE`

---

## 7. Phase 4：跑 configure-keycloak.sh

```bash
# .env 里 SCENARIO 已经设好就直接：
./configure-keycloak.sh

# 或者临时切场景：
SCENARIO=idc ./configure-keycloak.sh
SCENARIO=ad  ./configure-keycloak.sh
```

`configure-keycloak.sh` 是幂等的，重跑安全。

跑完跑验证：

```bash
./verify-oidc.sh
```

期望最后看到：`OK — Keycloak side looks good.`

**场景 2 还可以跑额外的端到端 OIDC 测试**：

```bash
./test-keycloak-ldap-login.sh
```

这个脚本会：
- 临时打开 `directAccessGrantsEnabled` 在 OIDC client 上
- 用 `quicktest1` + AD 密码跑 OIDC password grant
- 解 id_token 看 email/given_name/family_name 是否齐全
- 退出前自动关回 `directAccessGrantsEnabled`

期望看到：`PASS — Keycloak LDAP federation works for quicktest1 and id_token contains email.`

---

## 8. Phase 5：在 Quick 控制台建 Extension Access

详细见 [05-quick-extension-access.md](./05-quick-extension-access.md)。**两场景填一样的 OIDC endpoints**：

| 字段 | 值（替换 `<...>`） |
|---|---|
| Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
| Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
| Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
| JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
| Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>`（默认 `amazon-quick-desktop`） |

⚠️ **保存前再核一遍**，控制台说创建后不能改。

---

## 9. Phase 6：装 Quick Desktop 端到端验证

1. https://aws.amazon.com/quick/download/ 下载 Quick Desktop（macOS / Windows 10+）
2. 装好打开 → **Enterprise login**
3. 输入 Quick 账号名（`QUICK_NAMESPACE`）
4. 浏览器跳到 Keycloak 登录页：

| 场景 | 看到什么 |
|---|---|
| 1 (idc) | "Sign in with AWS IAM Identity Center" 按钮 → 点了跳 IdC 登录 |
| 2 (ad) | username/password 表单 → 输 AD 用户名 + 密码 |

5. 一路 302 回 Desktop，进 Quick 主界面 ✅

---

## 10. 常见故障

### 通用
| 现象 | 排查 |
|---|---|
| `deploy-infra.sh` 报 ACM 证书不对 | 证书不在 us-east-1 / 不覆盖 KEYCLOAK_DOMAIN 或 ORIGIN_ALIAS_NAME |
| `deploy-infra.sh` 报子网不对 | ECS_SUBNET 的 AZ 不在 PUBLIC_SUBNET_1/2 的 AZ 里 |
| Keycloak Admin UI 502 / 504 | ECS task 还在跑 Liquibase migration（5-10 分钟），看 `aws elbv2 describe-target-health` |
| Quick Desktop `redirect_mismatch` | OIDC client redirect URI 不是精确的 `http://localhost:18080`（不能加路径斜杠） |
| Quick Desktop "User not found" | Quick 内 user 的 email 和登录的 IdP user email 不一致（注意大小写） |
| 客户端 token 过期太快 | `offline_access` 没在 scope 里，看 Quick Extension Access 配置 |

### 场景 1 (idc)
| 现象 | 排查 |
|---|---|
| Keycloak 没显示 SAML 按钮 | `configure-keycloak.sh` 没跑 / SCENARIO != idc / metadata 文件不存在 |
| 点 SAML 按钮报 "Invalid SAML Response" | IdC ACS URL 路径里的 alias 和 `KEYCLOAK_IDP_ALIAS` 不一致 |
| IdC 登录后 Keycloak 报 "Could not find email address" | IdC application 的 attribute mapping 没配 email，或 Format 写错 |

### 场景 2 (ad)
| 现象 | 排查 |
|---|---|
| Keycloak 登录页还有 SAML 按钮 | `SCENARIO=ad ./configure-keycloak.sh` 重跑，或手动到 Identity providers 禁用 |
| AD 用户登 Keycloak 提示 invalid credentials | 密码错（含 % 等特殊字符在某些表单出问题）；或 LDAP federation 没配；用 `inspect-keycloak-ldap.sh` 排查 |
| Quick Desktop 拿到 token 后报 user not found | AD `mail` 属性 ≠ Quick user email；用 `aws ds-data describe-user` 看 mail，不一致就修 |
| `ad-setup-quick.sh` 创建一堆数字 group | 你改了脚本把 `QUICK_GROUPS` 变量名换成 `GROUPS`，`GROUPS` 在 bash 是只读内置变量，不要用这名字 |
| 订阅 Quick 时 group 下拉显示 "No options" | 框里输 `quick` 触发模糊匹配，别输 placeholder |

更详细的故障定位指令在每个 `0[345]b]-*.md` 文件最后的 **故障排查** 段。

---

## 11. 清理 / 卸载

按反序：

```bash
# 1. Quick 控制台 → Extension access / Extensions：手动删
# 2. 场景 1: IdC 控制台 → Applications → Customer managed → 删 SAML application
#    场景 2: AD 用户/组（可选；ds-data delete-user / delete-group）
# 3. Route53: 手动删 KEYCLOAK_DOMAIN 的 A 记录
# 4. CFN stacks（顺序: CF → Keycloak → AD）
aws cloudformation delete-stack --stack-name quicksuite-keycloak-cf --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak-cf --region us-east-1

aws cloudformation delete-stack --stack-name quicksuite-keycloak --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak --region us-east-1
# Aurora 默认 DeletionPolicy=Snapshot，会留 final snapshot

aws cloudformation delete-stack --stack-name quicksuite-managed-ad --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-managed-ad --region us-east-1

# 5. ACM 证书：不再用了手动删
```
