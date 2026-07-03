#!/usr/bin/env bash
# Interactive init flow for the Claude apps gateway deploy.
# Discovers AWS-side inputs (VPC, subnets, ACM cert, R53 zone, ECR image)
# and prompts for the human-decision inputs (OIDC, hostname, prefix, policy).
# Sourced by deploy.sh; also runnable standalone via `bash lib/init.sh`.
#
# Writes deploy.env atomically with mode 600 at the end (contains OIDC_CLIENT_SECRET).
# Prompts before overwriting an existing deploy.env.

set -euo pipefail

# ---- output helpers --------------------------------------------------------
_init_hdr()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
_init_info() { printf '    %s\n' "$*"; }
_init_ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
_init_warn() { printf '    \033[1;33m! %s\033[0m\n' "$*"; }
_init_die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- prompt helpers --------------------------------------------------------
# _prompt VAR "question" "default"     -> reads from stdin, uses default on empty
_prompt() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if [ -n "$__def" ]; then
    printf '    %s [%s]: ' "$__q" "$__def" >&2
  else
    printf '    %s: ' "$__q" >&2
  fi
  read -r __ans || true
  [ -z "$__ans" ] && __ans="$__def"
  eval "$__var=\"\$__ans\""
}

# _prompt_hidden VAR "question"        -> read -rs (no echo), no default
_prompt_hidden() {
  local __var="$1" __q="$2" __ans=""
  printf '    %s (hidden): ' "$__q" >&2
  read -rs __ans || true
  printf '\n' >&2
  eval "$__var=\"\$__ans\""
}

# _prompt_yn VAR "question" "default(y|n)"
_prompt_yn() {
  local __var="$1" __q="$2" __def="${3:-n}" __ans=""
  local __hint="y/N"
  [ "$__def" = "y" ] && __hint="Y/n"
  printf '    %s [%s]: ' "$__q" "$__hint" >&2
  read -r __ans || true
  [ -z "$__ans" ] && __ans="$__def"
  case "$__ans" in
    y|Y|yes|YES) eval "$__var=yes" ;;
    *)           eval "$__var=no"  ;;
  esac
}

# _pick VAR "prompt"  choices ...
# Presents a numbered list; user types the number. Sets VAR to the CHOSEN LINE.
# If there's only one choice, auto-selects and confirms.
# If there are zero, returns 1 so caller can fall back.
_pick() {
  local __var="$1" __q="$2"; shift 2
  local __n=$#
  if [ "$__n" = "0" ]; then
    return 1
  fi
  if [ "$__n" = "1" ]; then
    _init_info "$__q — only one option, auto-selected: $1"
    eval "$__var=\"\$1\""
    return 0
  fi
  printf '    %s\n' "$__q" >&2
  local i=1
  for c in "$@"; do
    printf '      %2d) %s\n' "$i" "$c" >&2
    i=$((i+1))
  done
  local __ans=""
  while :; do
    printf '    Enter number [1-%d]: ' "$__n" >&2
    read -r __ans || true
    if printf '%s' "$__ans" | grep -qE '^[0-9]+$' && [ "$__ans" -ge 1 ] && [ "$__ans" -le "$__n" ]; then
      break
    fi
    _init_warn "invalid selection: '$__ans'"
  done
  # shellcheck disable=SC2124
  local args=("$@")
  eval "$__var=\"\${args[$((__ans-1))]}\""
}

# ---- validators ------------------------------------------------------------
_validate_name_prefix() {
  local v="$1"
  case "$v" in
    -* | *- ) return 1 ;;
  esac
  printf '%s' "$v" | grep -qE '^[a-z0-9][a-z0-9-]{0,18}$'
}

# ---- discovery helpers -----------------------------------------------------
# Each returns lines of the form "value|human-readable-description" so _pick
# can show a readable label while we later split the chosen value out with awk.

_discover_vpcs() {
  aws ec2 describe-vpcs --region "$REGION" \
    --query 'Vpcs[*].[VpcId,CidrBlock,IsDefault,Tags[?Key==`Name`].Value|[0]]' --output text 2>/dev/null \
    | awk -F'\t' '{
        name = ($4 == "" || $4 == "None") ? "(no Name tag)" : $4;
        def = ($3 == "True") ? " (default)" : "";
        printf "%s|%s  %s  %s%s\n", $1, $1, $2, name, def
      }'
}

