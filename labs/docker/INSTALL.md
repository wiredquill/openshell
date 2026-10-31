# Install OpenShell on a Linux host

This page builds a lab host from a fresh openSUSE Leap 16.0 or SLES 16 VM: it switches on
Landlock, installs Docker and OpenShell 0.1.5, and starts the gateway. Each step says what it
does and why OpenShell needs it, then shows how to check it.

[install.sh](install.sh) runs steps 1 to 4 for you, and [setup.sh](setup.sh) runs step 5.
Work through the steps by hand once to learn the parts; after that, the scripts are the
quick way to build a host.

| Step | Run as | Script |
|---|---|---|
| 1. Landlock | root | `install.sh` |
| 2. Docker | root | `install.sh` |
| 3. OpenShell RPMs | root | `install.sh` |
| 4. Lab user | root | `install.sh` |
| 5. Start the gateway | lab user | `setup.sh` |

**Needs Linux.** The sandbox boundary is built from Linux kernel features (Landlock, seccomp,
network namespaces), so a Mac or Windows laptop can't be the lab host. Use your laptop to SSH
into the VM.

## Quick path

```bash
# as root, or any user with sudo
sudo ./install.sh <lab-user>     # may ask you to reboot for Landlock; then run it again
# log out, then SSH in as <lab-user>
./setup.sh
```

## 1. Landlock

**What:** Landlock is the Linux security module that OpenShell uses to limit which files a
sandbox can read and write. A sandbox can be refused a file that ordinary Unix permissions
would allow, and that refusal comes from Landlock.

**Why you might have to switch it on:** SUSE kernels include Landlock, but some releases
don't activate it at boot. The kernel activates only the security modules on its `lsm=` list.

Check, as root:

```bash
cat /sys/kernel/security/lsm
# ...,landlock,...   <- active: skip to step 2
```

If `landlock` isn't in the list, add it to the kernel command line and reboot. **Keep the
modules already in the list**: `lsm=` replaces the default list, so leaving out `selinux`
or `apparmor` switches it off for the whole host. For GRUB 2:

```bash
cur=$(cat /sys/kernel/security/lsm)
cp /etc/default/grub /etc/default/grub.bak
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/&lsm=landlock,${cur} /" /etc/default/grub
update-bootloader --refresh
reboot
```

Other bootloaders, `lsm=` entries that are already there, and how to undo the change are
covered in [docs/landlock](../../docs/landlock/README.md).

After the reboot:

```bash
cat /sys/kernel/security/lsm   # now includes landlock
dmesg | grep -i landlock       # landlock: Up and running.
```

## 2. Docker

**What:** this lab uses OpenShell's Docker *compute driver*. The gateway asks Docker to run
each sandbox as two containers: your workload, and a trusted supervisor beside it.

```bash
zypper --non-interactive install docker
systemctl enable --now docker
docker version
```

## 3. OpenShell

**What:** two RPMs from NVIDIA's [v0.1.5 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.5):

| Package | Gives you |
|---|---|
| `openshell` | the `openshell` CLI you drive the labs with |
| `openshell-gateway` | the gateway (control plane) and its **user** systemd unit, `openshell-gateway.service` |

The RPMs are built for Fedora (`fc44`) and aren't GPG-signed, so check them against the
release's SHA-256 checksums before you install them:

```bash
V=0.1.5; ARCH=$(uname -m)            # x86_64 or aarch64
R=https://github.com/NVIDIA/OpenShell/releases/download/v$V
cd /tmp
for p in openshell openshell-gateway; do
  curl -fLO $R/$p-$V-1.fc44.$ARCH.rpm
  curl -fsSL $R/$p-checksums-sha256.txt | grep "$p-$V-1.fc44.$ARCH.rpm" | sha256sum -c
done
zypper --non-interactive install --allow-unsigned-rpm \
  ./openshell-$V-1.fc44.$ARCH.rpm ./openshell-gateway-$V-1.fc44.$ARCH.rpm
rpm -q openshell openshell-gateway
```

## 4. The lab user

**Why not root:** the gateway runs as an ordinary user, under that user's own systemd
(`systemctl --user`), and talks to Docker through `/var/run/docker.sock`. Use a normal
account:

```bash
useradd -m <lab-user> && passwd <lab-user>   # skip if the account exists
usermod -aG docker <lab-user>                # may use the Docker socket
loginctl enable-linger <lab-user>            # user services keep running after logout
```

Being in the `docker` group gives the user root-equivalent control of the host. That's
fine on a lab VM; think twice about it on a shared machine.

**Log out, then SSH in as the lab user.** A new login picks up the docker group and starts
the user's systemd session. `su` and `sudo -i` don't start that session, and `systemctl --user`
then fails with `Failed to connect to bus`.

## 5. Start the gateway

From here on, run everything as the lab user. [setup.sh](setup.sh) does this step and
then prepares the labs. By hand:

**Configure it.** The gateway reads `~/.config/openshell/gateway.toml`. The lab's
[gateway.toml](gateway/gateway.toml) chooses the Docker driver and the lab's default image:

```bash
mkdir -p ~/.config/openshell
cp gateway/gateway.toml ~/.config/openshell/gateway.toml
openshell-gateway config preflight      # validates the config
```

**Start it.** The gateway listens on `127.0.0.1:17670`, with mutual TLS:

```bash
systemctl --user enable --now openshell-gateway
systemctl --user status openshell-gateway
journalctl --user -u openshell-gateway | grep driver   # Using compute driver driver=docker
```

**Point the CLI at it.** The CLI needs the gateway's address and a client certificate.
`--local` takes the certificate from the local gateway and makes this gateway the active
one:

```bash
openshell gateway add https://127.0.0.1:17670 --local --name local
openshell status                        # Status: Connected
```

## Next

Run `./setup.sh` (it skips the parts you've already done), then go on to the
[Docker lab README](README.md).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `setup.sh`: `'openshell' not found` | Step 3 not done. `setup.sh` runs `install.sh` through sudo. |
| `cp: ... gateway.toml: No such file or directory` | An older `setup.sh`. Pull the latest. |
| `Status: No gateway configured` / `No active gateway` | Step 5, `openshell gateway add`. |
| `Failed to connect to bus` | Logged in with `su` or `sudo`. SSH in as the lab user. |
| `permission denied ... docker.sock` | Not in the docker group in this login. Log out and back in. |
| Sandbox fails to start, mentions Landlock | Step 1: `landlock` missing from `/sys/kernel/security/lsm`. |
