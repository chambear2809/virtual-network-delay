#!/usr/bin/env bash

set -euo pipefail

BACKEND_PROTOCOL="${BACKEND_PROTOCOL:-http}"
BACKEND_HOST="${BACKEND_HOST:-backend}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
PUBLIC_PORT="${PUBLIC_PORT:-80}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5s}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-60s}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-60s}"

mkdir -p /run/haproxy

mode="http"
case "${BACKEND_PROTOCOL}" in
  http)
    mode="http"
    ;;
  https|rtsp|tcp)
    mode="tcp"
    ;;
  *)
    printf 'Unsupported protocol: %s\n' "${BACKEND_PROTOCOL}" >&2
    exit 1
    ;;
esac

cat >/etc/haproxy/haproxy.cfg <<EOF
global
  log stdout format raw local0
  maxconn 4096
  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners

defaults
  log global
  mode ${mode}
  option dontlognull
  timeout connect ${CONNECT_TIMEOUT}
  timeout client ${CLIENT_TIMEOUT}
  timeout server ${SERVER_TIMEOUT}

frontend public_${BACKEND_PROTOCOL}_${PUBLIC_PORT}
  bind *:${PUBLIC_PORT}
  mode ${mode}
  default_backend backend_${BACKEND_PROTOCOL}_${BACKEND_PORT}

backend backend_${BACKEND_PROTOCOL}_${BACKEND_PORT}
  mode ${mode}
  server target ${BACKEND_HOST}:${BACKEND_PORT} check
EOF

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
public_if="$(ip route show default | awk '{print $5; exit}')"
if [[ -n "${public_if}" ]]; then
  iptables -t nat -C POSTROUTING -o "${public_if}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "${public_if}" -j MASQUERADE 2>/dev/null \
    || true
fi

haproxy -c -f /etc/haproxy/haproxy.cfg
haproxy -f /etc/haproxy/haproxy.cfg -D -p /run/haproxy.pid

while kill -0 "$(cat /run/haproxy.pid)" >/dev/null 2>&1; do
  sleep 5
done
