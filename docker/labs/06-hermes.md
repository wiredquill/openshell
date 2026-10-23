# Lab 06: Hermes Agent

**Goal:** run a real agent, Nous Research's [Hermes Agent](https://github.com/NousResearch/hermes-agent),
inside OpenShell with qwen as its model. Then watch the sandbox decide what the agent's
own tools may do.

Same loop: **try it** → **enable it** → **try it again**. Everything from Labs 01 to 05
comes together here.

Image: [../images/hermes/Dockerfile](../images/hermes/Dockerfile).
Starting policy: [../policies/06-hermes.yaml](../policies/06-hermes.yaml), with no network
rules and no `/lab` access.

## 0. Build the Hermes image

```bash
cd /data/openshell-lab/docker
docker build -t localhost/openshell-lab/hermes:16.0 images/hermes     # about 4 minutes, 4.7 GB
```

The image is the lab image plus Hermes v0.22.2, installed with Hermes's own installer.
It's already configured for qwen:

| Setting | Value | Why |
|---|---|---|
| `HERMES_HOME` | `/opt/hermes` | Hermes's code, its own Python, and its state all live here |
| `model.provider` / `base_url` / `default` | `custom`, `http://10.9.0.42:30400/v1`, `qwen3.8-27b` | an OpenAI-compatible endpoint |
| `agent.api_max_retries` 1, `agent.auto_recovery_cycles` 0 | | fail in seconds, not minutes, when the sandbox blocks the model |

Two things had to be solved to make Hermes work in a sandbox. Both are general lessons:

* **OpenShell doesn't pass the image's `ENV` to sandbox processes.** It starts them with
  its own environment, including `HOME=/sandbox`. A Dockerfile `ENV HERMES_HOME=...` is
  ignored, so `/usr/local/bin/hermes` is a small wrapper script that sets it.
* **The sandbox has no route to PyPI.** If Hermes's data root differs from its install
  root, Hermes downloads its Python dependencies on first run. That fails inside the
  sandbox, so the install root is also the data root.

```bash
openshell sandbox create --name lab-hermes --from localhost/openshell-lab/hermes:16.0 \
  --policy policies/06-hermes.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-hermes --no-tty --"
H="$X hermes chat -Q --max-turns 6 -q"       # one question, quiet output, then exit
```

## 1. Give Hermes its model

### Try it

```bash
$H "Reply with just the word ok"
# custom didn't respond in time on any of 1 attempts ...
# Provider said: Connection error.
```

```bash
openshell logs lab-hermes --since 5m --source sandbox | grep DENIED
# DENIED /opt/hermes/tools/python-3.14.7+20260901-linux-x64/bin/python3.14(0) -> 10.9.0.42:30400
# DENIED /opt/hermes/tools/python-3.14.7+20260901-linux-x64/bin/python3.14(0) -> api.github.com:443
```

Note the program name. Hermes doesn't run on the system's `/usr/bin/python3.13`: it
brings its own Python 3.14. The api.github.com line is Hermes checking for updates. It
can stay denied.

### Enable it

Attach the qwen provider, as in Lab 05:

```bash
openshell sandbox provider attach lab-hermes qwen --wait
```

### Try it again

```bash
$H "Reply with just the word ok"
# Provider said: Connection error.         <- still failing!
```

```bash
openshell logs lab-hermes --since 2m --source sandbox | grep 'not allowed'
# ... reason=binary '/opt/hermes/tools/python-3.14.7+20260901-linux-x64/bin/python3.14'
#     not allowed in policy '_provider_qwen' ...
```

The provider supplied the endpoint, but its profile only lists `/usr/bin/curl` and
`/usr/bin/python3.13`. A provider grants **programs** access to an endpoint, and Hermes's
program isn't on the list.

### Enable it, part two: add Hermes to the profile

Export the profile and add a line under `binaries:`. Use a glob, because the versioned
directory name changes whenever Hermes updates its Python:

```bash
openshell profile export qwen-local -o yaml > /tmp/qwen-local.yaml
sed -i 's#^  - /usr/bin/python3.13$#&\n  - /opt/hermes/tools/python-*/bin/python3.14#' /tmp/qwen-local.yaml
grep -A3 '^binaries' /tmp/qwen-local.yaml
# binaries:
#   - /usr/bin/curl
#   - /usr/bin/python3.13
#   - /opt/hermes/tools/python-*/bin/python3.14
openshell profile update qwen-local -f /tmp/qwen-local.yaml
```

