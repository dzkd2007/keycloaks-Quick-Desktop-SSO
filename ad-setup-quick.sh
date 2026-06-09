#!/usr/bin/env bash
# ad-setup-quick.sh — Bootstrap AD users + groups for the AD-backed Quick scenario.
# Idempotent: re-running is safe (skips existing groups/users).

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${AD_DIRECTORY_ID:?}"
: "${AWS_REGION:?}"
: "${AD_TEST_USER_SAM:?}"
: "${AD_TEST_USER_EMAIL:?}"
: "${AD_TEST_USER_PASSWORD:?}"

REGION="$AWS_REGION"
DIR="$AD_DIRECTORY_ID"

# Three Quick role groups (Quick subscription wizard binds these to Admin/Author/Reader).
# NOTE: avoid the name `GROUPS` — it's a bash built-in readonly array variable.
QUICK_GROUPS=("quickadmins" "quickauthors" "quickreaders")

# Helpers ---------------------------------------------------------------------
group_exists() {
  aws ds-data describe-group --directory-id "$DIR" --sam-account-name "$1" \
    --region "$REGION" >/dev/null 2>&1
}
user_exists() {
  aws ds-data describe-user --directory-id "$DIR" --sam-account-name "$1" \
    --region "$REGION" >/dev/null 2>&1
}
member_exists() {
  # $1=group $2=user
  aws ds-data list-group-members --directory-id "$DIR" --sam-account-name "$1" \
    --region "$REGION" --output text \
    --query "Members[?MemberName=='$2'].MemberName" 2>/dev/null \
    | grep -q "$2"
}

echo "==================== ad-setup-quick.sh ==================="
echo "Directory : $DIR"
echo "Region    : $REGION"
echo "Test user : $AD_TEST_USER_SAM ($AD_TEST_USER_EMAIL)"
echo "Groups    : ${QUICK_GROUPS[*]}"
echo "==========================================================="
echo

# 1. Create groups -------------------------------------------------------------
echo "[1/4] Groups ..."
for g in "${QUICK_GROUPS[@]}"; do
  if group_exists "$g"; then
    echo "  - $g  (already exists)"
  else
    aws ds-data create-group --directory-id "$DIR" --sam-account-name "$g" \
      --region "$REGION" >/dev/null
    echo "  - $g  CREATED"
  fi
done
echo

# 2. Create test user ----------------------------------------------------------
echo "[2/4] Test user ..."
if user_exists "$AD_TEST_USER_SAM"; then
  echo "  - $AD_TEST_USER_SAM  (already exists)"
else
  aws ds-data create-user --directory-id "$DIR" \
    --sam-account-name "$AD_TEST_USER_SAM" \
    --email-address "$AD_TEST_USER_EMAIL" \
    --given-name "Quick" \
    --surname "Test1" \
    --region "$REGION" >/dev/null
  echo "  - $AD_TEST_USER_SAM  CREATED"
fi
echo

# 3. Reset password (always — also enables a freshly-created user) -------------
echo "[3/4] Resetting password (and enabling user) ..."
aws ds reset-user-password \
  --directory-id "$DIR" \
  --user-name "$AD_TEST_USER_SAM" \
  --new-password "$AD_TEST_USER_PASSWORD" \
  --region "$REGION" >/dev/null
echo "  password reset, user enabled."
echo

# 4. Add user to quickadmins ---------------------------------------------------
echo "[4/4] Group membership ..."
if member_exists "quickadmins" "$AD_TEST_USER_SAM"; then
  echo "  - $AD_TEST_USER_SAM  already in quickadmins"
else
  aws ds-data add-group-member --directory-id "$DIR" \
    --group-name "quickadmins" \
    --member-name "$AD_TEST_USER_SAM" \
    --region "$REGION" >/dev/null
  echo "  - $AD_TEST_USER_SAM  ADDED to quickadmins"
fi
echo

echo "==================== verification ========================="
echo "Users:"
aws ds-data list-users --directory-id "$DIR" --region "$REGION" \
  --query "Users[].[SAMAccountName,Enabled,EmailAddress]" --output table 2>/dev/null \
  || aws ds-data list-users --directory-id "$DIR" --region "$REGION" --output json
echo
echo "Groups:"
aws ds-data list-groups --directory-id "$DIR" --region "$REGION" \
  --query "Groups[].[SAMAccountName]" --output table 2>/dev/null \
  || aws ds-data list-groups --directory-id "$DIR" --region "$REGION" --output json
echo
echo "Members of quickadmins:"
aws ds-data list-group-members --directory-id "$DIR" --sam-account-name quickadmins \
  --region "$REGION" --query "Members[].[MemberName]" --output table

echo
echo "Done."
