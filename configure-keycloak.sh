#!/usr/bin/env bash
# configure-keycloak.sh — Idempotent: build the SAML IdP + OIDC public client
# in Keycloak realm ${KEYCLOAK_REALM}. Safe to re-run.
#
# What this script creates / updates:
#   1. SAML Identity Provider, alias = ${KEYCLOAK_IDP_ALIAS}
#      - Imported from IDC_SAML_METADATA_FILE
#      - Sync mode FORCE, trustEmail on
#   2. SAML attribute mappers on that IdP: email / firstName / lastName
#   3. OIDC public client ${KEYCLOAK_OIDC_CLIENT_ID}
#      - publicClient + PKCE S256
#      - redirect_uri http://localhost:18080
#      - default scopes openid/email/profile, optional offline_access

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
: "${IDC_SAML_METADATA_FILE:?}"

if [[ ! -f "$IDC_SAML_METADATA_FILE" ]]; then
  echo "ERROR: metadata file not found: $IDC_SAML_METADATA_FILE"; exit 1
fi

API="https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}"

get_token() {
  curl -fsS --max-time 10 \
    "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
    -d grant_type=password \
    -d client_id=admin-cli \
    -d username="${KEYCLOAK_ADMIN_USER}" \
    -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])'
}

TOKEN=$(get_token)
AUTH=( -H "Authorization: Bearer $TOKEN" )

###############################################################################
# 1) SAML Identity Provider
###############################################################################
echo "[1/4] SAML Identity Provider '$KEYCLOAK_IDP_ALIAS' ..."

# Use Keycloak's import-config endpoint to convert metadata XML -> provider config
curl -fsS "${AUTH[@]}" \
  -F "providerId=saml" \
  -F "file=@${IDC_SAML_METADATA_FILE};type=application/xml" \
  "$API/identity-provider/import-config" > /tmp/kc_idp_config.json

python3 - <<PYEOF > /tmp/kc_idp_payload.json
import json
cfg = json.load(open("/tmp/kc_idp_config.json"))
# Override / harden the parts we care about
cfg["nameIDPolicyFormat"] = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
cfg["principalType"] = "Subject"
cfg["wantAuthnRequestsSigned"] = "false"
cfg["wantAssertionsSigned"] = "true"
cfg["wantAssertionsEncrypted"] = "false"
cfg["postBindingResponse"] = "true"
cfg["postBindingAuthnRequest"] = "true"
cfg["validateSignature"] = "true"
cfg["syncMode"] = "FORCE"
# Keycloak SP entity ID (audience IdC will assert to)
cfg["entityId"] = "https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}".replace("\${KEYCLOAK_DOMAIN}", "${KEYCLOAK_DOMAIN}").replace("\${KEYCLOAK_REALM}", "${KEYCLOAK_REALM}")

payload = {
    "alias": "${KEYCLOAK_IDP_ALIAS}",
    "displayName": "Sign in with AWS IAM Identity Center",
    "providerId": "saml",
    "enabled": True,
    "trustEmail": True,
    "storeToken": False,
    "addReadTokenRoleOnCreate": False,
    "linkOnly": False,
    "firstBrokerLoginFlowAlias": "first broker login",
    "config": cfg,
}
json.dump(payload, open("/tmp/kc_idp_payload.json","w"))
PYEOF

# Does it already exist?
HTTP=$(curl -s -o /tmp/kc_idp_existing.json -w "%{http_code}" "${AUTH[@]}" \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}")

if [[ "$HTTP" == "200" ]]; then
  echo "  exists, updating ..."
  curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_idp_payload.json \
    "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /dev/null
elif [[ "$HTTP" == "404" ]]; then
  echo "  creating ..."
  curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_idp_payload.json \
    "$API/identity-provider/instances" > /dev/null
else
  echo "  unexpected HTTP $HTTP"; cat /tmp/kc_idp_existing.json; exit 1
fi
echo "  OK"
echo

###############################################################################
# 2) SAML attribute mappers
###############################################################################
echo "[2/4] SAML attribute mappers (email / firstName / lastName) ..."

curl -fsS "${AUTH[@]}" \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" \
  > /tmp/kc_idp_mappers.json

create_mapper() {
  local name="$1" attr="$2" user_attr="$3"
  local exists
  exists=$(python3 - <<PYEOF
import json
arr=json.load(open("/tmp/kc_idp_mappers.json"))
print("yes" if any(m.get("name")=="$name" for m in arr) else "no")
PYEOF
)
  if [[ "$exists" == "yes" ]]; then
    echo "  - $name : already exists, skipping"
    return
  fi
  cat > /tmp/kc_mapper.json <<JSON
{
  "name": "$name",
  "identityProviderAlias": "${KEYCLOAK_IDP_ALIAS}",
  "identityProviderMapper": "saml-user-attribute-idp-mapper",
  "config": {
    "syncMode": "INHERIT",
    "attribute.name": "$attr",
    "user.attribute": "$user_attr"
  }
}
JSON
  curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_mapper.json \
    "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}/mappers" > /dev/null
  echo "  - $name : created"
}

