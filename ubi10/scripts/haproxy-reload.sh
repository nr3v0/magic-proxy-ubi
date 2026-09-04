#!/bin/sh
# /usr/local/bin/haproxy-reload.sh
set -eu

CFG="${HAPROXY_CFG_FILE:-/etc/haproxy/haproxy.cfg}"
CONF_DIR="${HAPROXY_CONF_D_DIR:-/etc/haproxy/conf.d}"
PIDFILE="${HAPROXY_PIDFILE:-/var/lib/haproxy/haproxy.pid}"

if [ -d "$CONF_DIR" ]; then
    haproxy -c -f "$CFG" -f "$CONF_DIR"
else
    haproxy -c -f "$CFG"
fi

if [ ! -s "$PIDFILE" ]; then
    echo "ERROR: HAProxy pidfile not found: $PIDFILE" >&2
    exit 1
fi

kill -USR2 "$(cat "$PIDFILE")"