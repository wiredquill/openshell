# Lab 04: Inference with qwen via a provider

**Goal:** give a sandbox access to the qwen model the supported 0.1.x way, through a
**provider profile** and an attachment, instead of hand-writing network rules into every
policy.

Profile: [../providers/qwen-local.yaml](../providers/qwen-local.yaml)

> OpenShell 0.1.x removed the old `openshell inference set` / `inference.local` managed
> route. Agents now call the model's **native** endpoint, and the attached provider
> supplies the network grant and, for hosted APIs, the credential.

## 1. The pieces

| Object | What it is | Here |
|---|---|---|
| profile | a *type*: endpoints, rules, binaries, credential schema | `qwen-local` |
| provider | an *instance* of a profile, holding credential values | `qwen` (no credentials) |
| attachment | provider ↔ sandbox | `--provider qwen` or `sandbox provider attach` |

`setup.sh` already did:

```bash
openshell profile lint   -f providers/qwen-local.yaml
openshell profile import -f providers/qwen-local.yaml
openshell provider create --name qwen --type qwen-local
openshell profile describe qwen-local
```

## 2. A sandbox with no network rules of its own, plus the provider

Reuse the **files** policy, which has no `network_policies`:

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-qwen --from localhost/openshell-lab/leap:16.0 \
  --policy policies/01-files.yaml --provider qwen \
  --env OPENAI_BASE_URL=http://10.9.0.42:30400/v1 --env OPENAI_MODEL=qwen3.8-27b \
  --detach -- sleep infinity
openshell sandbox exec -n lab-qwen --no-tty -- ask-qwen "In one sentence, what is Landlock?"
# Landlock is a Linux kernel security feature that allows unprivileged applications ...
```

See where the access came from:

```bash
openshell policy get lab-qwen --base   # your file: no network_policies
openshell policy get lab-qwen --full   # effective: network_policies._provider_qwen
```

The gateway composes the provider's rules into the effective policy on demand. Because the
effective policy now has a network rule, the baseline paths from Lab 01 §5 are added.
They're saved as a new revision of *your* policy:

```bash
openshell policy list lab-qwen                       # revision 2 appeared without you doing anything
openshell policy get lab-qwen --base | grep var/log  # - /var/log   (/app skipped: not in image)
```

## 3. Revoke and restore without restarting

```bash
openshell sandbox provider detach lab-qwen qwen --wait
openshell sandbox exec -n lab-qwen --no-tty -- ask-qwen hi
# connection failed: [Errno 13] Permission denied
openshell sandbox provider attach lab-qwen qwen --wait
openshell sandbox exec -n lab-qwen --no-tty -- ask-qwen "say ok"
# ok
```

Network grants follow attachment live. *Environment variables* don't: a process started
before an attach doesn't get the new provider's env vars. Start a new process.

## 4. What the profile still enforces

The profile's rules are the API surface. Only models, chat and completions are allowed:

```bash
X="openshell sandbox exec -n lab-qwen --no-tty --"
$X curl -s http://10.9.0.42:30400/v1/models | jq -r '.data[].id'   # qwen3.8-27b
$X curl -s http://10.9.0.42:30400/v1/embeddings -d '{}'           # policy_denied (l7)
$X bash -c 'cp /usr/bin/curl /tmp/c && /tmp/c -s http://10.9.0.42:30400/v1/models'
# denied: /tmp/c is not a profile binary
```

## 5. When the endpoint needs a key

This vLLM server is unauthenticated, so `credentials: []`. For an authenticated
OpenAI-compatible server, declare a credential in the profile:

```yaml
credentials:
  - name: api_key
    env_vars: [OPENAI_API_KEY]
    required: true
    auth_style: bearer
    header_name: authorization
discovery:
  credentials: [api_key]
```

Create the provider with `OPENAI_API_KEY=... openshell provider create --name qwen
--type qwen-local --from-existing`. The sandbox then sees
`OPENAI_API_KEY=openshell:resolve:env:...`, an opaque placeholder. The supervisor swaps in
the real key only on requests to the profile's endpoint, so the agent never holds the
secret, and a request carrying it to any other host fails with `credential_endpoint_mismatch`.

## Clean up

```bash
openshell sandbox delete lab-qwen
```
