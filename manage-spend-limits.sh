#!/usr/bin/env bash
#
# manage-spend-limits.sh — manage Claude apps gateway spend limits via the Admin API.
# Wraps POST/GET/DELETE /v1/organizations/spend_limits so you don't hand-write curl each time.
# Amounts are entered in DOLLARS (the API uses cents; this script converts for you).
#
# Prerequisites: the gateway is private, so connect the VPN first, then either:
#   1) source ./deploy.env (script auto-fetches ADMIN_KEY from Secrets Manager), or
#   2) export GATEWAY_URL + ADMIN_KEY manually.
#
# Config resolution order:
#   GATEWAY_URL: env > "https://${HOSTNAME_FQDN}" from deploy.env > error
#   ADMIN_KEY:   env > `aws secretsmanager get-secret-value ${NAME_PREFIX}/admin-write-key` > error
#
# Usage:
#   ./manage-spend-limits.sh list                       # list all caps
#   ./manage-spend-limits.sh effective                  # caps that apply to the caller
#   ./manage-spend-limits.sh set-org 500                # $500/month org-wide
#   ./manage-spend-limits.sh set-org 100 daily          # $100/day org-wide
#   ./manage-spend-limits.sh set-group contractors 100 daily
#   ./manage-spend-limits.sh set-user <oidc_sub> 50 daily
#   ./manage-spend-limits.sh delete spl_abc123          # deletion requires typed confirmation
#   CONFIRM=DELETE ./manage-spend-limits.sh delete spl_abc123    # skip prompt (for scripts)
#
# Find a user's OIDC sub with:  ./manage-spend-limits.sh effective   (the user_id field)
#
# If your endpoint uses a cert curl doesn't trust, run with: CURL_OPTS="-k" ./manage-spend-limits.sh ...
set -euo pipefail

ENV_FILE="${DEPLOY_ENV_FILE:-deploy.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

die() { echo "error: $*" >&2; exit 1; }

# ---- resolve GATEWAY_URL ---------------------------------------------------
if [ -z "${GATEWAY_URL:-}" ]; then
  if [ -n "${HOSTNAME_FQDN:-}" ]; then
    GATEWAY_URL="https://${HOSTNAME_FQDN}"
  else
    die "GATEWAY_URL not set and HOSTNAME_FQDN missing from deploy.env. Export GATEWAY_URL manually."
  fi
fi

# ---- resolve ADMIN_KEY (auto-fetch from Secrets Manager if missing) --------
if [ -z "${ADMIN_KEY:-}" ]; then
  : "${REGION:?ADMIN_KEY not set and REGION not set — export ADMIN_KEY manually or source deploy.env.}"
  : "${NAME_PREFIX:?ADMIN_KEY not set and NAME_PREFIX not set — export ADMIN_KEY manually or source deploy.env.}"
  command -v aws >/dev/null || die "aws CLI required to auto-fetch ADMIN_KEY from Secrets Manager."
  secret_id="${NAME_PREFIX}/admin-write-key"
  echo "info: fetching ADMIN_KEY from Secrets Manager ${secret_id} in ${REGION}" >&2
  ADMIN_KEY=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_id" \
    --query SecretString --output text --region "$REGION" 2>/dev/null) \
    || die "Could not fetch ${secret_id} from Secrets Manager. Check credentials."
  [ -n "$ADMIN_KEY" ] || die "ADMIN_KEY resolved to empty string."
fi

API="${GATEWAY_URL%/}/v1/organizations/spend_limits"
CURL_OPTS="${CURL_OPTS:-}"

pp() { if command -v jq >/dev/null 2>&1; then jq; else cat; fi; }

to_cents() {
  awk -v d="$1" 'BEGIN{ if (d !~ /^[0-9]+([.][0-9]+)?$/){ exit 1 } printf "%.0f", d*100 }' \
    || die "invalid dollar amount: $1"
}

valid_period() {
  case "$1" in daily|weekly|monthly) ;; *) die "period must be daily, weekly, or monthly (got: $1)";; esac
}

# HTTP wrapper: captures body + status, fails on non-2xx with the body echoed.
http() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local out status
  out=$(mktemp)
  # Splitting CURL_OPTS on whitespace is intentional (users pass e.g. "-k" or "--proxy foo").
  # shellcheck disable=SC2086
  if [ -n "$body" ]; then
    status=$(curl -sS $CURL_OPTS -o "$out" -w '%{http_code}' -X "$method" "$url" \
      -H "x-api-key: $ADMIN_KEY" -H "Content-Type: application/json" -d "$body" || echo 000)
  else
    # shellcheck disable=SC2086
    status=$(curl -sS $CURL_OPTS -o "$out" -w '%{http_code}' -X "$method" "$url" \
      -H "x-api-key: $ADMIN_KEY" || echo 000)
  fi
  if [ "$status" = "000" ]; then
    rm -f "$out"; die "curl failed to reach $url (network / DNS / VPN? — is the VPN connected?)"
  fi
  if [ "${status#2}" = "$status" ]; then
    # 4xx / 5xx / non-2xx — echo body then die.
    printf 'HTTP %s from %s %s\n' "$status" "$method" "$url" >&2
    cat "$out" >&2 || true
    rm -f "$out"
    exit 1
  fi
  cat "$out" | pp
  rm -f "$out"
}

post_scope() { # scope-json  cents  period
  http POST "$API" "$(printf '{"scope":%s,"amount":"%s","period":"%s"}' "$1" "$2" "$3")"
}

usage() { sed -n '3,31p' "$0"; }

case "${1:-help}" in
  list)      http GET "$API" ;;
  effective) http GET "$API/effective" ;;
  set-org)
    [ $# -ge 2 ] || die "usage: set-org <dollars> [daily|weekly|monthly]"
    period="${3:-monthly}"; valid_period "$period"
    post_scope '{"type":"organization"}' "$(to_cents "$2")" "$period" ;;
  set-group)
    [ $# -ge 3 ] || die "usage: set-group <group_id> <dollars> [daily|weekly|monthly]"
    period="${4:-monthly}"; valid_period "$period"
    post_scope "$(printf '{"type":"rbac_group","rbac_group_id":"%s"}' "$2")" "$(to_cents "$3")" "$period" ;;
  set-user)
    [ $# -ge 3 ] || die "usage: set-user <oidc_sub> <dollars> [daily|weekly|monthly]"
    period="${4:-monthly}"; valid_period "$period"
    post_scope "$(printf '{"type":"user","user_id":"%s"}' "$2")" "$(to_cents "$3")" "$period" ;;
  delete)
    [ $# -ge 2 ] || die "usage: delete <spend_limit_id>"
    if [ "${CONFIRM:-}" != "DELETE" ]; then
      printf 'About to DELETE spend limit %s from %s.\nType DELETE to proceed: ' "$2" "$API" >&2
      read -r ans
      [ "$ans" = "DELETE" ] || { echo "aborted." >&2; exit 1; }
    fi
    http DELETE "$API/$2" ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $1" >&2; usage; exit 1 ;;
esac
