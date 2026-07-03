#!/usr/bin/env bash
###############################################################################
# One-command deploy for the Claude apps gateway.
#
#   bash deploy.sh init                   # generate deploy.env via discovery + prompts
#   bash deploy.sh                        # runs: preflight -> app -> [vpn] -> verify
#
# Subcommands (all idempotent):
#   init        interactive: discover VPC/subnets/cert/zone/image, prompt for OIDC + policy,
#               write deploy.env (mode 0600).
#   preflight   read-only checks against your AWS account (VPC, cert, zone, Bedrock, OIDC)
#   app         deploy the gateway stack + render/upload gateway.yaml + roll ECS
#   vpn         run vpn-setup.sh (Client VPN endpoint + client.ovpn)
#   verify      post-deploy health probe (rollout state + /healthz + log tail)
#   all         preflight + app + (vpn if DEPLOY_VPN=yes) + verify   [default]
#
# Reads config exclusively from ./deploy.env — NO personal defaults are baked in.
# If any required variable is missing, the script fails fast with a clear message.
###############################################################################
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

ENV_FILE="${DEPLOY_ENV_FILE:-deploy.env}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The envsubst allowlist for gateway.yaml.template. Anything OUTSIDE this list
# stays literal (crucial: the gateway binary itself resolves ${OIDC_CLIENT_ID},
# ${GATEWAY_JWT_SECRET}, ${GATEWAY_POSTGRES_URL}, ${GATEWAY_DB_PASSWORD},
# ${GATEWAY_ADMIN_WRITE_KEY} at container startup — do NOT substitute them here).
readonly ENVSUBST_ALLOWLIST='${HOSTNAME_FQDN} ${VPC_CIDR} ${OIDC_ISSUER} ${EMAIL_DOMAIN} ${BEDROCK_REGION} ${ADMIN_GROUP}'
readonly RUNTIME_ALLOWED='OIDC_CLIENT_ID|OIDC_CLIENT_SECRET|GATEWAY_JWT_SECRET|GATEWAY_POSTGRES_URL|GATEWAY_DB_PASSWORD|GATEWAY_ADMIN_WRITE_KEY'

load_env() {
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found. Run: cp deploy.env.example deploy.env  then fill it in."
  set -a; . "$ENV_FILE"; set +a
  : "${NAME_PREFIX:?NAME_PREFIX must be set in deploy.env (default: claude-gateway).}"
  # GW_STACK defaults to NAME_PREFIX so `deploy.sh app` + `teardown.sh` operate on one logical stack.
  # Override in deploy.env if you already have a stack under a different name.
  GW_STACK="${GW_STACK:-$NAME_PREFIX}"
}

cmd_init() {
  # No load_env — init GENERATES deploy.env. It only needs aws creds.
  [ -f "$HERE/lib/init.sh" ] || die "lib/init.sh not found."
  . "$HERE/lib/init.sh"
  init_run
}

cmd_preflight() {
  load_env
  . "$HERE/lib/preflight.sh"
  preflight_run
}

