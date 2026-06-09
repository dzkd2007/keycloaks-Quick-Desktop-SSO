# Deployment Guide

[中文版](DEPLOYMENT.zh.md) | English

End-to-end walkthrough for deploying QuickSuite Desktop SSO with Keycloak from a clean AWS account. Total time: roughly 1.5–2.5 hours, most of which is waiting for the Managed AD CloudFormation stack to finish on first creation.

## Contents

1. [Choose a scenario](#1-choose-a-scenario)
2. [Prerequisites](#2-prerequisites)
3. [Configure `.env`](#3-configure-env)
4. [Phase 1 — Provision infrastructure](#4-phase-1--provision-infrastructure)
5. [Phase 2 — Bootstrap the Keycloak realm](#5-phase-2--bootstrap-the-keycloak-realm)
6. [Phase 3 — Configure the identity backend](#6-phase-3--configure-the-identity-backend)
7. [Phase 4 — Wire up Keycloak](#7-phase-4--wire-up-keycloak)
8. [Phase 5 — Register the Extension Access in Amazon Quick](#8-phase-5--register-the-extension-access-in-amazon-quick)
9. [Phase 6 — End-to-end test with Quick Desktop](#9-phase-6--end-to-end-test-with-quick-desktop)
10. [Troubleshooting](#10-troubleshooting)
11. [Cleanup](#11-cleanup)

---

## 1. Choose a scenario

| | Scenario 1 (`SCENARIO=idc`) | Scenario 2 (`SCENARIO=ad`) |
|---|---|---|
| Quick account identity type | IAM Identity Center | Active Directory |
| Where users / groups live | IdC internal directory | AWS Managed Microsoft AD |
| Password authority | IdC | AD |
| Keycloak role | OIDC ↔ SAML identity broker | OIDC + LDAP federation to AD |
| Managed AD required | optional (saves ~$88/month if skipped) | **required** |
| Monthly cost (baseline) | ≈ $193 | ≈ $280 (Standard AD) |
| Best fit | already standardized on IdC for workforce SSO | AD is the single source of truth |

### When this package does not fit

- Region other than `us-east-1` (CloudFront ACM and Quick Desktop are us-east-1 only)
- Account is not the AWS Organizations management account or delegated admin (Scenario 2 requires it)
- Scenario 1 — your existing Quick account is not IdC backed
- Scenario 2 — your existing Quick account is not AD backed (and you cannot unsubscribe to switch)

```bash
# Quick self-check
aws sso-admin list-instances --region us-east-1
aws quicksight describe-account-subscription \
  --aws-account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,AccountSubscriptionStatus]' --output table
```

---

## 2. Prerequisites

### Tooling

| Tool | Version |
|------|---------|
| AWS CLI | v2.x |
| `python3` | ≥ 3.8 |
| `curl` | any modern build |
| `git` | for cloning the repo |

### Service quota

The CloudFront origin-facing managed prefix list reference counts ~45 entries against a security group's inbound-rule limit. The default is 60, which leaves no headroom; raise the quota first:

```
Service: VPC
Quota:   L-0EA8095F  (Inbound or outbound rules per security group)
Request: 200
```

Approval is usually 1–3 business days.

### Networking

| Resource | Requirement |
|----------|-------------|
| VPC | Existing, with NAT Gateway so private subnets can reach the public internet for image pulls |
| Private subnets | ≥ 2, in different AZs (Aurora needs cross-AZ subnet group) |
| Public subnets | ≥ 2, in different AZs (ALB needs cross-AZ) |
| ECS task subnet | A private subnet whose AZ is also covered by one of the public subnets — otherwise ALB targets will be marked `unused` |

### Domain & ACM certificate

- A Route 53 public hosted zone for your domain.
- Two hostnames inside the zone:
  - `KEYCLOAK_DOMAIN` — public entry point, e.g. `keycloak.example.com`
  - `ORIGIN_ALIAS_NAME` — internal SNI alias used by CloudFront → ALB, e.g. `kc-origin.example.com`
- An ACM certificate **in `us-east-1`** that covers both hostnames. The simplest path is a wildcard `*.example.com`:

```bash
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region us-east-1
# Complete the DNS validation in the console; wait until Status=ISSUED.
```

### Amazon Quick subscription

If Quick is not yet subscribed for this account, sign up for Quick Enterprise edition with home region `us-east-1`. The identity choice you make at signup can be wrong — the deployment lets you switch by unsubscribing and re-subscribing under your chosen scenario.

---

## 3. Configure `.env`

```bash
git clone https://github.com/dzkd2007/keycloaks-Quick-Desktop-SSO.git
cd keycloaks-Quick-Desktop-SSO
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

`.env` is the single source of truth for every script and CFN command. The file is `.gitignore`-d.

The variables that differ by scenario are highlighted below; everything else is the same.

| Variable | Scenario 1 | Scenario 2 |
|---|---|---|
| `SCENARIO` | `idc` | `ad` |
| `IDC_INSTANCE_ARN`, `IDC_IDENTITY_STORE_ID` | required | leave empty |
| `AD_TEST_USER_EMAIL`, `AD_TEST_USER_PASSWORD` | leave empty | required |
| `QUICK_AUTHENTICATION_TYPE` | `IAM_IDENTITY_CENTER` | `ACTIVE_DIRECTORY` |

`AD_DIRECTORY_ID`, `AD_DNS_IP_*`, `ALB_DNS_NAME`, `CLOUDFRONT_*`, and `IDC_SAML_APPLICATION_ARN` are populated automatically during the deploy steps — leave them blank.

---

## 4. Phase 1 — Provision infrastructure

```bash
./deploy-infra.sh
```

The orchestrator runs five stages:

| Stage | What runs | Time |
|------|-----------|------|
| Pre-flight | CLI / region / ACM / Route 53 sanity checks | seconds |
| CFN | `quicksuite-managed-ad` (`01-managed-ad.yaml`) | ≈ 30 min on first create |
| CFN | `quicksuite-keycloak` (`02-keycloak-infra.yaml`) | ≈ 10 min |
| CFN | `quicksuite-keycloak-cf` (`02b-cloudfront.yaml`) | ≈ 5–10 min |
| Route 53 | UPSERT alias for `KEYCLOAK_DOMAIN` → CloudFront | seconds |
| Healthcheck | Polls `https://<KEYCLOAK_DOMAIN>/realms/master/.well-known/openid-configuration` | up to 10 min |

> If you are running Scenario 1 and want to skip Managed AD entirely (saving ~$88/month), deploy `02-keycloak-infra.yaml` and `02b-cloudfront.yaml` directly with `aws cloudformation deploy`, passing dummy values for `ManagedADDnsIp1` / `ManagedADDnsIp2` (the LDAP federation will not be exercised in the Desktop SSO chain).

When `deploy-infra.sh` finishes, you should see a summary block listing the Keycloak admin URL, the OIDC discovery URL, and the ALB / CloudFront identifiers. Open the admin URL — you should reach Keycloak's login page.

> The very first Keycloak boot runs Liquibase migrations against an empty Aurora; ALB target health may take 5–10 minutes to flip to `healthy`. You can watch it with:
>
> ```bash
> aws elbv2 describe-target-health --region us-east-1 \
>   --target-group-arn $(aws elbv2 describe-target-groups --names keycloak-tg \
>     --region us-east-1 --query 'TargetGroups[0].TargetGroupArn' --output text)
> ```

---

## 5. Phase 2 — Bootstrap the Keycloak realm

`configure-keycloak.sh` requires the realm to already exist. Create it once by hand:

1. Open `https://<KEYCLOAK_DOMAIN>/admin`.
2. Sign in with `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD`.
3. From the realm dropdown in the upper-left, choose **Create Realm**.
4. **Realm name** — use the value of `KEYCLOAK_REALM` (default `quicksuite`). Click **Create**.

Apply the recommended settings from [`03-keycloak-realm-config.md`](03-keycloak-realm-config.md) §1.

For Scenario 2, also configure the LDAP federation in this same realm — see [`03-keycloak-realm-config.md`](03-keycloak-realm-config.md) §2. Scenario 1 may skip LDAP federation, or configure it for unrelated future use.

---

## 6. Phase 3 — Configure the identity backend

| Scenario | Document |
|----------|----------|
| `idc` | [`04a-identity-center-setup.md`](04a-identity-center-setup.md) — create a Customer Managed SAML 2.0 application in IAM Identity Center and download its metadata. |
| `ad` | [`04b-ad-quick-setup.md`](04b-ad-quick-setup.md) — create AD groups + a test user via the Directory Service Data API, then unsubscribe and re-subscribe Amazon Quick with **Active Directory** as the identity type. |

For Scenario 1, save the downloaded SAML metadata as `idc-saml-metadata.xml` in the repo root — `configure-keycloak.sh` reads it from there.

For Scenario 2, after the new Quick subscription is provisioned update `.env` with the new `QUICK_NAMESPACE` and set `QUICK_AUTHENTICATION_TYPE=ACTIVE_DIRECTORY`.

---

## 7. Phase 4 — Wire up Keycloak

```bash
./configure-keycloak.sh
```

The script reads `SCENARIO` from `.env` and is idempotent.

| Step | Scenario 1 (`idc`) | Scenario 2 (`ad`) |
|------|---|---|
| Create SAML Identity Provider `iam-identity-center` from `idc-saml-metadata.xml` | ✅ | — |
| Add SAML attribute mappers (`email`, `firstName`, `lastName`) | ✅ | — |
| Disable any existing SAML Identity Provider | — | ✅ |
| Create / update OIDC public client `amazon-quick-desktop` | ✅ | ✅ |
| Apply PKCE S256, redirect URI `http://localhost:18080`, default scopes `email profile`, optional `offline_access` | ✅ | ✅ |

Then sanity-check:

```bash
./verify-oidc.sh
```

You should see `OK — Keycloak side looks good.`

For Scenario 2, also run an end-to-end OIDC password-grant test using the AD credentials:

```bash
./test-keycloak-ldap-login.sh
```

The script temporarily enables `directAccessGrantsEnabled` on the OIDC client, runs a password grant for `quicktest1`, decodes the resulting `id_token` to confirm the `email` / `given_name` / `family_name` claims are present, and disables direct access grants again on exit. Expected output: `PASS — Keycloak LDAP federation works for quicktest1 and id_token contains email.`

---

## 8. Phase 5 — Register the Extension Access in Amazon Quick

Detail: [`05-quick-extension-access.md`](05-quick-extension-access.md). Both scenarios use the same OIDC endpoints (same Keycloak realm and OIDC client).

In the Amazon Quick admin console:

1. **Permissions → Extension access → Add extension access**
2. Choose **Desktop application for Quick** and click **Next**.
3. Fill in the OIDC fields below and click **Add**:

   | Field | Value |
   |---|---|
   | Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
   | Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
   | Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
   | JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
   | Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>` (default `amazon-quick-desktop`) |

4. **Connect apps and data → Extensions → Add extension** — pick the Extension Access you just created.

> The Issuer URL must **not** include the `/.well-known/openid-configuration` suffix, and the OIDC config cannot be edited after creation. Double-check before saving.

---

## 9. Phase 6 — End-to-end test with Quick Desktop

1. Download Quick Desktop (macOS or Windows 10+) from <https://aws.amazon.com/quick/download/>.
2. Launch the application and choose **Enterprise login**.
3. Enter your Quick account name (the value of `QUICK_NAMESPACE`).
4. A browser opens the Keycloak login page:

   | Scenario | What you should see |
   |---|---|
   | 1 (`idc`) | A **Sign in with AWS IAM Identity Center** button — clicking it redirects to the IdC login page. |
   | 2 (`ad`) | A standard username + password form — enter the AD username (e.g. `quicktest1`) and password. |

5. Sign in. The browser redirects back to `http://localhost:18080?code=...`, the Desktop client exchanges the code for tokens via PKCE, validates the `email` claim, and shows the Quick main interface.

---

## 10. Troubleshooting

### General

| Symptom | Likely cause |
|---------|--------------|
| `deploy-infra.sh` fails on ACM certificate check | Certificate not in `us-east-1`, or does not cover both `KEYCLOAK_DOMAIN` and `ORIGIN_ALIAS_NAME` |
| `deploy-infra.sh` fails on subnet check | `ECS_SUBNET` is not in any of the AZs covered by `PUBLIC_SUBNET_1` / `PUBLIC_SUBNET_2` |
| Keycloak admin UI returns 502 / 504 | Liquibase migration still running on first deploy (5–10 min); inspect target health |
| Quick Desktop returns `redirect_mismatch` | OIDC client redirect URI must be exactly `http://localhost:18080` — no trailing slash, no path, no wildcard |
| Quick Desktop returns "User not found" | `id_token.email` does not match any Quick user (case-sensitive) |
| Sessions expire very quickly | `offline_access` scope missing from the Quick Extension Access configuration |

### Scenario 1 — IdC

| Symptom | Likely cause |
|---------|--------------|
| Keycloak login page does not show the SAML button | `configure-keycloak.sh` did not run with `SCENARIO=idc`, or the metadata file is missing |
| "Invalid SAML Response" after IdC login | The alias inside the IdC ACS URL does not match `KEYCLOAK_IDP_ALIAS` |
| Keycloak reports "Could not find email address" | The IdC application's attribute mapping does not emit `email`, or the Format is wrong |

### Scenario 2 — AD

| Symptom | Likely cause |
|---------|--------------|
| Keycloak login page still shows the SAML button | Re-run `SCENARIO=ad ./configure-keycloak.sh`, or disable the IdP manually in **Identity providers** |
| AD user fails to authenticate via Keycloak | Bad password (special characters in some forms); LDAP federation not yet attached; run `./inspect-keycloak-ldap.sh` |
| Quick Desktop accepts the token but shows "User not found" | AD `mail` attribute differs from Quick's user email; verify with `aws ds-data describe-user` |
| `ad-setup-quick.sh` creates groups named `12`, `20`, `61`, ... | The script was modified to use a `GROUPS=(...)` shell array — `GROUPS` is a bash built-in read-only variable. Rename to e.g. `QUICK_GROUPS`. |
| Quick subscription form shows "No options" for an AD group | Type `quick` in the field to trigger fuzzy lookup; do not enter placeholder text |

Per-document troubleshooting sections live at the bottom of each `0[345]*.md` file.

---

## 11. Cleanup

UI-only artefacts first, then CloudFormation stacks in reverse order.

```bash
# 1. Quick console — delete the Extension and Extension Access
# 2. Scenario 1: IAM Identity Center → Applications → Customer managed → delete the SAML application
#    Scenario 2: optionally remove AD test users / groups via aws ds-data delete-*
# 3. Route 53 — delete the public alias for KEYCLOAK_DOMAIN
# 4. CloudFormation stacks
aws cloudformation delete-stack --stack-name quicksuite-keycloak-cf --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak-cf --region us-east-1

aws cloudformation delete-stack --stack-name quicksuite-keycloak --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-keycloak --region us-east-1
# Aurora has DeletionPolicy: Snapshot — a final snapshot is retained.

aws cloudformation delete-stack --stack-name quicksuite-managed-ad --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name quicksuite-managed-ad --region us-east-1
# 5. Optional: delete the ACM certificate if no longer needed.
```

The Route 53 hosted zone, VPC, NAT Gateway, and Quick subscription pre-date this template and are not removed.