_discover_subnets() {
  local vpc="$1" exclude_az="${2:-}"
  aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
    --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text 2>/dev/null \
    | awk -F'\t' -v xaz="$exclude_az" '{
        if (xaz != "" && $2 == xaz) next;
        name = ($4 == "" || $4 == "None") ? "(no Name tag)" : $4;
        printf "%s|%s  %s  %s  %s\n", $1, $1, $2, $3, name
      }'
}

_subnet_az() {
  aws ec2 describe-subnets --subnet-ids "$1" --region "$REGION" \
    --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null
}

_vpc_cidr() {
  aws ec2 describe-vpcs --vpc-ids "$1" --region "$REGION" \
    --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null
}

_discover_certs() {
  aws acm list-certificates --region "$REGION" --certificate-statuses ISSUED \
    --query 'CertificateSummaryList[*].[CertificateArn,DomainName]' --output text 2>/dev/null \
    | awk -F'\t' '{ printf "%s|%s  (%s)\n", $1, $2, $1 }'
}

_discover_zones() {
  aws route53 list-hosted-zones \
    --query 'HostedZones[*].[Id,Name,Config.PrivateZone]' --output text 2>/dev/null \
    | awk -F'\t' '{
        id = $1; sub("/hostedzone/", "", id);
        vis = ($3 == "True") ? "private" : "PUBLIC";
        printf "%s|%s  %s  (%s)\n", id, id, $2, vis
      }'
}

_zone_name() {
  aws route53 get-hosted-zone --id "$1" --query 'HostedZone.Name' --output text 2>/dev/null | sed 's/\.$//'
}

_zone_private() {
  aws route53 get-hosted-zone --id "$1" --query 'HostedZone.Config.PrivateZone' --output text 2>/dev/null
}

_discover_ecr_repos() {
  aws ecr describe-repositories --region "$REGION" \
    --query 'repositories[*].[repositoryName,repositoryUri]' --output text 2>/dev/null \
    | awk -F'\t' '{ printf "%s|%s\n", $2, $1 }'
}

_latest_image_tag() {
  local repo="$1"
  aws ecr describe-images --repository-name "$repo" --region "$REGION" \
    --query 'sort_by(imageDetails[?imageTags != null],&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null
}

_email_from_identity() {
  local uid
  uid=$(aws sts get-caller-identity --query 'UserId' --output text 2>/dev/null | tr -d '\r\n')
  case "$uid" in
    *@*) printf '%s' "${uid#*:}" | awk -F'@' '{print $2}' ;;
    *)   printf '' ;;
  esac
}

