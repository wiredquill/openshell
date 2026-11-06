# OpenShell

Agents in [NVIDIA OpenShell](https://docs.nvidia.com/openshell/latest/) 0.1.5 sandboxes on
SUSE: hands-on labs, Helm charts, sandbox images and SUSE AI Factory blueprints.

## Layout

```
docs/
  landlock/             enable Landlock on SLES and openSUSE nodes, required before installing
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
  clusterrepos/         the Rancher ClusterRepo for this repo's charts
scripts/
  publish-charts.sh     package charts/* onto the aif/charts branch
  vendor-openshell-chart.sh   re-vendor NVIDIA's chart with nvidia-chart.patch
```
## Add the chart repositories to Rancher

The blueprints find their charts through ClusterRepos **with exactly these names**
(`chartRepo:` in each blueprint). Under any other name, for example `openshell`, the
AI Factory blueprint editor shows raw YAML instead of the install forms and the
components can't install.

| ClusterRepo name | Source | Used by |
|---|---|---|
| `wiredquill-openshell` | this repo, branch `aif/charts` | every blueprint |
| `wiredquill-can-i` | `wiredquill/can-i`, branch `aif/charts` | `can-i-openshell` |
| `wiredquill-ai-demos` | `wiredquill/ai-demos`, branch `aif/charts` | `hermes-openshell-vllm` (SUSE `vllm` with an install form) |

In Rancher, open the **local** cluster, click **Import YAML** (the up-arrow icon in the
top bar) and paste this. `catalog/clusterrepos/` holds only `wiredquill-openshell`, the one
this repo owns; the other two are defined in can-i and ai-demos:

```yaml
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: wiredquill-openshell
spec:
  gitRepo: https://github.com/wiredquill/openshell
  gitBranch: aif/charts
---
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: wiredquill-can-i
spec:
  gitRepo: https://github.com/wiredquill/can-i
  gitBranch: aif/charts
---
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: wiredquill-ai-demos
spec:
  gitRepo: https://github.com/wiredquill/ai-demos
  gitBranch: aif/charts
```

If you added this repo earlier as `openshell`, delete that one after the new ones show
**Active**, so the charts aren't listed twice in Apps.

## Install order

Every node that runs sandboxes needs Landlock enabled in its kernel, or no sandbox starts.
Do this first: [Enable Landlock on SLES and openSUSE](docs/landlock/README.md).

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

The blueprints need the three ClusterRepos in
[Add the chart repositories to Rancher](#add-the-chart-repositories-to-rancher).

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
