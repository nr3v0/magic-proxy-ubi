#!/bin/sh
# /usr/local/bin/acme-agent.sh
# ACME DNS-01 certificate agent for HAProxy.
#
# Uses acme.sh with the Porkbun DNS provider to obtain and auto-renew TLS
# certificates, then hands each cert to HAProxy through the Data Plane API
# (see acme-deploy-dataplane.sh, wired in as acme.sh's --reloadcmd).
#
# One certificate PER domain (not one multi-SAN cert covering every domain
# in the list) -- each is issued and renewed independently, so a DNS-01
# problem with any single domain can't block issuance for the rest.
#
# Runs as a long‑lived background daemon launched by the container entrypoint
# when ACME_ENABLED=true. It never exits on transient failure so the container
# stays up; errors are logged and retried on the next cycle.
#
# Configuration:
#   * Domains:
#       - ACME_DOMAINS           – space‑separated list (legacy)
#       - ACME_DOMAINS_FILE      – path to a file with one domain per line
#                                  (lines starting with # are ignored).
#       Defaults to /etc/haproxy/acme/acme_domains.txt, which ships with
#       everything commented out (safe no-op). If the file exists but is
#       empty/all-comments, ACME_DOMAINS is used instead; if the file has
#       real entries, it takes precedence over ACME_DOMAINS.
#   * API credentials and email are read from environment variables
#     (they can be sourced via `podman run --env-file ...`).
#   * Optional: ACME_CA, ACME_EMAIL, ACME_RENEW_INTERVAL, ACME_EXTRA_ARGS.
#
# Required runtime env (if not using ACME_DOMAINS_FILE):
#   ACME_DOMAINS            e.g. "example.com *.example.com"
#   PORKBUN_API_KEY         Porkbun API key (pk1_...)
#   PORKBUN_SECRET_API_KEY  Porkbun secret key (sk1_...)
# Optional:
#   ACME_CA                 acme.sh CA (default: letsencrypt)
#   ACME_EMAIL              account email for registration
#   ACME_RENEW_INTERVAL     seconds between renewal checks (default: 43200)
#   ACME_EXTRA_ARGS         extra flags passed verbatim to `acme.sh --issue`
#   DATAPLANE_URL/USER/PASS consumed by acme-deploy-dataplane.sh
set -euf

ACME_SH="/usr/local/share/acme.sh/acme.sh"
: "${LE_CONFIG_HOME:=/etc/haproxy/acme}"
export LE_CONFIG_HOME

ACME_CA="${ACME_CA:-letsencrypt}"
ACME_DOMAINS="${ACME_DOMAINS:-}"
ACME_DOMAINS_FILE="${ACME_DOMAINS_FILE:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
RENEW_INTERVAL="${ACME_RENEW_INTERVAL:-43200}"
DEPLOY_HOOK="/usr/local/bin/acme-deploy-dataplane.sh"

log() { echo "[acme-agent] $*"; }

