# Quick Console: Extension Access for Desktop

This step exposes the Keycloak OIDC endpoints to Amazon Quick so that Quick Desktop can run the Enterprise login flow. Both scenarios use the same configuration because they share the same Keycloak realm and the same OIDC public client.

Reference: [Setting up Amazon Quick on desktop for enterprise deployments](https://docs.aws.amazon.com/quick/latest/userguide/desktop-enterprise-setup.html).

## 0. Prerequisites

- Phase 4 is complete (`configure-keycloak.sh` finished successfully).
- Phase 3 (`04a-...md` for Scenario 1, or `04b-...md` for Scenario 2) is complete.
- `./verify-oidc.sh` ends with `OK — Keycloak side looks good.`

## 1. Add an Extension Access entry

1. Sign in to Amazon Quick:
   - Scenario 1 — sign in with an IdC user that is assigned to the IdC SAML application.
   - Scenario 2 — sign in with an AD username and password (e.g. `quicktest1`).
2. Top-right user menu → **Manage Quick**.
3. **Permissions → Extension access → Add extension access**.
4. Choose **Desktop application for Quick** → **Next**.

### 1.1 OIDC endpoints

| Field | Value |
|-------|-------|
| Issuer URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |
| Authorization endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/auth` |
| Token endpoint | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/token` |
| JWKS URI | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/protocol/openid-connect/certs` |
| Client ID | `<KEYCLOAK_OIDC_CLIENT_ID>` |

Copy the values from `verify-oidc.sh`'s output — the `[1] OIDC discovery` block lists them verbatim.

> ⚠️ Issuer URL must **not** include the `/.well-known/openid-configuration` suffix. The Quick console explicitly states the configuration **cannot be edited** after creation; verify each value before clicking **Add**.

### 1.2 Activate the extension

1. **Connect apps and data → Extensions → Add extension**.
2. Choose the Extension Access you just created → **Next** → **Create**.
3. The extension status should be **Active**.

## 2. End-to-end test

1. Download Amazon Quick Desktop from <https://aws.amazon.com/quick/download/> (macOS 12+, Windows 10+).
2. Launch the app and choose **Enterprise login**.
3. Enter your Quick account name (`QUICK_NAMESPACE`).
4. A browser window opens the Keycloak login page:

   | Scenario | Expected |
   |----------|----------|
   | 1 (`idc`) | A **Sign in with AWS IAM Identity Center** button — clicking it redirects to the IdC login page. |
   | 2 (`ad`) | A standard username + password form — enter the AD username (e.g. `quicktest1`) and password. |

5. After signing in, the browser redirects to `http://localhost:18080?code=…`, the Desktop client exchanges the code for tokens via PKCE, validates the `email` claim, and shows the Quick main interface.

## 3. Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `redirect_mismatch` | The OIDC client's redirect URI must be exactly `http://localhost:18080` — no trailing slash, no path, no wildcard. `verify-oidc.sh` reports the current value. |
| "User not found after sign-in" | The signed-in identity's email does not match a Quick user. Inspect both sides: <br>• Scenario 1 — IdC user email vs. Quick user email <br>• Scenario 2 — `aws ds-data describe-user --directory-id "$AD_DIRECTORY_ID" --sam-account-name <user>` and Quick → Manage users |
| "Session expires frequently" | `offline_access` not in scope. Check that the OIDC client lists `offline_access` under Optional Client Scopes (visible in `verify-oidc.sh`). |
| Token validation failure | Issuer URL mismatch. Keycloak's issuer is `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` with no trailing slash and no `.well-known` suffix. |
| Scenario 2: Keycloak login page still shows the SAML button | Re-run `SCENARIO=ad ./configure-keycloak.sh`, or disable the IdP manually in **Identity providers**. |
| Login page returns 502 / 504 | The ALB target group health check is failing. On a fresh deploy, Keycloak takes 5–10 minutes to finish Liquibase migrations before the targets become healthy. Inspect `aws elbv2 describe-target-health`. |
