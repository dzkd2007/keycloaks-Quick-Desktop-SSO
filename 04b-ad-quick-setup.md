# Step 4b — AD-backed 场景：建 AD 用户/组 + 重订阅 Quick 为 AD identity

> **本文档只适用于场景 2（`SCENARIO=ad`）**。
> 场景 1（IdC backed）请用 `04a-identity-center-setup.md`。
>
> 本步骤会**取消现有 Quick 订阅**，所以如果 Quick 上有重要数据先备份。

## 0. 前置条件

- `01-managed-ad.yaml` / `02-keycloak-infra.yaml` / `02b-cloudfront.yaml` 三个 stack 已部署
- `.env` 里 `AD_DIRECTORY_ID` / `AD_DNS_IP_1` / `AD_DNS_IP_2` 已被 `deploy-infra.sh` 自动回填
- AWS CLI 默认凭据是该账号的管理员

## 1. 启用 Directory Service Data API

ds-data API 是 Managed AD 的现代用户/组管理通道（不需要域加入 Windows EC2）。
默认是关的，先启用：

```bash
source .env
aws ds enable-directory-data-access \
  --directory-id "$AD_DIRECTORY_ID" --region "$AWS_REGION"

# 等几秒确认状态
sleep 5
aws ds describe-directory-data-access \
  --directory-id "$AD_DIRECTORY_ID" --region "$AWS_REGION"
# 期望: DataAccessStatus = Enabled
```

## 2. 填好测试用户的 email + 强密码

编辑 `.env`：

```ini
AD_TEST_USER_SAM=quicktest1
AD_TEST_USER_EMAIL=<你的真实邮箱，例如 you+quicktest1@yourmail.com>
AD_TEST_USER_PASSWORD=<生成一个强密码>
```

> **email 必须能实际收信** —— Quick 订阅时可能往这个邮箱发邀请；并且 Quick Desktop
> 用 id_token.email 匹配用户，必须和 Quick 内显示的 email 完全一致。
>
> 密码要满足 AD 默认复杂度（≥8 字符，含大小写 + 数字 + 符号）。生成参考：
>
> ```bash
> python3 -c "import secrets,string; chars='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#%^*-_=+'; print(''.join(secrets.choice(chars) for _ in range(18)))"
> ```

## 3. 一键建 3 个 group + 1 个测试用户

```bash
./ad-setup-quick.sh
```

脚本幂等，运行后：

- 3 个 AD group 在 `OU=Users,OU=<SHORT_NAME>`：
  - `quickadmins`（之后绑成 Quick Admin）
  - `quickauthors`（之后绑成 Quick Author）
  - `quickreaders`（之后绑成 Quick Reader）
- 1 个测试用户 `quicktest1`：
  - mail = `AD_TEST_USER_EMAIL`
  - GivenName = `Quick`, Surname = `Test1`
  - 密码 = `AD_TEST_USER_PASSWORD`，已 enabled
  - 在 group `quickadmins` 里

输出最后会列出所有用户和 group，确认看到 `quicktest1` 和三个 group 即可。

## 4. 取消当前 Quick 订阅

> 这一步**会清掉 Quick 上的所有数据**（datasets、dashboards、analyses）。如果有
> 不想丢的内容先 export。

1. 浏览器登 https://quicksuite.aws.amazon.com/
2. 右上角用户名 → **Manage Quick**
3. 左侧 **Account settings** → 滚到底 → **Delete account / Unsubscribe**
4. 输入账号名确认
5. 等几分钟让 AWS 后端释放资源

## 5. 重新订阅 Quick Enterprise，identity 选 Active Directory

1. https://aws.amazon.com/quick/ → **Sign up for Quick** → **Enterprise edition**
2. **Authentication method** → **Use Active Directory**
3. **Directory** 下拉选 `corp.example.com`（你的 Managed AD）
4. **Account name** 起一个新的（例如 `ad-test`）。同名复用可能要等几小时。
5. **Region**: us-east-1
6. **Notification email**: 你的邮箱
7. **Group bindings**（这一步**只能在订阅时填**，建好账号再加要进控制台单独操作）：

   | Quick role | AD group |
   |---|---|
   | **Admin Pro** (Enterprise) | `quickadmins` |
   | Admin (legacy) | （留空） |
   | Author Pro (Enterprise) | `quickauthors` |
   | Author (legacy) | （留空） |
   | Reader Pro (Professional) | `quickreaders` |
   | Reader (legacy) | （留空） |

   > Quick 的 group 选择框是模糊查询：在框里输 `quick` 就会下拉显示三个组。
   > 如果你输 `AD group` 之类的占位符文字会显示 "No options"。

8. **Encryption**: 选 AWS-managed key（默认）
9. 提交订阅

订阅成功后回 `.env` 把新账号名写回：

```ini
QUICK_NAMESPACE=ad-test          # 你刚填的 Account name
QUICK_AUTHENTICATION_TYPE=ACTIVE_DIRECTORY
```

## 6. 验证 quicktest1 已经在 Quick 里

订阅完成后等 2-5 分钟，AD group `quickadmins` 的成员（即 `quicktest1`）会自动进 Quick。

测一下浏览器登录：
1. 打开 https://quicksuite.aws.amazon.com/sn/start （或者你 Quick 账号的 access URL）
2. 输入 username = `quicktest1`，password = `AD_TEST_USER_PASSWORD`
3. 应该进入 Quick 主界面

> 这时是 Quick **直连 AD** 的登录路径，没有走 Keycloak。
> Keycloak OIDC 是给 **Quick Desktop 客户端** 用的，下一步才用到。

## 7. 进入下一步

- 回到 Step 3 §3 配置 Keycloak 的 OIDC public client（`configure-keycloak.sh` 自动跑，
  脚本不创建 SAML IdP，只建 OIDC client；同一脚本两个场景都用）
- 然后 `verify-oidc.sh` → `test-keycloak-ldap-login.sh`
- 然后 `05-quick-extension-access.md` 把 Keycloak OIDC endpoint 填进 Quick

## 故障排查

### 订阅 Quick 时 group dropdown 显示 "No options"
- 框里别输 placeholder，输 `quick` 触发模糊匹配。
- 确认 `ad-setup-quick.sh` 跑成功，`aws ds-data list-groups` 能看到三个 group。

### 用 quicktest1 登 Quick web 报 "Invalid credentials"
- 密码错了（特殊字符可能在 web form 不支持，回 .env 检查）
- 用户被 disabled。`aws ds-data describe-user --directory-id ... --sam-account-name quicktest1`
  应该看到 `Enabled: true`
- AD 那边密码 lockout。等 30 分钟或者重新跑 `ad-setup-quick.sh` reset 密码

### 订阅后 Quick 控制台看不到 quicktest1
- 等 5-10 分钟，AD group sync 不是即时的
- 或者在 Quick 控制台 Manage users → Add user 手动加（按 sAMAccountName 填）
