# Lab 03: Files

**Goal:** allow an agent to read one directory and write another, and learn why file rules
need a restart when network rules don't.

Same loop: **try it** → **enable it** → **try it again**, with one extra step in the
middle this time.

Starting policy: [../policies/03-files.yaml](../policies/03-files.yaml). `/lab/public` is
read-only. `/lab/secret` and `/lab/scratch` aren't listed, so they're denied.

## 0. Create the sandbox

```bash
cd /data/openshell-lab/docker
openshell sandbox create --name lab-files --from localhost/openshell-lab/leap:16.0 \
  --policy policies/03-files.yaml --no-auto-providers --detach -- sleep infinity
X="openshell sandbox exec -n lab-files --no-tty --"
```

What's listed works:

```bash
$X cat /lab/public/readme.txt
# public data: readable when /lab/public is read_only
```

## 1. Read /lab/secret and write /lab/scratch

### Try it

```bash
$X cat /lab/secret/creds.txt
# cat: /lab/secret/creds.txt: Permission denied
$X bash -c 'echo hi > /lab/scratch/a'
# bash: line 1: /lab/scratch/a: Permission denied
$X ls -ld /lab/secret/creds.txt /lab/scratch
# drwxr-xr-x 1 sandbox sandbox  0 ... /lab/scratch             <- the agent's own directory
# -rw------- 1 sandbox sandbox 37 ... /lab/secret/creds.txt    <- and its own file!
```

Both are owned by the agent's own user (`sandbox`), so Unix permissions allow them. The
denial comes from **Landlock**, the kernel feature OpenShell uses for file rules. Landlock
gives the same `Permission denied` as a normal permission error.

`ls -ld` worked because Landlock controls *opening* files, not looking them up with `stat`.
An agent can learn a file's name, owner and size without being able to read it.

### Enable it

In `policies/03-files.yaml`, add `/lab/secret` under `read_only` and `/lab/scratch` under
`read_write`:

```yaml
  read_only:
    ...
    - /lab/public
    - /lab/secret
  read_write:
    - /tmp
    - /dev/null
    - /lab/scratch
```

```bash
openshell policy set lab-files --policy policies/03-files.yaml --wait
# ✓ Policy version 2 loaded (active version: 2)
```

### Try it again

```bash
$X cat /lab/secret/creds.txt
# cat: /lab/secret/creds.txt: Permission denied      <- still denied!
```

The policy says "loaded", and you can see the new paths in `openshell policy get lab-files
--base`, but the kernel isn't enforcing them yet.

### Enable it, part two: restart

```bash
openshell sandbox stop lab-files && openshell sandbox start lab-files
```

### Try it again

```bash
$X cat /lab/secret/creds.txt
# TOP-SECRET: should never be readable
$X bash -c 'echo hi > /lab/scratch/a && cat /lab/scratch/a'
# hi
```

**Lesson:** Landlock rules are built once, when the sandbox's processes start. After that
they can only get stricter, never looser. OpenShell stores a file-rule change straight
away, but it takes effect on the next start. A restart takes about two seconds and keeps
the sandbox's files.

| Policy section | Change on a running sandbox |
|---|---|
| `network_policies` | live, immediately (Labs 01 and 02) |
| `filesystem_policy` additions | stored now, enforced after `stop` + `start` |
| `filesystem_policy` removals | **rejected** |
| `process` | rejected: recreate the sandbox (Lab 04) |

## 2. You can't take access away from a running sandbox

### Try it

Remove `/lab/public` from the file and reload it:

```bash
grep -v '/lab/public' policies/03-files.yaml > /tmp/fs-remove.yaml
openshell policy set lab-files --policy /tmp/fs-remove.yaml --wait
# Error: filesystem read_only path '/lab/public' cannot be removed on a live sandbox
```

Because a running sandbox can't drop a path, the gateway refuses the change rather than
let you believe it applied. To remove access, delete the sandbox and create it again with
the smaller policy.

Moving a path from `read_only` to `read_write` counts as a removal too, so it's also
rejected.

## 3. Baseline paths: OpenShell adds some for you

This policy has no network rules, so it's enforced exactly as written. As soon as the
policy has **any** network rule, including one an attached provider adds (Lab 05),
OpenShell adds the paths that DNS, TLS and shared libraries need: `/usr /lib /etc /app
/var/log /proc /dev/urandom` read-only and `/tmp /dev/null` read-write. That's the extra
revision you saw appear on its own in Lab 01. A path you already listed keeps the access
you gave it.

## 4. Landlock compatibility mode

The policy sets `landlock.compatibility: hard_requirement`:

| mode | if Landlock can't be applied |
|---|---|
| `best_effort` (default) | the sandbox runs **without file rules** and logs a high-severity finding |
| `hard_requirement` | the sandbox fails to start |

Use `hard_requirement` anywhere you rely on the file rules. This host's kernel (6.12, with
`landlock` in `/sys/kernel/security/lsm`) supports it.

## Clean up

```bash
openshell sandbox delete lab-files
```

Next: [Lab 04: Processes](04-process.md).
