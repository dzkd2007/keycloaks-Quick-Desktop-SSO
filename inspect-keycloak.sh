#!/usr/bin/env bash
# inspect-keycloak.sh — Read-only snapshot of current Keycloak state.

set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${KEYCLOAK_DOMAIN:?}"
: "${KEYCLOAK_ADMIN_USER:?}"
: "${KEYCLOAK_ADMIN_PASSWORD:?}"
: "${KEYCLOAK_REALM:?}"
: "${KEYCLOAK_OIDC_CLIENT_ID:?}"
: "${KEYCLOAK_IDP_ALIAS:?}"

echo "============================================================"
echo "  Keycloak inspection"
echo "  Host  : $KEYCLOAK_DOMAIN"
echo "  Realm : $KEYCLOAK_REALM"
echo "============================================================"

TOKEN=$(curl -fsS --max-time 10 \
  "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER}" \
  -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

API="https://${KEYCLOAK_DOMAIN}/admin/realms"

echo "[1] Realms exist?"
curl -fsS -H "Authorization: Bearer $TOKEN" "$API" > /tmp/kc_realms.json
python3 - <<'PYEOF'
import json
data = json.load(open("/tmp/kc_realms.json"))
for r in data:
    name = r.get("realm","")
    print(f"  - {name:<20} enabled={r.get('enabled')}")
PYEOF
echo

echo "[2] Realm exists?"
HTTP=$(curl -s -o /tmp/kc_realm.json -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" "$API/${KEYCLOAK_REALM}")
if [[ "$HTTP" == "200" ]]; then
  echo "  YES — realm '${KEYCLOAK_REALM}' found"
else
  echo "  NO  — HTTP $HTTP. Realm not yet created."
  echo
  echo "Stop here. First create realm '${KEYCLOAK_REALM}' (Step 3 §1)."
  exit 0
fi
echo

echo "[3] User federation providers"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/${KEYCLOAK_REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
  > /tmp/kc_userfed.json
python3 - <<'PYEOF'
import json
data = json.load(open("/tmp/kc_userfed.json"))
if not data:
    print("  (none)")
else:
    for d in data:
        print(f"  - name={d.get('name')} provider={d.get('providerId')}")
PYEOF
echo

echo "[4] Identity providers (SAML/OIDC brokers)"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/${KEYCLOAK_REALM}/identity-provider/instances" \
  > /tmp/kc_idps.json
python3 - <<'PYEOF'
import json
data = json.load(open("/tmp/kc_idps.json"))
if not data:
    print("  (none)")
else:
    for d in data:
        print(f"  - alias={d.get('alias')} providerId={d.get('providerId')} enabled={d.get('enabled')}")
PYEOF
echo

echo "[5] Clients"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/${KEYCLOAK_REALM}/clients" \
  > /tmp/kc_clients.json
python3 - <<'PYEOF'
import json
data = json.load(open("/tmp/kc_clients.json"))
for d in data:
    cid = d.get("clientId","")
    public = d.get("publicClient")
    std = d.get("standardFlowEnabled")
    redirects = d.get("redirectUris", [])
    print(f"  - {cid:<35} public={public}  stdFlow={std}  redirects={redirects}")
PYEOF
echo

echo "[6] Specific OIDC client: $KEYCLOAK_OIDC_CLIENT_ID"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}" \
  > /tmp/kc_targetclient.json
python3 - <<'PYEOF'
import json
arr = json.load(open("/tmp/kc_targetclient.json"))
if not arr:
    print("  NOT YET CREATED — Step 3 §4 will create this.")
else:
    c = arr[0]
    attrs = c.get("attributes") or {}
    print("  EXISTS")
    print(f"    publicClient                = {c.get('publicClient')}")
    print(f"    standardFlowEnabled         = {c.get('standardFlowEnabled')}")
    print(f"    directAccessGrantsEnabled   = {c.get('directAccessGrantsEnabled')}")
    print(f"    redirectUris                = {c.get('redirectUris')}")
    print(f"    pkce method                 = {attrs.get('pkce.code.challenge.method')}")
    print(f"    defaultClientScopes         = {c.get('defaultClientScopes')}")
    print(f"    optionalClientScopes        = {c.get('optionalClientScopes')}")
PYEOF
echo

echo "[7] SAML IdP alias: $KEYCLOAK_IDP_ALIAS"
HTTP=$(curl -s -o /tmp/kc_idp.json -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$API/${KEYCLOAK_REALM}/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}")
if [[ "$HTTP" == "200" ]]; then
  echo "  EXISTS"
  python3 - <<'PYEOF'
import json
d = json.load(open("/tmp/kc_idp.json"))
cfg = d.get("config") or {}
print(f"    providerId        = {d.get('providerId')}")
print(f"    entityId          = {cfg.get('entityId')}")
print(f"    SSO URL           = {cfg.get('singleSignOnServiceUrl')}")
print(f"    nameIDPolicyFmt   = {cfg.get('nameIDPolicyFormat')}")
print(f"    syncMode          = {cfg.get('syncMode')}")
print(f"    wantAssertionsSig = {cfg.get('wantAssertionsSigned')}")
PYEOF
else
  echo "  NOT YET CREATED — Step 3 §3 will create this (after IdC metadata is downloaded in Step 4)."
fi
echo

echo "============================================================"
echo "  Inspection complete."
echo "============================================================"
