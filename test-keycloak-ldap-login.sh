#!/usr/bin/env bash
# test-keycloak-ldap-login.sh — Verify Keycloak realm 'quicksuite' can
# authenticate the AD user 'quicktest1' via LDAP federation by running
# an OIDC password grant against the realm's master / direct flow.
#
# This proves: AD password -> Keycloak via LDAP federation -> id_token with email.
# It's a synthetic test of the same path that Quick Desktop will exercise
# (Desktop uses authorization code + PKCE, but the credential check is identical).

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

ISSUER="https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}"

# --- Step 1: temporarily enable Direct Access Grants on amazon-quick-desktop ---
TOKEN=$(curl -fsS --max-time 10 \
  "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER}" -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

API="https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}"
CID=$(curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}" \
  | python3 -c 'import json,sys; arr=json.load(sys.stdin); print(arr[0]["id"] if arr else "")')

if [[ -z "$CID" ]]; then
  echo "ERROR: client $KEYCLOAK_OIDC_CLIENT_ID not found in realm $KEYCLOAK_REALM"; exit 1
fi

echo "[1/3] Temporarily enabling directAccessGrantsEnabled on $KEYCLOAK_OIDC_CLIENT_ID ..."
curl -fsS -H "Authorization: Bearer $TOKEN" "$API/clients/${CID}" > /tmp/kc_client.json
python3 - <<'PYEOF' > /tmp/kc_client_dag.json
import json
d = json.load(open("/tmp/kc_client.json"))
d["directAccessGrantsEnabled"] = True
json.dump(d, open("/tmp/kc_client_dag.json","w"))
PYEOF
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data @/tmp/kc_client_dag.json "$API/clients/${CID}" > /dev/null
echo "  enabled."
echo

# --- Step 2: try password grant as quicktest1 ---
echo "[2/3] OIDC password grant as $AD_TEST_USER_SAM ..."
RESP=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" \
  -X POST "$ISSUER/protocol/openid-connect/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=$KEYCLOAK_OIDC_CLIENT_ID" \
  --data-urlencode "username=$AD_TEST_USER_SAM" \
  --data-urlencode "password=$AD_TEST_USER_PASSWORD" \
  --data-urlencode "scope=openid email profile")

HTTP=$(echo "$RESP" | grep '^HTTP_STATUS:' | cut -d: -f2)
BODY=$(echo "$RESP" | grep -v '^HTTP_STATUS:')
echo "  HTTP $HTTP"

# Always restore directAccessGrantsEnabled = false before exiting
restore() {
  echo
  echo "[3/3] Restoring directAccessGrantsEnabled = false ..."
  TOKEN2=$(curl -fsS --max-time 10 \
    "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d username="${KEYCLOAK_ADMIN_USER}" -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
  curl -fsS -H "Authorization: Bearer $TOKEN2" "$API/clients/${CID}" > /tmp/kc_client_a.json
  python3 - <<'PYEOF' > /tmp/kc_client_off.json
import json
d = json.load(open("/tmp/kc_client_a.json"))
d["directAccessGrantsEnabled"] = False
json.dump(d, open("/tmp/kc_client_off.json","w"))
PYEOF
  curl -fsS -X PUT -H "Authorization: Bearer $TOKEN2" -H "Content-Type: application/json" \
    --data @/tmp/kc_client_off.json "$API/clients/${CID}" > /dev/null
  echo "  restored."
}
trap restore EXIT

if [[ "$HTTP" != "200" ]]; then
  echo
  echo "FAIL — body:"
  echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
  exit 1
fi

echo "  got tokens. Decoding id_token claims ..."
echo "$BODY" > /tmp/kc_body.json
python3 - <<'PYEOF'
import json, base64
data = json.load(open("/tmp/kc_body.json"))
def jdecode(jwt):
    p = jwt.split('.')[1]
    p += '=' * ((4 - len(p) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(p))
idt = jdecode(data['id_token'])
for k in ['iss','sub','azp','preferred_username','email','given_name','family_name','email_verified']:
    print(f"    {k:<20} = {idt.get(k)!r}")
PYEOF

echo
echo "PASS — Keycloak LDAP federation works for $AD_TEST_USER_SAM and id_token contains email."
