#!/usr/bin/env bash
# inspect-keycloak-ldap.sh — Verify Keycloak LDAP federation can see the AD
# user we just created (and that the mail attribute came across).

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${KEYCLOAK_DOMAIN:?}"
: "${KEYCLOAK_REALM:?}"
: "${KEYCLOAK_ADMIN_USER:?}"
: "${KEYCLOAK_ADMIN_PASSWORD:?}"
: "${AD_TEST_USER_SAM:?}"

API="https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}"

TOKEN=$(curl -fsS --max-time 10 \
  "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER}" \
  -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

echo "[1] LDAP federation provider id"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/components?type=org.keycloak.storage.UserStorageProvider" \
  > /tmp/kc_userfed.json
LDAP_ID=$(python3 - <<'PYEOF'
import json
arr = json.load(open("/tmp/kc_userfed.json"))
for d in arr:
    if d.get("providerId") == "ldap":
        print(d.get("id"))
        break
PYEOF
)
echo "  id = $LDAP_ID"
echo

echo "[2] Mappers attached to LDAP federation"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/components?parent=${LDAP_ID}&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  > /tmp/kc_ldap_mappers.json
python3 - <<'PYEOF'
import json
arr = json.load(open("/tmp/kc_ldap_mappers.json"))
for m in arr:
    cfg = m.get("config") or {}
    name = m.get("name")
    pid  = m.get("providerId")
    user_attr = (cfg.get("user.model.attribute") or [""])[0] if isinstance(cfg.get("user.model.attribute"), list) else cfg.get("user.model.attribute","")
    ldap_attr = (cfg.get("ldap.attribute") or [""])[0] if isinstance(cfg.get("ldap.attribute"), list) else cfg.get("ldap.attribute","")
    if pid == "user-attribute-ldap-mapper":
        print(f"  {name:<25} {pid:<35} user.{user_attr} <- ldap.{ldap_attr}")
    else:
        print(f"  {name:<25} {pid}")
PYEOF
echo

echo "[3] Trigger LDAP sync (changed users) ..."
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" \
  "$API/user-storage/${LDAP_ID}/sync?action=triggerChangedUsersSync" \
  > /tmp/kc_sync.json
python3 - <<'PYEOF'
import json
d = json.load(open("/tmp/kc_sync.json"))
print(f"  result: {d}")
PYEOF
echo

echo "[4] Look up user '$AD_TEST_USER_SAM' in Keycloak"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/users?username=${AD_TEST_USER_SAM}&exact=true" \
  > /tmp/kc_user.json
python3 - <<'PYEOF'
import json
arr = json.load(open("/tmp/kc_user.json"))
if not arr:
    print("  NOT FOUND in Keycloak yet. LDAP federation may not have synced.")
else:
    u = arr[0]
    print(f"  username   : {u.get('username')}")
    print(f"  email      : {u.get('email')}")
    print(f"  firstName  : {u.get('firstName')}")
    print(f"  lastName   : {u.get('lastName')}")
    print(f"  enabled    : {u.get('enabled')}")
    print(f"  federation : {u.get('federationLink')}")
PYEOF
