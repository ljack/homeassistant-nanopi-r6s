# Troubleshooting

Failure modes actually hit on a NanoPi R6S, and what each one really means.

---

## The board looks bricked: kernel alive, nothing listening

**Symptoms:** SYS LED blinking, replies to `ping6 ff02::1%<iface>`, but **every TCP port closed**,
no DHCP, no traffic at all from its MAC in `tcpdump`.

**This is not a brick.** ICMPv6 replies and IPv6 link-local autoconfiguration are handled entirely
**in-kernel**. So this pattern means precisely: *the kernel booted, userspace never started.*

Most common cause: something killed all services and then failed before finishing its job — e.g. a
half-working `sysupgrade`/`stage2` invocation. **Power-cycle and the previous system comes right
back**, because nothing was ever written.

Distinguish it from a real brick: a real brick has no LED heartbeat and no ICMPv6 replies.

---

## `setsid /lib/upgrade/stage2 "" "<cmd>"` does nothing

Looks like it's working — SSH drops immediately, exactly as a successful pivot would. Then nothing
happens and the board is stuck in the state above.

Two reasons:

1. **`sysupgrade` never execs `stage2` directly.** It hands off to procd:
   ```sh
   json_add_string prefix "$RAM_ROOT"
   json_add_string command "$COMMAND"
   ubus call system sysupgrade "$(json_dump)"
   ```
   PID 1 performs the pivot. Running `stage2` from a shell can't reproduce that context.
2. **The ramfs needs the musl dynamic loader.** `install_bin` pulls libraries via `ldd`; if you
   hand-populate a ramfs and forget `ld-musl-aarch64.so.1` and `libc.so`, nothing can `exec` after
   the pivot and it dies silently.

**Fix:** use the `sysupgrade` CLI. It's the supported path and gets all of this right.

---

## `ubus call system sysupgrade` → "Firmware image couldn't be validated: no JSON input"

procd validates the image against fwtool metadata, which a non-OpenWrt image doesn't have.
Passing `"force": true` does **not** help — procd rejects it before force is considered.

**Fix:** use `sysupgrade -F …`, which reaches the same code path with validation properly bypassed.

---

## Supervisor loops forever, no `homeassistant` container

```
Platform linux/arm64 not found in manifest list for ghcr.io/home-assistant/generic-x86-64-homeassistant
Can't install ghcr.io/home-assistant/generic-x86-64-homeassistant:landingpage:
  no matching manifest for linux/arm64 in the manifest list entries
Failed to install landingpage, retrying after 30sec
```

The machine type is wrong. The plugin containers (`hassio_dns`, `hassio_cli`, …) come up fine
because they're pulled as `aarch64-*`; only Core uses the machine type.

**Cause:** the debconf key is **`ha/machine-type`**, not `homeassistant/machine-type`. Preseeding
the wrong key leaves the default `generic-x86-64`:

```sh
debconf-show homeassistant-supervised
#   ha/machine-type: generic-x86-64          <- what's actually used
# * homeassistant/machine-type: qemuarm-64   <- what a wrong preseed set
```

**Fix — and note a restart is not enough**, because `SUPERVISOR_MACHINE` is baked into the
container at creation time:

```sh
echo "ha/machine-type select qemuarm-64" | debconf-set-selections
sed -i 's#"machine": "generic-x86-64"#"machine": "qemuarm-64"#' /etc/hassio.json

systemctl stop hassio-supervisor
docker rm -f hassio_supervisor      # supervisor data lives in /var/lib/homeassistant — safe
systemctl start hassio-supervisor
```

Confirm:

```sh
docker inspect hassio_supervisor --format '{{range .Config.Env}}{{println .}}{{end}}' | grep MACHINE
# SUPERVISOR_MACHINE=qemuarm-64
```

---

## `scp` to the board fails: `/usr/libexec/sftp-server: not found`

OpenWrt's dropbear has no SFTP server, and modern `scp` uses SFTP by default. Worse, piping the
output through another command can mask the failure and return exit 0.

**Fix:** `scp -O` (legacy protocol), or just pipe over ssh:

```sh
ssh root@<ip> 'cat > /tmp/image.gz' < image.gz
```

Always verify the far end afterwards rather than trusting the exit code:

```sh
ssh root@<ip> 'sha256sum /tmp/image.gz; gzip -t /tmp/image.gz && echo GZ_OK'
```

---

## Losing network after installing HA / NetworkManager

HA Supervised `dpkg-divert`s `/etc/NetworkManager/NetworkManager.conf` and restarts NM. On Armbian
(systemd-networkd via netplan) two managers then contend for the interface.

**Fix:** migrate deliberately *before* installing HA, with a rollback —
`scripts/migrate-to-networkmanager.sh`. Key trick: `systemctl mask NetworkManager` **before**
`apt install`, so it can't grab the interface during installation.

Expect the IP to change: NetworkManager sends a UUID-based DHCP client-id, not the MAC, so the
DHCP server usually issues a new lease.

---

## The board's MAC (and therefore its IP) changes every reboot

Armbian ships `/etc/netplan/20-eth-fixed-mac.yaml` with pinned MACs, but the stanza may not match
the live interface — the active config can come from a broader `match: name: "e*"` rule instead. The
Rockchip/Realtek NIC then gets a random locally-administered MAC each boot.

Check:

```sh
cat /sys/class/net/<iface>/address
grep -A1 '<iface>:' /etc/netplan/20-eth-fixed-mac.yaml
```

If they differ, the pin isn't applying. The migration script pins it to the live value.

---

## Docker won't restart after installing the HA package

The package installs `/etc/docker/daemon.json` with `"ip6tables": true`. Kernels lacking IPv6
nftables/ip6tables modules — common on Rockchip BSP 6.1 — fail to start dockerd.

```sh
journalctl -u docker -n 50 --no-pager
sed -i 's/"ip6tables": true/"ip6tables": false/' /etc/docker/daemon.json
systemctl restart docker
```

Does not occur on Armbian's mainline kernel, which has the modules. HA will then flag `ip6tables`
as a repair item — cosmetic.

---

## `Could not find /etc/default/grub or /boot/firmware/cmdline.txt failed to switch to cgroup v1`

Harmless on this platform. Modern Supervisor runs on cgroup v2; verify with `mount | grep cgroup2`.

---

## `supported: false`

Expected. `ha resolution info` will show `unsupported: - os` — Armbian isn't on HA's approved OS
list. Add-ons, backups and updates all work regardless. Watch `healthy: true` instead.

---

## Finding the board when it has no DHCP lease

On a direct cable to a laptop, neither end gets an address (Armbian is a DHCP *client*). Use IPv6
link-local, which always works:

```sh
ping6 -c4 ff02::1%en9          # all-nodes multicast; replies reveal the board
nc -6 -w6 fe80::<addr>%en9 22  # grab the SSH banner
```

The banner identifies the OS immediately: `SSH-2.0-dropbear` = OpenWrt,
`SSH-2.0-OpenSSH_… Debian-…` = Debian/Armbian.

Note `bash`'s `/dev/tcp` cannot handle IPv6 zone IDs (`%iface`) — use `nc`.
