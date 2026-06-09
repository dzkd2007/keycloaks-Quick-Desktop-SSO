# Scenario 1 — IAM Identity Center: Custom SAML Application

> Applies to **Scenario 1 (`SCENARIO=idc`) only**. For Scenario 2 see [`04b-ad-quick-setup.md`](04b-ad-quick-setup.md).

This step registers Keycloak with IAM Identity Center as a Customer Managed SAML 2.0 application, so Keycloak can delegate authentication to IdC. **It does not change the IdC identity source** — switching the identity source to or from Active Directory deletes every existing user / group assignment in IdC, and would also rotate the Identity Store ID and the AWS access portal URL. This deployment deliberately avoids that path.

## 0. Prerequisites

- You can sign in to the [IAM Identity Center console](https://console.aws.amazon.com/singlesignon).
- The IdC instance is in `us-east-1` (the same region as Quick).
- The Quick account has `AuthenticationType=IAM_IDENTITY_CENTER` and at least one assigned user whose email matches a Keycloak-federated identity.

```bash
# Confirm Quick is IdC backed
aws quicksight describe-account-subscription \
  --aws-account-id "$AWS_ACCOUNT_ID" --region us-east-1 \
  --query 'AccountInfo.[AuthenticationType,IAMIdentityCenterInstanceArn]' --output table

# Capture IdC instance + identity store IDs into .env
aws sso-admin list-instances --region us-east-1 --output table
```

If `AuthenticationType` is anything other than `IAM_IDENTITY_CENTER`, this scenario does not apply — re-subscribe Quick with the correct identity type, then come back.

## 1. Create the SAML application

1. Open the IAM Identity Center console (region must be `us-east-1`).
2. **Applications → Customer managed → Add application**.
3. Choose **I have an application I want to set up** → **SAML 2.0** → **Next**.

### 1.1 Configure application

| Field | Value |
|-------|-------|
| Display name | `Amazon Quick Desktop via Keycloak` |
| Description | `Brokered through Keycloak realm <KEYCLOAK_REALM> for Amazon Quick Desktop SSO` |

### 1.2 Download the IdC metadata

Under **IAM Identity Center metadata**:

- Click **Download** next to **IAM Identity Center SAML metadata file**, save it as `idc-saml-metadata.xml`, and place it in the repository root (next to `configure-keycloak.sh`).

### 1.3 Application properties

| Field | Value |
|-------|-------|
| Application start URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/account` |
| Relay state | (leave empty) |
| Session duration | `8 hours` |

### 1.4 Application metadata (the two values that matter)

Choose **Manually type your metadata values** and enter:

| Field | Value |
|-------|-------|
| Application ACS URL | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>/broker/<KEYCLOAK_IDP_ALIAS>/endpoint` |
| Application SAML audience | `https://<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` |

With `.env` defaults the URLs become:

- ACS: `https://<KEYCLOAK_DOMAIN>/realms/quicksuite/broker/iam-identity-center/endpoint`
- Audience: `https://<KEYCLOAK_DOMAIN>/realms/quicksuite`

> The alias inside the ACS URL must match `KEYCLOAK_IDP_ALIAS` in `.env`. If you change one side, change both.

Click **Submit**.

## 2. Configure attribute mappings

On the application detail page, choose **Actions → Edit attribute mappings**.

| Application attribute | Maps to | Format |
|-----------------------|---------|--------|
| **Subject** | `${user:email}` | `emailAddress` |
| `email` | `${user:email}` | `unspecified` |
| `firstName` | `${user:givenName}` | `unspecified` |
| `lastName` | `${user:familyName}` | `unspecified` |

Quick Desktop requires NameID format `emailAddress`, so the **Format** column on the `Subject` row is mandatory.

Click **Save changes**.

## 3. Assign users

On the application detail page, choose **Assigned users and groups → Assign users and groups** and add:

- A real user whose email matches an existing Quick user (case-sensitive).
- Optionally an IdC group containing all users who should reach Quick Desktop. Group-based assignment is the recommended pattern at any scale.

## 4. Persist the application ARN

```bash
APP_ARN=$(aws sso-admin list-applications \
  --instance-arn "$IDC_INSTANCE_ARN" --region us-east-1 \
  --query "Applications[?Name=='Amazon Quick Desktop via Keycloak'].ApplicationArn | [0]" \
  --output text)
echo "IDC_SAML_APPLICATION_ARN=$APP_ARN"
# Update the IDC_SAML_APPLICATION_ARN line in .env with this value.
```

## 5. Verify the metadata file is in place

```bash
ls -la idc-saml-metadata.xml
# Expected: file present, ~2-3 KB, starts with <?xml version="1.0" encoding="UTF-8"?>
```

When this is OK, return to Phase 4 and run `./configure-keycloak.sh`.

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| Keycloak reports "Invalid SAML Response" after IdC login | The alias inside the IdC ACS URL does not match `KEYCLOAK_IDP_ALIAS`. Re-edit the application metadata or change the `.env` value, then re-run `configure-keycloak.sh`. |
| Keycloak reports "Could not find email address" | The `email` attribute mapping is missing or the format is wrong. Re-check §1.4 and §2. |
| IdC reports "User not assigned to application" | Add the user (or a group containing the user) under **Assigned users and groups**. |
| Quick Desktop accepts the token but shows "User not found" | The IdC user's email differs from the Quick user's email. Update the IdC user's email — Quick re-syncs from IdC automatically. |
