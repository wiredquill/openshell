#!/bin/bash
# Configure the local OpenShell gateway for the Docker labs.
# Idempotent: safe to re-run after editing the image, profile, or config.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=localhost/openshell-lab/leap:16.0
CONF=~/.config/openshell/gateway.toml

echo "==> preflight"
for bin in openshell openshell-gateway docker systemctl; do
  command -v "$bin" >/dev/null || { echo "error: '$bin' not found. Install the OpenShell RPM and Docker first." >&2; exit 1; }
done
systemctl --user cat openshell-gateway.service >/dev/null 2>&1 \
  || { echo "error: user unit openshell-gateway.service not found. Is the OpenShell RPM installed?" >&2; exit 1; }

echo "==> gateway: pin Docker compute driver"
mkdir -p "$(dirname "$CONF")"
# The RPM may seed a Podman-pinned config; keep the original once, if there is one.
if [ -f "$CONF" ] && [ ! -f "$CONF.podman.bak" ]; then
  cp "$CONF" "$CONF.podman.bak"
fi
if ! cmp -s gateway/gateway.toml "$CONF"; then
  cp gateway/gateway.toml "$CONF"
  openshell-gateway config preflight
  systemctl --user restart openshell-gateway
fi
systemctl --user is-active -q openshell-gateway || systemctl --user enable --now openshell-gateway

echo "==> CLI: register the local gateway"
# The RPM starts the gateway but doesn't register it with the CLI.
# `--local` uses the local gateway's own client mTLS bundle and makes it active.
if ! openshell gateway list 2>/dev/null | grep -qw local; then
  openshell gateway add https://127.0.0.1:17670 --local --name local
fi
openshell gateway select local >/dev/null

# The Docker driver takes a few seconds to connect after a restart.
for _ in $(seq 30); do openshell status 2>/dev/null | grep -q 'Status: Connected' && break; sleep 1; done
openshell status
openshell status | grep -q 'Status: Connected' \
  || { echo "error: gateway not connected; see: journalctl --user -u openshell-gateway -n 50" >&2; exit 1; }

echo "==> image: build $IMAGE"
docker build -q -t "$IMAGE" images/leap

echo "==> provider: qwen (no credentials, LAN vLLM)"
if ! openshell profile export qwen-local -o yaml >/dev/null 2>&1; then
  # lint also checks the gateway, so it only passes before the first import.
  openshell profile lint -f providers/qwen-local.yaml
  openshell profile import -f providers/qwen-local.yaml
else
  # Updates must carry the stored resource_version (optimistic locking).
  rv=$(openshell profile export qwen-local -o yaml | awk '/^resource_version:/{print $2}')
  tmp=$(mktemp --suffix=.yaml)
  { echo "resource_version: $rv"; cat providers/qwen-local.yaml; } > "$tmp"
  openshell profile update qwen-local -f "$tmp" || true
  rm -f "$tmp"
fi
openshell provider get qwen >/dev/null 2>&1 \
  || openshell provider create --name qwen --type qwen-local
openshell provider list

echo "==> ready. Start with labs/01-files.md"
