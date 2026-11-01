#!/bin/bash
# Delete every lab sandbox. Pass --restore-podman to also put back the
# gateway config setup.sh replaced, if there was one.
set -uo pipefail

for s in $(openshell sandbox list 2>/dev/null | awk 'NR>1 && $1 ~ /^lab-/ {print $1}'); do
  openshell sandbox delete "$s"
done

if [ "${1:-}" = "--restore-podman" ]; then
  CONF=~/.config/openshell/gateway.toml
  if [ -f "$CONF.podman.bak" ]; then
    cp "$CONF.podman.bak" "$CONF"
    systemctl --user restart openshell-gateway
    echo "restored Podman gateway config"
  else
    echo "no $CONF.podman.bak: there was no config before setup.sh, so nothing to restore"
  fi
fi
