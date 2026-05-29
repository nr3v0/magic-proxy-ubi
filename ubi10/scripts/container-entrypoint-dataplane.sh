#!/bin/sh
# /usr/local/bin/container-entrypoint-dataplane.sh
# Supervises HAProxy and the Data Plane API as a single container process.
set -eu

MAIN_CFG="/etc/haproxy/haproxy.cfg"
CONF_DIR="/etc/haproxy/conf.d"
PIDFILE="/var/lib/haproxy/haproxy.pid"
HAPROXY_SOCKET="/run/haproxy/admin.sock"
DP_CFG="/etc/haproxy/dataplaneapi.yaml"

# Container-arg convention: a leading "-" means HAProxy flags (the default
# CMD), so prepend "haproxy". A first arg of "haproxy" is handled the same way.
# Anything else (e.g. `podman run ... sh`) is exec'd verbatim, bypassing the
# Data Plane API supervision so an override can get a debug shell or one-off
# command.
# Note: this path supervises a long-running server, so check-only flags like
# `-c` don't fit here (the supervisor waits for a socket that never opens). For
# a one-shot config check, use the exec form: `... sh -c 'haproxy -c -f ...'`.
if [ "$#" -gt 0 ] && [ "${1#-}" != "$1" ]; then
    set -- haproxy "$@"
fi

if [ "${1:-}" != "haproxy" ]; then
    exec "$@"
fi
shift

# "$@" now holds the HAProxy config flags to use; the CMD default is
#   -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/
# Fall back to the standard layout if the override supplied none.
if [ "$#" -eq 0 ]; then
    if [ -d "$CONF_DIR" ]; then
        set -- -f "$MAIN_CFG" -f "$CONF_DIR"
    else
        set -- -f "$MAIN_CFG"
    fi
fi

term_handler() {
    [ -n "${ACME_PID:-}" ] && kill -TERM "$ACME_PID" 2>/dev/null || true
    [ -n "${DP_PID:-}" ] && kill -TERM "$DP_PID" 2>/dev/null || true
    [ -n "${HAPROXY_PID:-}" ] && kill -TERM "$HAPROXY_PID" 2>/dev/null || true
    wait "${ACME_PID:-}" 2>/dev/null || true
    wait "${DP_PID:-}" 2>/dev/null || true
    wait "${HAPROXY_PID:-}" 2>/dev/null || true
    exit 0
}

trap term_handler TERM INT

if [ ! -r "$MAIN_CFG" ]; then
    echo "ERROR: $MAIN_CFG is missing or not readable" >&2
    exit 1
fi

# Validate the resolved config, then launch supervised in master-worker mode.
haproxy -c "$@"
/usr/sbin/haproxy -W -db -p "$PIDFILE" -S "$HAPROXY_SOCKET" "$@" &
HAPROXY_PID=$!

i=0
while [ $i -lt 30 ]; do
    if [ -S "$HAPROXY_SOCKET" ] && [ -s "$PIDFILE" ]; then
        break
    fi
    i=$((i+1))
    sleep 1
done

if [ ! -S "$HAPROXY_SOCKET" ]; then
    echo "ERROR: HAProxy socket did not appear at $HAPROXY_SOCKET" >&2
    exit 1
fi

/usr/sbin/dataplaneapi -f "$DP_CFG" -c "$MAIN_CFG" &
DP_PID=$!

# Optional ACME DNS-01 certificate agent. Started after the Data Plane API is
# up so it can push certs to it. It self-heals on failure, so it is NOT part of
# the wait -n set below: its death must not bring the container down.
if [ "${ACME_ENABLED:-false}" = "true" ]; then
    /usr/local/bin/acme-agent.sh &
    ACME_PID=$!
fi

wait -n "$HAPROXY_PID" "$DP_PID"
rc=$?

[ -n "${ACME_PID:-}" ] && kill -TERM "$ACME_PID" 2>/dev/null || true
kill -TERM "$DP_PID" 2>/dev/null || true
kill -TERM "$HAPROXY_PID" 2>/dev/null || true
wait "${ACME_PID:-}" 2>/dev/null || true
wait "$DP_PID" 2>/dev/null || true
wait "$HAPROXY_PID" 2>/dev/null || true

exit "$rc"