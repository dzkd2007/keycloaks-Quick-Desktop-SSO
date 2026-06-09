# QuickSuite Desktop SSO

完整可复用的部署包：把 **Amazon Quick Desktop** 客户端的 SSO 接到企业 IdP。

提供两种**实测可用**的架构，用同一套 Keycloak / Aurora / ALB / CloudFront 基础设施，
通过 `SCENARIO` 环境变量切换：

| 场景 | 架构 | 适用 |
|---|---|---|
| **场景 1 (`SCENARIO=idc`)** | Quick is **IAM Identity Center** backed; Keycloak 在中间做 OIDC↔SAML broker | 已经/想要把 IdC 当统一 workforce identity 入口；用户/组都在 IdC 内置 directory |
| **场景 2 (`SCENARIO=ad`)** | Quick is **Active Directory** backed; Keycloak 通过 LDAP federation 直连 Managed AD | 用户/组以 AD 为权威；想去掉 IdC 这一层 |

两种场景都让 Quick Desktop 客户端走 OIDC + PKCE 的 Enterprise login 流程，
最终匹配 `id_token.email` → Quick 用户登录。

## 架构图

### 共用基础设施（两个场景都跑同一套）

```
                              Internet
                                 │
                                 ▼
            ┌────────────────────────────────────────┐
            │  CloudFront (CachingDisabled+AllViewer)│
            │  Alias → keycloak.<your-domain>        │
            └─────────────────┬──────────────────────┘
                              │ HTTPS, SNI=kc-origin.<your-domain>
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  AWS account · region us-east-1 · existing VPC                      │
│                                                                     │
│  ┌──────────────────────────┐                                       │
│  │  Internet-facing ALB     │  SG ingress: 443 from CloudFront      │
│  │  + ACM cert              │  origin-facing managed prefix list    │
│  └─────────────┬────────────┘  (no 0.0.0.0/0 allowed)               │
│                ▼                                                    │
│  ┌──────────────────────────┐    ┌─────────────────────┐            │
│  │  ECS Fargate · Keycloak  │───▶│ Aurora Serverless v2│            │
│  │  realm: quicksuite       │    │ PostgreSQL          │            │
│  │  OIDC client:            │    └─────────────────────┘            │
│  │    amazon-quick-desktop  │                                       │
│  │    (public + PKCE S256)  │                                       │
│  └─────────────┬────────────┘                                       │
│                │                                                    │
└────────────────┼────────────────────────────────────────────────────┘
                 │
        Identity source ↓ depends on SCENARIO
```

### 场景 1：`SCENARIO=idc`

```
                 OIDC PKCE                     SAML 2.0
Quick Desktop ─────────────→ Keycloak ──────────────────→ IAM Identity Center
   redirect_uri=                broker                      ╲
   localhost:18080                                            ╲ users/groups in
                                                                IdC internal directory
                                                                (no AD needed)

Quick account (IdC backed) ──► IdC (identity source) ──► same users
```

- Keycloak realm 有一个 SAML Identity Provider `iam-identity-center` 指向 IdC
- IdC 端有一个 Customer Managed SAML 2.0 application 指回 Keycloak ACS URL
- `id_token.email` 来自 IdC SAML assertion 里的 email attribute
- AD/LDAP federation **可选**（不部署可省 ~$88/月）

### 场景 2：`SCENARIO=ad`

```
                  OIDC PKCE              LDAP federation
Quick Desktop ─────────────→ Keycloak ──────────────────→ AWS Managed Microsoft AD
   redirect_uri=                                            ╲
   localhost:18080                                            ╲ users/groups + passwords
                                                                in AD (corp.example.com)

Quick account (AD backed) ──► AD (identity source) ──► same users via AD groups
```

- Keycloak realm **没有** SAML IdP，直接用 LDAP federation 做用户密码校验
- `id_token.email` 来自 AD user 的 `mail` 属性
- Quick 订阅时把 AD groups（`quickadmins/quickauthors/quickreaders`）绑给 Admin/Author/Reader

