#!/usr/bin/env bash
# Print the sandbox policy a Hermes chart would apply, before you deploy it.
#
#   scripts/preview-policy.sh [chart] [helm args...]
#
#   chart  hermes-openshell (default) or hermes-rancher
#
#   scripts/preview-policy.sh hermes-openshell --set profile=custom \
#     --set policy.addons.githubRead=true --set policy.addons.pypi=true \
#     --set-string policy.extraHosts=$'api.example.com:8443 read-write'
#
# Feed the output to `openshell policy set <sandbox> --policy <file>` to apply
# it to a running sandbox without redeploying.
set -euo pipefail
cd "$(dirname "$0")/.."
chart=hermes-openshell
case "${1:-}" in hermes-openshell|hermes-rancher) chart=$1; shift ;; esac
helm template preview "charts/$chart" "$@" -s templates/configmap.yaml \
  | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin)
print(doc["data"]["policy.yaml"], end="")
'
