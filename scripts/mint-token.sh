#!/usr/bin/env bash
# Mint a PoC HS256 JWT that Kong's `jwt` plugin will accept.
#
#   iss   = mis-auth   (must match the jwt_secret `key` in kong.yml)
#   secret= $JWT_SECRET (must match docker-compose.yml's JWT_SECRET)
#
# Usage:
#   ./scripts/mint-token.sh                 # prints the token
#   TOKEN=$(./scripts/mint-token.sh)
#   curl -H "Authorization: Bearer $TOKEN" localhost:8000/api/auth/
#
# Env overrides: JWT_SECRET, JWT_TTL (seconds), JWT_SUB, JWT_ROLES (csv)
set -euo pipefail

SECRET="${JWT_SECRET:-mis-poc-dev-secret-change-me}"
TTL="${JWT_TTL:-3600}"
SUB="${JWT_SUB:-u-001}"
ROLES="${JWT_ROLES:-admin}"

now=$(date +%s)
exp=$(( now + TTL ))
roles_json=$(printf '%s' "$ROLES" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

header='{"alg":"HS256","typ":"JWT"}'
payload="{\"iss\":\"mis-auth\",\"sub\":\"${SUB}\",\"name\":\"Dev User\",\"email\":\"dev@mis.local\",\"roles\":[${roles_json}],\"iat\":${now},\"exp\":${exp}}"

h=$(printf '%s' "$header"  | b64url)
p=$(printf '%s' "$payload" | b64url)
sig=$(printf '%s' "${h}.${p}" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64url)

echo "${h}.${p}.${sig}"
echo "minted JWT — sub=${SUB} roles=[${ROLES}] exp in ${TTL}s (iss=mis-auth)" >&2
