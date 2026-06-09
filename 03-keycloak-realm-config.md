# Keycloak Realm Configuration

This document covers the Keycloak Admin UI steps that cannot be automated. Most of the realm wiring (SAML Identity Provider for Scenario 1, OIDC public client for both scenarios) is performed by `configure-keycloak.sh`; what remains here is the realm bootstrap, optional LDAP federation (mandatory for Scenario 2), and a browser smoke test.

## Quick reference by scenario

| Step | Scenario 1 (`idc`) | Scenario 2 (`ad`) |
|------|--------------------|-------------------|
| 1. Create realm `quicksuite` | required | required |
| 2. LDAP federation against Managed AD | optional (kept for future use) | **required** (password authority + user source) |
| 3. Run `configure-keycloak.sh` | required (creates SAML IdP + OIDC client) | required (disables SAML IdP + creates OIDC client) |
| 4. Browser smoke test | recommended | recommended |

## 0. Prerequisites

- The infrastructure stacks are deployed (`./deploy-infra.sh` finished successfully).
- You can reach `https://<KEYCLOAK_DOMAIN>/admin`.
- Scenario 1 — Step 4a is complete and `idc-saml-metadata.xml` is in the repo root.
- Scenario 2 — Step 4b is complete: AD users / groups exist and Quick has been re-subscribed as AD-backed.

## 1. Create the realm (both scenarios)

1. Open `https://<KEYCLOAK_DOMAIN>/admin` and sign in with `KEYCLOAK_ADMIN_USER` / `KEYCLOAK_ADMIN_PASSWORD`.
2. From the realm dropdown, choose **Create Realm**.
3. **Realm name** — use the value of `KEYCLOAK_REALM` (default `quicksuite`). Click **Create**.

Then under **Realm settings**:

- **Login** tab
  - User registration: **Off**
  - Forgot password: **Off** (passwords are managed by IdC or AD, not by Keycloak)
  - Login with email: **On**
  - Duplicate emails: **Off**
- **Tokens** tab
  - Access Token Lifespan: `5 Minutes`
  - SSO Session Idle: `30 Minutes`
  - SSO Session Max: `10 Hours`

## 2. LDAP user federation against Managed AD

> **Scenario 2** — required. The realm uses LDAP to authenticate users with their AD password and to enrich `id_token` with `email`, `firstName`, and `lastName`.
>
> **Scenario 1** — optional; only configure if you want to expose this realm to other applications later. It is not part of the Quick Desktop SSO chain.

In **User federation**, click **Add LDAP providers** → **LDAP**.

### 2.1 General options

| Field | Value |
|-------|-------|
| Console display name | `managed-ad` |
| Vendor | **Active Directory** |

### 2.2 Connection and authentication

| Field | Value |
|-------|-------|
| Connection URL | `ldap://<AD_DNS_IP_1>:389 ldap://<AD_DNS_IP_2>:389` |
| Enable StartTLS | Off |
| Use Truststore SPI | `Only for ldaps` |
| Connection pooling | On |
| Connection timeout (ms) | `10000` |
| Bind type | `simple` |
| Bind DN | `CN=Admin,OU=Users,OU=<AD_SHORT_NAME>,<DC=corp,DC=example,DC=com>` (replace each domain label) |
| Bind credentials | `<AD_ADMIN_PASSWORD>` |

Click **Test connection** → expect `Success`. Click **Test authentication** → expect `Success`.

### 2.3 LDAP searching and updating

| Field | Value |
|-------|-------|
| Edit mode | **READ_ONLY** |
| Users DN | `OU=Users,OU=<AD_SHORT_NAME>,<DC=corp,DC=example,DC=com>` |
| Username LDAP attribute | `cn` (or `sAMAccountName` — Managed AD typically has `cn` ≡ `sAMAccountName` for users created via the Data API) |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |
| Search scope | `Subtree` |

### 2.4 Synchronization

| Field | Value |
|-------|-------|
| Import users | On |
| Sync registrations | Off |
| Periodic full sync | On / `604800` seconds (7 days) |
| Periodic changed users sync | On / `86400` seconds (1 day) |

Save and run **Action → Sync all users**.

### 2.5 Attribute mappers

In the LDAP provider's **Mappers** tab, the AD vendor preset already creates the mappers below. Verify that they exist:

| Mapper | Type | Effect |
|--------|------|--------|
| email | user-attribute | `user.email ← ldap.mail` |
| first name | user-attribute | `user.firstName ← ldap.givenName` |
| last name | user-attribute | `user.lastName ← ldap.sn` |
| username | user-attribute | `user.username ← ldap.cn` |
| groups | group-ldap-mapper | group sync |
| MSAD account controls | msad-user-account-control-mapper | enabled / locked |

> **Scenario 2** must have the `email` mapper present, otherwise `id_token.email` is empty and Quick Desktop sign-in fails. Run `./inspect-keycloak-ldap.sh` for an automated sanity check.

## 3. Run the automated configuration

```bash
# Pulls SCENARIO from .env, or override on the command line:
SCENARIO=idc ./configure-keycloak.sh
SCENARIO=ad  ./configure-keycloak.sh
```

What the script does, by scenario:

| Action | `idc` | `ad` |
|--------|:-:|:-:|
| Create SAML IdP `iam-identity-center` from `idc-saml-metadata.xml` | ✅ | — |
| Add SAML attribute mappers (`email`, `firstName`, `lastName`) | ✅ | — |
| Disable existing SAML IdP (avoid stale buttons on the login page) | — | ✅ |
| Create / update OIDC public client `amazon-quick-desktop` (PKCE S256, redirect `http://localhost:18080`) | ✅ | ✅ |

After it finishes, run:

```bash
./verify-oidc.sh
```

Expected output ends with `OK — Keycloak side looks good.`

## 4. Browser smoke test

Open `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/account`.

| Scenario | Expected |
|----------|----------|
| 1 (`idc`) | A **Sign in with AWS IAM Identity Center** button. Clicking it redirects to the IdC login page; signing in with an assigned IdC user returns you to the Keycloak account console. |
| 2 (`ad`) | A standard username + password form (no SAML button). Signing in with an AD username (e.g. `quicktest1`) and password returns you to the Keycloak account console. |

If a Scenario-2 login page still shows the SAML button, re-run `SCENARIO=ad ./configure-keycloak.sh`, or disable the IdP manually in **Identity providers**.

## 5. Next step

Continue with [`05-quick-extension-access.md`](05-quick-extension-access.md) to register the Keycloak OIDC endpoints in the Amazon Quick admin console, then test the full flow with Quick Desktop.