# ---- main flow -------------------------------------------------------------
init_run() {
  local OUT_FILE="${DEPLOY_ENV_FILE:-deploy.env}"

  printf '\n\033[1;35m=== Claude apps gateway — interactive init ===\033[0m\n'
  printf '  Populates %s from AWS discovery + a few prompts. Ctrl-C anytime to abort;\n' "$OUT_FILE"
  printf '  nothing is written until the review at the end.\n'

  if [ -f "$OUT_FILE" ]; then
    _init_warn "$OUT_FILE already exists."
    local __over
    _prompt_yn __over "Overwrite (existing contents will be lost)?" n
    [ "$__over" = "yes" ] || _init_die "aborted — existing $OUT_FILE preserved."
  fi

  command -v aws >/dev/null || _init_die "aws CLI not found on PATH."

  # 1. REGION
  _init_hdr "1. AWS region"
  local __default_region
  __default_region=$(aws configure get region 2>/dev/null || echo us-east-1)
  [ -z "$__default_region" ] && __default_region=us-east-1
  _prompt REGION "AWS region" "$__default_region"

  # 2. verify creds against that region
  _init_hdr "2. Verify AWS credentials"
  local acct arn
  acct=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
    || _init_die "AWS credentials not working for region $REGION. Run 'aws sso login' or set AWS_PROFILE."
  arn=$(aws sts get-caller-identity --query Arn --output text --region "$REGION")
  _init_ok "account $acct, arn $arn"

  # 3. NAME_PREFIX (validate)
  _init_hdr "3. Naming"
  while :; do
    _prompt NAME_PREFIX "NAME_PREFIX (resource-name prefix; 1-19 chars, lowercase alnum + hyphens)" "claude-gateway"
    _validate_name_prefix "$NAME_PREFIX" && break
    _init_warn "invalid NAME_PREFIX: '$NAME_PREFIX' — must be 1-19 chars, lowercase alnum + hyphens, no leading/trailing hyphen"
  done

  # 4. GW_STACK (default = NAME_PREFIX)
  _prompt GW_STACK "GW_STACK (CloudFormation stack name)" "$NAME_PREFIX"

  # 5. VPC + derived CIDR
  _init_hdr "4. VPC"
  local vpcs vpc_pick vpc_lines
  vpcs=$(_discover_vpcs)
  if [ -z "$vpcs" ]; then
    _init_warn "no VPCs discovered in $REGION."
    _prompt VPC_ID "VPC id" ""
  else
    IFS=$'\n' read -r -d '' -a vpc_lines < <(printf '%s\0' "$vpcs") || true
    local labels=(); for l in "${vpc_lines[@]}"; do labels+=("${l#*|}"); done
    _pick vpc_pick "Pick a VPC:" "${labels[@]}"
    # Map the picked label back to its vpc-id (the value before the first |).
    for l in "${vpc_lines[@]}"; do
      if [ "${l#*|}" = "$vpc_pick" ]; then VPC_ID="${l%%|*}"; break; fi
    done
  fi
  VPC_CIDR=$(_vpc_cidr "$VPC_ID")
  _init_ok "VPC_ID=$VPC_ID  VPC_CIDR=$VPC_CIDR (auto-derived)"

  # 6-7. Two subnets in different AZs
  _init_hdr "5. Subnets (must be in different AZs)"
  local subnets_all sub_pick sub_lines
  subnets_all=$(_discover_subnets "$VPC_ID")
  if [ -z "$subnets_all" ]; then
    _init_warn "no subnets in $VPC_ID."
    _prompt SUBNET_A "SUBNET_A id" ""
    _prompt SUBNET_B "SUBNET_B id (different AZ)" ""
  else
    IFS=$'\n' read -r -d '' -a sub_lines < <(printf '%s\0' "$subnets_all") || true
    local labels=(); for l in "${sub_lines[@]}"; do labels+=("${l#*|}"); done
    _pick sub_pick "Pick SUBNET_A:" "${labels[@]}"
    for l in "${sub_lines[@]}"; do
      if [ "${l#*|}" = "$sub_pick" ]; then SUBNET_A="${l%%|*}"; break; fi
    done
    local az_a
    az_a=$(_subnet_az "$SUBNET_A")
    _init_ok "SUBNET_A=$SUBNET_A in $az_a"

    local subnets_b
    subnets_b=$(_discover_subnets "$VPC_ID" "$az_a")
    if [ -z "$subnets_b" ]; then
      _init_die "no subnets found in $VPC_ID outside AZ $az_a — you need a subnet in a second AZ. Create one and rerun."
    fi
    IFS=$'\n' read -r -d '' -a sub_lines < <(printf '%s\0' "$subnets_b") || true
    labels=(); for l in "${sub_lines[@]}"; do labels+=("${l#*|}"); done
    _pick sub_pick "Pick SUBNET_B (different AZ from A):" "${labels[@]}"
    for l in "${sub_lines[@]}"; do
      if [ "${l#*|}" = "$sub_pick" ]; then SUBNET_B="${l%%|*}"; break; fi
    done
    _init_ok "SUBNET_B=$SUBNET_B"
  fi

  # 8. ACM cert
  _init_hdr "6. ACM certificate (must be ISSUED and cover your gateway hostname)"
  local certs cert_pick cert_lines
  certs=$(_discover_certs)
  if [ -z "$certs" ]; then
    _init_warn "no ISSUED ACM certificates in $REGION."
    _init_info "See README §4 (Domain & cert) for the three paths (public ACM / Private CA / self-signed)."
    _prompt CERT_ARN "CERT_ARN (paste ACM cert ARN)" ""
  else
    IFS=$'\n' read -r -d '' -a cert_lines < <(printf '%s\0' "$certs") || true
    local labels=(); for l in "${cert_lines[@]}"; do labels+=("${l#*|}"); done
    _pick cert_pick "Pick certificate:" "${labels[@]}"
    for l in "${cert_lines[@]}"; do
      if [ "${l#*|}" = "$cert_pick" ]; then CERT_ARN="${l%%|*}"; break; fi
    done
    _init_ok "CERT_ARN=$CERT_ARN"
  fi

  # 9. Route 53 hosted zone
  _init_hdr "7. Route 53 hosted zone (private recommended)"
  local zones zone_pick zone_lines
  zones=$(_discover_zones)
  if [ -z "$zones" ]; then
    _init_warn "no Route 53 hosted zones found."
    _prompt ZONE_ID "ZONE_ID (paste zone id)" ""
  else
    IFS=$'\n' read -r -d '' -a zone_lines < <(printf '%s\0' "$zones") || true
    local labels=(); for l in "${zone_lines[@]}"; do labels+=("${l#*|}"); done
    _pick zone_pick "Pick zone:" "${labels[@]}"
    for l in "${zone_lines[@]}"; do
      if [ "${l#*|}" = "$zone_pick" ]; then ZONE_ID="${l%%|*}"; break; fi
    done
  fi
  local zone_priv
  zone_priv=$(_zone_private "$ZONE_ID" 2>/dev/null || echo Unknown)
  if [ "$zone_priv" = "True" ]; then
    _init_ok "ZONE_ID=$ZONE_ID (private)"
  else
    _init_warn "ZONE_ID=$ZONE_ID is PUBLIC. deploy.sh preflight will refuse unless PREFLIGHT_ALLOW_PUBLIC_ZONE=yes."
  fi

  # 10. Hostname (suggest <NAME_PREFIX>.<zone-name>)
  local zone_name suggest_host
  zone_name=$(_zone_name "$ZONE_ID" 2>/dev/null || echo internal.example.com)
  suggest_host="${NAME_PREFIX}.${zone_name}"
  _prompt HOSTNAME_FQDN "HOSTNAME_FQDN (gateway public URL)" "$suggest_host"

  # 11. ECR image URI
  _init_hdr "8. Gateway image (ECR)"
  local repos repo_pick repo_lines
  repos=$(_discover_ecr_repos)
  local IMAGE_URI=""
  if [ -z "$repos" ]; then
    _init_warn "no ECR repositories in $REGION. Build + push the gateway image first (README §5)."
    _prompt IMAGE_URI "IMAGE_URI (full ECR image URI incl. tag)" ""
  else
    IFS=$'\n' read -r -d '' -a repo_lines < <(printf '%s\0' "$repos") || true
    local labels=(); for l in "${repo_lines[@]}"; do labels+=("${l#*|}"); done
    _pick repo_pick "Pick ECR repository:" "${labels[@]}"
    local chosen_uri=""
    for l in "${repo_lines[@]}"; do
      if [ "${l#*|}" = "$repo_pick" ]; then chosen_uri="${l%%|*}"; break; fi
    done
    local latest_tag
    latest_tag=$(_latest_image_tag "$repo_pick" 2>/dev/null || echo "")
    if [ -z "$latest_tag" ] || [ "$latest_tag" = "None" ]; then
      _init_warn "repo $repo_pick has no tagged images yet."
      _prompt IMAGE_URI "IMAGE_URI (paste full URI)" "${chosen_uri}:v1"
    else
      _prompt IMAGE_URI "IMAGE_URI" "${chosen_uri}:${latest_tag}"
    fi
  fi

  # 12-14. OIDC IdP
  _init_hdr "9. OIDC identity provider"
  _prompt OIDC_ISSUER "OIDC_ISSUER (e.g. https://<org>.okta.com)" ""
  if [ -n "$OIDC_ISSUER" ] && command -v curl >/dev/null; then
    if curl -fsS --max-time 5 "${OIDC_ISSUER%/}/.well-known/openid-configuration" >/dev/null 2>&1; then
      _init_ok "OIDC discovery URL reachable"
    else
      _init_warn "could not reach ${OIDC_ISSUER}/.well-known/openid-configuration — preflight will refuse. Continue anyway."
    fi
  fi
  _prompt OIDC_CLIENT_ID "OIDC_CLIENT_ID" ""
  _prompt_hidden OIDC_CLIENT_SECRET "OIDC_CLIENT_SECRET"

  # 15-16. Policy
  _init_hdr "10. Policy"
  local default_email
  default_email=$(_email_from_identity || echo "")
  _prompt EMAIL_DOMAIN "EMAIL_DOMAIN (allowed OIDC email domain)" "${default_email:-example.com}"
  _prompt ADMIN_GROUP "ADMIN_GROUP (IdP group whose members manage spend caps)" "${NAME_PREFIX}-admins"

  # 17-19. Rest
  _init_hdr "11. Upstream + collector"
  _prompt BEDROCK_REGION "BEDROCK_REGION (region for InvokeModel)" "$REGION"
  _prompt OTEL_COLLECTOR_TAG "OTEL_COLLECTOR_TAG (pinned aws-otel-collector tag)" "v0.42.0"
  _prompt_yn __deploy_vpn "Deploy the Client VPN stack too?" n
  DEPLOY_VPN="$__deploy_vpn"

  # ---- review + write ------------------------------------------------------
  _init_hdr "Review"
  cat <<REVIEW
    NAME_PREFIX        = $NAME_PREFIX
    GW_STACK           = $GW_STACK
    REGION             = $REGION
    VPC_ID             = $VPC_ID
    VPC_CIDR           = $VPC_CIDR
    SUBNET_A           = $SUBNET_A
    SUBNET_B           = $SUBNET_B
    CERT_ARN           = $CERT_ARN
    ZONE_ID            = $ZONE_ID
    HOSTNAME_FQDN      = $HOSTNAME_FQDN
    IMAGE_URI          = $IMAGE_URI
    OIDC_ISSUER        = $OIDC_ISSUER
    OIDC_CLIENT_ID     = $OIDC_CLIENT_ID
    OIDC_CLIENT_SECRET = (hidden, ${#OIDC_CLIENT_SECRET} chars)
    EMAIL_DOMAIN       = $EMAIL_DOMAIN
    ADMIN_GROUP        = $ADMIN_GROUP
    BEDROCK_REGION     = $BEDROCK_REGION
    OTEL_COLLECTOR_TAG = $OTEL_COLLECTOR_TAG
    DEPLOY_VPN         = $DEPLOY_VPN
REVIEW
  local __ok
  _prompt_yn __ok "Write these values to $OUT_FILE?" y
  [ "$__ok" = "yes" ] || _init_die "aborted — nothing written."

  # Atomic write via tmp file in the same directory, then mv. chmod 600 before rename.
  local tmp
  tmp=$(mktemp "${OUT_FILE}.XXXXXX") || _init_die "could not create tempfile alongside $OUT_FILE"
  # Escape any shell-special chars in values by quoting each RHS.
  {
    cat <<'HEADER'
# deploy.env — generated by `bash deploy.sh init`. Contains OIDC_CLIENT_SECRET.
# Not tracked in git (.gitignore excludes it). Rerun `bash deploy.sh init` to regenerate.
HEADER
    printf 'NAME_PREFIX=%s\n'        "$NAME_PREFIX"
    printf 'GW_STACK=%s\n'           "$GW_STACK"
    printf 'REGION=%s\n'             "$REGION"
    printf 'VPC_ID=%s\n'             "$VPC_ID"
    printf 'VPC_CIDR=%s\n'           "$VPC_CIDR"
    printf 'SUBNET_A=%s\n'           "$SUBNET_A"
    printf 'SUBNET_B=%s\n'           "$SUBNET_B"
    printf 'CERT_ARN=%s\n'           "$CERT_ARN"
    printf 'ZONE_ID=%s\n'            "$ZONE_ID"
    printf 'HOSTNAME_FQDN=%s\n'      "$HOSTNAME_FQDN"
    printf 'IMAGE_URI=%s\n'          "$IMAGE_URI"
    printf 'OIDC_ISSUER=%s\n'        "$OIDC_ISSUER"
    printf 'OIDC_CLIENT_ID=%s\n'     "$OIDC_CLIENT_ID"
    printf 'OIDC_CLIENT_SECRET=%s\n' "$OIDC_CLIENT_SECRET"
    printf 'EMAIL_DOMAIN=%s\n'       "$EMAIL_DOMAIN"
    printf 'ADMIN_GROUP=%s\n'        "$ADMIN_GROUP"
    printf 'BEDROCK_REGION=%s\n'     "$BEDROCK_REGION"
    printf 'OTEL_COLLECTOR_TAG=%s\n' "$OTEL_COLLECTOR_TAG"
    printf 'DEPLOY_VPN=%s\n'         "$DEPLOY_VPN"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$OUT_FILE"

  printf '\n\033[1;32m✓ wrote %s (mode 0600)\033[0m\n' "$OUT_FILE"
  cat <<NEXT

  Next:
    bash deploy.sh preflight    # read-only sanity checks
    bash deploy.sh app          # deploy the gateway stack + roll ECS
    bash deploy.sh              # or run: preflight + app + [vpn if DEPLOY_VPN=yes] + verify
NEXT
}

# Standalone entrypoint
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  init_run
fi
