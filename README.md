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
| `wiredquill-openshell` | this repo, branch `aif/charts` | every blueprint (and can-i's) |

In Rancher, open the **local** cluster, click **Import YAML** (the up-arrow icon in the
top bar) and paste this (also `catalog/clusterrepos/wiredquill-openshell.yaml`):

```yaml
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: wiredquill-openshell
spec:
  gitRepo: https://github.com/wiredquill/openshell
  gitBranch: aif/charts
```

If you added this repo earlier as `openshell`, delete that one after the new one shows
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
| 3 | **OpenShell 3 - can-i sandbox** | `can-i` (from [SUSE-Technical-Marketing/can-i](https://github.com/SUSE-Technical-Marketing/can-i), its own chart repo) | in the gateway's namespace |

Only step 3 creates a sandbox and a web UI. The architecture diagram is in
[`charts/agent-sandbox/README.md`](charts/agent-sandbox/README.md#architecture).
`openshell-gateway` vendors NVIDIA's chart with a patch: rebuild it with
`scripts/vendor-openshell-chart.sh`, never `helm dependency update`.

## Blueprints

One blueprint per Rancher app, with the same chart, version and defaults. Install them in
the numbered order, like the Rancher apps:

| Blueprint | Chart | Namespace |
|---|---|---|
| **OpenShell 1 - Agent Sandbox controller** (`openshell-agent-sandbox` 1.0.0) | `agent-sandbox` 1.0.11 | always `agent-sandbox-system`; once per cluster |
| **OpenShell 2 - Gateway** (`openshell-gateway` 1.0.0) | `openshell-gateway` 0.1.9 | the namespace you pick, e.g. `openshell` |
| **OpenShell 3 - Hermes Agent sandbox** (`hermes-openshell` 2.0.0) | `hermes-openshell` 0.2.1 | the gateway's namespace |
| **Hermes for Rancher** (`hermes-rancher` 2.0.0) | `hermes-rancher` 0.2.2 | the gateway's namespace |

`hermes-openshell` and `hermes-rancher` 1.x bundled Agent Sandbox and the gateway, and
`hermes-openshell-vllm` added SUSE vLLM; they're gone. For an in-cluster model, install
vLLM separately and pick the vLLM backend in the Hermes form.

The blueprints need the `wiredquill-openshell` ClusterRepo in
[Add the chart repositories to Rancher](#add-the-chart-repositories-to-rancher).

The `can-i-openshell` blueprint lives in its own catalog in
[SUSE-Technical-Marketing/can-i](https://github.com/SUSE-Technical-Marketing/can-i). It
installs `agent-sandbox` and `openshell-gateway` from this repo's `wiredquill-openshell`
ClusterRepo and only `can-i` from its own.

## Publishing

- **Charts:** `.github/workflows/publish-charts.yml` runs `scripts/publish-charts.sh --push`
  on every push to `main` that touches `charts/`. Published versions are immutable, so bump
  a chart's `version` to ship a change.
- **Images:** `.github/workflows/build-hermes-openshell.yml` builds `hermes-openshell`,
  `hermes-openshell-opensuse`, `hermes-openshell-client` and `hermes-rancher` to
  `ghcr.io/wiredquill/`, tagged with the commit sha; `main` also moves `latest`.