## 成本对比（us-east-1，On-Demand，单 task / Aurora 平均 0.7 ACU / 低 SSO 流量）

价格来自 AWS Pricing API，按 730 hr/月 估算。**两个场景共用大部分组件**，差异在
身份后端是 IdC（免费）还是 Managed AD。

### 共用组件（两个场景都有）

| 组件 | 单价 | 月成本 |
|---|---|---|
| ALB（Application LB-hour + ~1 LCU） | $0.0225/hr + $0.008/LCU-hr | **$22.27** |
| ECS Fargate（2 vCPU + 4 GB，24/7）| $0.04048/vCPU-hr + $0.004445/GB-hr | **$72.08** |
| Aurora Serverless v2 (PostgreSQL，平均 0.7 ACU + 5GB) | $0.12/ACU-hr | **$61.82** |
| CloudFront (PriceClass_All，<10GB egress/月) | $0.085/GB + $0.0075/10K req | **~$1.00** |
| Route53 (1 hosted zone + queries) | $0.50/zone/月 + $0.40/M | **~$0.60** |
| Secrets Manager (3 secrets) | $0.40/secret/月 | **$1.20** |
| CloudWatch Logs (~2 GB/月 ingest+store) | $0.50/GB ingest + $0.03/GB-mo | **~$1.00** |
| NAT Gateway (现有 VPC 复用 1 个) | $0.045/hr + 数据 | **$32.85** |
| ACM 证书 | 免费 | $0 |
| IAM Identity Center | 免费 | $0 |
| **共用合计** | | **~$192.82 / 月** |

### 场景 1（IdC backed）总成本

| 组件 | 月成本 |
|---|---|
| 共用合计 | $192.82 |
| Managed AD（**可选**，本场景 SSO 链路不需要 LDAP） | $0（不部署）  /  +$87.60（保留给将来用） |
| **场景 1 合计** | **~$192.82** （或保留 AD 时 ~$280.42） |

> 场景 1 推荐**不部署 Managed AD**：可以把 `01-managed-ad.yaml` 跳过，相关 `.env` 字段
> 留空，`02-keycloak-infra.yaml` 的 `ManagedADDnsIp1/2` 用 dummy 值（LDAP federation
> 不在登录链路里），整套架构不依赖 AD。

### 场景 2（AD backed）总成本

| 组件 | 月成本 |
|---|---|
| 共用合计 | $192.82 |
| AWS Managed Microsoft AD Standard（2 DC × $0.06/hr × 730 hr）**必需** | **$87.60** |
| （或升级到 Enterprise，2 DC × $0.20/hr × 730 hr） | $292.00 |
| **场景 2 合计（Standard）** | **~$280.42** |
| **场景 2 合计（Enterprise）** | ~$484.82 |

### 两场景净差额

> **场景 2 比场景 1 多 ~$87.60/月**（不计可选 AD），即 Managed AD Standard 的固定费用。
> 用户量 < 5,000 时 Standard 够用；超过则要 Enterprise（再贵 $204.40/月）。

> ⚠️ 价格估算假设：单 task、低流量、平均负载。实际跑生产请按真实 LCU、ACU、egress、
> Logs ingest 量重估。Aurora 在峰值会 scale 到 4 ACU（短时 ~$350/月 等价），LCU 在突发
> 流量可飙到 10+。

## 文件清单

