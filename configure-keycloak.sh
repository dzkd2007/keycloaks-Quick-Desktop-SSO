#!/usr/bin/env bash
# configure-keycloak.sh — Idempotent Keycloak realm config.
# Behavior depends on SCENARIO env var:
#   - SCENARIO=idc : create SAML IdP `${KEYCLOAK_IDP_ALIAS}` from IDC metadata,
#                    add 3 SAML attribute mappers, create OIDC public client.
#                    LDAP federation (if any) is left alone.
#   - SCENARIO=ad  : disable any SAML IdP `${KEYCLOAK_IDP_ALIAS}` (so Keycloak
#                    falls back to LDAP-federated username/password form),
#                    create OIDC public client. LDAP federation must already
#                    exist (configured via Keycloak Admin UI per 03-keycloak-realm-config.md).
#
# Re-runnable.

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
: "${SCENARIO:?must be 'idc' or 'ad'}"

if [[ "$SCENARIO" != "idc" && "$SCENARIO" != "ad" ]]; then
  echo "ERROR: SCENARIO must be 'idc' or 'ad' (got '$SCENARIO')"; exit 1
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
# 1) SAML Identity Provider — only for SCENARIO=idc
###############################################################################
if [[ "$SCENARIO" == "idc" ]]; then
  echo "[1/4] (idc) SAML Identity Provider '$KEYCLOAK_IDP_ALIAS' ..."
  : "${IDC_SAML_METADATA_FILE:?}"
  if [[ ! -f "$IDC_SAML_METADATA_FILE" ]]; then
    echo "ERROR: IdC SAML metadata file not found: $IDC_SAML_METADATA_FILE"
    echo "Did you complete Step 4a (download IdC application metadata)?"
    exit 1
  fi

  curl -fsS "${AUTH[@]}" \
    -F "providerId=saml" \
    -F "file=@${IDC_SAML_METADATA_FILE};type=application/xml" \
    "$API/identity-provider/import-config" > /tmp/kc_idp_config.json

  python3 - <<PYEOF > /tmp/kc_idp_payload.json
import json
cfg = json.load(open("/tmp/kc_idp_config.json"))
cfg["nameIDPolicyFormat"] = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
cfg["principalType"] = "Subject"
cfg["wantAuthnRequestsSigned"] = "false"
cfg["wantAssertionsSigned"] = "true"
cfg["wantAssertionsEncrypted"] = "false"
cfg["postBindingResponse"] = "true"
cfg["postBindingAuthnRequest"] = "true"
cfg["validateSignature"] = "true"
cfg["syncMode"] = "FORCE"
cfg["entityId"] = "https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}"

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

  HTTP=$(curl -s -o /tmp/kc_idp_existing.json -w "%{http_code}" "${AUTH[@]}" \
    "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}")
  if [[ "$HTTP" == "200" ]]; then
    echo "  exists, updating ..."
    curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
      --data @/tmp/kc_idp_payload.json \
      "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /dev/null
  else
    echo "  creating ..."
    curl -fsS -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
      --data @/tmp/kc_idp_payload.json \
      "$API/identity-provider/instances" > /dev/null
  fi
  echo "  OK"

  echo "[2/4] (idc) SAML attribute mappers (email / firstName / lastName) ..."
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

else
  echo "[1/4] (ad) Disable SAML IdP '$KEYCLOAK_IDP_ALIAS' if exists ..."
  HTTP=$(curl -s -o /tmp/kc_idp_curr.json -w "%{http_code}" "${AUTH[@]}" \
    "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}")
  if [[ "$HTTP" == "200" ]]; then
    python3 - <<'PYEOF' > /tmp/kc_idp_disabled.json
import json
d = json.load(open("/tmp/kc_idp_curr.json"))
d["enabled"] = False
json.dump(d, open("/tmp/kc_idp_disabled.json","w"))
PYEOF
    curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
      --data @/tmp/kc_idp_disabled.json \
      "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /dev/null
    echo "  disabled."
  else
    echo "  not present (HTTP $HTTP), nothing to do."
  fi
  echo "[2/4] (ad) (LDAP federation expected to be configured via Admin UI; not modified here.)"
  echo
fi

###############################################################################
# 3) OIDC public client — both scenarios
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

EXISTING=$(curl -fsS "${AUTH[@]}" \
  "$API/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}")
INTERNAL_ID=$(printf '%s' "$EXISTING" | python3 -c '
import json,sys
arr=json.load(sys.stdin)
print(arr[0]["id"] if arr else "")
')

if [[ -z "$INTERNAL_ID" ]]; then
  echo "  creating ..."
  LOC=$(curl -fsS -i -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_client.json \
    "$API/clients" | awk -F': ' 'tolower($1)=="location" {print $2}' | tr -d '\r')
  INTERNAL_ID="${LOC##*/}"
  echo "  internalId = $INTERNAL_ID"
else
  echo "  exists ($INTERNAL_ID), updating ..."
  printf '%s' "$EXISTING" > /tmp/kc_client_old.json
  python3 - <<PYEOF > /tmp/kc_client_merged.json
import json
old = json.load(open("/tmp/kc_client_old.json"))[0]
new = json.load(open("/tmp/kc_client.json"))
new["id"] = old["id"]
json.dump(new, open("/tmp/kc_client_merged.json","w"))
PYEOF
  curl -fsS -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    --data @/tmp/kc_client_merged.json \
    "$API/clients/${INTERNAL_ID}" > /dev/null
fi
echo "  OK"

echo "  ensuring scopes (default: email/profile, optional: offline_access) ..."
curl -fsS "${AUTH[@]}" "$API/client-scopes" > /tmp/kc_scopes.json

ensure_scope() {
  local scope_name="$1" mode="$2"
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
    echo "    (skip $scope_name — realm-level scope not present, e.g. 'openid' is OIDC-protocol-level)"
    return
  fi
  curl -fsS -X PUT "${AUTH[@]}" \
    "$API/clients/${INTERNAL_ID}/${mode}/${sid}" > /dev/null || true
  echo "    $scope_name -> $mode (set)"
}

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

if [[ "$SCENARIO" == "idc" ]]; then
  curl -fsS "${AUTH[@]}" \
    "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /tmp/kc_idp_final.json
  python3 - <<'PYEOF'
import json
d = json.load(open("/tmp/kc_idp_final.json"))
cfg = d.get("config") or {}
print(f"  IdP alias        = {d.get('alias')}")
print(f"  enabled          = {d.get('enabled')}")
print(f"  entityId(SP)     = {cfg.get('entityId')}")
print(f"  IdP SSO URL      = {cfg.get('singleSignOnServiceUrl')}")
print(f"  nameIDFormat     = {cfg.get('nameIDPolicyFormat')}")
print(f"  syncMode         = {cfg.get('syncMode')}")
PYEOF
fi

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
echo "Done. Scenario: $SCENARIO"