cmd_app() {
  load_env
  command -v envsubst >/dev/null || die "envsubst not found on PATH (install: brew install gettext / apt install gettext-base)."
  [ -f phase2-fargate.yaml ] || die "phase2-fargate.yaml not found."
  [ -f gateway.yaml.template ] || die "gateway.yaml.template not found."

  local ACCOUNT_ID
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
    || die "AWS credentials not working for region $REGION. Run 'aws sso login' or set AWS_PROFILE."
  log "Account $ACCOUNT_ID, region $REGION, gateway https://${HOSTNAME_FQDN}"

  # ---- 1/4  deploy the gateway stack -----------------------------------------
  # OIDC creds go through as NoEcho parameters. CFN owns the OidcSecret contents —
  # no separate put-secret-value step and no REPLACE_ME state on first CREATE.
  log "1/4 Deploying gateway stack ($GW_STACK)"
  aws cloudformation deploy --stack-name "$GW_STACK" --template-file phase2-fargate.yaml \
    --parameter-overrides \
      NamePrefix="$NAME_PREFIX" \
      VpcId="$VPC_ID" \
      SubnetA="$SUBNET_A" \
      SubnetB="$SUBNET_B" \
      CertificateArn="$CERT_ARN" \
      HostedZoneId="$ZONE_ID" \
      GatewayHostname="$HOSTNAME_FQDN" \
      ImageUri="$IMAGE_URI" \
      OidcClientId="$OIDC_CLIENT_ID" \
      OidcClientSecret="$OIDC_CLIENT_SECRET" \
      OtelCollectorTag="$OTEL_COLLECTOR_TAG" \
    --capabilities CAPABILITY_IAM \
    --tags "auto-delete=no" "app=claude-apps-gateway" "name-prefix=${NAME_PREFIX}" \
    --region "$REGION" \
    --no-fail-on-empty-changeset

  CONFIG_BUCKET=$(aws cloudformation describe-stacks --stack-name "$GW_STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='ConfigBucket'].OutputValue | [0]" --output text)
  [ -n "$CONFIG_BUCKET" ] && [ "$CONFIG_BUCKET" != "None" ] || die "Could not read ConfigBucket output from stack."
  info "Config bucket: $CONFIG_BUCKET"

  # ---- 2/4  render + upload gateway.yaml -------------------------------------
  # envsubst is called with an explicit allowlist so runtime placeholders
  # (${OIDC_CLIENT_ID}, ${GATEWAY_JWT_SECRET}, etc.) are preserved for the
  # gateway binary to resolve at container startup.
  log "2/4 Rendering gateway.yaml.template (allowlist: $ENVSUBST_ALLOWLIST) and uploading"
  local RENDERED
  RENDERED=$(mktemp)
  # Null-safe: RENDERED is local to this function; the EXIT trap fires at script exit when
  # RENDERED has gone out of scope. ${RENDERED:-} avoids "unbound variable" under set -u.
  trap 'rm -f "${RENDERED:-}"' EXIT
  envsubst "$ENVSUBST_ALLOWLIST" < gateway.yaml.template > "$RENDERED"

  # Anything left of the form ${VAR} must be in the runtime allowlist.
  # Otherwise it means the template referenced a variable that no one will resolve
  # (e.g. someone added ${NEW_THING} but didn't add it to ENVSUBST_ALLOWLIST).
  local UNRESOLVED
  UNRESOLVED=$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$RENDERED" | sort -u \
    | grep -vE "^\\\$\\{($RUNTIME_ALLOWED)\\}$" || true)
  if [ -n "$UNRESOLVED" ]; then
    printf 'unresolved placeholder(s) in rendered gateway.yaml:\n%s\n' "$UNRESOLVED" >&2
    die "Add these vars to ENVSUBST_ALLOWLIST in deploy.sh (or to RUNTIME_ALLOWED if the gateway binary resolves them at startup)."
  fi
  info "no unexpected placeholders remain"

  aws s3 cp "$RENDERED" "s3://${CONFIG_BUCKET}/gateway.yaml" --region "$REGION" >/dev/null
  info "uploaded s3://${CONFIG_BUCKET}/gateway.yaml"

  # ---- 3/4  roll the service -------------------------------------------------
  log "3/4 Forcing a new ECS deployment (cluster/service: $NAME_PREFIX) to pick up the config"
  aws ecs update-service --cluster "$NAME_PREFIX" --service "$NAME_PREFIX" \
    --force-new-deployment --region "$REGION" >/dev/null

  info "waiting for the service to stabilize (a few minutes)"
  # `wait services-stable` polls up to 40 * 15s = 10 min. We hard-fail if it
  # times out — the OLD script logged a warning and printed a success banner.
  aws ecs wait services-stable --cluster "$NAME_PREFIX" --services "$NAME_PREFIX" --region "$REGION" \
    || die "ECS service did not stabilize within 10 minutes. Run: aws logs tail /ecs/${NAME_PREFIX} --region $REGION --since 10m --format short"

  # And even after wait returns clean, verify the actual state.
  local ROLLOUT RUNNING DESIRED
  read -r ROLLOUT RUNNING DESIRED < <(aws ecs describe-services --cluster "$NAME_PREFIX" --services "$NAME_PREFIX" --region "$REGION" \
    --query 'services[0].[deployments[?status==`PRIMARY`]|[0].rolloutState,runningCount,desiredCount]' --output text)
  info "rollout=$ROLLOUT running=$RUNNING desired=$DESIRED"
  [ "$ROLLOUT" = "COMPLETED" ] || die "ECS rollout state is $ROLLOUT (expected COMPLETED)."
  [ "$RUNNING" = "$DESIRED" ] || die "ECS runningCount=$RUNNING != desiredCount=$DESIRED."

  # ---- 4/4  done -------------------------------------------------------------
  log "4/4 gateway stack deployed and rolled"
}

