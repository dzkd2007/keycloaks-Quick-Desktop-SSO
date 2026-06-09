#!/usr/bin/env bash
# deploy-infra.sh — Orchestrate the 3 CloudFormation stacks for QuickSuite Desktop SSO.
#
# Phases:
#   1. Validate prerequisites (CLI, region, .env, hosted zone, ACM cert)
#   2. Deploy 01-managed-ad.yaml      (~30 min on first create)
#   3. Deploy 02-keycloak-infra.yaml  (~10 min)
#   4. Deploy 02b-cloudfront.yaml     (~5–10 min)
#   5. Update Route53 to point KEYCLOAK_DOMAIN at CloudFront
#   6. Wait for keycloak.<domain>/realms/master health-check to come back 200
#
# Re-running is safe — `aws cloudformation deploy` does an UPDATE on existing stacks
# and a no-op if nothing changed. Route53 record uses UPSERT.

set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. cp .env.example .env and fill it in first."
  exit 1
fi
# shellcheck disable=SC1091
set -a; . ./.env; set +a

require() {
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "ERROR: env var $v is not set in .env"; exit 1
    fi
  done
}

require AWS_REGION AWS_ACCOUNT_ID VPC_ID PRIVATE_SUBNET_1 PRIVATE_SUBNET_2 \
        PUBLIC_SUBNET_1 PUBLIC_SUBNET_2 ECS_SUBNET \
        AD_DOMAIN_NAME AD_SHORT_NAME AD_ADMIN_PASSWORD \
        ROUTE53_HOSTED_ZONE_ID KEYCLOAK_DOMAIN ORIGIN_ALIAS_NAME CERTIFICATE_ARN \
        KEYCLOAK_ADMIN_PASSWORD DB_MASTER_PASSWORD ALB_INGRESS_PREFIX_LIST_ID

if [[ "$AWS_REGION" != "us-east-1" ]]; then
  echo "ERROR: AWS_REGION must be us-east-1 (CloudFront ACM + Quick Desktop home region)."
  exit 1
fi

STACK_AD="quicksuite-managed-ad"
STACK_KC="quicksuite-keycloak"
STACK_CF="quicksuite-keycloak-cf"

###############################################################################
echo "================================================================"
echo " Phase 1 / 5  —  Pre-flight checks"
echo "================================================================"
ACTUAL_ACCT=$(aws sts get-caller-identity --query Account --output text)
if [[ "$ACTUAL_ACCT" != "$AWS_ACCOUNT_ID" ]]; then
  echo "ERROR: aws-cli is signed in to account $ACTUAL_ACCT but .env says $AWS_ACCOUNT_ID."
  exit 1
fi

aws acm describe-certificate --certificate-arn "$CERTIFICATE_ARN" --region "$AWS_REGION" \
  --query 'Certificate.Status' --output text \
  | grep -q ISSUED || { echo "ERROR: ACM cert $CERTIFICATE_ARN not in ISSUED state"; exit 1; }

aws route53 get-hosted-zone --id "$ROUTE53_HOSTED_ZONE_ID" \
  --query 'HostedZone.Name' --output text > /dev/null \
  || { echo "ERROR: Route53 hosted zone $ROUTE53_HOSTED_ZONE_ID not accessible"; exit 1; }

# Check both KEYCLOAK_DOMAIN and ORIGIN_ALIAS_NAME live under the hosted zone
HZ_ROOT=$(aws route53 get-hosted-zone --id "$ROUTE53_HOSTED_ZONE_ID" \
  --query 'HostedZone.Name' --output text | sed 's/\.$//')
for d in "$KEYCLOAK_DOMAIN" "$ORIGIN_ALIAS_NAME"; do
  if [[ "$d" != *"$HZ_ROOT" ]]; then
    echo "ERROR: '$d' is not under hosted zone '$HZ_ROOT'"; exit 1
  fi
done

echo "  OK — account, region, ACM cert, hosted zone all valid"

###############################################################################
echo
echo "================================================================"
echo " Phase 2 / 5  —  Managed AD ($STACK_AD)"
echo " (first-time create takes ~30 min — go get coffee)"
echo "================================================================"
aws cloudformation deploy \
  --template-file 01-managed-ad.yaml \
  --stack-name "$STACK_AD" \
  --region "$AWS_REGION" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    DomainName="$AD_DOMAIN_NAME" \
    DomainShortName="$AD_SHORT_NAME" \
    AdminPassword="$AD_ADMIN_PASSWORD" \
    Edition="${AD_EDITION:-Standard}" \
  --no-fail-on-empty-changeset

