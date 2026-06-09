# Step 5 — Amazon Quick 控制台：创建 Extension Access

> 这一步把 Keycloak 的 OIDC 端点告诉 Amazon Quick，让 Quick Desktop 客户端在
> 用户点 **Enterprise login** 时知道要去哪里跑 OIDC 流程。
>
> 参考：[Setting up Amazon Quick on desktop for enterprise deployments](https://docs.aws.amazon.com/quick/latest/userguide/desktop-enterprise-setup.html)

## 0. 前置条件

- Step 3（Keycloak realm + SAML IdP + OIDC client）已完成
- Step 4（IdC SAML application）已完成
- `./verify-oidc.sh` 已通过（看到 `OK — Keycloak side looks good.`）
- 你是 Amazon Quick 账号管理员（在 Quick 管理控制台能看到 Permissions 菜单）

## 1. 在 Quick 管理控制台添加 Extension Access

1. 浏览器登录 Amazon Quick
   （账号 `<AWS_ACCOUNT_ID>`，namespace `<QUICK_NAMESPACE>`）
2. 点右上角用户名 → **Manage Quick** 进管理控制台
3. 左侧导航 **Permissions** → **Extension access** → **Add extension access**
4. 选 **Desktop application for Quick** → **Next**

### 1.1 填 OIDC 端点

| 字段 | 值 |
|---|---|
| Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
| Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
| Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
| JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
| Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>` |

替换 `<...>` 为 `.env` 里的实际值。也可以从 `./verify-oidc.sh` 输出里直接抄。

> ⚠️ **Issuer URL 不要带 `/.well-known/openid-configuration` 后缀**。
> Quick 控制台明确说创建后不可编辑，**保存前再核一遍**。错了只能删了重建。

点 **Add**。

### 1.2 创建 Extension

1. 左侧导航 **Connect apps and data** → **Extensions** → **Add extension**
2. 选刚才创建的 Extension Access → **Next** → **Create**

## 2. 端到端验证

1. 在 macOS 或 Windows 下载 Amazon Quick Desktop：
   https://aws.amazon.com/quick/download/
2. 打开应用，选 **Enterprise login**
3. 输入 Quick 账号名（namespace，即 `<QUICK_NAMESPACE>`）
4. 浏览器会被打开并跳到 Keycloak 登录页
5. 登录页应该有 **Sign in with AWS IAM Identity Center** 按钮
6. 点按钮 → IdC 登录页 → 输入已 assign 给 SAML application 的 IdC 用户邮箱 + 密码
7. IdC SAML assertion 回到 Keycloak → Keycloak 自动建 / 更新联邦用户 →
   302 回 `http://localhost:18080?code=...`
8. Quick Desktop 用 code + PKCE verifier 在 Keycloak token endpoint 换 token
9. Desktop 解 id_token，按 `email` claim 匹配 Quick 账号里的 user → 进 Quick 主界面

## 3. 故障排查

### `redirect_mismatch`
- Keycloak `<KEYCLOAK_OIDC_CLIENT_ID>` client 的 Valid redirect URIs 必须**精确**等于
  `http://localhost:18080`（不能加斜杠、不能加路径、不能加 `*`）。
- 用 `./verify-oidc.sh` 检查 `redirectUris == [http://localhost:18080]` 那行有没有 OK。

### `User not found after sign-in`
- IdC 里那个登录用户的 email 和 Quick 里看到的 email 不一致。
- 在 Quick 控制台 → Manage users 里看一下登录用的那个 Quick user 的 email，
  必须**逐字符一致**（包括大小写）。
- 在 IdC 里改 email 之后，Quick 那边可能需要重新同步（Quick 自动从 IdC 拉 user）。

### "Session expires frequently"
- `offline_access` 没配进 scope。检查 Keycloak `<KEYCLOAK_OIDC_CLIENT_ID>` 的
  Optional Client Scopes 是否包含 `offline_access`。`./verify-oidc.sh` 会显示这个。

### Token validation failure
- Issuer URL 不一致。Keycloak issuer 是 `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>`
  （**没有**结尾的斜杠，**没有** `/.well-known/openid-configuration` 后缀）。
- 比对一下 id_token 里的 `iss` claim 和 Quick Extension Access 里填的 Issuer URL。

### Keycloak 登录页除了 SAML 按钮还有用户名 / 密码框
- 这是 Keycloak realm 默认带的 form。可以保留无害（本 realm 没本地用户登不进），
  也可以在 Realm settings → Authentication → Browser flow 里改 flow 把 forms
  步骤设为 `disabled`。**首次部署不建议改**，等整链路都通了再做美化。

### 登录页空白或 502 / 504
- ALB target group 健康检查失败。`aws elbv2 describe-target-health
  --target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg
  --query 'TargetGroups[0].TargetGroupArn' --output text) --region us-east-1`。
- 大概率是 ECS task 启动 / Liquibase migration 还没好（首次部署 5-10 分钟），
  或者 ECS 子网和 ALB AZ 不重合（target 标 unused）。
