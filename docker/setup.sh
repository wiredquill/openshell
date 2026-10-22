#!/bin/bash
# Configure the local OpenShell gateway for the Docker labs.
# Idempotent: safe to re-run after editing the image, profile, or config.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE=localhost/openshell-lab/leap:16.0
CONF=~/.config/openshell/gateway.toml

echo "==> gateway: pin Docker compute driver"
# The RPM seeds a Podman-pinned config; keep the original once.
[ -f "$CONF.podman.bak" ] || cp "$CONF" "$CONF.podman.bak"
if ! cmp -s gateway/gateway.toml "$CONF"; then
  cp gateway/gateway.toml "$CONF"
  openshell-gateway config preflight
  systemctl --user restart openshell-gateway
fi
# The Docker driver takes a few seconds to connect after a restart.
for _ in $(seq 30); do openshell status >/dev/null 2>&1 && break; sleep 1; done
openshell status

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