# ----------------------------------------------------------------------
# Helper: load domain list from either ACME_DOMAINS_FILE (one per line, #
# comments ignored) or ACME_DOMAINS (space-separated). The file only wins
# if it actually has content after stripping comments/blank lines -- this
# matters because ACME_DOMAINS_FILE has a baked-in default (see Containerfile)
# that ships empty, so a bare `-e ACME_DOMAINS=...` override still works
# without also having to unset ACME_DOMAINS_FILE.
# Returns a space-separated list suitable for rebuilding the -d arguments.
# ----------------------------------------------------------------------
load_domains() {
    local result=""
    if [ -n "$ACME_DOMAINS_FILE" ] && [ -r "$ACME_DOMAINS_FILE" ]; then
        # Strip comments, trim whitespace, ignore empty lines, join with space.
        result=$(grep -v '^#' "$ACME_DOMAINS_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ' ')
    fi
    if [ -z "$result" ] && [ -n "$ACME_DOMAINS" ]; then
        result="$ACME_DOMAINS"
    fi
    # Trim trailing space
    printf "%s" "${result%"${result##*[![:space:]]}"}"
}

# ----------------------------------------------------------------------
# Handler for SIGUSR1: reload domain list from config/env and rebuild args.
# ----------------------------------------------------------------------
reload_domains_on_signal() {
    local new_list
    new_list=$(load_domains)
    if [ -z "$new_list" ]; then
        log "No domains configured after reload – idling."
        idle_forever
    fi
    domains_list="$new_list"
    log "Domains reloaded via SIGUSR1 – new list: '$new_list'"
}

# ----------------------------------------------------------------------
# Simple idle loop used when there are no domains to manage.
# ----------------------------------------------------------------------
idle_forever() {
    # Keep the daemon alive but inert so the container stays healthy.
    while true; do sleep 3600; done
}

# ----------------------------------------------------------------------
# Initialisation
# ----------------------------------------------------------------------

# Determine initial domain list.
domains_list=$(load_domains)
if [ -z "$domains_list" ]; then
    log "No domains configured (ACME_DOMAINS or ACME_DOMAINS_FILE). Idling."
    idle_forever
fi

if [ -z "${PORKBUN_API_KEY:-}" ] || [ -z "${PORKBUN_SECRET_API_KEY:-}" ]; then
    log "ERROR: PORKBUN_API_KEY / PORKBUN_SECRET_API_KEY are not set. Idling." >&2
    idle_forever
fi
export PORKBUN_API_KEY PORKBUN_SECRET_API_KEY

# One certificate PER domain, not one multi-SAN cert covering all of them --
# each domain is issued/tracked independently by acme.sh (keyed by its own
# $LE_CONFIG_HOME/<domain> directory) so a DNS-01 failure on any single
# domain (rate limit, a stale/missing DNS record, etc.) can't block
# issuance for every other domain in the list.
cert_exists_for() {
    d="$1"
    [ -d "$LE_CONFIG_HOME/$d" ] || [ -d "${LE_CONFIG_HOME}/${d}_ecc" ]
}

# Register an ACME account up front (idempotent; some CAs require an email).
if [ -n "$ACME_EMAIL" ]; then
    "$ACME_SH" --register-account --server "$ACME_CA" -m "$ACME_EMAIL" || \
        log "account registration returned non-zero (continuing)"
fi

issue_or_renew() {
    for d in $domains_list; do
        if cert_exists_for "$d"; then
            continue
        fi
        log "issuing certificate for: $d"
        "$ACME_SH" --issue --server "$ACME_CA" --dns dns_porkbun -d "$d" \
            --reloadcmd "$DEPLOY_HOOK" ${ACME_EXTRA_ARGS:-} || \
            log "issue failed for $d; will retry next cycle"
    done
    # --cron renews (across all domains issued above, in past cycles, or
    # already present before this container started) only the certs that
    # are due, and reruns each one's own stored reloadcmd.
    "$ACME_SH" --cron || log "renewal cycle returned non-zero (will retry)"
}

# Install signal handler for hot-reload of domain list.
trap 'reload_domains_on_signal' USR1

log "starting (CA=$ACME_CA, domains='$domains_list', interval=${RENEW_INTERVAL}s)"
# Perform an initial issuance/renewal right away.
issue_or_renew

# Initialise the last modification time for the domain file (if used).
if [ -n "$ACME_DOMAINS_FILE" ] && [ -r "$ACME_DOMAINS_FILE" ]; then
    last_mtime=$(stat -c %Y "$ACME_DOMAINS_FILE" 2>/dev/null || echo 0)
else
    last_mtime=0
fi

# ----------------------------------------------------------------------
# Main loop:
#   * Sleep for the renewal interval.
#   * If a domain file is configured, check its modification time.
#   * If the file changed, reload the list and rebuild the -d arguments.
#   * Then perform the renewal/issuance check.
#   * SIGUSR1 can also trigger a reload at any time.
# ----------------------------------------------------------------------
while true; do
    sleep "$RENEW_INTERVAL"

    # If we are using a domain file, poll its modification time.
    if [ -n "$ACME_DOMAINS_FILE" ] && [ -r "$ACME_DOMAINS_FILE" ]; then
        current_mtime=$(stat -c %Y "$ACME_DOMAINS_FILE" 2>/dev/null || echo 0)
        if [ "$current_mtime" -ne "$last_mtime" ]; then
            # File changed – reload the list.
            domains_list=$(load_domains)
            if [ -z "$domains_list" ]; then
                log "Domain file now empty – idling until domains are added."
                idle_forever
            fi
            last_mtime="$current_mtime"
            log "Domains file changed (mtime) – new list: '$domains_list'"
        fi
    fi

    # Perform the renewal/issuance check.
    issue_or_renew
done