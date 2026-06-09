# QuickSuite Desktop SSO

完整可复用的部署包：把 **Amazon Quick Desktop** 客户端的 SSO 接到 **AWS IAM Identity Center**，
中间用 **Keycloak**（ECS Fargate）做 OIDC↔SAML identity broker，AWS Managed Microsoft AD 作为可选的 LDAP federation 资源。

## 架构

```
                                OIDC PKCE                       SAML 2.0
   Amazon Quick Desktop  ──────────────────────→  Keycloak  ───────────────→  IAM Identity Center
   redirect_uri=http://localhost:18080            (broker)                   (密码权威，用户来源)
                                                    │
                                                    │ LDAP (可选，独立功能)
                                                    ▼
                                          AWS Managed Microsoft AD
                                          (给将来其它应用做 IdP 用)
```

| 组件 | 说明 |
|---|---|
| **Amazon Quick Desktop** | 客户端，强制 OIDC public client + PKCE，redirect_uri 写死 `http://localhost:18080` |
| **Keycloak 25** | ECS Fargate + Aurora Serverless v2 PostgreSQL，对外 ALB + CloudFront |
| **CloudFront** | 唯一对外入口；ALB SG 只接 CloudFront origin-facing prefix list（合规：禁止 `0.0.0.0/0`） |
| **IAM Identity Center** | 通过 customer-managed SAML 2.0 application 暴露给 Keycloak 当上游 IdP |
| **Managed AD** | 可选，给 Keycloak LDAP federation 用；**Quick Desktop SSO 链路不依赖** |

## 文件清单

| 文件 | 作用 |
|---|---|
| `DEPLOYMENT.md` | **从零开始的完整部署指南，先看这个** |
| `.env.example` | 环境变量模板，复制成 `.env` 后填值 |
| `01-managed-ad.yaml` | CFN: AWS Managed Microsoft AD |
| `02-keycloak-infra.yaml` | CFN: Keycloak ECS + Aurora + ALB |
| `02b-cloudfront.yaml` | CFN: CloudFront 前置 |
| `03-keycloak-realm-config.md` | 手动: 首次创建 Keycloak realm + 浏览器自检步骤 |
| `04-identity-center-setup.md` | 手动: IdC 创建 Custom SAML application（含下载 metadata） |
| `05-quick-extension-access.md` | 手动: Quick 控制台 Extension Access |
| `deploy-infra.sh` | 自动: 串联 3 个 CFN stack + Route53 alias + 健康检查 |
| `configure-keycloak.sh` | 自动: 用 Admin REST API 配 SAML IdP + OIDC public client（幂等） |
| `verify-oidc.sh` | 验证: Keycloak OIDC discovery / JWKS / client / SAML IdP 配置 |
| `verify-ldap.sh` | 验证: ECS → Managed AD 的 LDAP 通路（独立功能） |
| `inspect-keycloak.sh` | 排障: 当前 Keycloak realm / IdP / client 状态快照 |

## 5 分钟快速理解执行顺序

```
.env (填值)
  ↓
deploy-infra.sh         ←── Phase 1: AD + Keycloak + CloudFront 三套 CFN stack
  ↓
[手动] 03 §1: Keycloak Admin UI 建 realm
  ↓
[手动] 04: IdC 控制台建 Custom SAML application，下载 metadata XML
  ↓
configure-keycloak.sh   ←── Phase 2: Keycloak SAML IdP + OIDC public client
  ↓
verify-oidc.sh          ←── 全绿才往下走
  ↓
[手动] 05: Quick 控制台填 Extension Access
  ↓
装 Quick Desktop，点 Enterprise login，端到端验证
```

详细步骤、前置条件、参数说明、故障排查见 **[DEPLOYMENT.md](./DEPLOYMENT.md)**。

## 设计要点（不要踩）

- **`redirect_uri = http://localhost:18080`** 是 Quick Desktop 写死的，不能改
- **OIDC client 必须 public + PKCE S256**，不能藏 client secret
- **IdC ACS URL 路径里的 alias** 必须等于 Keycloak SAML IdP 的 alias（默认 `iam-identity-center`），改一边就要改另一边
- **不要切 IdC identity source**，会清空所有 user/group assignments
- **必须 us-east-1**：CloudFront ACM 要求 us-east-1，Quick Desktop 也只在 us-east-1
- **CloudFront 必须 `CachingDisabled`**：OIDC token / JWKS 不能被边缘缓存
- **ALB SG 不能 `0.0.0.0/0`**：合规要求；用 CloudFront origin-facing prefix list 替代
- **ECS task 子网必须和 ALB 至少一个 AZ 重合**，否则 target 被标 unused
