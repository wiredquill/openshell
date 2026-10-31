# OpenShell

Agents in [NVIDIA OpenShell](https://docs.nvidia.com/openshell/latest/) 0.1.5 sandboxes on
SUSE: hands-on labs, Helm charts, sandbox images and SUSE AI Factory blueprints.

## Layout

```
labs/                   hands-on OpenShell labs (Docker driver, then Kubernetes) — start at labs/README.md
charts/
  agent-sandbox/        Agent Sandbox CRD + controller, the prerequisite for the Kubernetes driver
  openshell-gateway/    NVIDIA's gateway chart (vendored, patched) with an install form
  hermes-openshell/     Hermes Agent in a sandbox, four security profiles, browser terminal
  hermes-rancher/       Hermes for platform engineers, with kubectl on the cluster
images/
  hermes/               Hermes sandbox image (SUSE BCI 16 or openSUSE Leap 16)
  hermes-client/        client pod: the openshell CLI that creates the sandbox
  hermes-rancher/       the Hermes image plus Rancher's agent CLI
catalog/
  blueprints/           SUSE AI Factory blueprints and their BlueprintCatalog
  clusterrepos/         the Rancher ClusterRepos the blueprints read charts from
scripts/
  publish-charts.sh     package charts/* onto the aif/charts branch
  vendor-openshell-chart.sh   re-vendor NVIDIA's chart with nvidia-chart.patch
```
## Add Repo to Rancher by importing ClusterRepo info 

```
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: openshell
spec:
  gitRepo: https://github.com/wiredquill/openshell
  gitBranch: aif/charts
```


## Install order

In Rancher **Apps** the chart names start with **OpenShell** and give the order:

| # | Rancher app | Chart | How many |
|---|---|---|---|
| 1 | **OpenShell 1 - Agent Sandbox controller** | `agent-sandbox` | **one per cluster**, install first |
| 2 | **OpenShell 2 - Gateway** | `openshell-gateway` | one per namespace; creates no sandbox |
| 3 | **OpenShell 3 - Hermes Agent sandbox** | `hermes-openshell` | in the gateway's namespace |
| 3 | **Hermes for Rancher** | `hermes-rancher` | in the gateway's namespace |
| 3 | **OpenShell 3 - can-i sandbox** | `can-i` ([wiredquill/can-i](https://github.com/wiredquill/can-i)) | in the gateway's namespace |

Only step 3 creates a sandbox and a web UI. The architecture diagram is in
[`charts/agent-sandbox/README.md`](charts/agent-sandbox/README.md#architecture).
`openshell-gateway` vendors NVIDIA's chart with a patch: rebuild it with
`scripts/vendor-openshell-chart.sh`, never `helm dependency update`.

## Blueprints

| Blueprint | Components |
|---|---|
| `hermes-openshell` 1.0.0 | `agent-sandbox`, `openshell-gateway`, `hermes-openshell`. The model is an external OpenAI-compatible API (OpenRouter by default). |
| `hermes-openshell-vllm` 1.0.0 | Same, plus SUSE `vllm` 0.1.10 serving Qwen2.5-7B-Instruct (GPU) |
| `hermes-rancher` 1.0.0 | `agent-sandbox`, `openshell-gateway`, `hermes-rancher` |
| `can-i-openshell` 1.0.0 | `agent-sandbox`, `openshell-gateway`, and `can-i` |

The blueprints read charts from three ClusterRepos, all in `catalog/clusterrepos/`:
`wiredquill-openshell` (this repo), `wiredquill-can-i` (the can-i chart) and
`wiredquill-ai-demos` (the SUSE `vllm` chart with an install form). Register them once per
Rancher management cluster:

```bash
kubectl apply -f catalog/clusterrepos/
```

The `can-i-openshell` blueprint also exists in the can-i repository. Register only one of
the two blueprint catalogs that contain it, because Fleet won't adopt a Blueprint that
another catalog created.

## Publishing

- **Charts:** `.github/workflows/publish-charts.yml` runs `scripts/publish-charts.sh --push`
  on every push to `main` that touches `charts/`. Published versions are immutable, so bump
  a chart's `version` to ship a change.
- **Images:** `.github/workflows/build-hermes-openshell.yml` builds `hermes-openshell`,
  `hermes-openshell-opensuse`, `hermes-openshell-client` and `hermes-rancher` to
  `ghcr.io/wiredquill/`, tagged with the commit sha; `main` also moves `latest`.
