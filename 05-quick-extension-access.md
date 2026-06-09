# Step 5 — Amazon Quick 控制台：创建 Extension Access

> 这一步把 Keycloak 的 OIDC endpoints 告诉 Quick，让 Quick Desktop 客户端在用户
> 点 **Enterprise login** 时知道要去哪里跑 OIDC 流程。**两个场景都用同样的配置**
> （因为两个场景共享同一个 Keycloak realm + OIDC client）。
>
> 参考：[Setting up Amazon Quick on desktop for enterprise deployments](https://docs.aws.amazon.com/quick/latest/userguide/desktop-enterprise-setup.html)

## 0. 前置条件

- Step 3 已完成（`configure-keycloak.sh` 跑成功）
- Step 4a（场景 1）或 Step 4b（场景 2）已完成
- `./verify-oidc.sh` 看到 `OK — Keycloak side looks good.`

## 1. 在 Quick 管理控制台添加 Extension Access

1. 浏览器登录 Amazon Quick：
   - 场景 1：用 IdC 用户登入（IdC SAML application 已 assign 给你这个 user/group）
   - 场景 2：用 AD 用户名+密码登入（如 `quicktest1`）
2. 右上角用户名 → **Manage Quick**
3. 左侧 **Permissions** → **Extension access** → **Add extension access**
4. 选 **Desktop application for Quick** → **Next**

### 1.1 填 OIDC 端点

| 字段 | 值 |
|---|---|
| Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
| Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
| Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
| JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
| Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>` |

替换 `<...>` 为 `.env` 里的实际值，或从 `./verify-oidc.sh` 输出抄。

> ⚠️ Issuer URL **不要带** `/.well-known/openid-configuration` 后缀。
> Quick 控制台明确说创建后不可编辑，**保存前再核一遍**。

点 **Add**。

### 1.2 创建 Extension

1. 左侧 **Connect apps and data** → **Extensions** → **Add extension**
2. 选刚才创建的 Extension Access → **Next** → **Create**

## 2. 端到端验证

1. 下载 Amazon Quick Desktop：https://aws.amazon.com/quick/download/
2. 打开应用 → **Enterprise login**
3. 输入 Quick 账号名（即 `QUICK_NAMESPACE`）
4. 浏览器跳到 Keycloak 登录页

| 场景 | 期望看到 |
|---|---|
| **1 (idc)** | 一个 **Sign in with AWS IAM Identity Center** 按钮，点了跳 IdC 登录 |
| **2 (ad)** | 标准 username + password 表单，输 AD 用户名/密码（如 `quicktest1`） |

5. 登录成功后浏览器 302 回 `http://localhost:18080?code=...`
6. Quick Desktop 用 code + PKCE verifier 换 token
7. Desktop 解 id_token，按 `email` claim 匹配 Quick 账号里的 user → 进入 Quick 主界面

## 3. 故障排查

### `redirect_mismatch`
Keycloak `<KEYCLOAK_OIDC_CLIENT_ID>` client 的 Valid redirect URIs 必须**精确**等于
`http://localhost:18080`。`./verify-oidc.sh` 会显示这个字段。

### `User not found after sign-in`
登录用的用户的 email 和 Quick 里看到的 email 不一致。
- 场景 1：检查 IdC user 的 email = Quick user 的 email
- 场景 2：检查 AD user 的 mail attribute = Quick 里 sync 来的 user email
  ```bash
  aws ds-data describe-user --directory-id "$AD_DIRECTORY_ID" \
    --sam-account-name quicktest1 --region us-east-1 \
    --query EmailAddress --output text
  ```

### "Session expires frequently"
`offline_access` 没在 scope 里。检查 Quick Extension Access 的 scope 字段
（通常默认就含 `openid email profile offline_access`）。

### Token validation failure
Issuer URL 不一致。Keycloak issuer 是 `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>`
（**没有**结尾的斜杠，**没有** `/.well-known/openid-configuration` 后缀）。

### 场景 2：Keycloak 登录页还有 SAML 按钮
跑 `SCENARIO=ad ./configure-keycloak.sh` 重新禁用，或者手动去 Keycloak Admin
→ Identity providers → `iam-identity-center` → Settings 把 Enabled 关掉。

### 登录页 502 / 504
ALB target group 健康检查失败。`aws elbv2 describe-target-health
--target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg
--query 'TargetGroups[0].TargetGroupArn' --output text) --region us-east-1`。
首次部署 Keycloak 跑 Liquibase migration 5-10 分钟才会变 healthy。
