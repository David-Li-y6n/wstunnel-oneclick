#!/bin/bash
# 搭建 Debian 13 测试容器（改编自 acs-v2/containers/rebuild-debian13.sh）
set -x
ROOT="/var/lib/wstunnel-test/debian13"
rm -rf "$ROOT"
mkdir -p "$ROOT"
debootstrap --variant=minbase trixie "$ROOT" http://deb.debian.org/debian || exit 1
mount -t proc proc "$ROOT/proc" 2>/dev/null || true
mount --bind /dev "$ROOT/dev" 2>/dev/null || true
mount --bind /sys "$ROOT/sys" 2>/dev/null || true
export http_proxy=http://198.19.0.1:3128 https_proxy=http://198.19.0.1:3128
export HTTP_PROXY=http://198.19.0.1:3128 HTTPS_PROXY=http://198.19.0.1:3128
chroot "$ROOT" apt-get update -y || exit 1
chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd systemd-sysv dbus ca-certificates curl gnupg iproute2 procps psmisc python3 \
  openssl tar ufw || exit 1
umount "$ROOT/proc" "$ROOT/dev" "$ROOT/sys" 2>/dev/null || true
# prep（改编自 prep-container.sh，不装 acs-agent，改用 nsenter 执行命令）
umask 022
echo 'root:root' | chroot "$ROOT" chpasswd
systemctl --root="$ROOT" mask getty@tty1.service serial-getty@tty1.service \
  systemd-networkd-wait-online.service systemd-logind.service e2scrub_reap.service >/dev/null
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
printf '127.0.0.1 localhost wstunnel-test\n::1 localhost ip6-localhost ip6-loopback\n198.19.0.1 hatch-egress-proxy\nfd8b:4f84:7d32:99::1 hatch-egress-proxy\n' > "$ROOT/etc/hosts"
echo "wstunnel-test" > "$ROOT/etc/hostname"
mkdir -p "$ROOT/etc/ssl/certs" "$ROOT/usr/local/share/ca-certificates"
chmod 755 "$ROOT/etc/ssl" "$ROOT/etc/ssl/certs" "$ROOT/usr/local/share/ca-certificates"
cp /run/hatch/egress-tls/ca-bundle.pem "$ROOT/etc/ssl/certs/hatch-egress-ca.pem"
chmod 644 "$ROOT/etc/ssl/certs/hatch-egress-ca.pem"
cp /run/hatch/egress-tls/ca-bundle.pem "$ROOT/usr/local/share/ca-certificates/hatch-egress-ca.crt"
cat > "$ROOT/etc/apt/apt.conf.d/99hatch-proxy" <<'EOF'
Acquire::http::Proxy "http://198.19.0.1:3128";
Acquire::https::Proxy "http://198.19.0.1:3128";
EOF
mkdir -p "$ROOT/root" "$ROOT/mnt/host"
echo "BUILD DONE: $ROOT"
