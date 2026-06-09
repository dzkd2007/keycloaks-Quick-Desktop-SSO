#!/usr/bin/env bash
# disable-saml-idp.sh — Disable (not delete) the iam-identity-center SAML IdP
# in Keycloak realm. Keeps it for rollback if we ever switch back to the
# IdC-backed Quick scenario.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

API="https://${KEYCLOAK_DOMAIN}/admin/realms/${KEYCLOAK_REALM}"

TOKEN=$(curl -fsS --max-time 10 \
  "https://${KEYCLOAK_DOMAIN}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="${KEYCLOAK_ADMIN_USER}" -d password="${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

HTTP=$(curl -s -o /tmp/kc_idp_curr.json -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}")

if [[ "$HTTP" != "200" ]]; then
  echo "  IdP '$KEYCLOAK_IDP_ALIAS' not found (HTTP $HTTP). Nothing to do."
  exit 0
fi

python3 - <<'PYEOF' > /tmp/kc_idp_disabled.json
import json
d = json.load(open("/tmp/kc_idp_curr.json"))
d["enabled"] = False
json.dump(d, open("/tmp/kc_idp_disabled.json","w"))
PYEOF

curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data @/tmp/kc_idp_disabled.json \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /dev/null

curl -fsS -H "Authorization: Bearer $TOKEN" \
  "$API/identity-provider/instances/${KEYCLOAK_IDP_ALIAS}" > /tmp/kc_idp_after.json
python3 - <<'PYEOF'
import json
d = json.load(open("/tmp/kc_idp_after.json"))
print(f"  alias={d.get('alias')}  enabled={d.get('enabled')}")
PYEOF
