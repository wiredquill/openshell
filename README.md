# OpenShell Lab

Hands-on lab for [NVIDIA OpenShell](https://docs.nvidia.com/openshell/latest/) 0.1.5, the
sandbox runtime for autonomous agents. Everything runs on openSUSE: the gateway host is
openSUSE Leap 16.0 (`hermes`, 10.0.9.102) and every sandbox image is built
`FROM registry.opensuse.org/opensuse/leap:16.0`.

The model used throughout is `qwen3.8-27b`, served by vLLM at `http://10.9.0.42:30400/v1`
(OpenAI-compatible, no API key).

## What OpenShell is, in one picture

```
  you ── openshell CLI ──mTLS──▶ gateway (control plane: policy, providers, sandbox records)
                                    │  compute driver: docker | podman | kubernetes | vm
                                    ▼
          ┌──────────────── one sandbox ────────────────┐
          │  supervisor (trusted)      workload (agent) │
          │  - policy engine (OPA)     - your image     │
          │  - DNS + TCP egress   ◀──── - no network     │
          │  - credential inject  mTLS - Landlock       │
          │  - L7 HTTP inspection  sock - seccomp       │
          │                            - 0 capabilities │
          └──────────────────────────────────────────────┘
```

The workload has **no network device of its own**. Every DNS query and TCP connect is
caught by seccomp and handed to the supervisor, which checks it against policy and opens
the real connection only if allowed. Policy is one YAML file with four sections:

| Section | Controls | Enforced by | Changes on a live sandbox? |
|---|---|---|---|
| `filesystem_policy`, `landlock` | which paths are readable / writable | Landlock LSM | additions are stored but apply on next start; removals are rejected |
| `process` | the non-root UID/GID the agent runs as | driver + seccomp, no_new_privs, zero caps | rejected |
| `network_policies` | which binary may reach which host:port, and which HTTP methods/paths | supervisor proxy (L4 + L7) | yes, hot reload |
| providers (attached) | credentials and their allowed endpoints, e.g. a model API | gateway composes `_provider_*` rules | yes, attach/detach |

## Layout

```
docker/                 Docker-driver lab (gateway on 10.0.9.102)
  setup.sh              pin the gateway to Docker, build image, register qwen provider
  teardown.sh           delete lab sandboxes (--restore-podman to undo the driver switch)
  gateway/gateway.toml  gateway config installed to ~/.config/openshell/gateway.toml
  images/leap/          openSUSE Leap 16 workload image + probe scripts
  policies/             one policy per lab
  providers/            provider profile for the qwen vLLM server
  labs/                 the exercises, in order
k8s/                    Kubernetes lab (next)
podman/                 reserved
```

## Order

1. [docker/README.md](docker/README.md): set up, and see how the Docker driver builds the boundary
2. [Lab 01: Files](docker/labs/01-files.md)
3. [Lab 02: Network](docker/labs/02-network.md)
4. [Lab 03: Processes](docker/labs/03-process.md)
5. [Lab 04: Inference with qwen](docker/labs/04-inference-qwen.md)
6. Hermes agent in a sandbox (after the access labs)
7. Same labs on Kubernetes
