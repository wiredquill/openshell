# Lab 01: Network

**Goal:** see OpenShell block an outbound connection, allow it two ways (from the command
line, and by editing the policy file), and learn how the two ways interact.

Every lab uses the same loop:

1. **Try it**: the command fails.
2. **Enable it**: change the policy.
3. **Try it again**: now it works.

Starting policy: [../policies/01-network.yaml](../policies/01-network.yaml). Curl may reach
`download.opensuse.org`, and nothing else.

## 0. Create the sandbox

```bash
cd /data/openshell-lab/labs/docker
openshell sandbox create --name lab-net --from localhost/openshell-lab/leap:16.0 \
  --policy policies/01-network.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-net --no-tty --"     # shorthand: run a command in lab-net
```

The one thing the policy allows works:

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://download.opensuse.org/
# 200
```

## 1. Allow www.suse.com from the command line

### Try it

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://www.suse.com/
# curl: (7) Failed to connect to www.suse.com port 443 after 0 ms: Could not connect to server
```

Ask OpenShell why:

```bash
openshell logs lab-net --since 5m --source sandbox | grep DENIED
# NET:REFUSE [MED] DENIED www.suse.com [reason:policy_dns_ineligible]
# NET:OPEN   [MED] DENIED /usr/bin/curl(0) -> www.suse.com:443 [reason:transparent_tcp_policy_denied]
```

The log names the **program** (`/usr/bin/curl`) and the **destination**
(`www.suse.com:443`). A rule needs exactly those two things.

### Enable it

```bash
openshell policy update lab-net --rule-name suse_web --binary /usr/bin/curl \
  --add-endpoint www.suse.com:443:read-only:rest:enforce --wait
# ✓ Policy version 3 submitted
# ✓ Policy version 3 loaded (active version: 3)
```

`--add-endpoint` is `host:port:access:protocol:enforcement`:

| field | value | meaning |
|---|---|---|
| access | `read-only` | GET, HEAD and OPTIONS only (also `read-write`, `full`) |
| protocol | `rest` | inspect each HTTP request, not just the connection |
| enforcement | `enforce` | block violations (`audit` only logs them) |

### Try it again

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://www.suse.com/
# 200
```

No restart was needed: network rules are **live**. See what changed:

```bash
openshell policy list lab-net              # one row per revision; the newest is "Loaded"
openshell policy get lab-net --base        # suse_web is now in the policy
```

Version 2 appeared on its own when the sandbox started, and you didn't create it. OpenShell
added `/var/log` to the file rules, because any policy with network rules gets a few
baseline paths. Lab 03 covers that.

### What read-only means

```bash
$X curl -sS -X POST -d x=1 https://www.suse.com/
# {"error":"policy_denied","policy":"suse_web","rule":"POST /","detail":"POST / not permitted by policy",
#  "layer":"l7","method":"POST","host":"www.suse.com","binary":"/usr/bin/curl",...}
```

The connection is allowed, but OpenShell read the HTTP request and refused the POST
itself. The request never reached suse.com.

## 2. Allow www.opensuse.org by editing the policy file

### Try it

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://www.opensuse.org/
# curl: (7) Failed to connect to www.opensuse.org port 443 ... Could not connect to server
```

### Enable it

Add this block to the end of `policies/01-network.yaml`, under `network_policies:`. It
uses the same indentation as `opensuse_mirror`:

```yaml
  opensuse_web:
    endpoints:
      - host: www.opensuse.org
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: /usr/bin/curl
```

Then reload the file into the running sandbox:

```bash
openshell policy set lab-net --policy policies/01-network.yaml --wait
# ✓ Policy version 4 loaded (active version: 4)
```

### Try it again

```bash
$X curl -sS -o /dev/null -w "%{http_code}\n" https://www.opensuse.org/
# 200
$X curl -sS -o /dev/null -w "%{http_code}\n" https://www.suse.com/
# curl: (7) Failed to connect ...        <- suse.com is blocked again!
```

