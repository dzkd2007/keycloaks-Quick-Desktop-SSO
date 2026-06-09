#!/usr/bin/env bash
# inspect-ad.sh — Read-only snapshot of AD users + groups.
# Avoids shell-quoting issues by base64-encoding both the script and the
# Java program. Inside the ECS task we just decode and run.

set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; . ./.env; set +a

: "${AD_DNS_IP_1:?}"
: "${AD_ADMIN_PASSWORD:?}"
: "${AD_DOMAIN_NAME:?}"
: "${AD_SHORT_NAME:?}"

DC_PARTS=$(echo "$AD_DOMAIN_NAME" | awk -F. '{ for (i=1;i<=NF;i++) printf "%sDC=%s",(i>1?",":""),$i }')
ADMIN_BIND_DN="CN=Admin,OU=Users,OU=${AD_SHORT_NAME},${DC_PARTS}"
USERS_DN="OU=Users,OU=${AD_SHORT_NAME},${DC_PARTS}"

REGION=${AWS_REGION:-us-east-1}
CLUSTER=${ECS_CLUSTER_NAME:-keycloak-cluster}
SERVICE=${ECS_SERVICE_NAME:-keycloak}

TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
  --region "$REGION" --desired-status RUNNING --query 'taskArns[0]' --output text)
TASK_ID=${TASK##*/}

# Java program — does ONE LDAP search using filter from CLI args.
JAVA_PROG=$(cat <<'JEOF'
import java.util.Hashtable;
import javax.naming.*;
import javax.naming.directory.*;
public class LdapDump {
  public static void main(String[] a) throws Exception {
    String url=a[0], bindDn=a[1], pw=a[2], baseDn=a[3], filter=a[4];
    String[] attrs = {"sAMAccountName","cn","mail","givenName","sn","userPrincipalName","memberOf"};
    Hashtable<String,String> e = new Hashtable<>();
    e.put(Context.INITIAL_CONTEXT_FACTORY,"com.sun.jndi.ldap.LdapCtxFactory");
    e.put(Context.PROVIDER_URL,url);
    e.put(Context.SECURITY_AUTHENTICATION,"simple");
    e.put(Context.SECURITY_PRINCIPAL,bindDn);
    e.put(Context.SECURITY_CREDENTIALS,pw);
    e.put("com.sun.jndi.ldap.connect.timeout","5000");
    e.put("com.sun.jndi.ldap.read.timeout","5000");
    DirContext ctx = new InitialDirContext(e);
    SearchControls c = new SearchControls();
    c.setSearchScope(SearchControls.SUBTREE_SCOPE);
    c.setCountLimit(200);
    c.setReturningAttributes(attrs);
    NamingEnumeration<SearchResult> r = ctx.search(baseDn, filter, c);
    int n=0;
    while (r.hasMore()) {
      SearchResult sr = r.next();
      Attributes at = sr.getAttributes();
      StringBuilder sb = new StringBuilder("ENTRY ");
      sb.append("dn=").append(sr.getNameInNamespace());
      for (String k : attrs) {
        Attribute v = at.get(k);
        if (v != null) {
          NamingEnumeration<?> e2 = v.getAll();
          while (e2.hasMore()) sb.append(" | ").append(k).append("=").append(e2.next());
        }
      }
      System.out.println(sb.toString());
      n++;
    }
    System.out.println("TOTAL " + n);
    ctx.close();
  }
}
JEOF
)
JAVA_B64=$(printf '%s' "$JAVA_PROG" | base64 | tr -d '\n')

LDAP_URL="ldap://${AD_DNS_IP_1}:389"

run_query() {
  local label="$1" base="$2" filter="$3"
  echo "================================================================"
  echo " $label  ($filter)"
  echo "================================================================"

  # Build the full inner bash script as a heredoc, base64 it, hand to ECS exec.
  local INNER
  INNER=$(cat <<INNEREOF
set -e
cd /tmp
echo $JAVA_B64 | base64 -d > LdapDump.java
JAVA=\$(find / -path '*/bin/java' -type f 2>/dev/null | grep -v src.zip | head -1)
"\$JAVA" LdapDump.java "$LDAP_URL" "$ADMIN_BIND_DN" "$AD_ADMIN_PASSWORD" "$base" "$filter"
INNEREOF
)
  local INNER_B64
  INNER_B64=$(printf '%s' "$INNER" | base64 | tr -d '\n')

  # Outer script just decodes + runs the inner one.
  aws ecs execute-command --cluster "$CLUSTER" --task "$TASK_ID" \
    --container keycloak --interactive --region "$REGION" \
    --command "/bin/bash -c \"echo $INNER_B64 | base64 -d | bash\"" 2>&1 \
    | tail -30
  echo
}

run_query "Users in Users OU"  "$USERS_DN" "(objectClass=user)"
run_query "Groups in Users OU" "$USERS_DN" "(objectClass=group)"
