# Home Assistant Supervised on the NanoPi R6S

A tested, end-to-end recipe for running **Home Assistant Supervised** (full add-on store, Supervisor,
HA-managed updates) on a **FriendlyELEC NanoPi R6S** (Rockchip RK3588S), installed to **eMMC**.

Result on the reference board:

```
OS          Armbian 26.5.1 (Debian 13 trixie), kernel 6.18.x-current-rockchip64
HA Core     2026.8.0 (aarch64)
Supervisor  healthy: true, supported: false (reason: os)
Storage     eMMC, rootfs auto-expanded to full disk
```

`supported: false` is normal and harmless for Supervised on non-listed hardware. It means *no
official support*, not *broken* — the add-on store, backups and HA-managed updates all work.
`healthy: true` is the flag that matters.

---

## ⚠️ Read this first: the SD card is not a recovery path

On this board an SD card **will not boot** while a valid bootloader exists on eMMC.

RK3588 BootROM order is **SPI → eMMC → SD → USB**. The "SD wins" behaviour people expect comes
from the *U-Boot SPL* on eMMC chaining to the card — and not every eMMC image does that. On a
NanoPi R6S with a stock OpenWrt/FriendlyWrt eMMC install, both an Armbian card and FriendlyELEC's
own OpenWrt card were **silently ignored**; the board booted eMMC every time.

FriendlyELEC document the same outcome in their wiki:

> "Flashing third-party firmware carries a risk of bricking the device. If the device gets bricked,
> **or if you wish to restore the ability to boot from SD card**, please refer to this link to
> recover the device."

**Therefore: build the maskrom recovery kit *before* you touch eMMC.** See
[docs/recovery.md](docs/recovery.md). You will need a **USB A-to-A cable** — the R6S enters maskrom
over its USB 3.0 Type-A port, not USB-C. Without that cable and kit you have no way back.

---

## Why Armbian rather than FriendlyELEC's Debian

The HA Supervised installer is strict, and these were verified by grepping the decompressed image
before flashing, then confirmed on the running system:

| Requirement | Armbian trixie `current` | Why it matters |
|---|---|---|
| `ID=debian`, `VERSION_ID="13"` | ✅ | Installer `preinst` has `supported_os_version_id=("13")` — **Debian 13 only**. Armbian overrides only `PRETTY_NAME`, so it passes unmodified. Guides saying "Debian 12" are stale. |
| `CONFIG_SECURITY_APPARMOR=y` + default LSM | ✅ | Supervisor requires AppArmor. Rockchip BSP kernels often lack it. |
| `IP6_NF_IPTABLES`, `IP6_NF_NAT`, `NF_TABLES` | ✅ | The HA package writes `/etc/docker/daemon.json` with `"ip6tables": true`. BSP-6.1 kernels missing these produce the documented "docker won't restart" failure on FriendlyELEC boards. |
| `OVERLAY_FS`, cgroup v2 | ✅ | Docker `overlay2` + Supervisor |

