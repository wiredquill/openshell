#!/bin/bash
# Prepare a fresh openSUSE / SLES host for the OpenShell Docker labs. Run as root:
#
#   sudo ./install.sh [lab-user]      # lab-user defaults to $SUDO_USER
#
# Each step is explained in INSTALL.md. The script is idempotent: re-run it after
# the reboot it may ask for.
#   1. Landlock: check it's active; if not, add it to the kernel command line (reboot needed)
#   2. Docker: install, enable, start
#   3. OpenShell: install the openshell and openshell-gateway RPMs from the GitHub release
#   4. Lab user: docker group, lingering user services
set -euo pipefail

VERSION=0.1.5
RELEASE=https://github.com/NVIDIA/OpenShell/releases/download/v$VERSION
LAB_USER=${1:-${SUDO_USER:-}}

[ "$(id -u)" -eq 0 ] || { echo "error: run as root: sudo $0" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "error: OpenShell's Docker labs need a Linux host." >&2; exit 1; }
if [ -z "$LAB_USER" ] || [ "$LAB_USER" = root ]; then
  echo "error: name the (non-root) user who will run the labs: $0 <lab-user>" >&2; exit 1
fi
id "$LAB_USER" >/dev/null 2>&1 || { echo "error: no such user '$LAB_USER'. Create it: useradd -m $LAB_USER && passwd $LAB_USER" >&2; exit 1; }

echo "==> 1/4 Landlock"
lsm=$(cat /sys/kernel/security/lsm)
if [[ ",$lsm," == *,landlock,* ]]; then
  echo "active: $lsm"
else
  echo "not active: $lsm"
  grep -q '^CONFIG_SECURITY_LANDLOCK=y' "/boot/config-$(uname -r)" \
    || { echo "error: this kernel has no Landlock (needs CONFIG_SECURITY_LANDLOCK=y, kernel 5.13+). Update the kernel." >&2; exit 1; }
  loader=$(sed -n 's/^LOADER_TYPE="\(.*\)"/\1/p' /etc/sysconfig/bootloader 2>/dev/null || true)
  case "$loader" in
    grub2|grub2-efi)
      grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*lsm=' /etc/default/grub \
        && { echo "error: /etc/default/grub already has an lsm= entry; add landlock to it by hand (see ../../docs/landlock/README.md)." >&2; exit 1; }
      cp /etc/default/grub /etc/default/grub.bak
      sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/&lsm=landlock,${lsm} /" /etc/default/grub
      grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
      update-bootloader --refresh ;;
    systemd-boot|grub2-bls)
      grep -q 'lsm=' /etc/kernel/cmdline \
        && { echo "error: /etc/kernel/cmdline already has an lsm= entry; add landlock to it by hand (see ../../docs/landlock/README.md)." >&2; exit 1; }
      cp /etc/kernel/cmdline /etc/kernel/cmdline.bak
      sed -i "1s/\$/ lsm=landlock,${lsm}/" /etc/kernel/cmdline
      cat /etc/kernel/cmdline
      sdbootutil update-all-entries ;;
    *)
      echo "error: bootloader '${loader:-unknown}' not handled here; follow ../../docs/landlock/README.md, reboot, and re-run." >&2; exit 1 ;;
  esac
  echo
  echo "Landlock added to the kernel command line. Reboot, then re-run: sudo $0 $LAB_USER"
  exit 0
fi

echo "==> 2/4 Docker"
rpm -q docker >/dev/null 2>&1 || zypper --non-interactive install docker
systemctl enable --now docker
docker version --format 'docker {{.Server.Version}}'

echo "==> 3/4 OpenShell $VERSION"
arch=$(uname -m)   # x86_64 or aarch64
need=()
for p in openshell openshell-gateway; do
  rpm -q "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  rpms=()
  for p in "${need[@]}"; do
    rpm_file=$p-$VERSION-1.fc44.$arch.rpm
    curl -fsSL -o "$tmp/$rpm_file" "$RELEASE/$rpm_file"
    curl -fsSL -o "$tmp/$p.sha256" "$RELEASE/$p-checksums-sha256.txt"
    sum=$(awk -v f="$rpm_file" '{n=$2; sub(/^\*/,"",n); sub(/.*\//,"",n)} n==f {print $1}' "$tmp/$p.sha256")
    [ -n "$sum" ] || { echo "error: no checksum for $rpm_file in $p-checksums-sha256.txt" >&2; exit 1; }
    echo "$sum  $tmp/$rpm_file" | sha256sum -c --quiet
    rpms+=("$tmp/$rpm_file")
  done
  # The release RPMs are built for Fedora and not GPG-signed; the checksum is the check.
  zypper --non-interactive install --allow-unsigned-rpm "${rpms[@]}"
fi
rpm -q openshell openshell-gateway

echo "==> 4/4 lab user: $LAB_USER"
usermod -aG docker "$LAB_USER"
loginctl enable-linger "$LAB_USER"
echo "  in group docker, user services linger"

cat <<EOF

Done. Log in as $LAB_USER over SSH (a new login, so the docker group applies;
'su' or 'sudo -i' don't start the user's systemd session), then:

  cd $(cd "$(dirname "$0")" && pwd)
  ./setup.sh
EOF