cmd_vpn() {
  load_env
  [ -f vpn-setup.sh ] || die "vpn-setup.sh not found."
  log "Client VPN — delegating to vpn-setup.sh"
  bash vpn-setup.sh
}

cmd_verify() {
  load_env
  log "Verifying rollout state (cluster/service: $NAME_PREFIX)"
  local ROLLOUT RUNNING DESIRED
  read -r ROLLOUT RUNNING DESIRED < <(aws ecs describe-services --cluster "$NAME_PREFIX" --services "$NAME_PREFIX" --region "$REGION" \
    --query 'services[0].[deployments[?status==`PRIMARY`]|[0].rolloutState,runningCount,desiredCount]' --output text 2>/dev/null) \
    || die "Could not describe ECS service ${NAME_PREFIX}/${NAME_PREFIX} in $REGION. Run 'bash deploy.sh app' first."
  info "rollout=$ROLLOUT running=$RUNNING desired=$DESIRED"
  [ "$ROLLOUT" = "COMPLETED" ] || die "rolloutState=$ROLLOUT (expected COMPLETED)."
  [ "$RUNNING" = "$DESIRED" ] || die "runningCount=$RUNNING != desiredCount=$DESIRED."

  log "Probing https://${HOSTNAME_FQDN}/healthz (via any private path you can reach)"
  # The gateway ALB is INTERNAL — this probe only succeeds if run from inside the VPC or via VPN.
  # Warn (not fail) if we're outside the VPC and can't reach it; the ECS rollout check above is
  # the primary success signal for `app`.
  if curl -sfk --max-time 5 "https://${HOSTNAME_FQDN}/healthz" >/dev/null 2>&1; then
    info "healthz returned 200"
  else
    info "healthz unreachable from this host (expected if not on VPN / not inside VPC) — skipping"
  fi

  log "Log tail (last 3 minutes) to confirm OIDC discovery + config load"
  aws logs tail "/ecs/${NAME_PREFIX}" --region "$REGION" --since 3m --format short 2>/dev/null | tail -n 40 || true

  printf '\n\033[1;32m================ Verify complete ================\033[0m\n'
  cat <<EOF

Gateway:   https://${HOSTNAME_FQDN}
Verify:    aws logs tail /ecs/${NAME_PREFIX} --region ${REGION} --since 10m --format short
           (expect: download gateway.yaml -> config.load -> listening -> oidc issuer ${OIDC_ISSUER})

Next (laptop): connect the VPN, drop managed-settings.json (README §8), then: claude -> /login
EOF
}

cmd_all() {
  cmd_preflight
  cmd_app
  if [ "${DEPLOY_VPN:-no}" = "yes" ]; then
    cmd_vpn
  else
    log "Skipping VPN (set DEPLOY_VPN=yes in deploy.env to include it)"
  fi
  cmd_verify
}

case "${1:-all}" in
  init)      cmd_init ;;
  preflight) cmd_preflight ;;
  app)       cmd_app ;;
  vpn)       cmd_vpn ;;
  verify)    cmd_verify ;;
  all)       cmd_all ;;
  help|-h|--help)
    sed -n '2,19p' "$0"
    ;;
  *)
    printf 'unknown subcommand: %s\n' "$1" >&2
    sed -n '2,19p' "$0" >&2
    exit 1
    ;;
esac
