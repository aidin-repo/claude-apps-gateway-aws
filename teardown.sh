#!/usr/bin/env bash
###############################################################################
# Tear down the Claude apps gateway POC.  bash teardown.sh
#
# Order (matters):
#   1. Optional VPN stack delete (with bounded waiter)
#   2. FORCE-delete Secrets Manager secrets (BEFORE the stack; kills the 30-day
#      tombstone that would block the next deploy)
#   3. Empty the versioned config bucket in batches (aws s3api delete-objects)
#   4. Delete the gateway stack (bounded waiter; on failure dumps recent stack events)
#   5. Optional: delete imported server.cvpn.local ACM certs
#
# NOTE: RDS DeletionPolicy is now Snapshot (was Delete). Teardown will leave a
# `claude-gateway-db-final-*` snapshot behind — delete it manually when done.
#
# Flags (env vars):
#   CONFIRM=DELETE          skip the interactive prompt
#   DELETE_CVPN_CERTS=yes   also delete imported server.cvpn.local ACM certs
# Not touched: the ECR repo, CodeBuild projects, and the ACM gateway wildcard cert.
###############################################################################
set -euo pipefail

ENV_FILE="${DEPLOY_ENV_FILE:-deploy.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

REGION="${REGION:-us-east-1}"
: "${NAME_PREFIX:?NAME_PREFIX must be set in deploy.env — teardown needs it to know which secrets and bucket to purge.}"
GW_STACK="${GW_STACK:-$NAME_PREFIX}"
VPN_STACK="${VPN_STACK:-${NAME_PREFIX}-client-vpn}"
DELETE_CVPN_CERTS="${DELETE_CVPN_CERTS:-no}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info(){ printf '    %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws CLI not found on PATH."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
  || die "AWS credentials not working for region $REGION."

stack_exists() { aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" >/dev/null 2>&1; }

# ---- bounded waiter with events dump on failure ----------------------------
# The AWS CLI waiter polls up to 30 min silently. On failure it just says "waiter
# failed after N attempts" with no reason. This waiter polls describe-stacks
# directly, prints progress, and on DELETE_FAILED dumps the last stack events so
# the user sees WHY the delete failed (usually: a still-non-empty bucket, or an
# ENI blocked by a running Client VPN endpoint).
wait_stack_delete() {
  local stack="$1"
  local i=0 max=120  # 120 * 15s = 30 min
  while [ "$i" -lt "$max" ]; do
    local status
    status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1) || {
        # Stack no longer exists — describe-stacks 404s. Success.
        info "$stack deleted"; return 0
      }
    case "$status" in
      DELETE_IN_PROGRESS)  info "$stack: $status (attempt $((i+1))/$max)" ;;
      DELETE_COMPLETE)     info "$stack deleted"; return 0 ;;
      DELETE_FAILED)
        printf '\n\033[1;31m%s: DELETE_FAILED — recent events:\033[0m\n' "$stack" >&2
        aws cloudformation describe-stack-events --stack-name "$stack" --region "$REGION" \
          --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
          --output table >&2 || true
        return 1
        ;;
      *)
        info "$stack: unexpected status $status"; return 1 ;;
    esac
    sleep 15
    i=$((i+1))
  done
  info "$stack: waiter timed out after $((max*15))s"
  return 1
}

# ---- confirmation ----------------------------------------------------------
if [ "${CONFIRM:-}" != "DELETE" ]; then
  printf '\n\033[1;31mThis destroys stacks %s + %s, force-deletes %s/* secrets, and empties\n' "$GW_STACK" "$VPN_STACK" "$NAME_PREFIX"
  printf 'the %s config bucket in account %s (%s).\n' "$NAME_PREFIX" "$ACCOUNT_ID" "$REGION"
  printf 'The RDS DB will leave a final snapshot behind (DeletionPolicy: Snapshot).\033[0m\n'
  printf 'Type DELETE to proceed: '
  read -r ans
  [ "$ans" = "DELETE" ] || { echo "Aborted."; exit 1; }
fi

# ---- 1. VPN stack ----------------------------------------------------------
if stack_exists "$VPN_STACK"; then
  log "Deleting VPN stack $VPN_STACK (endpoint teardown takes a few minutes)"
  aws cloudformation delete-stack --stack-name "$VPN_STACK" --region "$REGION"
  wait_stack_delete "$VPN_STACK" || die "VPN stack delete did not complete."
else
  log "VPN stack $VPN_STACK not present — skipping"
fi

