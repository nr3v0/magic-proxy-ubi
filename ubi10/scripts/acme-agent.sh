#!/bin/sh
# /usr/local/bin/acme-agent.sh
# ACME DNS-01 certificate agent for HAProxy.
#
# Uses acme.sh with the Porkbun DNS provider to obtain and auto-renew TLS
# certificates, then hands each cert to HAProxy through the Data Plane API
# (see acme-deploy-dataplane.sh, wired in as acme.sh's --reloadcmd).
#
# Runs as a long-lived background daemon launched by the container entrypoint
# when ACME_ENABLED=true. It never exits on transient failure so the container
# stays up; errors are logged and retried on the next cycle.
#
# Required runtime env:
#   ACME_DOMAINS            space-separated domains, e.g. "example.com *.example.com"
#   PORKBUN_API_KEY         Porkbun API key (pk1_...)
#   PORKBUN_SECRET_API_KEY  Porkbun secret key (sk1_...)
# Optional:
#   ACME_CA                 acme.sh CA (default: letsencrypt)
#   ACME_EMAIL              account email for registration
#   ACME_RENEW_INTERVAL     seconds between renewal checks (default: 43200)
#   ACME_EXTRA_ARGS         extra flags passed verbatim to `acme.sh --issue`
#   DATAPLANE_URL/USER/PASS  consumed by acme-deploy-dataplane.sh
set -euf

ACME_SH="/usr/local/share/acme.sh/acme.sh"
: "${LE_CONFIG_HOME:=/etc/haproxy/acme}"
export LE_CONFIG_HOME

ACME_CA="${ACME_CA:-letsencrypt}"
ACME_DOMAINS="${ACME_DOMAINS:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
RENEW_INTERVAL="${ACME_RENEW_INTERVAL:-43200}"
DEPLOY_HOOK="/usr/local/bin/acme-deploy-dataplane.sh"

log() { echo "[acme-agent] $*"; }

idle_forever() {
    # Keep the daemon alive but inert so the container stays healthy.
    while true; do sleep 3600; done
}

if [ -z "$ACME_DOMAINS" ]; then
    log "ACME_DOMAINS is empty; no certificates to manage. Idling."
    idle_forever
fi

if [ -z "${PORKBUN_API_KEY:-}" ] || [ -z "${PORKBUN_SECRET_API_KEY:-}" ]; then
    log "ERROR: PORKBUN_API_KEY / PORKBUN_SECRET_API_KEY are not set. Idling." >&2
    idle_forever
fi
export PORKBUN_API_KEY PORKBUN_SECRET_API_KEY

# Build the -d argument list; the first domain is the cert/account identity.
# set -f (above) keeps wildcard domains like *.example.com from glob-expanding.
set --
for d in $ACME_DOMAINS; do
    set -- "$@" -d "$d"
done
MAIN_DOMAIN="${ACME_DOMAINS%% *}"

cert_exists() {
    [ -d "$LE_CONFIG_HOME/$MAIN_DOMAIN" ] || [ -d "${LE_CONFIG_HOME}/${MAIN_DOMAIN}_ecc" ]
}

# Register an ACME account up front (idempotent; some CAs require an email).
if [ -n "$ACME_EMAIL" ]; then
    "$ACME_SH" --register-account --server "$ACME_CA" -m "$ACME_EMAIL" || \
        log "account registration returned non-zero (continuing)"
fi

issue_or_renew() {
    if cert_exists; then
        log "checking renewal for $MAIN_DOMAIN"
        # --cron renews only certs that are due and reruns their stored reloadcmd.
        "$ACME_SH" --cron || log "renewal cycle returned non-zero (will retry)"
    else
        log "issuing certificate for: $ACME_DOMAINS"
        # shellcheck disable=SC2086
        "$ACME_SH" --issue --server "$ACME_CA" --dns dns_porkbun "$@" \
            --reloadcmd "$DEPLOY_HOOK" ${ACME_EXTRA_ARGS:-} || \
            log "issue failed; will retry next cycle"
    fi
}

log "starting (CA=$ACME_CA, domains='$ACME_DOMAINS', interval=${RENEW_INTERVAL}s)"
# "$@" still holds the -d domain list built above; pass it into the function so
# its own positional parameters are the domain args.
issue_or_renew "$@"
while true; do
    sleep "$RENEW_INTERVAL"
    issue_or_renew "$@"
done