| 文件 | 作用 |
|---|---|
| `DEPLOYMENT.md` | **从零开始的完整部署指南，先看这个** |
| `.env.example` | 环境变量模板，复制成 `.env` 后填值 |
| `01-managed-ad.yaml` | CFN: AWS Managed AD（场景 1 可选 / 场景 2 必需） |
| `02-keycloak-infra.yaml` | CFN: Keycloak ECS + Aurora + ALB |
| `02b-cloudfront.yaml` | CFN: CloudFront 前置 |
| `03-keycloak-realm-config.md` | 手动: 首次创建 realm + LDAP（场景 2）+ 浏览器自检 |
| `04a-identity-center-setup.md` | 手动（场景 1 only）: IdC 创建 Custom SAML application |
| `04b-ad-quick-setup.md` | 手动（场景 2 only）: AD 用户/组 + Quick 重订阅 AD-backed |
| `05-quick-extension-access.md` | 手动: Quick 控制台 Extension Access（两场景共用） |
| `deploy-infra.sh` | 自动: 串联 3 个 CFN stack + Route53 alias + 健康检查 |
| `configure-keycloak.sh` | 自动: 按 SCENARIO 配 SAML IdP / 禁 SAML + OIDC public client |
| `ad-setup-quick.sh` | 自动（场景 2）: 用 ds-data API 建 AD 用户/组 |
| `verify-oidc.sh` | 验证: Keycloak OIDC discovery / JWKS / client / SAML IdP |
| `verify-ldap.sh` | 验证: ECS → Managed AD 的 LDAP 链路 |
| `inspect-keycloak.sh` | 排障: 当前 Keycloak realm / IdP / client 状态快照 |
| `inspect-keycloak-ldap.sh` | 排障（场景 2）: 验 LDAP federation + email mapper + 用户同步 |
| `inspect-ad.sh` | 排障（场景 2）: AD 用户/组当前状态 |
| `test-keycloak-ldap-login.sh` | 验证（场景 2）: 模拟 AD 用户走完整 OIDC password grant |
| `disable-saml-idp.sh` | 工具（场景 2 切换）: 把 SAML IdP 禁用 |

## 5 分钟看懂执行顺序

```
.env (填值，含 SCENARIO)
  ↓
deploy-infra.sh                           ← Phase 1: 3 套 CFN stack
  ↓
[手动] 03 §1: Keycloak Admin UI 建 realm
  ↓
分支：
  场景 1: [手动] 04a: IdC 控制台建 SAML application + 下载 metadata
  场景 2: [手动] 04b: 建 AD 用户/组 → 取消旧 Quick 订阅 → 重订阅 AD-backed
  ↓
configure-keycloak.sh                     ← Phase 2: SAML IdP / 禁 SAML + OIDC client
  ↓
verify-oidc.sh                            ← 全绿才往下走
  ↓
[手动] 05: Quick 控制台填 Extension Access
  ↓
装 Quick Desktop，点 Enterprise login，端到端验证
```

详细步骤、前置条件、参数说明、故障排查见 **[DEPLOYMENT.md](./DEPLOYMENT.md)**。

## 设计要点（不要踩）

通用：
- **`redirect_uri = http://localhost:18080`** 是 Quick Desktop 写死的，不能改
- **OIDC client 必须 public + PKCE S256**，不能藏 client secret
- **必须 us-east-1**：CloudFront ACM 要求 us-east-1，Quick Desktop 也只在 us-east-1
- **CloudFront 必须 `CachingDisabled`**：OIDC token / JWKS 不能被边缘缓存
- **ALB SG 不能 `0.0.0.0/0`**：合规；用 CloudFront origin-facing prefix list 替代
- **ECS task 子网必须和 ALB 至少一个 AZ 重合**

场景 1：
- **IdC ACS URL 路径里的 alias** 必须等于 Keycloak SAML IdP 的 alias，改一边就要改另一边
- **不要切 IdC identity source**，会清空所有 user/group assignments

场景 2：
- **AD 用户必须有 `mail` 属性**，否则 id_token 里 email 为空 → 登 Quick Desktop 失败
- **Quick 订阅是不可逆的 identity 选择**：要换 identity type 必须 unsubscribe 再 subscribe
- **3 个 AD group 必须在订阅 Quick 时绑定**（之后改不了 group ↔ role 映射）
