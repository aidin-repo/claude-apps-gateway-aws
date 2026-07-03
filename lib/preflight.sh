#!/usr/bin/env bash
# Preflight checks for the claude apps gateway deploy. Read-only. Fails fast
# with a clear message so mistakes surface BEFORE CloudFormation creates
# resources. Sourced by deploy.sh; also usable standalone via `bash lib/preflight.sh`.
#
# Requires deploy.env to be loaded before this runs (deploy.sh handles that).

set -euo pipefail

_pf_log() { printf '    [preflight] %s\n' "$*"; }
_pf_die() { printf '\n\033[1;31m[preflight] FAIL: %s\033[0m\n' "$*" >&2; exit 1; }
_pf_ok()  { printf '    \033[1;32m[preflight] ok:\033[0m %s\n' "$*"; }

preflight_run() {
  printf '\n\033[1;36m==> Preflight checks (read-only)\033[0m\n'

  for var in NAME_PREFIX REGION VPC_ID VPC_CIDR SUBNET_A SUBNET_B CERT_ARN ZONE_ID \
             HOSTNAME_FQDN IMAGE_URI OIDC_ISSUER OIDC_CLIENT_ID \
             OIDC_CLIENT_SECRET EMAIL_DOMAIN ADMIN_GROUP BEDROCK_REGION \
             OTEL_COLLECTOR_TAG; do
    eval "val=\${$var:-}"
    [ -n "$val" ] || _pf_die "$var is required (set it in deploy.env)."
  done
  _pf_ok "all required env vars set"

  # NAME_PREFIX character/length rules: matches phase2-fargate.yaml AllowedPattern
  # (1-19 chars, lowercase alphanumeric + hyphens, no leading/trailing hyphen).
  # Enforced here as well so failures surface locally before a CFN call.
  case "$NAME_PREFIX" in
    -* | *- ) _pf_die "NAME_PREFIX '$NAME_PREFIX' cannot start or end with a hyphen." ;;
  esac
  if ! printf '%s' "$NAME_PREFIX" | grep -qE '^[a-z0-9][a-z0-9-]{0,18}$'; then
    _pf_die "NAME_PREFIX '$NAME_PREFIX' must be 1-19 chars, lowercase alphanumeric + hyphens."
  fi
  _pf_ok "NAME_PREFIX '$NAME_PREFIX' passes naming rules"

  for tool in aws curl envsubst grep openssl; do
    command -v "$tool" >/dev/null || _pf_die "$tool not found on PATH."
  done
  _pf_ok "required CLIs present"

  local ACCOUNT_ID
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
    || _pf_die "AWS credentials not working. Run 'aws sso login' or set AWS_PROFILE."
  _pf_ok "aws sts get-caller-identity ok (account $ACCOUNT_ID, region $REGION)"

  aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" >/dev/null 2>&1 \
    || _pf_die "VPC $VPC_ID not found in $REGION for this account."
  _pf_ok "VPC $VPC_ID exists"

  local subnet_a_vpc subnet_b_vpc subnet_a_az subnet_b_az
  subnet_a_vpc=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_A" --region "$REGION" \
    --query 'Subnets[0].VpcId' --output text 2>/dev/null) || _pf_die "SUBNET_A $SUBNET_A not found."
  subnet_b_vpc=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_B" --region "$REGION" \
    --query 'Subnets[0].VpcId' --output text 2>/dev/null) || _pf_die "SUBNET_B $SUBNET_B not found."
  [ "$subnet_a_vpc" = "$VPC_ID" ] || _pf_die "SUBNET_A is in VPC $subnet_a_vpc, not $VPC_ID."
  [ "$subnet_b_vpc" = "$VPC_ID" ] || _pf_die "SUBNET_B is in VPC $subnet_b_vpc, not $VPC_ID."
  subnet_a_az=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_A" --region "$REGION" \
    --query 'Subnets[0].AvailabilityZone' --output text)
  subnet_b_az=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_B" --region "$REGION" \
    --query 'Subnets[0].AvailabilityZone' --output text)
  [ "$subnet_a_az" != "$subnet_b_az" ] \
    || _pf_die "SUBNET_A and SUBNET_B are both in $subnet_a_az. ALB + RDS require two AZs."
  _pf_ok "subnets in different AZs ($subnet_a_az, $subnet_b_az) and both in $VPC_ID"

  local cert_region cert_status cert_sans
  cert_region=$(printf '%s' "$CERT_ARN" | awk -F: '{print $4}')
  [ "$cert_region" = "$REGION" ] \
    || _pf_die "CERT_ARN region ($cert_region) does not match REGION ($REGION). ACM certs are per-region."
  cert_status=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
    --query 'Certificate.Status' --output text 2>/dev/null) \
    || _pf_die "ACM cert $CERT_ARN not found in $REGION."
  [ "$cert_status" = "ISSUED" ] || _pf_die "ACM cert status is $cert_status (need ISSUED)."
  cert_sans=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
    --query 'Certificate.SubjectAlternativeNames' --output text)
  if ! printf '%s' "$cert_sans" | tr '\t' '\n' | awk -v h="$HOSTNAME_FQDN" '
      { san=$0; sub(/^\*\./, "", san); if (san==h) { m=1; next }
        if (index($0,"*.")==1) { suf=substr($0,2);
          if (length(h) > length(suf) && index(h,suf)==length(h)-length(suf)+1) m=1 } }
      END { exit m ? 0 : 1 }'; then
    _pf_die "ACM cert SANs [$cert_sans] do not cover $HOSTNAME_FQDN."
  fi
  _pf_ok "ACM cert ISSUED in $REGION with SAN covering $HOSTNAME_FQDN"

  local zone_private
  zone_private=$(aws route53 get-hosted-zone --id "$ZONE_ID" \
    --query 'HostedZone.Config.PrivateZone' --output text 2>/dev/null) \
    || _pf_die "Route 53 zone $ZONE_ID not found."
  if [ "$zone_private" = "True" ]; then
    _pf_ok "Route 53 zone $ZONE_ID is private"
  elif [ "${PREFLIGHT_ALLOW_PUBLIC_ZONE:-no}" = "yes" ]; then
    printf '    \033[1;33m[preflight] WARN:\033[0m Route 53 zone %s is PUBLIC. Bypassed (PREFLIGHT_ALLOW_PUBLIC_ZONE=yes). Public A-alias to internal ALB IPs leaks topology to public DNS.\n' "$ZONE_ID"
  else
    _pf_die "Route 53 zone $ZONE_ID is PUBLIC. Gateway ALB is internal — a public A-alias leaks private IPs to public DNS. Use a private hosted zone, or set PREFLIGHT_ALLOW_PUBLIC_ZONE=yes to bypass this check for POC use."
  fi

  curl -fsS --max-time 10 "${OIDC_ISSUER%/}/.well-known/openid-configuration" >/dev/null \
    || _pf_die "OIDC discovery failed for $OIDC_ISSUER/.well-known/openid-configuration. Fix the issuer URL before deploy."
  _pf_ok "OIDC issuer $OIDC_ISSUER reachable"

  aws bedrock list-foundation-models --by-provider anthropic --region "$BEDROCK_REGION" \
    --query 'modelSummaries[0].modelId' --output text >/dev/null 2>&1 \
    || _pf_die "Bedrock list-foundation-models failed in $BEDROCK_REGION. Enable Bedrock + request Anthropic model access in the console."
  _pf_ok "Bedrock reachable in $BEDROCK_REGION (model access still requires console opt-in per model — see README §4)"

  local img_name img_tag
  img_name=$(printf '%s' "$IMAGE_URI" | awk -F/ '{print $NF}' | awk -F: '{print $1}')
  img_tag=$(printf '%s' "$IMAGE_URI" | awk -F: '{print $NF}')
  aws ecr describe-images --repository-name "$img_name" --image-ids imageTag="$img_tag" \
    --region "$REGION" >/dev/null 2>&1 \
    || _pf_die "Image $IMAGE_URI not found in ECR. Build and push it first (see README §5)."
  _pf_ok "image $IMAGE_URI present in ECR"

  local stale=""
  for s in jwt-secret db-password oidc admin-write-key; do
    local deleted
    deleted=$(aws secretsmanager describe-secret --secret-id "${NAME_PREFIX}/${s}" --region "$REGION" \
      --query 'DeletedDate' --output text 2>/dev/null || echo "None")
    if [ "$deleted" != "None" ] && [ -n "$deleted" ]; then
      stale="${stale} ${NAME_PREFIX}/${s}"
    fi
  done
  if [ -n "$stale" ]; then
    _pf_die "Secrets scheduled for deletion (30-day recovery window):${stale}. Run: aws secretsmanager restore-secret --secret-id <name> --region $REGION  (or wait out the window)."
  fi
  _pf_ok "no stale secret tombstones for ${NAME_PREFIX}/*"

  [ -f phase2-fargate.yaml ] || _pf_die "phase2-fargate.yaml missing — run from the project root."
  [ -f gateway.yaml.template ] || _pf_die "gateway.yaml.template missing — run from the project root."
  _pf_ok "template files present"

  printf '\033[1;32m    all preflight checks passed\033[0m\n'
}

# Standalone entrypoint: `bash lib/preflight.sh` sources deploy.env and runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ENV_FILE="${DEPLOY_ENV_FILE:-deploy.env}"
  [ -f "$ENV_FILE" ] || _pf_die "$ENV_FILE not found. Copy deploy.env.example -> deploy.env and fill it in."
  set -a; . "$ENV_FILE"; set +a
  preflight_run
fi
