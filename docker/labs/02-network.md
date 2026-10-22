# Lab 02: Network

**Goal:** understand default-deny egress, binary-scoped rules, L7 method/path
enforcement, and hot reload.

Policy: [../policies/02-network.yaml](../policies/02-network.yaml)

## 1. Default deny, and how the workload is wired

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-default --from localhost/openshell-lab/leap:16.0 \
  --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-default --no-tty -- net-probe
```

```
https://api.github.com/zen            curl rc=7: Failed to connect ... Could not connect to server
https://download.opensuse.org/        curl rc=7: ...
http://10.9.0.42:30400/v1/models      curl rc=7: ...
http://169.254.169.254/latest/...     curl rc=7: ...
DNS download.opensuse.org -> 198.18.0.3
Raw TCP (nc 1.1.1.1:53): blocked
Interfaces: lo
```

Three things to notice:

* **Interfaces: lo.** The workload container runs with `--network none`. It has no route
  out at all.
* **DNS "works", but returns 198.18.0.x.** That range (RFC 2544, benchmarking) is used for
  synthetic answers. Seccomp intercepts the lookup, and the supervisor's *policy DNS* hands
  back a placeholder so the name can be tied to the later `connect()`.
* **connect() is refused immediately**, before any packet leaves.

Check the audit trail on the host:

```bash
openshell logs lab-default --since 5m --source sandbox | grep DENIED
# NET:REFUSE [MED] DENIED api.github.com [reason:policy_dns_ineligible]
# NET:OPEN  [MED] DENIED /usr/bin/curl(0) -> api.github.com:443 [reason:transparent_tcp_policy_denied]
# NET:OPEN  [MED] DENIED /usr/bin/nc(0) -> 1.1.1.1:53 [reason:transparent_tcp_policy_denied]
```

Every denial names the **binary** that tried. That's the key to the rule model.

## 2. Apply the network policy

A rule is *(binaries) × (endpoints)*. Any listed binary, or any process whose parent chain
includes one, may reach any listed endpoint.

```bash
openshell sandbox create --name lab-net --from localhost/openshell-lab/leap:16.0 \
  --policy policies/02-network.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-net --no-tty --"
$X net-probe
```

```
https://api.github.com/zen            HTTP 200
https://download.opensuse.org/        HTTP 200
http://10.9.0.42:30400/v1/models      HTTP 200
http://169.254.169.254/latest/...     curl rc=7   <- metadata is never allowed, by any rule
```

## 3. Binary scoping

`github_readonly` lists only `/usr/bin/curl`. Same host, different program:

```bash
$X python3 -c 'import urllib.request; urllib.request.urlopen("https://api.github.com/zen")'
# urllib.error.URLError: <urlopen error [Errno 13] Permission denied>
```

```
NET:OPEN [MED] DENIED /usr/bin/python3.13(0) -> api.github.com:443
```

OpenShell identifies the caller from the kernel's view (`/proc/<pid>/exe`), so you must list
**real paths, not symlinks**. `/usr/bin/python3` → `/usr/bin/python3.13` on Leap 16. The
binary is also hashed on first use, and if the file later changes, connections are denied.
Copying curl to `/tmp/curl` doesn't help either: `/tmp/curl` isn't a listed path.

```bash
$X readlink -f /usr/bin/python3     # /usr/bin/python3.13
```

## 4. L7: methods and paths

`protocol: rest` makes the supervisor terminate TLS and inspect each HTTP request. For
HTTPS it re-signs with an ephemeral per-sandbox CA, and the runtime points every common
trust variable at it:

```bash
$X env | grep -E 'CA|CERT'
# SSL_CERT_FILE=/run/openshell-supervisor-ca/material/ca-bundle.crt
# CURL_CA_BUNDLE=...  REQUESTS_CA_BUNDLE=...  NODE_EXTRA_CA_CERTS=...  GIT_SSL_CAINFO=...
```

A client that pins certificates, or ignores these variables, needs `tls: skip`, and then
there's no L7 inspection. `access: read-only` allows `GET/HEAD/OPTIONS`:

```bash
$X curl -s -X POST https://api.github.com/repos/octocat/hello-world/issues -d '{}'
# {"error":"policy_denied","policy":"github_readonly","rule":"POST /repos/octocat/hello-world/issues",
#  "layer":"l7","binary":"/usr/bin/curl",...}
```

`qwen_local` uses explicit `rules` instead of a preset. Only `GET /v1/models` and
`POST /v1/chat/completions` are allowed:

```bash
$X curl -s http://10.9.0.42:30400/v1/models                    # 200
$X curl -s http://10.9.0.42:30400/v1/embeddings -d '{}'        # policy_denied, layer l7
$X ask-qwen "Explain seccomp in one sentence"                   # python3.13, POST chat: allowed
```

Switch any endpoint to `enforcement: audit` to log violations without blocking them. That's
the usual way to build a policy for a new agent.

## 5. Private addresses (SSRF protection)

Destinations on private networks are blocked by default. An endpoint with an **exact**
hostname or literal IP may reach the private address it names. Wildcard and hostless
endpoints need `allowed_ips`. The qwen rule pins `allowed_ips: [10.9.0.42/32]` anyway, as
defense in depth: if a hostname were later used and DNS changed, the connection would fail
instead of following it. (Tested: removing `allowed_ips` from this literal-IP rule still
works.) Loopback, link-local and `169.254.169.254` can never be allowed, and neither can the
Kubernetes and etcd control-plane ports (2379, 2380, 6443, 10250, 10255).

## 6. Hot reload

Network rules are live. Grant python access to PyPI without restarting:

```bash
openshell policy update lab-net --rule-name pypi_python --binary /usr/bin/python3.13 \
  --add-endpoint pypi.org:443:read-only:rest:enforce --wait
$X python3 -c 'import urllib.request; print(urllib.request.urlopen("https://pypi.org/simple/requests/").status)'
# 200
openshell policy list lab-net                   # new revision
openshell policy set lab-net --policy policies/02-network.yaml --wait   # back to the file
```

Running processes see the change on their next connection. Nothing restarts.

## 7. Let OpenShell draft rules (optional)

Every denial feeds the **policy advisor**, which groups denials by host, port and binary and
drafts a narrow rule. The gateway's **prover** flags risky grants before you see them:

```bash
openshell rule get lab-net --status pending
openshell rule approve lab-net --chunk-id <id>    # or: rule reject ... --reason "..."
```

## Clean up

```bash
openshell sandbox delete lab-default lab-net
```