### Try it again

Give it a few seconds to reach the sandbox, then:

```bash
$H "Reply with just the word ok"
# ok
```

To keep the change, add the same line to the `binaries:` list in
[../providers/qwen-local.yaml](../providers/qwen-local.yaml) and run `./setup.sh`.

## 2. The agent's tools: network

Hermes can run shell commands with its terminal tool. Those commands are inside the
sandbox too.

### Try it

```bash
$H "Use your terminal tool to run exactly: curl -sS -o /dev/null -w %{http_code} https://www.suse.com/ ; then tell me the exact output in one line."
# stdout: 000
# (curl also printed: curl: (7) Failed to connect to www.suse.com port 443 ...: Could not connect to server)
```

```bash
openshell logs lab-hermes --since 2m --source sandbox | grep 'DENIED /usr/bin/curl'
# DENIED /usr/bin/curl(0) -> www.suse.com:443 [reason:transparent_tcp_policy_denied]
```

### Enable it

This is exactly the Lab 01 command:

```bash
openshell policy update lab-hermes --rule-name suse_web --binary /usr/bin/curl \
  --add-endpoint www.suse.com:443:read-only:rest:enforce --wait
```

### Try it again

```bash
$H "Use your terminal tool to run exactly: curl -sS -o /dev/null -w %{http_code} https://www.suse.com/ ; then tell me the exact output in one line."
# 200
```

The agent didn't restart, and it didn't have to know a rule changed.

A rule's binary matches the program that connects **or any of its parent processes**.
Hermes's Python is in the qwen profile, so any program Hermes starts may reach qwen too.
For the suse rule, which lists only curl, that doesn't apply: Hermes's own Python still
can't reach suse.com.

## 3. The agent's tools: files

### Try it

```bash
$H "Use your terminal tool to run exactly: echo hello-from-hermes > /lab/scratch/hermes.txt && cat /lab/scratch/hermes.txt ; then tell me the exact output in one line."
# /usr/bin/bash: line 5: /lab/scratch/hermes.txt: Permission denied (exit code 1)
# The write failed because /lab/scratch is owned by root ...      <- or: "...has mode 0755, so
#                                                                    no one can create files"
```

**The agent's explanation is wrong**, and it changes from run to run. Check it yourself:

```bash
$X ls -ld /lab/scratch
# drwxr-xr-x 1 sandbox sandbox 0 ... /lab/scratch      <- owned by the agent's own user
```

Landlock gives the same `Permission denied` as Unix permissions (Lab 03), so the agent
can't tell the sandbox apart from ordinary permissions, and it guesses. Don't trust an
agent's diagnosis of its own sandbox. Check the policy.

### Enable it

Add `/lab/scratch` to `read_write` in `policies/06-hermes.yaml`:

```yaml
  read_write: [/tmp, /dev/null, /opt/hermes, /lab/scratch]
```

File rules need a restart (Lab 03):

```bash
openshell policy set lab-hermes --policy policies/06-hermes.yaml --wait
openshell sandbox stop lab-hermes && openshell sandbox start lab-hermes
```

### Try it again

```bash
$H "Use your terminal tool to run exactly: echo hello-from-hermes > /lab/scratch/hermes.txt && cat /lab/scratch/hermes.txt ; then tell me the exact output in one line."
# Output: hello-from-hermes (exit code 0 ...)
$X hermes sessions list          # sessions from before the restart are still there
```

## 4. Use it interactively

```bash
openshell sandbox exec -n lab-hermes --tty -- hermes
```

This is the full Hermes interface, with every model call, tool command and file access
running under the policy. In a second terminal, follow what it's doing:

```bash
openshell logs lab-hermes --source sandbox --tail | grep -E 'ALLOWED|DENIED'
```

When Hermes hits something the policy doesn't allow, OpenShell drafts a narrow rule for
it. Review the drafts with `openshell rule get lab-hermes --status pending`, and approve
one with `openshell rule approve lab-hermes --chunk-id <id>`.

## Clean up

```bash
openshell sandbox delete lab-hermes
```

If you added the Hermes line only to the stored profile and not to the repo file,
`./setup.sh` puts the profile back to the repo version.
