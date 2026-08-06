#!/usr/bin/env bash
# Migrate Armbian (systemd-networkd via netplan) to NetworkManager, safely, on a headless box.
#
# Home Assistant Supervised Pre-Depends on network-manager and its postinst dpkg-diverts
# NetworkManager.conf then restarts it. On a box with no console, letting that happen
# implicitly can strand the machine. This does it deliberately, with a boot-time rollback.
#
# Also pins the Ethernet MAC: Armbian's shipped 20-eth-fixed-mac.yaml may not match the live
# interface, leaving the MAC randomised every boot (new DHCP lease each time).
#
# Usage (run as root ON THE BOARD):
#   bash migrate-to-networkmanager.sh              # migrate, then reboot
#   bash migrate-to-networkmanager.sh --confirm    # after reboot, once you can reach it again
#
# If you never run --confirm, a timer restores systemd-networkd 180 s after boot and reboots.
set -euo pipefail

BACKUP=/root/netplan-backup
FLAG=/root/.net-ok

info() { printf '\033[32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[fail] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root."

# ---------------------------------------------------------------- confirm ---
if [ "${1:-}" = "--confirm" ]; then
  touch "$FLAG"
  systemctl disable --now net-rollback.timer >/dev/null 2>&1 || true
  info "Confirmed — rollback disarmed."
  echo "  NetworkManager: $(systemctl is-active NetworkManager)"
  echo "  systemd-networkd: $(systemctl is-active systemd-networkd)"
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null | grep -v '^lo:' || true
  ip -4 -br addr | grep -v '^lo'
  exit 0
fi

# --------------------------------------------------------------- preflight ---
command -v netplan >/dev/null || die "netplan not found — this script targets Armbian."
[ -d /etc/netplan ] || die "/etc/netplan missing."

# primary interface = the one carrying the default route
IFACE="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
[ -n "$IFACE" ] || die "Could not determine the interface holding the default route."
MAC="$(cat "/sys/class/net/$IFACE/address")"

info "Primary interface: $IFACE (MAC $MAC)"
ip -4 -br addr show "$IFACE"

# ------------------------------------------------------- install NM (masked) ---
if ! dpkg -s network-manager >/dev/null 2>&1; then
  info "Installing network-manager (masked so it cannot grab $IFACE mid-install)"
  systemctl mask NetworkManager >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq network-manager
else
  info "network-manager already installed"
  systemctl mask NetworkManager >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ backup ---
info "Backing up /etc/netplan -> $BACKUP"
rm -rf "$BACKUP"; mkdir -p "$BACKUP"
cp -a /etc/netplan/. "$BACKUP"/
rm -f "$FLAG"

# ------------------------------------------------------- rollback machinery ---
info "Arming boot-time rollback (fires 180 s after boot unless --confirm is run)"
cat > /usr/local/sbin/net-rollback.sh <<'EOF'
#!/bin/sh
[ -f /root/.net-ok ] && exit 0
logger -t net-rollback "migration NOT confirmed - restoring systemd-networkd"
cp -a /root/netplan-backup/. /etc/netplan/
systemctl mask NetworkManager
systemctl unmask systemd-networkd || true
systemctl enable systemd-networkd || true
netplan generate || true
systemctl disable net-rollback.timer || true
sleep 2
reboot -f
EOF
chmod +x /usr/local/sbin/net-rollback.sh

cat > /etc/systemd/system/net-rollback.service <<'EOF'
[Unit]
Description=Rollback to systemd-networkd if migration unconfirmed
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/net-rollback.sh
EOF

cat > /etc/systemd/system/net-rollback.timer <<'EOF'
[Unit]
Description=Check network migration after boot
[Timer]
OnBootSec=180
Unit=net-rollback.service
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable net-rollback.timer >/dev/null 2>&1

# --------------------------------------------------------- switch renderer ---
info "Switching netplan renderer to NetworkManager"
grep -rl 'renderer:[[:space:]]*networkd' /etc/netplan/ 2>/dev/null | while read -r f; do
  sed -i 's/renderer:[[:space:]]*networkd/renderer: NetworkManager/' "$f"
  echo "  updated $f"
done

# pin the live MAC so it stops being randomised each boot
if [ -f /etc/netplan/20-eth-fixed-mac.yaml ]; then
  info "Pinning $IFACE MAC to its live value ($MAC)"
  python3 - "$IFACE" "$MAC" <<'PY'
import sys, re
iface, mac = sys.argv[1], sys.argv[2].upper()
p = '/etc/netplan/20-eth-fixed-mac.yaml'
s = open(p).read()
new, n = re.subn(r'(\b%s:\s*\n\s*macaddress:\s*)\S+' % re.escape(iface), r'\g<1>' + mac, s)
if n:
    open(p, 'w').write(new)
    print("  pinned", iface, "->", mac)
else:
    print("  no stanza for", iface, "- left unchanged")
PY
fi

chmod 600 /etc/netplan/*.yaml
netplan generate || die "netplan generate failed — config restored manually from $BACKUP"

# ------------------------------------------------------------------ enable ---
systemctl unmask NetworkManager
systemctl enable NetworkManager >/dev/null 2>&1
systemctl disable systemd-networkd >/dev/null 2>&1 || true

info "Rebooting. The IP may change: NetworkManager sends a UUID-based DHCP client-id."
warn "Once reachable again, run:  bash $0 --confirm"
warn "If you do not, systemd-networkd is restored automatically 180 s after boot."
(sleep 2; reboot) >/dev/null 2>&1 &
exit 0
