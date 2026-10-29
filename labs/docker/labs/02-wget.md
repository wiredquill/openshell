# Lab 02: Add wget

**Goal:** add a new tool to a sandbox, and see that installing a program doesn't give it
network access. The policy has to name it.

Same loop as Lab 01: **try it** → **enable it** → **try it again**. This lab has two
blockers, so you go round the loop twice.

Starting policy: [../policies/01-network.yaml](../policies/01-network.yaml), unchanged from
the repo. Curl may reach `download.opensuse.org`.

## 0. Create the sandbox

```bash
cd /data/openshell-lab/labs/docker
openshell sandbox create --name lab-wget --from localhost/openshell-lab/leap:16.0 \
  --policy policies/01-network.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-wget --no-tty --"
```

## 1. Blocker one: wget isn't installed

### Try it

```bash
$X wget --tries=1 -O /dev/null https://download.opensuse.org/
# /bin/bash: line 1: wget: command not found
```

You can't fix this from inside: the agent isn't root, `sudo` is blocked (Lab 04), and
`zypper` has no network. Software comes from the **image**.

### Enable it

[../images/leap-wget/Dockerfile](../images/leap-wget/Dockerfile) builds on the lab image and
adds one package:

```dockerfile
FROM localhost/openshell-lab/leap:16.0
USER root
RUN zypper --non-interactive install --no-recommends wget && zypper clean --all
USER sandbox
```

Build it, then recreate the sandbox from it. A sandbox's image is fixed when it's created:

```bash
docker build -t localhost/openshell-lab/leap:16.0-wget images/leap-wget
openshell sandbox delete lab-wget
openshell sandbox create --name lab-wget --from localhost/openshell-lab/leap:16.0-wget \
  --policy policies/01-network.yaml --no-auto-providers --detach -- sleep infinity
```

### Try it again

```bash
$X readlink -f /usr/bin/wget
# /usr/bin/wget         <- installed, and it's a real file, not a symlink
```

## 2. Blocker two: the policy doesn't name wget

### Try it

curl and wget, to the same allowed host:

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://download.opensuse.org/
# 200
$X wget --tries=1 -O /dev/null https://download.opensuse.org/
# Connecting to download.opensuse.org (download.opensuse.org)|198.18.0.2|:443... failed: Permission denied.
# Giving up.
```

```bash
openshell logs lab-wget --since 2m --source sandbox | grep 'DENIED /usr/bin/wget'
# NET:OPEN [MED] DENIED /usr/bin/wget(0) -> download.opensuse.org:443 [reason:transparent_tcp_policy_denied]
```

Always pass `--tries=1` here. By default wget retries a refused connection 20 times, with
growing waits, so it looks hung.

`198.18.0.2` is not the mirror's real address. The workload has no network of its own, so
OpenShell answers DNS with a placeholder from `198.18.0.0/15` and maps it back to the name
when the program connects.

### Enable it

Add wget to the existing `opensuse_mirror` rule, live:

```bash
openshell policy update lab-wget --rule-name opensuse_mirror --binary /usr/bin/wget \
  --add-endpoint download.opensuse.org:443:read-only:rest:enforce --wait
```

### Try it again

```bash
$X wget --tries=1 -O /dev/null https://download.opensuse.org/
# HTTP request sent, awaiting response... 200 OK
```

HTTPS worked even though OpenShell decrypts and re-encrypts the traffic to inspect it. The
sandbox sets `SSL_CERT_FILE` to a bundle with OpenShell's per-sandbox CA, and wget trusts
it:

```bash
$X env | grep ^SSL_CERT_FILE
# SSL_CERT_FILE=/run/openshell-supervisor-ca/material/ca-bundle.crt
```

The rule's limits still apply to wget:

```bash
$X wget --tries=1 -O /dev/null --post-data=x=1 https://download.opensuse.org/
# ERROR 403: Forbidden.                      <- read-only: OpenShell refuses the POST
$X wget --tries=1 -O /dev/null https://www.opensuse.org/
# ... failed: Permission denied.             <- not in this rule, and not in the file
```

## 3. Make it permanent

The `policy update` lives only on the gateway. To keep it, add wget to
`opensuse_mirror` in `policies/01-network.yaml`:

```yaml
    binaries:
      - path: /usr/bin/curl
      - path: /usr/bin/wget
```

```bash
openshell policy set lab-wget --policy policies/01-network.yaml --wait
# ✓ Policy version 4 loaded (active version: 4)
$X wget --tries=1 -O /dev/null https://download.opensuse.org/
# HTTP request sent, awaiting response... 200 OK      <- still works, now from the file
```

The file loads as a new version even though it allows exactly what the live policy did.
The YAML isn't byte-for-byte the same: the live copy has `name:` fields and the `/var/log`
baseline path (Lab 03). Lab 01 §3's `policy get --base` export avoids that, which is why it
reported "unchanged".

## Clean up

```bash
openshell sandbox delete lab-wget
```

Next: [Lab 03: Files](03-files.md).