# Capture outputs
AD_DIR_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_AD" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DirectoryId'].OutputValue" --output text)
AD_IP_1=$(aws cloudformation describe-stacks --stack-name "$STACK_AD" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DnsIpAddress1'].OutputValue" --output text)
AD_IP_2=$(aws cloudformation describe-stacks --stack-name "$STACK_AD" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DnsIpAddress2'].OutputValue" --output text)

echo "  Directory: $AD_DIR_ID  DNS: $AD_IP_1, $AD_IP_2"

# Persist into .env (helps later scripts and humans)
update_env() {
  local key=$1 val=$2
  if grep -qE "^$key=" .env; then
    # macOS sed needs -i ''
    sed -i.bak -E "s|^$key=.*|$key=$val|" .env && rm -f .env.bak
  else
    echo "$key=$val" >> .env
  fi
}
update_env AD_DIRECTORY_ID "$AD_DIR_ID"
update_env AD_DNS_IP_1 "$AD_IP_1"
update_env AD_DNS_IP_2 "$AD_IP_2"

###############################################################################
echo
echo "================================================================"
echo " Phase 3 / 5  —  Keycloak ECS + Aurora + ALB ($STACK_KC)"
echo "================================================================"
aws cloudformation deploy \
  --template-file 02-keycloak-infra.yaml \
  --stack-name "$STACK_KC" \
  --capabilities CAPABILITY_IAM \
  --region "$AWS_REGION" \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    EcsSubnetIds="$ECS_SUBNET" \
    PublicSubnet1Id="$PUBLIC_SUBNET_1" \
    PublicSubnet2Id="$PUBLIC_SUBNET_2" \
    CertificateArn="$CERTIFICATE_ARN" \
    KeycloakDomainName="$KEYCLOAK_DOMAIN" \
    KeycloakImage="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:25.0}" \
    KeycloakAdminUser="$KEYCLOAK_ADMIN_USER" \
    KeycloakAdminPassword="$KEYCLOAK_ADMIN_PASSWORD" \
    DBMasterUsername="$DB_MASTER_USERNAME" \
    DBMasterPassword="$DB_MASTER_PASSWORD" \
    ManagedADDnsIp1="$AD_IP_1" \
    ManagedADDnsIp2="$AD_IP_2" \
    ManagedADDomainName="$AD_DOMAIN_NAME" \
    AlbIngressPrefixListIds="$ALB_INGRESS_PREFIX_LIST_ID" \
  --no-fail-on-empty-changeset

# Pull ALB DNS + canonical zone (for Route53 alias used by CloudFront stack)
ALB_DNS=$(aws cloudformation describe-stacks --stack-name "$STACK_KC" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" --output text)
ALB_ZONE=$(aws cloudformation describe-stacks --stack-name "$STACK_KC" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBHostedZoneId'].OutputValue" --output text)

if [[ -z "$ALB_DNS" ]]; then
  # Fallback: query ELBv2 directly if outputs aren't named like that
  ALB_DNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,'keycloak')].DNSName | [0]" --output text)
  ALB_ZONE=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName,'keycloak')].CanonicalHostedZoneId | [0]" --output text)
fi
update_env ALB_DNS_NAME "$ALB_DNS"
update_env ALB_HOSTED_ZONE_ID "$ALB_ZONE"
echo "  ALB: $ALB_DNS  zone $ALB_ZONE"

###############################################################################
echo
echo "================================================================"
echo " Phase 4 / 5  —  CloudFront ($STACK_CF)"
echo "================================================================"
aws cloudformation deploy \
  --template-file 02b-cloudfront.yaml \
  --stack-name "$STACK_CF" \
  --region "$AWS_REGION" \
  --parameter-overrides \
    KeycloakDomainName="$KEYCLOAK_DOMAIN" \
    CertificateArn="$CERTIFICATE_ARN" \
    AlbDnsName="$ALB_DNS" \
    AlbHostedZoneId="$ALB_ZONE" \
    Route53HostedZoneId="$ROUTE53_HOSTED_ZONE_ID" \
    OriginAliasName="$ORIGIN_ALIAS_NAME" \
  --no-fail-on-empty-changeset

CF_DNS=$(aws cloudformation describe-stacks --stack-name "$STACK_CF" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionDomainName'].OutputValue" --output text)
CF_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_CF" --region "$AWS_REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text)
update_env CLOUDFRONT_DOMAIN_NAME "$CF_DNS"
update_env CLOUDFRONT_DISTRIBUTION_ID "$CF_ID"
echo "  CloudFront: $CF_ID  ($CF_DNS)"

###############################################################################
echo
echo "================================================================"
echo " Phase 5 / 5  —  Route53 ($KEYCLOAK_DOMAIN -> CloudFront)"
echo "================================================================"
cat > /tmp/r53-change.json <<JSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${KEYCLOAK_DOMAIN}.",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "Z2FDTNDATAQYW2",
        "DNSName": "${CF_DNS}.",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
JSON
aws route53 change-resource-record-sets \
  --hosted-zone-id "$ROUTE53_HOSTED_ZONE_ID" \
  --change-batch file:///tmp/r53-change.json \
  --query 'ChangeInfo.Status' --output text

###############################################################################
echo
echo "================================================================"
echo " Waiting for Keycloak admin endpoint to become reachable ..."
echo "================================================================"
TARGET="https://${KEYCLOAK_DOMAIN}/realms/master/.well-known/openid-configuration"
for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "$TARGET" > /dev/null 2>&1; then
    echo "  OK after ~${i}0s — Keycloak is reachable at $TARGET"
    break
  fi
  printf "."
  sleep 10
done
echo

cat <<EOF
================================================================
 Infra deploy complete.

 Next steps (manual):
   1. Bootstrap the Keycloak realm — see 03-keycloak-realm-config.md §1
   2. Create the IdC SAML application — see 04-identity-center-setup.md
   3. Run ./configure-keycloak.sh to wire SAML IdP + OIDC public client
   4. Run ./verify-oidc.sh
   5. Add Quick Extension Access — see 05-quick-extension-access.md
   6. Install Quick Desktop and try Enterprise login.

 Useful endpoints:
   Admin UI       : https://${KEYCLOAK_DOMAIN}/admin
   OIDC discovery : https://${KEYCLOAK_DOMAIN}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration
   ALB DNS        : ${ALB_DNS}
   CloudFront     : ${CF_DNS} (id ${CF_ID})
================================================================
EOF
