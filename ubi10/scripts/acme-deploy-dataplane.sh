#!/bin/sh
# /usr/local/bin/acme-deploy-dataplane.sh
# acme.sh --reloadcmd hook: push a freshly issued/renewed certificate into
# HAProxy via the Data Plane API SSL certificate storage, then trigger a
# hitless reload (force_reload=true -> reload_cmd -> haproxy-reload.sh -> USR2).
#
# acme.sh exports these for the reloadcmd:
#   Le_Domain, CERT_FULLCHAIN_PATH, CERT_KEY_PATH, CERT_PATH, CA_CERT_PATH
set -eu

DPA_URL="${DATAPLANE_URL:-http://127.0.0.1:5555}"
DPA_USER="${DATAPLANE_USER:-admin}"
DPA_PASS="${DATAPLANE_PASS:-change-me}"

DOMAIN="${Le_Domain:?Le_Domain not set by acme.sh}"
: "${CERT_FULLCHAIN_PATH:?CERT_FULLCHAIN_PATH not set by acme.sh}"
: "${CERT_KEY_PATH:?CERT_KEY_PATH not set by acme.sh}"

# Data Plane API stores certs by filename; '*' from wildcard domains is not
# URL/path friendly, so map it to '_' (HAProxy still matches via SNI at runtime).
SAFE_DOMAIN=$(printf '%s' "$DOMAIN" | tr '*' '_')
CERT_NAME="${SAFE_DOMAIN}.pem"

PEM="$(mktemp)"
trap 'rm -f "$PEM"' EXIT
# HAProxy expects a single PEM: fullchain followed by the private key.
cat "$CERT_FULLCHAIN_PATH" "$CERT_KEY_PATH" > "$PEM"

log() { echo "[acme-deploy] $*"; }

log "pushing $CERT_NAME to $DPA_URL"

# Update first; if the cert isn't in storage yet, create it. Both force a reload.
code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -u "$DPA_USER:$DPA_PASS" \
    -H 'Content-Type: text/plain' \
    -X PUT "$DPA_URL/v3/services/haproxy/storage/ssl_certificates/$CERT_NAME?force_reload=true" \
    --data-binary @"$PEM" || echo 000)

case "$code" in
    2*)
        log "updated $CERT_NAME (HTTP $code)"
        ;;
    404)
        log "cert not in storage yet, creating $CERT_NAME"
        curl -fsS \
            -u "$DPA_USER:$DPA_PASS" \
            -X POST "$DPA_URL/v3/services/haproxy/storage/ssl_certificates?force_reload=true" \
            -F "file_upload=@${PEM};filename=${CERT_NAME}" >/dev/null
        log "created $CERT_NAME"
        ;;
    *)
        log "ERROR: Data Plane API returned HTTP $code for $CERT_NAME" >&2
        exit 1
        ;;
esac
