# Lab 05: Inference with qwen

**Goal:** give a sandbox access to the qwen model through a **provider**, and change what
the provider allows without touching any sandbox.

Same loop: **try it** → **enable it** → **try it again**.

Profile: [../providers/qwen-local.yaml](../providers/qwen-local.yaml)

## The pieces

In Labs 01 and 02 you wrote network rules into each sandbox's policy. A provider packages
the rules for one service so you can grant them in a single step:

| Object | What it is | Here |
|---|---|---|
| profile | a *type*: endpoints, allowed methods and paths, programs, credential schema | `qwen-local` |
| provider | an *instance* of a profile, holding credential values | `qwen` (this server needs no key) |
| attachment | provider ↔ sandbox | `--provider qwen` or `sandbox provider attach` |

`setup.sh` already imported the profile and created the provider:

```bash
openshell profile describe qwen-local
openshell provider list
```

> OpenShell 0.1.x removed the old `openshell inference set` / `inference.local` route.
> Agents call the model's own endpoint, and the attached provider supplies the network
> grant and, for hosted APIs, the credential.

## 0. Create the sandbox, without the provider

Use the Lab 03 file policy, which has no network rules at all:

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-qwen --from localhost/openshell-lab/leap:16.0 \
  --policy policies/03-files.yaml --no-auto-providers \
  --env OPENAI_BASE_URL=http://10.9.0.42:30400/v1 --env OPENAI_MODEL=qwen3.8-27b \
  --detach -- sleep infinity
X="openshell sandbox exec -n lab-qwen --no-tty --"
```

`ask-qwen` is a small Python client in the image. It sends one chat request to
`$OPENAI_BASE_URL`.

## 1. Talk to the model

### Try it

```bash
$X ask-qwen "say just ok"
# connection failed: [Errno 13] Permission denied
```

### Enable it

Attach the provider to the running sandbox:

```bash
openshell sandbox provider attach lab-qwen qwen --wait
# lab-qwen / qwen: ready
#   Installed: credentials=true, policy=true, future process environment=true
```

### Try it again

```bash
$X ask-qwen "say just ok"
# ok
```

Where did the access come from?

```bash
openshell policy get lab-qwen --base   # your file: still no network_policies
openshell policy get lab-qwen --full   # effective: network_policies._provider_qwen
```

The gateway merges the provider's rules into the effective policy as `_provider_qwen`.
Your policy file is untouched.

Detaching takes access away again, live:

```bash
openshell sandbox provider detach lab-qwen qwen --wait
$X ask-qwen hi
# connection failed: [Errno 13] Permission denied
openshell sandbox provider attach lab-qwen qwen --wait
```

Network access follows the attachment immediately. Environment variables don't: a
process that was already running before an attach doesn't get the provider's variables.
Start a new process to see them.

## 2. Allow another API path by updating the profile

The profile allows three API calls: `GET /v1/models`, `POST /v1/chat/completions` and
`POST /v1/completions`. vLLM also has a health check.

### Try it

```bash
$X curl -s http://10.9.0.42:30400/health
# {"error":"policy_denied","policy":"_provider_qwen","rule":"GET /health","detail":"GET /health not permitted by policy",...}
```

### Enable it

Export the stored profile, add a rule, and update it:

```bash
openshell profile export qwen-local -o yaml > /tmp/qwen-local.yaml
```

In `/tmp/qwen-local.yaml`, add a rule under `rules:`, after the `/v1/completions` one:

```yaml
      - allow:
          method: GET
          path: /health
```

```bash
openshell profile update qwen-local -f /tmp/qwen-local.yaml
# Updated provider profile.
```

The exported file includes `resource_version:`. The gateway rejects an update without it,
which stops two people from overwriting each other's changes.

### Try it again

```bash
$X curl -s -o /dev/null -w "%{http_code}\n" http://10.9.0.42:30400/health
# 200
```

You changed the **profile**, not the sandbox, and every sandbox with `qwen` attached picks
the change up on their own, with no restart. It isn't instant: in testing it took about
10 seconds, so if you still get a 403, wait and retry.

To keep the change, add the same rule to
[../providers/qwen-local.yaml](../providers/qwen-local.yaml) and run `./setup.sh`, which
updates the profile from the repo file. Running `setup.sh` without that edit puts the
profile back to the repo version and removes `/health` again.

## 3. What the profile still enforces

```bash
$X curl -s http://10.9.0.42:30400/v1/embeddings -d '{}'
# {"error":"policy_denied", "layer":"l7", ...}            <- not one of the profile's rules
$X bash -c 'cp /usr/bin/curl /tmp/c && /tmp/c -sS http://10.9.0.42:30400/v1/models'
# curl: (7) Failed to connect to 10.9.0.42 port 30400 ...  <- /tmp/c is not one of the profile's programs
```

## 4. When the endpoint needs a key

This vLLM server is unauthenticated, so the profile has `credentials: []`. For an
OpenAI-compatible server that needs a key, declare a credential:

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

Then create the provider with
`OPENAI_API_KEY=... openshell provider create --name qwen --type qwen-local --from-existing`.

Inside the sandbox, `OPENAI_API_KEY` holds only a placeholder,
`openshell:resolve:env:...`. The supervisor swaps in the real key, and only on requests to
the profile's endpoint. The agent never holds the secret, and sending the placeholder to
any other host fails with `credential_endpoint_mismatch`.

## Clean up

```bash
openshell sandbox delete lab-qwen
```

Next: [Lab 06: Hermes Agent](06-hermes.md).
