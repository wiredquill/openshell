# Lab 04: Processes

**Goal:** choose which user the agent runs as, and see what no policy can turn on.

Same loop: **try it** → **enable it** → **try it again**. This time "enable" means
creating the sandbox again.

Starting policy: [../policies/04-process.yaml](../policies/04-process.yaml). It has no
`process` section, so the agent runs as the image's user, `sandbox` (uid 1000).

## 0. Create the sandbox

```bash
cd /data/openshell-lab/labs/docker
openshell sandbox create --name lab-proc --from localhost/openshell-lab/leap:16.0 \
  --policy policies/04-process.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-proc --no-tty --"
$X id
# uid=1000(sandbox) gid=1000(sandbox) groups=1000(sandbox)
```

## 1. Read a file that belongs to uid 2000

### Try it

```bash
$X cat /lab/team/report.txt
# cat: /lab/team/report.txt: Permission denied
```

This time it isn't OpenShell. The policy lists `/lab/team` read-only, so Landlock allows
it. Ordinary Unix permissions refuse it: the directory and file belong to uid 2000, with
mode 0700 and 0600. Only uid 2000 can get in.

### Enable it

Add a `process` section to the end of `policies/04-process.yaml`:

```yaml
process:
  run_as_user: "2000"
  run_as_group: "2000"
```

Reload it into the running sandbox:

```bash
openshell policy set lab-proc --policy policies/04-process.yaml --wait
# Error: process policy cannot be changed on a live sandbox (applied at startup)
```

A running sandbox can't change its user. The change was rejected, so nothing was stored
and a restart won't pick it up. Recreate the sandbox:

```bash
openshell sandbox delete lab-proc
openshell sandbox create --name lab-proc --from localhost/openshell-lab/leap:16.0 \
  --policy policies/04-process.yaml --no-auto-providers --detach -- sleep infinity
```

### Try it again

```bash
$X id
# uid=2000 gid=2000 groups=2000
$X cat /lab/team/report.txt
# Q3 report: only uid 2000 can read this
$X bash -c 'echo x > /sandbox/f && ls -ln /sandbox/f'
# -rw-r--r-- 1 2000 2000 2 ... /sandbox/f      <- the workspace was made for the new user
```

The policy overrode the image's `USER`. Docker confirms it:

```bash
docker ps --format '{{.Names}}' | grep lab-proc | grep -v supervisor \
  | xargs docker inspect --format '{{.Config.User}}'
# 2000:2000
```

## 2. Root: try it, and it can't be enabled

### Try it

The image deliberately ships `sandbox ALL=(ALL) NOPASSWD: ALL` in sudoers, a classic
mistake:

```bash
openshell sandbox create --name lab-sudo --from localhost/openshell-lab/leap:16.0 \
  --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-sudo --no-tty -- sudo id
# sudo: The "no new privileges" flag is set, which prevents sudo from running as root.
```

### Enable it?

Ask for root in the policy:

```bash
sed 's/"2000"/"0"/g' policies/04-process.yaml > /tmp/root.yaml
openshell sandbox create --name lab-root --from localhost/openshell-lab/leap:16.0 \
  --policy /tmp/root.yaml --no-auto-providers --detach -- sleep infinity
# run_as_group must be 'sandbox' or a numeric UID/GID in range [1, 4294967294], got '0'
```

The gateway refuses. An image whose `USER` is root is rejected too, unless the policy sets
a non-root `run_as_user`. **Root is not something you can turn on.**

### What blocks it

`proc-probe` tries a dozen ways to escalate and shows each layer:

```bash
openshell sandbox exec -n lab-sudo --no-tty -- proc-probe
```

```
== identity
  id:            uid=1000(sandbox) gid=1000(sandbox)
  CapEff:        0000000000000000                         <- no capabilities at all
  CapBnd:        0000000000000000                         <- and none can ever be regained
  NoNewPrivs:    1                                        <- setuid binaries (sudo, su) don't elevate
  Seccomp:       2  (filter mode, 6 filters)
== process tree visible to the workload
  PID 1 openshell-sandb    <- OpenShell's runtime, not your command
      59 sleep
== escalation attempts
  sudo id                          BLOCKED
  su root                          BLOCKED
  unshare user namespace           BLOCKED
  unshare mount namespace          BLOCKED
  mount tmpfs                      BLOCKED
  chroot /                         BLOCKED
  ptrace (strace a child)          BLOCKED
  raw socket (ICMP ping)           BLOCKED   <- seccomp
  kill PID 1                       BLOCKED
  write /etc/passwd                BLOCKED   <- Landlock
  load kernel module info          ALLOWED   <- /proc/modules is readable: information only
  read /proc/1/environ             BLOCKED
```

| Layer | Set by | Effect |
|---|---|---|
| `--cap-drop ALL`, `no-new-privileges`, `--network none`, pids 2048 | Docker driver | container baseline |
| PID namespace | Docker | host and supervisor processes are invisible |
| non-root UID, empty capability bounding set | OpenShell runtime | `sudo` and `su` can't elevate, whatever sudoers says |
| seccomp filter | OpenShell runtime | blocks `unshare`, `mount`, `ptrace` and raw sockets, and hands `connect()` and DNS to the supervisor |
| Landlock | OpenShell runtime | file rules (Lab 03) |

The only process setting a policy controls is *which* non-root user to run as. Everything
in the table above is always on.

## 3. The supervisor, next door

Every sandbox has a second container, the supervisor. It enforces the policy and holds the
credentials, and the agent can't see it:

```bash
docker ps --format '{{.Names}}' | grep 'lab-proc.*supervisor' \
  | xargs docker inspect --format 'user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} net={{.HostConfig.NetworkMode}}'
# user=65534:65534 ro=true net=host
```

## Clean up

```bash
openshell sandbox delete lab-proc lab-sudo
```

Next: [Lab 05: Inference with qwen](05-inference-qwen.md).
