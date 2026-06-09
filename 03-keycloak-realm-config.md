# Step 3 — Keycloak Realm 配置

> Keycloak 大部分配置由 `configure-keycloak.sh` 自动完成（OIDC public client，
> 以及场景 1 的 SAML IdP）。本文档覆盖**必须手动做**的事，按场景分。

## 场景路径速查

| 步骤 | 场景 1 (idc) | 场景 2 (ad) |
|---|---|---|
| 1. 创建 realm `quicksuite` | ✅ | ✅ |
| 2. LDAP federation 连 Managed AD | 可选（保留给将来） | **必需**（密码权威 + 用户来源） |
| 3. 跑 `configure-keycloak.sh` | ✅（建 SAML IdP + OIDC client） | ✅（禁用 SAML IdP + 建 OIDC client） |
| 4. 浏览器自检 | ✅ | ✅ |

---

## 0. 前置条件

- 基础设施 stacks 已部署（`./deploy-infra.sh` 跑完）
- 可访问 `https://<KEYCLOAK_DOMAIN>/admin`
- **场景 1**: Step 4a 已完成，`idc-saml-metadata.xml` 已下载到本目录
- **场景 2**: Step 4b 已完成，AD 用户/组已建好，Quick 已重订阅为 AD-backed

---

## 1. 首次创建 Realm（两个场景都要做）

1. 浏览器打开 `https://<KEYCLOAK_DOMAIN>/admin`
2. 用 `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD` 登录
3. 左上角 realm 选择器 → **Create Realm**
4. **Realm name** 填 `KEYCLOAK_REALM` 的值（默认 `quicksuite`）
5. 点 **Create**

### 调整基础设置（Realm settings）

- **Login** tab
  - User registration: **Off**
  - Forgot password: **Off**
  - Login with email: **On**
  - Duplicate emails: **Off**
- **Tokens** tab
  - Access Token Lifespan: `5 Minutes`
  - SSO Session Idle: `30 Minutes`
  - SSO Session Max: `10 Hours`

---

## 2. LDAP User Federation（连接 Managed AD）

> **场景 2 必需**（密码归 AD 管，Keycloak 通过 LDAP 校验）。
> **场景 1 可选**（如果想保留给将来其他应用做 IdP；不做也能跑通 Quick Desktop SSO）。

`User federation` → **Add LDAP providers** → **LDAP**

### 2.1 General options

| 字段 | 值 |
|---|---|
| Console display name | `managed-ad` |
| Vendor | **Active Directory** |

### 2.2 Connection and authentication settings

| 字段 | 值 |
|---|---|
| Connection URL | `ldap://<AD_DNS_IP_1>:389 ldap://<AD_DNS_IP_2>:389` |
| Enable StartTLS | Off |
| Use Truststore SPI | `Only for ldaps` |
| Connection pooling | On |
| Connection timeout | `10000` (ms) |
| Bind type | `simple` |
| Bind DN | `CN=Admin,OU=Users,OU=<AD_SHORT_NAME>,<DC=corp,DC=example,DC=com>`（按你的 AD_DOMAIN_NAME 拆 DC） |
| Bind credentials | `<AD_ADMIN_PASSWORD>` |

点 **Test connection** → `Success` / **Test authentication** → `Success`。

### 2.3 LDAP searching and updating

| 字段 | 值 |
|---|---|
| Edit mode | **READ_ONLY** |
| Users DN | `OU=Users,OU=<AD_SHORT_NAME>,<DC=corp,DC=example,DC=com>` |
| Username LDAP attribute | `cn`（或 `sAMAccountName`，需与 AD 实际一致；Managed AD 默认 cn ≈ sAMAccountName） |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |
| Search scope | `Subtree` |

### 2.4 Synchronization settings

| 字段 | 值 |
|---|---|
| Import users | On |
| Sync registrations | Off |
| Periodic full sync | On / `604800` 秒（7 天） |
| Periodic changed users sync | On / `86400` 秒（1 天） |

Save → Action → **Sync all users**。

### 2.5 LDAP attribute mappers（默认就够，确认存在即可）

进 LDAP provider → **Mappers** tab。Keycloak 默认 AD vendor 创建好了：

| Mapper | 类型 | 作用 |
|---|---|---|
| email | user-attribute | `user.email <- ldap.mail` |
| first name | user-attribute | `user.firstName <- ldap.givenName` |
| last name | user-attribute | `user.lastName <- ldap.sn` |
| username | user-attribute | `user.username <- ldap.cn` |
| groups | group-ldap-mapper | 组同步 |
| MSAD account controls | msad-user-account-control-mapper | 处理禁用/锁定 |

> ✅ **场景 2 必须确认 `email` mapper 存在**，否则 id_token 里的 `email` claim 会空，
> Quick Desktop 登不上。可以用 `./inspect-keycloak-ldap.sh` 跑一遍自检。

---

## 3. 自动配置 SAML IdP / OIDC client

```bash
# 场景 1
SCENARIO=idc ./configure-keycloak.sh

# 场景 2
SCENARIO=ad  ./configure-keycloak.sh
```

或者把 `SCENARIO` 直接写进 `.env`，脚本会自动读。

脚本做的事：

| 动作 | 场景 1 | 场景 2 |
|---|---|---|
| 从 `idc-saml-metadata.xml` 建 SAML IdP `iam-identity-center` | ✅ | ✗ |
| 加 SAML attribute mappers (email/firstName/lastName) | ✅ | ✗ |
| 禁用 SAML IdP（避免登录页冗余按钮） | ✗ | ✅ |
| 建 / 更新 OIDC public client `amazon-quick-desktop` | ✅ | ✅ |
| 把 OIDC client 配成 PKCE S256 + redirect_uri=localhost:18080 | ✅ | ✅ |

成功后跑：

```bash
./verify-oidc.sh
```

应该看到 `OK — Keycloak side looks good.`。

---

## 4. 浏览器自检

打开 `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/account`：

**场景 1** 应看到：
- 一个 **Sign in with AWS IAM Identity Center** 按钮
- 点按钮 → 跳到 IdC 登录页 → 用 IdC 用户密码登录 → 跳回 Keycloak account console

**场景 2** 应看到：
- 标准 username + password 表单（**不应该**有 SAML 按钮）
- 输入 AD 用户名（如 `quicktest1`）+ AD 密码 → 登录后进 Keycloak account console

如果场景 2 的登录页**还**显示 SAML 按钮，是 `configure-keycloak.sh` 没禁用成功，
重跑一次或者手动到 Identity Providers 里把 `iam-identity-center` 设为 disabled。

---

## 5. 进入下一步

跑 `05-quick-extension-access.md` 把 Keycloak OIDC endpoints 注册到 Quick 控制台，
然后装 Quick Desktop 端到端测。