create_mapper "email"     "email"     "email"
create_mapper "firstName" "firstName" "firstName"
create_mapper "lastName"  "lastName"  "lastName"
echo

###############################################################################
# 3) OIDC public client
###############################################################################
echo "[3/4] OIDC public client '$KEYCLOAK_OIDC_CLIENT_ID' ..."

cat > /tmp/kc_client.json <<JSON
{
  "clientId": "${KEYCLOAK_OIDC_CLIENT_ID}",
  "name": "Amazon Quick Desktop",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": true,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "implicitFlowEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": true,
  "redirectUris": ["http://localhost:18080"],
  "webOrigins": [],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": "http://localhost:18080"
  }
}
JSON

# upsert
EXISTING=$(curl -fsS "${AUTH[@]}" \
  "$API/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}")
INTERNAL_ID=$(python3 -c "
import json
arr=json.loads('''$EXISTING''')
print(arr[0]['id'] if arr else '')
")

if [[ -z "$INTERNAL_ID" ]]; then
  echo "  creating ..."
  LOC=$(curl -fsS -i -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_client.json \
    "$API/clients" | awk -F': ' 'tolower($1)=="location" {print $2}' | tr -d '\r')
  INTERNAL_ID="${LOC##*/}"
  echo "  internalId = $INTERNAL_ID"
else
  echo "  exists ($INTERNAL_ID), updating ..."
  # Merge new fields into existing
  python3 - <<PYEOF > /tmp/kc_client_merged.json
import json
old = json.loads('''$EXISTING''')[0]
new = json.load(open("/tmp/kc_client.json"))
# preserve id, secret-related fields are irrelevant for public client
new["id"] = old["id"]
json.dump(new, open("/tmp/kc_client_merged.json","w"))
PYEOF
  curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_client_merged.json \
    "$API/clients/${INTERNAL_ID}" > /dev/null
fi
echo "  OK"

# Make sure offline_access is in optional client scopes
echo "  ensuring scopes (default: openid/email/profile, optional: offline_access) ..."
curl -fsS "${AUTH[@]}" "$API/client-scopes" > /tmp/kc_scopes.json

ensure_scope() {
  local scope_name="$1" mode="$2"   # mode: default-client-scopes | optional-client-scopes
  local sid
  sid=$(python3 - <<PYEOF
import json
arr=json.load(open("/tmp/kc_scopes.json"))
for s in arr:
    if s.get("name")=="$scope_name":
        print(s["id"]); break
PYEOF
)
  if [[ -z "$sid" ]]; then
    echo "    WARN: realm-level scope '$scope_name' not found; skipping"
    return
  fi
  curl -fsS -X PUT "${AUTH[@]}" \
    "$API/clients/${INTERNAL_ID}/${mode}/${sid}" > /dev/null || true
  echo "    $scope_name -> $mode (set)"
}

ensure_scope "openid"         "default-client-scopes"
ensure_scope "email"          "default-client-scopes"
ensure_scope "profile"        "default-client-scopes"
ensure_scope "offline_access" "optional-client-scopes"
echo

###############################################################################
# 4) Verify
###############################################################################
echo "[4/4] Verifying final state ..."
TOKEN=$(get_token)
AUTH=( -H "Authorization: Bearer $TOKEN" )

curl -fsS "${AUTH[@]}" \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /tmp/kc_idp_final.json
python3 - <<'PYEOF'
import json,os
d = json.load(open("/tmp/kc_idp_final.json"))
cfg = d.get("config") or {}
print(f"  IdP alias        = {d.get('alias')}")
print(f"  providerId       = {d.get('providerId')}")
print(f"  entityId(SP)     = {cfg.get('entityId')}")
print(f"  IdP SSO URL      = {cfg.get('singleSignOnServiceUrl')}")
print(f"  nameIDFormat     = {cfg.get('nameIDPolicyFormat')}")
print(f"  syncMode         = {cfg.get('syncMode')}")
print(f"  trustEmail       = {d.get('trustEmail')}")
PYEOF

curl -fsS "${AUTH[@]}" \
  "$API/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}" > /tmp/kc_client_final.json
python3 - <<'PYEOF'
import json
arr=json.load(open("/tmp/kc_client_final.json"))
c=arr[0]
print()
print(f"  OIDC clientId    = {c.get('clientId')}")
print(f"  publicClient     = {c.get('publicClient')}")
print(f"  standardFlow     = {c.get('standardFlowEnabled')}")
print(f"  redirectUris     = {c.get('redirectUris')}")
print(f"  pkce method      = {(c.get('attributes') or {}).get('pkce.code.challenge.method')}")
print(f"  defaultScopes    = {c.get('defaultClientScopes')}")
print(f"  optionalScopes   = {c.get('optionalClientScopes')}")
PYEOF

echo
echo "Done."