Armbian also publishes over plain HTTPS (FriendlyELEC's images are behind Google Drive/OneDrive),
and ships zram + log2ram.

Verify any candidate image yourself without mounting it:

```sh
xz -dc Armbian_*.img.xz | LC_ALL=C grep -a -o -E \
  'CONFIG_SECURITY_APPARMOR=y|CONFIG_IP6_NF_IPTABLES=[ym]|CONFIG_NF_TABLES=[ym]|VERSION_ID="[0-9]+"|ID=debian' \
  | sort | uniq -c
```

Home Assistant OS is **not** an option here: there is no RK3588 build and
[no plans for one](https://github.com/home-assistant/operating-system/discussions/3701).

---

## Prerequisites

- NanoPi R6S with its stock **OpenWrt / FriendlyWrt on eMMC** (this is what ships)
- Ethernet, and a USB-C supply that delivers 5 V at 3 A+
- **USB A-to-A cable** for maskrom recovery — get one before starting
- A Linux/macOS machine on the same network

Download the image (pick `current` for the mainline kernel):

```sh
curl -LO https://dl.armbian.com/nanopi-r6s/archive/Armbian_<ver>_Nanopi-r6s_trixie_current_<kver>_minimal.img.xz
curl -LO https://dl.armbian.com/nanopi-r6s/archive/Armbian_<ver>_Nanopi-r6s_trixie_current_<kver>_minimal.img.xz.sha
shasum -a 256 -c <(awk '{print $1"  Armbian_"$2}' *.sha) 2>/dev/null || shasum -a 256 Armbian_*.img.xz
```

Browse <https://dl.armbian.com/nanopi-r6s/archive/> for current filenames.

---

## Step 1 — Write Armbian to eMMC

Because SD boot doesn't work, the board must overwrite the disk it is running from. OpenWrt's own
`sysupgrade` does exactly that: its rockchip `platform_do_upgrade` is a full-disk `dd`, and procd
performs the ramfs pivot correctly.

```sh
# 1. convert to .gz (OpenWrt's get_image handles gz, not xz)
xz -dc Armbian_*.img.xz | gzip -1 > armbian.img.gz

# 2. copy into the board's tmpfs (RAM). scp fails — dropbear has no sftp-server
ssh root@<board-ip> 'cat > /tmp/armbian.img.gz' < armbian.img.gz

# 3. verify before writing anything
shasum -a 256 armbian.img.gz
ssh root@<board-ip> 'sha256sum /tmp/armbian.img.gz; gzip -t /tmp/armbian.img.gz && echo GZ_OK'

# 4. dry run
ssh root@<board-ip> 'sysupgrade -T -F -n -p /tmp/armbian.img.gz'

# 5. flash (SSH will drop as it pivots; ~2 min, then it reboots itself)
ssh root@<board-ip> 'sysupgrade -F -n -p /tmp/armbian.img.gz'
```

- `-F` — force past `REQUIRE_IMAGE_METADATA=1`; Armbian has no OpenWrt fwtool metadata
- `-n` — don't save config
- `-p` — don't restore the partition table → selects the full-disk `dd` branch

A correct dry run prints:

```
Image metadata not present
Reading partition table from bootdisk...
Reading partition table from image...
Partition layout has changed. Full image will be written.
Image check failed but --force given - will update anyway!
```

> **Alternative:** if the board runs FriendlyWrt (not vanilla OpenWrt), LuCI →
> **System → eMMC Tools** → upload the `.img.gz` → *Upload and Write*. Accepts
> `.img`, `.gz`, `.tgz`, `.zip`, including third-party images.

Do **not** try `setsid /lib/upgrade/stage2 …` or a raw `ubus call system sysupgrade` — see
[docs/troubleshooting.md](docs/troubleshooting.md) for why both fail.

Leave any SD card **out** so there's no ambiguity about what booted.

---

## Step 2 — First boot

Armbian resizes the rootfs to the full eMMC and reboots once. Then:

```sh
ssh root@<new-ip>        # password: 1234, wizard forces a change
ssh-copy-id root@<new-ip>
```

Sanity check:

```sh
cat /etc/os-release                            # ID=debian VERSION_ID=13
cat /sys/module/apparmor/parameters/enabled    # Y
mount | grep cgroup2
df -h /                                        # expanded to full eMMC
```

---

## Step 3 — Migrate to NetworkManager (do this before installing HA)

Armbian uses **systemd-networkd rendered by netplan**. HA Supervised `Pre-Depends:
network-manager`, and its postinst `dpkg-divert`s NetworkManager's config and restarts it. Letting
that happen implicitly on a headless box risks losing the machine.

`scripts/migrate-to-networkmanager.sh` does it deliberately, with a **boot-time rollback** that
restores networkd if you don't confirm within 3 minutes:

```sh
scp scripts/migrate-to-networkmanager.sh root@<ip>:/root/
ssh root@<ip> 'bash /root/migrate-to-networkmanager.sh'    # installs NM masked, switches renderer, reboots
# after it comes back (the IP may change — NM uses a UUID-based DHCP client-id):
ssh root@<new-ip> 'bash /root/migrate-to-networkmanager.sh --confirm'
```

It also **pins the Ethernet MAC**. Armbian's shipped `20-eth-fixed-mac.yaml` may not match the live
interface, leaving the MAC randomised on every boot — which changes the DHCP lease each time.

---

## Step 4 — Install Home Assistant

```sh
scp scripts/install-ha.sh root@<ip>:/root/
ssh root@<ip> 'bash /root/install-ha.sh'
```

Installs docker-ce (from Docker's repo — **not** `docker.io`, it's a hard dependency), `os-agent`,
and `homeassistant-supervised` with the machine type preseeded.

**The single most important detail:** the debconf key is **`ha/machine-type`**, *not*
`homeassistant/machine-type`. Preseeding the wrong key silently leaves the default
`generic-x86-64`, and Supervisor then loops forever on:

```
Can't install ghcr.io/home-assistant/generic-x86-64-homeassistant:landingpage:
no matching manifest for linux/arm64
```

Correct value for a generic aarch64 board is **`qemuarm-64`**.

Then open **`http://<ip>:8123`**. First start pulls ~1.5 GB; `version: landingpage` is the
placeholder shown while Core downloads.

Verify:

```sh
ha core info        # version, arch: aarch64
ha supervisor info  # healthy: true
```

---

## After it works

- **Reserve the IP** in your DHCP server against the now-pinned MAC.
- **Back up off-box** (Google Drive / Samba add-on) — not just onto the device.
- **Zigbee/Z-Wave sticks → the USB 2.0 port.** USB 3.0 radiates in 2.4 GHz and wrecks Zigbee range.
  Address them as `/dev/serial/by-id/…`, never `/dev/ttyUSB0`.

---

## Documents

- [docs/troubleshooting.md](docs/troubleshooting.md) — failure modes and what they actually mean
- [docs/recovery.md](docs/recovery.md) — maskrom recovery, build `rkdeveloptool` on macOS
- [docs/haos-route.md](docs/haos-route.md) — why HAOS via edk2 UEFI was evaluated and rejected

## Scripts

| Script | Purpose |
|---|---|
| `scripts/install-ha.sh` | docker-ce + os-agent + supervised, with preflight guards |
| `scripts/migrate-to-networkmanager.sh` | networkd → NetworkManager with boot-time rollback and MAC pinning |
| `scripts/write-img.sh` | guarded SD writer (macOS) — for FriendlyWrt cards, not for HA itself |

## Licence

MIT — see [LICENSE](LICENSE). Not affiliated with Home Assistant, FriendlyELEC or Armbian.
