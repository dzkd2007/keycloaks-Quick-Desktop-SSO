# Step 4 — IAM Identity Center：创建 Custom SAML Application

> ⚠️ **不要切 IdC 的 identity source**。
> 切到 AD / external IdP 会清空 IdC 里所有现有的用户/组 assignments
> （包括已经分给 Permission Sets / 其他应用的）。Identity Store ID 也会变，
> AWS access portal URL 也会变。**本部署链路不需要切**。
>
> 我们只做一件事：在 IdC 里建一个 customer-managed SAML 2.0 application，
> 把 IdC 当 SAML IdP，Keycloak 作为 SP 接进来。

## 0. 前置条件

- 已经能登录 [IAM Identity Center console](https://console.aws.amazon.com/singlesignon)
- IdC instance 在 us-east-1（与 Quick 账号同 region）
- Quick 账号的 `AuthenticationType=IAM_IDENTITY_CENTER`（用下面的命令确认）
- 你打算用 Quick Desktop 测试的真实用户，已经存在于 IdC 里且 email 和 Quick
  内现有用户**逐字符一致**

```bash
# 确认 Quick 是 IdC backed
aws quicksight describe-account-subscription \
  --aws-account-id "$AWS_ACCOUNT_ID" --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,IAMIdentityCenterInstanceArn]' --output table

# 看 IdC 实例
aws sso-admin list-instances --region us-east-1 --output table
# 把上面的 InstanceArn 和 IdentityStoreId 写进 .env 的
#   IDC_INSTANCE_ARN=
#   IDC_IDENTITY_STORE_ID=
```

如果 `AuthenticationType` 不是 `IAM_IDENTITY_CENTER`，本部署链路不适用，
请先把 Quick 重新订阅成 IdC backed（无法运行时切换；详见
https://docs.aws.amazon.com/quick/latest/userguide/setting-up-sso.html）。

## 1. 创建 Custom SAML Application

1. 打开 IAM Identity Center console（**Region 必须是 us-east-1**）
2. 左侧导航 → **Applications** → **Customer managed** tab → **Add application**
3. **Setup preference** → 选 **I have an application I want to set up**
4. **Application type** → **SAML 2.0** → **Next**

### 1.1 Configure application

| 字段 | 值 |
|---|---|
| Display name | `Amazon Quick Desktop via Keycloak` |
| Description | `Brokered through Keycloak realm <KEYCLOAK_REALM> for Amazon Quick Desktop SSO` |

### 1.2 IAM Identity Center metadata（下载，给 Keycloak 用）

页面上找 **IAM Identity Center metadata** 区域：
- 点 **IAM Identity Center SAML metadata file** 旁边的 **Download**
- 把下载下来的 XML 文件**保存为 `idc-saml-metadata.xml`**，**放到本仓库目录里**
  （和 `configure-keycloak.sh` 同级）

### 1.3 Application properties

| 字段 | 值 |
|---|---|
| Application start URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/account` |
| Relay state | （留空） |
| Session duration | `8 hours` |

### 1.4 Application metadata（最关键的两个值）

选 **Manually type your metadata values**：

| 字段 | 值 |
|---|---|
| **Application ACS URL** | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/broker/<KEYCLOAK_IDP_ALIAS>/endpoint` |
| **Application SAML audience** | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |

把所有 `<...>` 替换成 `.env` 里的实际值。**默认值的话**：
- ACS URL: `https://<KEYCLOAK_DOMAIN>/realms/quicksuite/broker/iam-identity-center/endpoint`
- SAML audience: `https://<KEYCLOAK_DOMAIN>/realms/quicksuite`

> ACS URL 路径里那个 `iam-identity-center` 是 `KEYCLOAK_IDP_ALIAS` 的值。
> **如果改了 .env 里的 alias**，这里也要同步改，否则 SAML 路由不上。

点 **Submit**。

## 2. 配置 Attribute Mappings

进入刚创建的 application 详情页 → **Actions** → **Edit attribute mappings**。

| Application attribute | Maps to | Format |
|---|---|---|
| **Subject** | `${user:email}` | `emailAddress` |
| `email` | `${user:email}` | `unspecified` |
| `firstName` | `${user:givenName}` | `unspecified` |
| `lastName` | `${user:familyName}` | `unspecified` |

> Quick Desktop 强制要求 NameID format = `emailAddress`，所以 Subject 那一行的
> Format 字段不能漏。

**Save changes**。

## 3. 分配用户

进入 application 详情页 → **Assigned users and groups** → **Assign users and groups**。

把所有要用 Quick Desktop 的真实用户 / 组加进来。要点：

- 用户 email **必须**和 Quick 内现有 user 的 email 完全一致（包括大小写）
- 推荐用 group 管理（IdC 里建一个 group `quick-desktop-users`，把人加进 group，再 assign group）
- 测试期间至少 assign 1 个真实用户（拿这个用户 email 验证端到端登录）

## 4. 把 Application ARN 写回 .env

```bash
APP_ARN=$(aws sso-admin list-applications \
  --instance-arn "$IDC_INSTANCE_ARN" \
  --region us-east-1 \
  --query "Applications[?Name=='Amazon Quick Desktop via Keycloak'].ApplicationArn | [0]" \
  --output text)
echo "IDC_SAML_APPLICATION_ARN=$APP_ARN"
# 把这一行追加 / 替换 .env 里的 IDC_SAML_APPLICATION_ARN
```

## 5. 验证元数据已下载

```bash
ls -la idc-saml-metadata.xml
# 应该有这个文件，~2-3 KB，开头是 <?xml version="1.0" encoding="UTF-8"?>
```

确认 OK 后回去执行 `./configure-keycloak.sh`（Step 3 §2）。

## 故障排查

### "Invalid SAML Response" 在 Keycloak 端
- 通常是 ACS URL 和 Keycloak SAML IdP 的 alias 不匹配。检查 IdC 这边的 ACS URL
  路径里的 alias 和 `.env` 的 `KEYCLOAK_IDP_ALIAS` 完全一致。

### 登录后 Keycloak 报 "Could not find email address"
- IdC application 的 attribute mapping 里 `email` 那一行没配对，或者 Format
  字段没选对。回到 §1.4 / §2 重新检查。

### IdC 报 "User not assigned to application"
- 在 Assigned users and groups 里把对应 IdC 用户/组加进来。

### 登录成功但 Quick 报 "User not found"
- Quick 内现有 user 的 email 和登录的 IdC user 的 email 不一致。
- 在 Quick 控制台 → Manage users 里看一下 Quick 内 user 的 email，把 IdC 那边
  的 email 改成完全一致（包括大小写）。
