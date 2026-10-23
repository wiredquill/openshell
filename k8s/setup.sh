#!/bin/bash
# Deploy OpenShell to the ai-4090 cluster and register it with the CLI on
# this host as gateway "k8s". Idempotent: safe to re-run after editing
# values.yaml or the qwen profile.
set -euo pipefail
cd "$(dirname "$0")"

export KUBECONFIG=${KUBECONFIG:-~/.kube/ai-4090.yaml}
CHART=oci://ghcr.io/nvidia/openshell/helm-chart
VERSION=0.1.5
NS=openshell
PORT=17680
GW=k8s

echo "==> agent-sandbox controller (prerequisite, cluster-scoped)"
kubectl get crd sandboxes.agents.x-k8s.io >/dev/null
kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=60s

echo "==> helm: $CHART $VERSION"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
helm upgrade --install openshell "$CHART" --version "$VERSION" -n "$NS" -f values.yaml
kubectl -n "$NS" rollout status statefulset/openshell --timeout=180s

echo "==> port-forward: 127.0.0.1:$PORT -> svc/openshell:8080 (user systemd unit)"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/openshell-k8s-forward.service <<EOF
[Unit]
Description=kubectl port-forward to the OpenShell gateway on ai-4090

[Service]
Environment=KUBECONFIG=$KUBECONFIG
ExecStart=$(command -v kubectl) -n $NS port-forward svc/openshell $PORT:8080
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now openshell-k8s-forward.service
systemctl --user restart openshell-k8s-forward.service   # pick up a restarted gateway pod
for _ in $(seq 20); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 1; done

echo "==> CLI: register gateway '$GW' with the chart's client TLS bundle"
# `gateway add --local` copies the local Docker gateway's bundle into the new
# registration and makes it active, so: add first, write the cluster's bundle
# after, then put the previously active gateway back.
active=$(cat ~/.config/openshell/active_gateway 2>/dev/null || true)
if ! openshell gateway list 2>/dev/null | grep -qw "$GW"; then
  openshell gateway add "https://127.0.0.1:$PORT" --local --name "$GW" || true
fi
[ -n "$active" ] && [ "$active" != "$GW" ] && openshell gateway select "$active" >/dev/null
D=~/.config/openshell/gateways/$GW/mtls
mkdir -p "$D"
for f in ca.crt tls.crt tls.key; do
  kubectl -n "$NS" get secret openshell-client-tls -o "jsonpath={.data.${f//./\\.}}" | base64 -d > "$D/$f"
done
chmod 600 "$D/tls.key"
OPENSHELL_GATEWAY=$GW openshell status

echo "==> provider: qwen (same profile as the Docker lab)"
export OPENSHELL_GATEWAY=$GW
P=../docker/providers/qwen-local.yaml
if ! openshell profile export qwen-local -o yaml >/dev/null 2>&1; then
  openshell profile import -f "$P"
else
  rv=$(openshell profile export qwen-local -o yaml | awk '/^resource_version:/{print $2}')
  tmp=$(mktemp); { echo "resource_version: $rv"; cat "$P"; } > "$tmp"
  openshell profile update qwen-local -f "$tmp"; rm -f "$tmp"
fi
openshell provider get qwen >/dev/null 2>&1 || openshell provider create --name qwen --type qwen-local

echo
echo "Done. Use this gateway with:  export OPENSHELL_GATEWAY=$GW"