**Lesson:** `policy set` **replaces** the whole policy with the file. The `suse_web` rule
from step 1 existed only on the gateway, not in your file, so it's gone. `policy update` is
a quick patch to the live policy. The file is the source of truth.

## 3. Keep command-line changes: save the live policy to a file

Add `suse_web` back, then save the live policy:

```bash
openshell policy update lab-net --rule-name suse_web --binary /usr/bin/curl \
  --add-endpoint www.suse.com:443:read-only:rest:enforce --wait
openshell policy get lab-net --base | sed '1,/^---$/d' > policies/my-network.yaml
```

`policy get` prints a short header, then `---`, then the YAML. The `sed` removes the
header. Prove the file holds everything:

```bash
openshell policy set lab-net --policy policies/my-network.yaml --wait
# · Policy unchanged (version 5, ...)      <- the file matches the live policy exactly
```

A common workflow is to experiment with `policy update`, then save the result with
`policy get --base` and commit the file.

## 4. Allow a second program (binary scoping)

The rules name `curl`. Python going to the same host is a different program:

### Try it

```bash
$X python3 -c 'import urllib.request as u; print(u.urlopen("https://www.suse.com/").status)'
# urllib.error.URLError: <urlopen error [Errno 13] Permission denied>
```

```bash
openshell logs lab-net --since 2m --source sandbox | grep python
# ... binary '/usr/bin/python3.13' not allowed in policy 'suse_web' ... SYMLINK HINT ...
```

The program is `/usr/bin/python3.13`, not `/usr/bin/python3`. OpenShell identifies the
caller by its real file (`/proc/<pid>/exe`), so a rule must list the real path, not a
symlink:

```bash
$X readlink -f /usr/bin/python3
# /usr/bin/python3.13
```

### Enable it

`--binary` on an existing rule name **adds** a program to that rule:

```bash
openshell policy update lab-net --rule-name suse_web --binary /usr/bin/python3.13 \
  --add-endpoint www.suse.com:443:read-only:rest:enforce --wait
openshell policy get lab-net --base | grep -A12 'suse_web:'
#     binaries:
#       - path: /usr/bin/curl
#       - path: /usr/bin/python3.13
```

### Try it again

```bash
$X python3 -c 'import urllib.request as u; print(u.urlopen("https://www.suse.com/").status)'
# urllib.error.HTTPError: HTTP Error 403: Forbidden      <- a different error!
```

It's still a 403, but this time OpenShell let it through, and it was **suse.com's CDN**
that refused Python's default User-Agent (`error code: 1010`). Send a browser-like one:

```bash
$X python3 -c 'import urllib.request as u; print(u.urlopen(u.Request("https://www.suse.com/", headers={"User-Agent": "Mozilla/5.0"})).status)'
# 200
```

### Who said no?

| What you see | Who refused |
|---|---|
| curl `(7) Could not connect`, Python `[Errno 13] Permission denied` | OpenShell: no rule for this program and host |
| JSON body `{"error":"policy_denied", "layer":"l7", ...}` | OpenShell: the host is allowed, but this method or path isn't |
| any other HTTP error | the remote server; OpenShell allowed it |

`openshell logs ... | grep -E 'DENIED|ALLOWED'` always settles it.

## 5. Your turn: a private address

Allow curl to reach a host on your LAN, for example a router at `10.0.0.1`. Private
addresses are blocked by default (SSRF protection), so pin the exact IP with `allowed_ips`.
Add this to `policies/my-network.yaml`, then reload it with `policy set`:

```yaml
  lan_gateway:
    endpoints:
      - host: 10.0.0.1
        port: 80
        allowed_ips: [10.0.0.1/32]
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: /usr/bin/curl
```

Loopback, link-local and the cloud metadata address `169.254.169.254` can never be allowed.

## Clean up

```bash
openshell sandbox delete lab-net
```

Next: [Lab 02: Add wget](02-wget.md).
