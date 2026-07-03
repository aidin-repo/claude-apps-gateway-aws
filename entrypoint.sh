#!/bin/sh
# Container entrypoint. Fetches the live gateway.yaml from S3 (task-role creds)
# and hard-fails if the fetch fails or the config still contains the sentinel.
# There is intentionally NO baked-in fallback: shipping stale config silently
# is worse than not starting.
set -eu

: "${GATEWAY_CONFIG_S3_URI:?GATEWAY_CONFIG_S3_URI must be set on the container (set by CloudFormation).}"

CONFIG=/etc/claude/gateway.yaml
mkdir -p /etc/claude

if ! aws s3 cp "$GATEWAY_CONFIG_S3_URI" "$CONFIG"; then
  echo "FATAL: failed to fetch gateway config from ${GATEWAY_CONFIG_S3_URI}" >&2
  echo "       Run deploy.sh to render + upload gateway.yaml.template to the config bucket." >&2
  exit 1
fi

if grep -qE '__NOT_YET_CONFIGURED__|REPLACE_ME' "$CONFIG"; then
  echo "FATAL: gateway config still contains a placeholder sentinel. Re-render from template." >&2
  exit 1
fi

exec claude gateway --config "$CONFIG"
