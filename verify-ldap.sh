#!/usr/bin/env bash
# verify-ldap.sh - Pre-flight check for Step 3 LDAP federation.
#
# Runs from inside an ECS Keycloak task (via ECS Exec) so the network path
# matches what Keycloak's LDAP federation will use at runtime. Validates:
#   1. TCP reach on 389 to both Managed AD DCs
#   2. LDAP simple bind with the admin DN + password
#   3. A baseline LDAP search on the Users DN
#
# Pass = you can confidently fill the Admin UI form (03-keycloak-realm-config.md).
#
# Usage:
#   ./verify-ldap.sh
#
# All values are sourced from .env in the same directory.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in $(pwd)"; exit 1
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${AD_DNS_IP_1:?AD_DNS_IP_1 not set in .env}"
: "${AD_DNS_IP_2:?AD_DNS_IP_2 not set in .env}"
: "${AD_DOMAIN_NAME:?AD_DOMAIN_NAME not set in .env}"
: "${AD_ADMIN_PASSWORD:?AD_ADMIN_PASSWORD not set in .env}"

# Derived: BaseDN, AdminBindDN, UsersDN
DC_PARTS=$(echo "$AD_DOMAIN_NAME" | awk -F. '{ for (i=1;i<=NF;i++) printf "%sDC=%s",(i>1?",":""),$i }')
SHORTNAME_UC=$(echo "${AD_SHORT_NAME:-CORP}" | tr '[:lower:]' '[:upper:]')
ADMIN_BIND_DN="CN=Admin,OU=Users,OU=${SHORTNAME_UC},${DC_PARTS}"
USERS_DN="OU=Users,OU=${SHORTNAME_UC},${DC_PARTS}"

REGION=${AWS_REGION:-us-east-1}
CLUSTER=${ECS_CLUSTER_NAME:-keycloak-cluster}
SERVICE=${ECS_SERVICE_NAME:-keycloak}

echo "==================== verify-ldap.sh ===================="
echo "AD domain     : $AD_DOMAIN_NAME"
echo "AD DC #1      : $AD_DNS_IP_1"
echo "AD DC #2      : $AD_DNS_IP_2"
echo "Admin Bind DN : $ADMIN_BIND_DN"
echo "Users DN      : $USERS_DN"
echo "ECS cluster   : $CLUSTER / $SERVICE  ($REGION)"
echo "========================================================"
echo

TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --region "$REGION" --desired-status RUNNING \
  --query 'taskArns[0]' --output text)
if [[ "$TASK_ARN" == "None" || -z "$TASK_ARN" ]]; then
  echo "ERROR: no running task in $CLUSTER/$SERVICE"; exit 1
