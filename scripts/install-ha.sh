#!/usr/bin/env bash
# Provision Home Assistant Supervised on Armbian (Debian 13 Trixie) / NanoPi R6S.
# Run as root ON THE BOARD:  bash install-ha.sh
set -euo pipefail

OS_AGENT_VER=1.11.0
SUPERVISED_URL=https://github.com/home-assistant/supervised-installer/releases/download/4.0.1/homeassistant-supervised.deb
MACHINE=qemuarm-64

info() { printf '\033[32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[fail] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root."

# ---------------------------------------------------------------- preflight --
info "Preflight"
. /etc/os-release
echo "  OS            : $PRETTY_NAME  (ID=$ID VERSION_ID=$VERSION_ID)"
echo "  Kernel        : $(uname -r)  $(uname -m)"
[ "$ID" = "debian" ]      || die "Installer requires ID=debian, got '$ID'."
[ "$VERSION_ID" = "13" ]  || die "Installer requires VERSION_ID=13, got '$VERSION_ID'."
[ "$(uname -m)" = "aarch64" ] || die "Expected aarch64."

aa=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo "?")
echo "  AppArmor      : $aa"
[ "$aa" = "Y" ] || warn "AppArmor not active — Supervisor will flag the system as unhealthy."

if mount | grep -q cgroup2; then echo "  cgroup        : v2"; else warn "cgroup v2 not mounted"; fi
echo "  Root fs free  : $(df -h / | awk 'NR==2{print $4" of "$2}')"

# ------------------------------------------------------------ dependencies ---
info "Installing installer dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# NOTE: deliberately NOT running full-upgrade. On a freshly flashed board that can
# pull a new kernel/u-boot and risk the boot path; not needed for HA.
apt-get install -y \
  curl jq wget ca-certificates gnupg dbus apparmor apparmor-utils \
  network-manager systemd-timesyncd systemd-journal-remote systemd-resolved \
  bluez cifs-utils nfs-common iproute2 udisks2 libglib2.0-bin

systemctl enable --now NetworkManager systemd-resolved systemd-timesyncd

# Armbian minimal may hand the NIC to systemd-networkd; the HA package expects
# NetworkManager to own it, and a split brain drops the link on reboot.
if systemctl is-enabled systemd-networkd &>/dev/null; then
  warn "systemd-networkd is enabled; disabling so NetworkManager owns the NIC."
  systemctl disable --now systemd-networkd systemd-networkd-wait-online || true
fi
nmcli device status || true

# ------------------------------------------------------------------ docker ---
if ! command -v docker &>/dev/null; then
  info "Installing docker-ce from Docker's repo"
  install -m0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
else
  info "docker already present, skipping"
fi

docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup Version" || die "docker not healthy"
docker info 2>/dev/null | grep -q "Storage Driver: overlay2" || warn "storage driver is not overlay2"

# ---------------------------------------------------------------- os-agent ---
info "Installing os-agent $OS_AGENT_VER"
cd /tmp
deb="os-agent_${OS_AGENT_VER}_linux_aarch64.deb"
[ -f "$deb" ] || wget -q --show-progress \
  "https://github.com/home-assistant/os-agent/releases/download/${OS_AGENT_VER}/${deb}"
dpkg -i "$deb"
gdbus introspect --system --dest io.hass.os --object-path /io/hass/os >/dev/null 2>&1 \
  || die "os-agent DBus service not responding — check: systemctl status haos-agent"
info "os-agent OK"

# -------------------------------------------------------------- supervised ---
info "Installing homeassistant-supervised (machine: $MACHINE)"
cd /tmp
[ -f homeassistant-supervised.deb ] || wget -q --show-progress -O homeassistant-supervised.deb "$SUPERVISED_URL"
# NOTE: the key is 'ha/machine-type'. Using 'homeassistant/machine-type' silently leaves the
# default generic-x86-64, and Supervisor then loops forever on a non-existent arm64 manifest.
echo "homeassistant-supervised ha/machine-type select $MACHINE" | debconf-set-selections
apt-get install -y ./homeassistant-supervised.deb

# The package writes /etc/docker/daemon.json with "ip6tables": true. This kernel
# has IP6_NF_IPTABLES, so it should be fine — but verify docker actually restarted.
sleep 3
if ! systemctl is-active --quiet docker; then
  warn "docker did not come back up; retrying with ip6tables disabled"
  journalctl -u docker -n 30 --no-pager || true
  sed -i 's/"ip6tables": true/"ip6tables": false/' /etc/docker/daemon.json
  systemctl restart docker
  systemctl is-active --quiet docker || die "docker still down — inspect journalctl -u docker"
fi

# ------------------------------------------------- verify the machine type ---
# SUPERVISOR_MACHINE is baked into the supervisor container at creation time, so a wrong
# value cannot be fixed by editing /etc/hassio.json + `systemctl restart` — the container
# has to be recreated. Symptom of a wrong value:
#   Can't install ghcr.io/home-assistant/generic-x86-64-homeassistant:landingpage:
#   no matching manifest for linux/arm64
CONFIGURED=$(sed -n 's/.*"machine": *"\([^"]*\)".*/\1/p' /etc/hassio.json 2>/dev/null)
if [ "$CONFIGURED" != "$MACHINE" ]; then
  warn "machine is '$CONFIGURED', expected '$MACHINE' — correcting and recreating supervisor"
  sed -i "s#\"machine\": *\"$CONFIGURED\"#\"machine\": \"$MACHINE\"#" /etc/hassio.json
  systemctl stop hassio-supervisor
  docker rm -f hassio_supervisor >/dev/null 2>&1 || true   # data lives in /var/lib/homeassistant
  systemctl start hassio-supervisor
  sleep 20
fi
env_machine=$(docker inspect hassio_supervisor --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^SUPERVISOR_MACHINE=//p')
info "SUPERVISOR_MACHINE=${env_machine:-unknown}"
[ "$env_machine" = "$MACHINE" ] || warn "machine type still wrong — see docs/troubleshooting.md"

# ------------------------------------------------------------------- done ----
ip=$(hostname -I | awk '{print $1}')
info "Done. Supervisor is pulling containers (5-15 min on first run)."
echo
echo "  Watch    : journalctl -fu hassio-supervisor"
echo "  Containers: docker ps"
echo "  Web UI   : http://${ip}:8123"
