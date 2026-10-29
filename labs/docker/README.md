# OpenShell with Docker

## Setup

The OpenShell RPM installs a **user** systemd unit (`openshell-gateway.service`) and seeds
`~/.config/openshell/gateway.toml` pinned to `compute_driver = "podman"`. This lab switches it
to Docker:

```bash
cd /data/openshell-lab/labs/docker
./setup.sh
```

`setup.sh`:

1. backs up the seeded config to `~/.config/openshell/gateway.toml.podman.bak`, installs
   [gateway/gateway.toml](gateway/gateway.toml), and restarts the gateway
2. builds `localhost/openshell-lab/leap:16.0` from [images/leap](images/leap/Dockerfile)
3. imports the [qwen-local](providers/qwen-local.yaml) provider profile and creates the `qwen` provider

Check it worked:

```bash
openshell status                                      # Status: Connected
journalctl --user -u openshell-gateway | grep driver  # Using compute driver driver=docker
```

## The lab image

`images/leap/Dockerfile` is openSUSE Leap 16.0 with the tools the labs need: curl, python3.13,
procps, iproute2, strace, nc, capsh. It also holds deliberate traps:

| Fixture | Why it's there |
|---|---|
| `USER sandbox` (1000) | Docker uses the image USER when policy doesn't set one. Root images are rejected. |
| no `wget` | Lab 02 adds it with [images/leap-wget](images/leap-wget/Dockerfile). |
| no agent | Lab 06 adds Hermes Agent with [images/hermes](images/hermes/Dockerfile). |
| `/lab/public`, `/lab/scratch`, `/lab/secret` | Lab 03 grants them one at a time. |
| `/lab/secret/creds.txt` owned by `sandbox`, mode 0600 | Unix permissions would allow it, so a denial can only come from Landlock. |
| `/lab/team/report.txt` owned by uid 2000, mode 0600 | Landlock allows it, Unix permissions don't. Lab 04 switches the agent to uid 2000. |
| `/opt/agent-home/notes.txt` owned by `sandbox` | Outside every policy and baseline path. |
| `sandbox ALL=(ALL) NOPASSWD: ALL` in sudoers | A misconfigured image. Lab 04 shows it still can't escalate. |

The probe scripts are installed into `/usr/local/bin`. The labs don't need them, but they
show a whole sandbox's boundary at once:

| Probe | Shows |
|---|---|
| `fs-probe [paths]` | LIST / READ / WRITE per path |
| `net-probe [urls]` | HTTP result per URL, synthetic DNS, raw TCP, interfaces |
| `proc-probe` | identity, capabilities, seccomp, and a dozen escalation attempts |
| `ask-qwen "prompt"` | one chat completion against `$OPENAI_BASE_URL` |

OpenShell **replaces the image's CMD/ENTRYPOINT** with its own runtime. You always pass the
command after `--`. The labs use `-- sleep infinity` plus `sandbox exec`.

## How the Docker driver builds a sandbox

Create any sandbox and look at Docker:

```bash
openshell sandbox create --name peek --from localhost/openshell-lab/leap:16.0 \
  --no-auto-providers --detach -- sleep infinity
docker ps --format '{{.Names}}' | grep peek
```

Every sandbox is **two containers** plus two named volumes:

| | workload `openshell-default--<name>-<uuid>` | supervisor `…-supervisor` |
|---|---|---|
| image | your image | `ghcr.io/nvidia/openshell/supervisor` (pinned to gateway version) |
| user | image USER, or policy `run_as_user` | 65534 (nobody) |
| network | **none** (loopback only) | **host**, so it reaches the gateway on 127.0.0.1:17670 |
| caps | `--cap-drop ALL`, `no-new-privileges` | `--cap-drop ALL`, `no-new-privileges`, read-only rootfs |
| entrypoint | `/.openshell/runtime/openshell-sandbox` | `/openshell-supervisor` |
| shared | `openshell-channel-*` volume, read-only: Unix socket for the mTLS sandbox protocol | same volume, read-write, plus its private `openshell-supervisor-*` volume |
| limits | pids 2048, plus `--cpu` / `--memory` if given | |

```bash
docker inspect <workload> --format 'net={{.HostConfig.NetworkMode}} user={{.Config.User}} caps={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}'
# net=none user=1000 caps=[ALL] sec=[no-new-privileges:true]
```

The workload's PID 1 is `openshell-sandbox`. It applies Landlock and seccomp to itself,
waits for the supervisor to confirm the boundary, and only then starts your command. If the
supervisor connection drops, the agent is frozen.

## Everyday commands

```bash
openshell sandbox create --name X --from IMAGE --policy FILE [--provider P] --detach -- CMD
openshell sandbox exec -n X --no-tty -- CMD        # new process in the sandbox
openshell sandbox exec -n X --tty -- /bin/bash -l  # interactive shell
openshell sandbox list | get X | stop X | start X | delete X
openshell policy get X --full                      # effective policy incl. provider rules
openshell policy set X --policy FILE --wait        # replace (live sections only)
openshell policy update X --rule-name R --binary B --add-endpoint host:port:access:proto:enforce --wait
openshell policy list X                            # revision history
openshell logs X --since 5m --source sandbox       # OCSF audit events (ALLOWED / DENIED)
openshell term                                     # TUI dashboard
```
