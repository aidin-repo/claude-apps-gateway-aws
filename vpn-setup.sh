#!/usr/bin/env bash
###############################################################################
# One-shot Client VPN profile builder for the Claude apps gateway.
#
#   bash vpn-setup.sh
#
# Reads config from ./deploy.env (or values already exported). It figures out
# what you need and does it, printing each step:
#   * If you already have client.crt + client.key AND they verify against ca.crt
#         -> just builds the profile
#   * If you have ca.crt + ca.key (no client, or a stale client)
#         -> mints a client, builds it
#   * If you have nothing
#         -> regenerates the CA + server cert, imports it to ACM, updates the
#           claude-client-vpn stack to trust it, mints a client, and builds the profile
#
# Output: client.ovpn  (import this into the AWS VPN Client and connect)
###############################################################################
set -euo pipefail

ENV_FILE="${DEPLOY_ENV_FILE:-deploy.env}"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

: "${REGION:?REGION must be set (deploy.env).}"
: "${NAME_PREFIX:?NAME_PREFIX must be set (deploy.env).}"
: "${VPC_ID:?VPC_ID must be set (deploy.env).}"
: "${VPC_CIDR:?VPC_CIDR must be set (deploy.env).}"
: "${SUBNET_A:?SUBNET_A must be set (deploy.env).}"
: "${HOSTNAME_FQDN:?HOSTNAME_FQDN must be set (deploy.env).}"

STACK="${VPN_STACK:-${NAME_PREFIX}-client-vpn}"
GW_STACK="${GW_STACK:-$NAME_PREFIX}"
ENDPOINT_DESC="${NAME_PREFIX} client vpn"
GATEWAY_URL="https://${HOSTNAME_FQDN}"
CN="client.cvpn.local"
OUT="client.ovpn"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- preflight -------------------------------------------------------------
command -v aws >/dev/null     || die "aws CLI not found on PATH."
command -v openssl >/dev/null || die "openssl not found on PATH."
# LibreSSL (default macOS /usr/bin/openssl) is rejected by AWS Client VPN cert imports.
openssl version | grep -q '^OpenSSL' \
  || die "openssl on PATH is not OpenSSL ($(openssl version)). Install OpenSSL >= 1.1.1 (brew install openssl && export PATH=/opt/homebrew/opt/openssl/bin:\$PATH)."

aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 \
  || die "AWS credentials not working for region $REGION. Run 'aws sso login' or set AWS_PROFILE."

# ---- 1. make sure we have a CA + client cert -------------------------------
mint_client() {
  info "Minting client cert (clientAuth)"
  openssl genrsa -out client.key 2048
  openssl req -new -key client.key -subj "/CN=${CN}" -out client.csr
  printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:%s\n" "$CN" > cli.cnf
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -sha256 -extfile cli.cnf -out client.crt
  rm -f client.csr cli.cnf
  chmod 600 client.key
}

if [ -f client.crt ] && [ -f client.key ] && [ -f ca.crt ]; then
  log "Found existing client.crt / client.key — verifying signature against ca.crt"
  if openssl verify -CAfile ca.crt client.crt >/dev/null 2>&1; then
    info "client.crt verifies against ca.crt — reusing"
    chmod 600 client.key 2>/dev/null || true
  else
    info "client.crt does NOT verify against ca.crt (stale after a CA rotation). Re-minting."
    if [ ! -f ca.key ]; then
      die "ca.crt present but ca.key missing — cannot re-sign a client. Delete ca.crt + client.* and rerun to regenerate the full PKI."
    fi
    rm -f client.crt client.key
    mint_client
  fi

elif [ -f ca.crt ] && [ -f ca.key ]; then
  log "Found CA — minting a client cert from it"
  mint_client