# ---- 2. secrets BEFORE the stack ------------------------------------------
# CFN will handle "already gone" gracefully; force-deleting here means teardown
# can't leave a 30-day tombstone that blocks the next deploy.
log "Force-deleting ${NAME_PREFIX}/* secrets (no recovery)"
for s in oidc jwt-secret db-password admin-write-key; do
  secret_id="${NAME_PREFIX}/${s}"
  if aws secretsmanager describe-secret --secret-id "$secret_id" --region "$REGION" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$secret_id" \
      --force-delete-without-recovery --region "$REGION" >/dev/null \
      && info "purged $secret_id" \
      || info "could not purge $secret_id (already gone?)"
  else
    info "$secret_id not present"
  fi
done

# ---- 3. empty the versioned config bucket in batches -----------------------
CONFIG_BUCKET=""
if stack_exists "$GW_STACK"; then
  CONFIG_BUCKET=$(aws cloudformation describe-stacks --stack-name "$GW_STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='ConfigBucket'].OutputValue | [0]" --output text 2>/dev/null)
fi
if [ -z "$CONFIG_BUCKET" ] || [ "$CONFIG_BUCKET" = "None" ]; then
  CONFIG_BUCKET="${NAME_PREFIX}-config-${ACCOUNT_ID}-${REGION}"
fi

# Batch-delete every version + delete-marker in a versioned bucket. Fails hard on any
# batch error (unlike the old per-object subshell loop that silently continued).
# s3api delete-objects accepts up to 1000 (Key,VersionId) pairs per call.
batch_delete_selector() {
  local bucket="$1" selector="$2"  # selector: Versions or DeleteMarkers
  while :; do
    local payload count
    payload=$(aws s3api list-object-versions --bucket "$bucket" --region "$REGION" --max-items 1000 \
      --query "{Objects: ${selector}[].{Key:Key,VersionId:VersionId}}" --output json)
    count=$(printf '%s' "$payload" | grep -c '"Key"' || true)
    if [ "$count" = "0" ]; then
      info "$selector: none left"
      return 0
    fi
    info "$selector: deleting $count entries"
    aws s3api delete-objects --bucket "$bucket" --region "$REGION" \
      --delete "$payload" --output json >/dev/null \
      || die "delete-objects batch failed for $selector on $bucket"
  done
}

if aws s3api head-bucket --bucket "$CONFIG_BUCKET" --region "$REGION" 2>/dev/null; then
  log "Emptying versioned bucket $CONFIG_BUCKET (batched delete-objects)"
  batch_delete_selector "$CONFIG_BUCKET" Versions
  batch_delete_selector "$CONFIG_BUCKET" DeleteMarkers

  REMAINING=$(aws s3api list-object-versions --bucket "$CONFIG_BUCKET" --region "$REGION" \
    --query 'length(Versions[]) + length(DeleteMarkers[])' --output text 2>/dev/null || echo 0)
  if [ "$REMAINING" != "0" ] && [ "$REMAINING" != "None" ]; then
    die "$CONFIG_BUCKET still has $REMAINING object versions after purge — stack delete would hang."
  fi
  info "$CONFIG_BUCKET is empty"
else
  log "Config bucket $CONFIG_BUCKET not present — skipping empty"
fi

# ---- 4. gateway stack ------------------------------------------------------
if stack_exists "$GW_STACK"; then
  log "Deleting gateway stack $GW_STACK"
  aws cloudformation delete-stack --stack-name "$GW_STACK" --region "$REGION"
  wait_stack_delete "$GW_STACK" \
    || die "Gateway stack delete did not complete. See the DELETE_FAILED events above."
else
  log "Gateway stack $GW_STACK not present — skipping"
fi

# ---- 5. optional: imported VPN certs ---------------------------------------
if [ "$DELETE_CVPN_CERTS" = "yes" ]; then
  log "Deleting imported server.cvpn.local ACM certs"
  for arn in $(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[?DomainName=='server.cvpn.local'].CertificateArn" --output text); do
    if aws acm delete-certificate --certificate-arn "$arn" --region "$REGION" 2>/dev/null; then
      info "deleted $arn"
    else
      info "could not delete $arn (still in use?)"
    fi
  done
fi

printf '\n\033[1;32m================ Teardown complete ================\033[0m\n'
cat <<EOF

Removed: ${VPN_STACK}, ${GW_STACK}, config bucket, and ${NAME_PREFIX}/* secrets.
Not touched:
  - ECR repo / image, CodeBuild projects, the ACM gateway wildcard cert
  - RDS final snapshot (name: ${NAME_PREFIX}-db-final-*) — delete manually to reclaim storage:
      aws rds describe-db-snapshots --region ${REGION} --query 'DBSnapshots[?starts_with(DBSnapshotIdentifier,\`${NAME_PREFIX}-db\`)].DBSnapshotIdentifier' --output text
Local key material (ca.key, client.key, client.ovpn) is still on this machine — delete if done.
EOF
