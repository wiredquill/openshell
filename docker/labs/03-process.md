# Lab 03: Processes

**Goal:** see the process identity and kernel restrictions every workload gets, and how
little of that policy can change.

Policy: [../policies/03-process.yaml](../policies/03-process.yaml)

## 1. What every sandbox gets, policy or not

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-default --from localhost/openshell-lab/leap:16.0 \
  --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-default --no-tty -- proc-probe
```

```
== identity
  id:            uid=1000(sandbox) gid=1000(sandbox)     <- image USER
  CapEff:        0000000000000000                         <- no capabilities at all
  CapBnd:        0000000000000000                         <- and none can ever be regained
  NoNewPrivs:    1                                        <- setuid binaries don't elevate
  Seccomp:       2  (filter mode, 6 filters)
== process tree visible to the workload
  PID 1 openshell-sandb    <- the in-sandbox runtime, not your command
      59 sleep
== escalation attempts
  sudo id                          BLOCKED   <- even with NOPASSWD in sudoers
  su root                          BLOCKED
  unshare user namespace           BLOCKED
  unshare mount namespace          BLOCKED
  mount tmpfs                      BLOCKED
  chroot /                         BLOCKED
  ptrace (strace a child)          BLOCKED
  raw socket (ICMP ping)           BLOCKED   <- "Protocol not supported": seccomp
  kill PID 1                       BLOCKED
  write /etc/passwd                BLOCKED   <- Landlock (/etc is read-only)
  load kernel module info          ALLOWED   <- /proc/modules is readable: info only
  read /proc/1/environ             BLOCKED
```

The layers, from outside in:

| Layer | Who sets it | Effect |
|---|---|---|
| Docker `--cap-drop ALL`, `no-new-privileges`, `--network none`, pids 2048 | Docker driver | container baseline |
| PID namespace | Docker | sees only its own tree; host and supervisor processes are invisible |
| non-root UID, bounding set emptied | runtime | `sudo`/`su` can't elevate, even when sudoers says yes |
| seccomp filter | runtime | blocks `unshare`, `mount`, `ptrace`, raw sockets, and intercepts `connect()` and DNS for the supervisor |
| Landlock | runtime | file access (Lab 01) |

**Lesson:** the image ships `sandbox ALL=(ALL) NOPASSWD: ALL`, a classic mistake, and it
doesn't matter. With `no_new_privs` set, the kernel ignores the setuid bit on `sudo`, and
with an empty bounding set there are no capabilities to gain anyway.

## 2. Pick the identity in policy

```bash
openshell sandbox create --name lab-proc --from localhost/openshell-lab/leap:16.0 \
  --policy policies/03-process.yaml --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-proc --no-tty -- id
# uid=2000 gid=2000 groups=2000
docker ps --format '{{.Names}}' | grep lab-proc | grep -v supervisor | xargs docker inspect --format '{{.Config.User}}'
# 2000:2000
```

The policy overrides the image's `USER`. UID 2000 has no passwd entry, which is fine. On
Docker, `/sandbox` is created for the chosen identity. Note that `/home/sandbox` now belongs
to someone else, which is one more reason to keep agent state in the workspace.

## 3. Root is not an option

```bash
sed 's/"2000"/"0"/g' policies/03-process.yaml > /tmp/root.yaml
openshell sandbox create --name lab-root --from localhost/openshell-lab/leap:16.0 \
  --policy /tmp/root.yaml --no-auto-providers --detach -- sleep infinity
# run_as_group must be 'sandbox' or a numeric UID/GID in range [1, 4294967294], got '0'
```

An image whose `USER` is root is also rejected, unless policy sets a non-root
`run_as_user`.

## 4. Identity is fixed for the sandbox's life

```bash
sed 's/"2000"/"3000"/g' policies/03-process.yaml > /tmp/p3000.yaml
openshell policy set lab-proc --policy /tmp/p3000.yaml --wait
# process policy cannot be changed on a live sandbox (applied at startup)
```

## 5. What the supervisor sees that the agent can't

```bash
docker ps --format '{{.Names}}' | grep 'lab-proc.*supervisor' \
  | xargs docker inspect --format 'user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} net={{.HostConfig.NetworkMode}}'
# user=65534:65534 ro=true net=host
```

The supervisor image (`ghcr.io/nvidia/openshell/supervisor:0.1.5`) is minimal. It
doesn't even ship `id`, so `docker exec` into it isn't useful. It holds the gateway
JWT and provider credentials, and the workload never does.

```bash
openshell sandbox get lab-proc        # phase, conditions, active policy
```

## Clean up

```bash
openshell sandbox delete lab-default lab-proc
```
