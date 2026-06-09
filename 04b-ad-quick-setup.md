# Scenario 2 — Active Directory and Amazon Quick Setup

> Applies to **Scenario 2 (`SCENARIO=ad`) only**. For Scenario 1 see [`04a-identity-center-setup.md`](04a-identity-center-setup.md).
>
> ⚠️ **This step unsubscribes the existing Amazon Quick account.** Back up anything you cannot afford to lose first; the test account in this guide assumes a clean slate.

This document creates AD groups and a test user via the Directory Service Data API, then unsubscribes Quick and re-subscribes it with **Active Directory** as the identity type so AD groups become Quick role bindings.

## 0. Prerequisites

- All three CloudFormation stacks deployed (`./deploy-infra.sh` completed).
- `.env` already contains `AD_DIRECTORY_ID`, `AD_DNS_IP_1`, and `AD_DNS_IP_2` (auto-populated by `deploy-infra.sh`).
- AWS CLI default credentials are administrator-level on this account.

## 1. Enable the Directory Service Data API

The Data API is the modern user/group management interface for Managed AD — no domain-joined Windows EC2 required. It is disabled by default; enable it once:

```bash
source .env
aws ds enable-directory-data-access \
  --directory-id "$AD_DIRECTORY_ID" --region "$AWS_REGION"

# Wait a few seconds for the state to flip
sleep 5
aws ds describe-directory-data-access \
  --directory-id "$AD_DIRECTORY_ID" --region "$AWS_REGION"
# Expected: DataAccessStatus = Enabled
```

## 2. Choose a test user email and password

Edit `.env`:

```ini
AD_TEST_USER_SAM=quicktest1
AD_TEST_USER_EMAIL=<a real, deliverable email address>
AD_TEST_USER_PASSWORD=<strong password>
```

The email **must be a real address** because Amazon Quick may send invitations / notifications to it, and Quick Desktop matches users by `id_token.email`. If you use a plus-address such as `you+quicktest1@example.com`, make sure your provider routes it correctly.

The password must satisfy AD's default complexity policy (≥ 8 characters, with at least three of the four categories: upper, lower, digit, symbol). A reasonable generator:

```bash
python3 - <<'PY'
import secrets
chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789!@#%^*-_=+'
while True:
    pw = ''.join(secrets.choice(chars) for _ in range(18))
    if any(c.isupper() for c in pw) and any(c.islower() for c in pw) \
       and any(c.isdigit() for c in pw) and any(not c.isalnum() for c in pw):
        print(pw); break
PY
```

## 3. Create three groups + one test user

```bash
./ad-setup-quick.sh
```

The script is idempotent. After it completes:

- Three security groups in `OU=Users,OU=<AD_SHORT_NAME>`:
  - `quickadmins` — to be bound to Quick **Admin** role
  - `quickauthors` — to be bound to Quick **Author** role
  - `quickreaders` — to be bound to Quick **Reader** role
- One test user `quicktest1`:
  - `mail` = `AD_TEST_USER_EMAIL`
  - `givenName` = `Quick`, `sn` = `Test1`
  - password set, account enabled
  - member of `quickadmins`

The script ends by printing the resulting users / groups / membership. Confirm `quicktest1` appears with the expected email and that it is a member of `quickadmins`.

## 4. Unsubscribe the current Amazon Quick account

> This deletes all datasets, dashboards, and analyses in the current Quick account.

1. Sign in to <https://quicksuite.aws.amazon.com/>.
2. Top-right user menu → **Manage Quick**.
3. **Account settings** → scroll to the bottom → **Delete account / Unsubscribe**.
4. Confirm by typing the account name.
5. Wait several minutes for AWS to fully release the resources.

## 5. Re-subscribe Quick with Active Directory as the identity type

1. Open <https://aws.amazon.com/quick/> → **Sign up for Quick** → **Enterprise edition**.
2. **Authentication method** → **Use Active Directory**.
3. **Directory** → choose `corp.example.com` (your Managed AD).
4. **Account name** → choose a fresh value (e.g. `ad-test`). Reusing the previous name may require waiting several hours.
5. **Region** → `us-east-1`.
6. **Notification email** → your administrator email.
7. **Group bindings** — these can only be set during signup:

   | Quick role | AD group |
   |------------|----------|
   | Admin Pro (Enterprise) | `quickadmins` |
   | Admin (legacy) | (leave empty) |
   | Author Pro (Enterprise) | `quickauthors` |
   | Author (legacy) | (leave empty) |
   | Reader Pro (Professional) | `quickreaders` |
   | Reader (legacy) | (leave empty) |

   > The Quick group selector is a fuzzy lookup. Type `quick` to surface the three groups; do not leave placeholder text in the field.

8. **Encryption** → AWS-managed key (default).
9. Submit.

After the new subscription is provisioned, update `.env`:

```ini
QUICK_NAMESPACE=ad-test                 # the new account name
QUICK_AUTHENTICATION_TYPE=ACTIVE_DIRECTORY
```

## 6. Confirm the test user lands in Quick

Within a few minutes, members of `quickadmins` (i.e. `quicktest1`) propagate to Quick automatically.

Sanity-check by signing in to the Quick web app directly:

1. Open <https://quicksuite.aws.amazon.com/sn/start> (or your account's access URL).
2. Username: `quicktest1`. Password: `AD_TEST_USER_PASSWORD`.
3. The Quick main interface should load.

> This is Quick's direct AD login path — no Keycloak in the loop. Keycloak is exercised in the next phase, when Quick **Desktop** uses OIDC against Keycloak.

## 7. Next step

Run `./configure-keycloak.sh` (Phase 4 in the deployment guide), then `./verify-oidc.sh`, then [`05-quick-extension-access.md`](05-quick-extension-access.md).

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `aws ds-data list-users` returns `AccessDeniedException: DS Data feature is not enabled` | Run `aws ds enable-directory-data-access` (§1) and retry. |
| Quick group dropdown shows "No options" | Type `quick` to trigger fuzzy lookup; do not enter placeholder text. Confirm the groups exist with `aws ds-data list-groups`. |
| `quicktest1` cannot sign in to Quick web | Wrong password (check special-character handling); user disabled (verify with `aws ds-data describe-user`); AD lockout (wait 30 min or re-run `./ad-setup-quick.sh` to reset). |
| Quick console does not show `quicktest1` | Wait 5–10 minutes for AD ↔ Quick sync, or add the user manually via Manage users. |
| `ad-setup-quick.sh` produces groups named `12`, `20`, `61`, ... | The script was edited to declare a Bash array named `GROUPS`. `GROUPS` is a Bash built-in read-only array variable; rename to e.g. `QUICK_GROUPS`. |
