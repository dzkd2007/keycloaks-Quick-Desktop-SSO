#!/usr/bin/env bash
# verify-oidc.sh — Sanity-check the public OIDC endpoints that Amazon Quick
# Desktop will consume.
#
# Quick Desktop expects:
#   - Standard OIDC discovery document at <issuer>/.well-known/openid-configuration
#   - Authorization Code + PKCE flow (no client secret)
#   - Reachable JWKS URI
#   - Issuer URL is the realm root (NOT the discovery URL)
#
# This script does NOT perform an end-to-end login because the actual login
# now happens via SAML against IAM Identity Center, which requires a real
# browser session. Use a browser to do the end-to-end test (Step 5 in 05-quick-extension-access.md).
#
# Usage:
#   ./verify-oidc.sh

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in $(pwd)"; exit 1
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${KEYCLOAK_DOMAIN:?KEYCLOAK_DOMAIN not set in .env}"
: "${KEYCLOAK_REALM:?KEYCLOAK_REALM not set in .env}"
: "${KEYCLOAK_OIDC_CLIENT_ID:?KEYCLOAK_OIDC_CLIENT_ID not set in .env}"

ISSUER="https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}"
DISCOVERY="${ISSUER}/.well-known/openid-configuration"

echo "==================== verify-oidc.sh ===================="
echo "Issuer    : $ISSUER"
echo "Client ID : $KEYCLOAK_OIDC_CLIENT_ID  (public, PKCE)"
echo "========================================================"
echo

# --- 1. Discovery document --------------------------------------------------
echo "[1/4] OIDC discovery ..."
DISC_JSON=$(curl -fsS --max-time 10 "$DISCOVERY")
python3 - <<PYEOF
import json, sys
d = json.loads('''$DISC_JSON''')
need = ["issuer","authorization_endpoint","token_endpoint","jwks_uri",
        "response_types_supported","grant_types_supported",
        "code_challenge_methods_supported"]
missing = [k for k in need if k not in d]
print(f"   issuer        : {d.get('issuer')}")
print(f"   authorization : {d.get('authorization_endpoint')}")
print(f"   token         : {d.get('token_endpoint')}")
print(f"   jwks_uri      : {d.get('jwks_uri')}")
print(f"   PKCE methods  : {d.get('code_challenge_methods_supported')}")
print(f"   grant_types   : {d.get('grant_types_supported')}")
if missing:
    print(f"   FAIL — missing fields: {missing}"); sys.exit(1)
if "S256" not in (d.get("code_challenge_methods_supported") or []):
    print("   FAIL — S256 PKCE not advertised"); sys.exit(1)
if "authorization_code" not in (d.get("grant_types_supported") or []):
    print("   FAIL — authorization_code grant not supported"); sys.exit(1)
if "refresh_token" not in (d.get("grant_types_supported") or []):
    print("   WARN — refresh_token grant missing; offline_access scope won't work")
PYEOF
echo

# --- 2. JWKS reachable & has at least one signing key -----------------------
echo "[2/4] JWKS endpoint ..."
JWKS=$(curl -fsS --max-time 10 "$(echo "$DISC_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["jwks_uri"])')")
python3 - <<PYEOF
import json, sys
j = json.loads('''$JWKS''')
keys = j.get("keys", [])
print(f"   keys returned : {len(keys)}")
if not keys:
    print("   FAIL — no keys"); sys.exit(1)
for k in keys[:3]:
    print(f"     kid={k.get('kid')} alg={k.get('alg')} use={k.get('use')}")
PYEOF
echo

# --- 3. Confirm the OIDC client exists & is correctly configured ------------
echo "[3/4] OIDC client config (via Admin REST) ..."
TOKEN=$(curl -fsS --max-time 10 "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password \
  -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER}" \
  -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')

CLIENT_JSON=$(curl -fsS --max-time 10 \
  -H "Authorization: Bearer $TOKEN" \
  "https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OIDC_CLIENT_ID}")

python3 - <<PYEOF
import json, sys
arr = json.loads('''$CLIENT_JSON''')
if not arr:
    print(f"   FAIL — client '${KEYCLOAK_OIDC_CLIENT_ID}' does not exist in realm '${KEYCLOAK_REALM}'")
    sys.exit(1)
c = arr[0]
checks = {
    "publicClient (no secret)"     : c.get("publicClient") is True,
    "standardFlowEnabled"          : c.get("standardFlowEnabled") is True,
    "directAccessGrantsEnabled OFF": c.get("directAccessGrantsEnabled") is False,
    "redirectUris == [http://localhost:18080]" : c.get("redirectUris") == ["http://localhost:18080"],
    "PKCE S256"                    : (c.get("attributes") or {}).get("pkce.code.challenge.method") == "S256",
}
ok = True
for k,v in checks.items():
    print(f"   {'OK' if v else 'FAIL'}  {k}  ({c.get(k.split()[0]) if k.split()[0] in c else ''})")
    ok = ok and v
print()
print(f"   default scopes : {c.get('defaultClientScopes')}")
print(f"   optional scopes: {c.get('optionalClientScopes')}")
# Note: 'openid' is an OIDC-protocol-level scope (always implicitly present
# when the client uses the openid-connect protocol), NOT a Keycloak realm
# client scope. So we don't check for it here.
need_default = {"email","profile"}
need_optional = {"offline_access"}
have_default = set(c.get("defaultClientScopes") or [])
have_optional = set(c.get("optionalClientScopes") or [])
missing_d = need_default - have_default
missing_o = need_optional - have_optional
if missing_d:
    print(f"   FAIL — missing default scopes: {missing_d}"); ok = False
if missing_o:
    print(f"   FAIL — missing optional scopes: {missing_o}"); ok = False
if not ok:
    sys.exit(1)
PYEOF
echo

# --- 4. SAML IdP brokering check -------------------------------------------
echo "[4/4] SAML Identity Provider (IdC) is wired in Keycloak ..."
IDP_JSON=$(curl -fsS --max-time 10 \
  -H "Authorization: Bearer $TOKEN" \
  "https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" \
  || echo '{}')

python3 - <<PYEOF
import json, sys
d = json.loads('''$IDP_JSON''')
if not d.get("alias"):
    print(f"   FAIL — Identity Provider '${KEYCLOAK_IDP_ALIAS}' not found in Keycloak yet.")
    print("          You haven't completed Step 3.5 (add SAML IdP). That's fine if you")
    print("          haven't reached that step; come back and rerun.")
    sys.exit(1)
print(f"   alias            : {d.get('alias')}")
print(f"   providerId       : {d.get('providerId')}")
cfg = d.get('config') or {}
print(f"   entityId         : {cfg.get('entityId')}")
print(f"   ssoUrl           : {cfg.get('singleSignOnServiceUrl')}")
print(f"   nameIDPolicyFmt  : {cfg.get('nameIDPolicyFormat')}")
print(f"   syncMode         : {cfg.get('syncMode')}")
PYEOF
echo

echo "OK — Keycloak side looks good."
echo
echo "Manual end-to-end test (browser required):"
echo "  https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth?\\"
echo "    client_id=${KEYCLOAK_OIDC_CLIENT_ID}&\\"
echo "    response_type=code&\\"
echo "    scope=openid+email+profile+offline_access&\\"
echo "    redirect_uri=http%3A%2F%2Flocalhost%3A18080&\\"
echo "    code_challenge=<S256 of a verifier>&\\"
echo "    code_challenge_method=S256"
echo
echo "Or just install Quick Desktop and click 'Enterprise login'."