else
  log "No cert materials found — regenerating the full PKI"
  info "Creating CA"
  openssl genrsa -out ca.key 2048
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -subj "/CN=claude-vpn-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.crt
  chmod 600 ca.key

  info "Creating server cert (keyUsage + serverAuth, required by AWS)"
  openssl genrsa -out server.key 2048
  openssl req -new -key server.key -subj "/CN=server.cvpn.local" -out server.csr
  printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:server.cvpn.local\n" > srv.cnf
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 3650 -sha256 -extfile srv.cnf -out server.crt
  rm -f server.csr srv.cnf
  chmod 600 server.key

  mint_client

  log "Importing server cert to ACM"
  NEW_ARN=$(aws acm import-certificate \
    --certificate fileb://server.crt --private-key fileb://server.key \
    --certificate-chain fileb://ca.crt \
    --region "$REGION" --query CertificateArn --output text)
  info "new ServerCertArn: $NEW_ARN"

  # The server private key is only needed for the ACM import above. Once imported, ACM has it —
  # keeping the local file is a liability. Remove it.
  info "Removing local server.key (ACM has it now)"
  rm -f server.key

  log "Updating stack $STACK to trust the new cert (VPN endpoint is replaced)"
  aws cloudformation deploy \
    --stack-name "$STACK" \
    --template-file client-vpn.yaml \
    --parameter-overrides \
      NamePrefix="$NAME_PREFIX" \
      GatewayStackName="$GW_STACK" \
      VpcId="$VPC_ID" \
      VpcCidr="$VPC_CIDR" \
      SubnetA="$SUBNET_A" \
      ServerCertArn="$NEW_ARN" \
    --capabilities CAPABILITY_IAM \
    --tags "auto-delete=no" "name-prefix=${NAME_PREFIX}" \
    --region "$REGION"
fi

# ---- 2. find the endpoint and wait until it can accept connections ---------
log "Locating the Client VPN endpoint"
ENDPOINT_ID=$(aws ec2 describe-client-vpn-endpoints --region "$REGION" \
  --query "ClientVpnEndpoints[?Description=='${ENDPOINT_DESC}'].ClientVpnEndpointId | [0]" --output text)
if [ -z "$ENDPOINT_ID" ] || [ "$ENDPOINT_ID" = "None" ]; then
  die "Could not find the '${ENDPOINT_DESC}' endpoint. Deploy the claude-client-vpn stack first (bash deploy.sh vpn or DEPLOY_VPN=yes bash deploy.sh all)."
fi
info "endpoint: $ENDPOINT_ID"

log "Waiting for the subnet association to become 'associated'"
STATUS=""
for _ in $(seq 1 40); do
  STATUS=$(aws ec2 describe-client-vpn-target-networks --client-vpn-endpoint-id "$ENDPOINT_ID" \
    --region "$REGION" --query "ClientVpnTargetNetworks[0].Status.Code" --output text 2>/dev/null || echo none)
  info "status: $STATUS"
  [ "$STATUS" = "associated" ] && break
  sleep 15
done
[ "$STATUS" = "associated" ] || die "Endpoint never became 'associated'. Check the VPN stack in the console."

# ---- 3. build the profile --------------------------------------------------
log "Exporting base profile"
aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id "$ENDPOINT_ID" --region "$REGION" --output text > "$OUT"

log "Appending client cert + key"
{
  printf '\n<cert>\n'; cat client.crt
  printf '</cert>\n<key>\n'; cat client.key
  printf '</key>\n'
} >> "$OUT"

# Clamp the in-tunnel TCP MSS. The endpoint pushes tun-mtu 1500, but some networks (corporate
# offices/hotel Wi-Fi behind inspection or extra encapsulation) have a lower effective path MTU and
# silently drop the oversized fragments without returning ICMP "fragmentation needed". The tunnel
# then connects and small packets flow, but the first large packet -- the TLS ClientHello to the
# gateway -- vanishes, which looks exactly like "the VPN is up but nothing works".
# mssfix makes OpenVPN advertise a smaller MSS so TCP segments always fit. 'mssfix' is on the AWS
# VPN Client's allowlist of accepted profile directives, so it survives profile import.
log "Appending mssfix (path-MTU mitigation)"
printf 'mssfix %s\n' "${OVPN_MSSFIX:-1260}" >> "$OUT"

# The profile embeds a private key — restrict to the owner.
chmod 600 "$OUT"

# ---- done ------------------------------------------------------------------
printf '\n\033[1;32m================ VPN profile ready ================\033[0m\n'
cat <<EOF

Profile written to: $(pwd)/${OUT}  (mode 0600, contains a private key inline)

Next steps on this laptop:
  1. Open the AWS VPN Client, import ${OUT}, and Connect.
  2. Create /Library/Application Support/ClaudeCode/managed-settings.json with:
       {"forceLoginMethod":"gateway","forceLoginGatewayUrl":"${GATEWAY_URL}"}
  3. Run:  claude   then  /login   and complete SSO.

SECURITY: ca.key, client.key, and ${OUT} are private key material. .gitignore
          excludes them, but back up ca.key + client.key to a password manager
          and delete the local copies once you no longer need them here.
EOF
