# Step 3 — Keycloak Realm 配置

> 大部分 Keycloak 配置由 `configure-keycloak.sh` 脚本完成（SAML IdP + 属性 mapper + OIDC public client）。
> 本文档只覆盖**必须手动做**的两件事：
>   1. 首次创建 realm（脚本要在 realm 已存在的前提下跑）
>   2. 完成后做端到端浏览器验证（如果 Quick Desktop 端报错，回这里看登录页）

## 0. 前置条件

- 基础设施 stacks 已部署（`./deploy-infra.sh` 跑完）
- 可访问 `https://<KEYCLOAK_DOMAIN>/admin`（替换为 `.env` 里的 `KEYCLOAK_DOMAIN`）
- IdC SAML application 已建（Step 4 完成），`idc-saml-metadata.xml` 已下载到本目录

## 1. 首次创建 Realm（手动）

1. 浏览器打开 `https://<KEYCLOAK_DOMAIN>/admin`
2. 用 `.env` 里的 `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` 登录
3. 左上角 realm 选择器 → **Create Realm**
4. **Realm name** 填 `.env` 里 `KEYCLOAK_REALM` 的值（默认 `quicksuite`）
5. 点 **Create**

### 调整基础设置

进 **Realm settings**：

- **Login** tab
  - User registration: **Off**
  - Forgot password: **Off**（密码由 IdC 管，不在 Keycloak 重置）
  - Login with email: **On**
  - Duplicate emails: **Off**
- **Tokens** tab
  - Access Token Lifespan: `5 Minutes`
  - SSO Session Idle: `30 Minutes`
  - SSO Session Max: `10 Hours`
- **Security defenses → Brute Force Detection**
  - Enabled: **Off**（本 realm 没有本地用户，brute force 检测意义不大）

## 2. 自动配置 SAML IdP + OIDC client

回到 shell：

```bash
./configure-keycloak.sh
```

脚本会幂等地建 / 更新：
- SAML Identity Provider（alias = `KEYCLOAK_IDP_ALIAS`，从 `idc-saml-metadata.xml` 导入）
- 3 个 SAML attribute mapper：`email` / `firstName` / `lastName`
- OIDC public client（id = `KEYCLOAK_OIDC_CLIENT_ID`，PKCE S256，redirect_uri `http://localhost:18080`）

成功后跑：

```bash
./verify-oidc.sh
```

应该看到 `OK — Keycloak side looks good.`

## 3. 浏览器自检（可选但推荐）

跳过 Quick Desktop，直接用浏览器走一遍登录链路验证 SAML brokering 通畅：

1. 打开 `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/account`
2. 应该看到 **Sign in with AWS IAM Identity Center** 按钮
3. 点按钮 → 跳到 IdC 登录页
4. 用一个**已 assign 给 IdC SAML application** 的用户登录（Step 4 §3 里 assign 的）
5. 登录成功后会回到 Keycloak account console

如果第 4 步报错，常见原因：
- "User not assigned to application" → 回 Step 4 §3 把对应用户加到 SAML application
- "Could not find email address" → IdC 那边 attribute mapping 里 email 没配对，回 Step 4 §2

## 4. （可选）保留 LDAP federation

如果你要让 Keycloak 同时给其他应用做 IdP 并接 Managed AD，按下面流程加 LDAP
federation。**Quick Desktop SSO 链路完全不依赖这一步**。

`User federation` → **Add LDAP providers** → **LDAP**：

| 字段 | 值 |
|---|---|
| Console display name | `managed-ad` |
| Vendor | **Active Directory** |
| Connection URL | `ldap://<AD_DNS_IP_1>:389 ldap://<AD_DNS_IP_2>:389` |
| Bind type | `simple` |
| Bind DN | `CN=Admin,OU=Users,OU=<AD_SHORT_NAME>,DC=corp,DC=example,DC=com`（按你的域名替换） |
| Bind credentials | `<AD_ADMIN_PASSWORD>` |
| Edit mode | **READ_ONLY** |
| Users DN | `OU=Users,OU=<AD_SHORT_NAME>,DC=corp,DC=example,DC=com` |
| Username LDAP attribute | `sAMAccountName` |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |

> Quick Desktop SSO 链路里**不会**用这些 LDAP 同步过来的用户做密码校验。
> 密码归 IdC 管，Keycloak 这个 realm 唯一登录入口是 SAML IdP `iam-identity-center`。