fi
TASK_ID=${TASK_ARN##*/}
echo "Using task: $TASK_ID"
echo

run_in_task() {
  # $1: bash command. Returns full stdout+stderr.
  aws ecs execute-command --cluster "$CLUSTER" --task "$TASK_ID" \
    --container keycloak --interactive --region "$REGION" \
    --command "/bin/bash -c '$1'" 2>&1
}

# --- Step 1: TCP reachability on 389 -----------------------------------------
echo "[1/3] TCP reach to AD DCs on port 389 ..."
for IP in "$AD_DNS_IP_1" "$AD_DNS_IP_2"; do
  OUT=$(run_in_task "timeout 5 bash -c \"</dev/tcp/${IP}/389\" && echo TCP_OK || echo TCP_FAIL")
  if echo "$OUT" | grep -q TCP_OK; then
    printf "    %-15s -> OK\n" "$IP"
  else
    printf "    %-15s -> FAIL\n" "$IP"
    echo "$OUT" | tail -3
    echo "ERROR: cannot reach $IP:389 from ECS task. Check Managed AD SG."
    exit 1
  fi
done
echo

# --- Step 2 + 3: LDAP bind + search via JNDI Java program --------------------
echo "[2-3/3] LDAP simple bind + search via JNDI ..."

JAVA_PROG='import java.util.Hashtable;
import javax.naming.*;
import javax.naming.directory.*;
public class LdapCheck {
  public static void main(String[] a) throws Exception {
    String url = a[0], bindDn = a[1], pw = a[2], baseDn = a[3];
    Hashtable<String,String> env = new Hashtable<>();
    env.put(Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
    env.put(Context.PROVIDER_URL, url);
    env.put(Context.SECURITY_AUTHENTICATION, "simple");
    env.put(Context.SECURITY_PRINCIPAL, bindDn);
    env.put(Context.SECURITY_CREDENTIALS, pw);
    env.put("com.sun.jndi.ldap.connect.timeout", "5000");
    env.put("com.sun.jndi.ldap.read.timeout",    "5000");
    DirContext ctx = new InitialDirContext(env);
    System.out.println("BIND_OK");
    SearchControls c = new SearchControls();
    c.setSearchScope(SearchControls.SUBTREE_SCOPE);
    c.setCountLimit(5);
    c.setReturningAttributes(new String[]{"sAMAccountName","mail","cn"});
    NamingEnumeration<SearchResult> r = ctx.search(baseDn, "(objectClass=user)", c);
    int n = 0;
    while (r.hasMore()) {
      SearchResult sr = r.next();
      Attributes at = sr.getAttributes();
      Attribute sam = at.get("sAMAccountName");
      Attribute cn  = at.get("cn");
      System.out.println("  USER: cn=" + (cn==null?"":cn.get()) + ", sAM=" + (sam==null?"":sam.get()));
      n++;
    }
    System.out.println("SEARCH_OK count=" + n);
    ctx.close();
  }
}'
JAVA_B64=$(printf '%s' "$JAVA_PROG" | base64 | tr -d '\n')

LDAP_URL="ldap://${AD_DNS_IP_1}:389"

# Inside the container we need to find javac+java (UBI minimal layout). Newer
# Keycloak images expose JAVA_HOME=/usr/lib/jvm/jre but we still want to be
# defensive and locate the JDK used to launch the server (which has javac).
SCRIPT="
set -e
cd /tmp
echo $JAVA_B64 | base64 -d > LdapCheck.java
JAVA=\$(find / -path '*/bin/java'  -type f 2>/dev/null | grep -v src.zip | head -1)
if [ -z \"\$JAVA\" ]; then echo ERROR_NO_JAVA; exit 2; fi
# Java 11+ supports running a .java source file directly, no javac needed.
\"\$JAVA\" LdapCheck.java '$LDAP_URL' '$ADMIN_BIND_DN' '$AD_ADMIN_PASSWORD' '$USERS_DN'
"
RESULT=$(run_in_task "$SCRIPT" || true)
echo "$RESULT" | grep -E '^(BIND_OK|SEARCH_OK|  USER:|ERROR_|javax\.|Caused by)' || echo "$RESULT" | tail -20

echo
if echo "$RESULT" | grep -q SEARCH_OK; then
  COUNT=$(echo "$RESULT" | grep -oE 'SEARCH_OK count=[0-9]+' | tr -dc 0-9)
  echo "DONE. BIND_OK + SEARCH_OK (returned $COUNT users)."
  echo
  if [[ "$COUNT" == "1" ]]; then
    echo "NOTE: only 1 user found — that's the built-in Admin account. To test"
    echo "      real SSO, create some test users in Managed AD first (e.g. via"
    echo "      a domain-joined Windows EC2 + 'New-ADUser' PowerShell, or via"
    echo "      AWS Directory Service Data API)."
    echo
  fi
  echo "Next: open https://${KEYCLOAK_DOMAIN}/admin and follow"
  echo "      03-keycloak-realm-config.md to configure the federation."
  exit 0
else
  echo "FAILED. The Admin UI 'Test authentication' button will likely also fail."
  echo "Common causes:"
  echo "  - Bind DN spelled wrong (must include OU=Users,OU=CORP)"
  echo "  - AD admin password rotated; update .env  AD_ADMIN_PASSWORD"
  echo "  - Users DN wrong; verify by running ldapsearch from the AD-joined EC2"
  exit 1
fi
