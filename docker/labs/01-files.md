# Lab 01: Files (Landlock)

**Goal:** see exactly which paths an agent can list, read and write, and learn why
filesystem policy is *static*.

Policy: [../policies/01-files.yaml](../policies/01-files.yaml)

## 1. Baseline: no policy

With no `--policy`, OpenShell applies its built-in default: workspace read-write, plus
`/bin /usr /lib /proc /dev/urandom /etc /var/log` read-only and `/tmp /dev/null` read-write.

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-default --from localhost/openshell-lab/leap:16.0 \
  --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-default --no-tty -- fs-probe
openshell policy get lab-default --full
```

Expected: `/lab/*`, `/opt/agent-home`, `/home/sandbox` and `/var/tmp` are all `DENY`.
`/home/sandbox` is the user's own home directory, and even that is off-limits.

## 2. Apply the lab policy

```bash
openshell sandbox create --name lab-files --from localhost/openshell-lab/leap:16.0 \
  --policy policies/01-files.yaml --no-auto-providers --detach -- sleep infinity
openshell sandbox exec -n lab-files --no-tty -- fs-probe
```

Observed:

```
PATH                       LIST   READ   WRITE
/sandbox                   ok     -      ok        include_workdir: true
/tmp                       ok     -      ok        read_write
/etc/os-release            ok     ok     DENY      read_only
/lab/public                ok     ok     DENY      read_only
/lab/scratch               ok     -      ok        read_write
/lab/secret/creds.txt      ok     DENY   DENY      not listed (file is owned by sandbox, 0600!)
/opt/agent-home/notes.txt  ok     DENY   DENY      not listed (owned by sandbox)
/home/sandbox              DENY   -      DENY
/var/tmp                   DENY   -      DENY
```

Try it by hand:

```bash
X="openshell sandbox exec -n lab-files --no-tty --"
$X bash -c 'echo hi > /lab/public/x'      # Permission denied (read_only)
$X bash -c 'echo hi > /lab/scratch/ok && cat /lab/scratch/ok'   # hi
$X cat /lab/secret/creds.txt              # Permission denied
$X ls -l /lab/secret/creds.txt            # works!
```

**Lesson:** Landlock controls *opening* files (read, write, execute, readdir, create,
remove). It does **not** control `stat()`. If a path's parent can be reached, the agent can
still learn a file's name, owner, size and mode. It just can't open it. Also, a Landlock
denial is the same `EACCES` as a Unix permission error. The fixtures are owned by
`sandbox`, so in this lab the denial can only be Landlock.

## 3. Static means static: change policy on a live sandbox

**Remove** a path while it's running:

```bash
grep -v '/lab/public' policies/01-files.yaml > /tmp/fs-remove.yaml
openshell policy set lab-files --policy /tmp/fs-remove.yaml --wait
# Error: filesystem read_only path '/lab/public' cannot be removed on a live sandbox
```

**Add** a path while it's running:

```bash
sed 's#^    - /lab/public .*#&\n    - /lab/secret#' policies/01-files.yaml > /tmp/fs-add.yaml
openshell policy set lab-files --policy /tmp/fs-add.yaml --wait
# ✓ Policy version N loaded
openshell sandbox exec -n lab-files --no-tty -- cat /lab/secret/creds.txt
# Permission denied        <- accepted, stored, NOT enforced yet
openshell sandbox stop lab-files && openshell sandbox start lab-files
openshell sandbox exec -n lab-files --no-tty -- cat /lab/secret/creds.txt
# TOP-SECRET: should never be readable
```

**Lesson:** the Landlock ruleset is built once, when the sandbox's process tree starts, and
a Landlock domain can only get narrower. Because of that, the gateway rejects removals
outright. Additions are accepted and saved as a new revision, but they only take effect on
the next start. "Loaded" in `policy list` refers to the revision, not to the kernel rules.
When you review a widening change, remember it will take effect on the next restart.

## 4. Landlock compatibility mode

The lab policy sets `landlock.compatibility: hard_requirement`. The difference only shows
when *none* of the listed paths can be applied, or Landlock fails:

| mode | effect |
|---|---|
| `best_effort` (default) | sandbox runs **without file rules** and logs a high-severity finding |
| `hard_requirement` | sandbox fails to start |

Use `hard_requirement` anywhere you rely on the file rules. This host's kernel
(6.12, `landlock` in `/sys/kernel/security/lsm`) meets the ABI v3 minimum.

## 5. Baseline paths: the gotcha when you add network rules

This policy has no `network_policies`, so it's enforced exactly as written. As soon as the
effective policy has **any** network rule, including one contributed by an attached
provider, OpenShell adds baseline paths it needs for DNS, TLS and shared libraries:
`/usr /lib /etc /app /var/log /proc /dev/urandom` read-only and `/tmp /dev/null` read-write.
A path you already listed keeps your access level. Lab 04 shows this.

## Clean up

```bash
openshell sandbox delete lab-default lab-files
```
