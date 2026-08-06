# Home Assistant OS via edk2 UEFI — evaluated, not taken

Recording this so nobody has to re-derive it. **HAOS is viable on paper for the R6S but was
rejected** for the reasons at the bottom.

## There is no RK3588 HAOS build

Home Assistant OS ships no Rockchip RK3588 image and the maintainers have
[no plans to add one](https://github.com/home-assistant/operating-system/discussions/3701):

> "Currently there are no plans to support RK3588/RK3588S devices with Home Assistant OS … you can
> still use them for a Supervised install."

## But `generic-aarch64` is a UEFI image, and RK3588 has UEFI firmware

| Fact | Evidence |
|---|---|
| edk2-rk3588 supports the R6S | `nanopi-r6s_UEFI_Release_v1.1.img`; R6S is listed **Platinum** tier, for which mainline-Device-Tree compatibility is a hard requirement |
| Mainline device tree exists | `rk3588s-nanopi-r6s.dts` is in Linux 6.18; edk2 ships `devicetree/mainline/rk3588s-nanopi-r6s-fixup.dts` |
| HAOS kernel is new enough | HAOS 18.2 = kernel 6.18.x; edk2 needs ≥ 6.15 for display output |
| HAOS has Rockchip drivers | `generic_aarch64_defconfig` sets `BR2_LINUX_KERNEL_USE_ARCH_DEFAULT_CONFIG=y` → mainline arm64 `defconfig`, which carries `CONFIG_ARCH_ROCKCHIP=y` |
| NICs covered | 1 GbE via GMAC/`stmmac`; 2×2.5 GbE RTL8125 via `R8169` + `BR2_PACKAGE_LINUX_FIRMWARE_RTL_815X=y` |
| Supervisor target already matches | `board/arm-uefi/generic-aarch64/meta` sets `SUPERVISOR_MACHINE=qemuarm-64` |

Note the HAOS `generic-aarch64` kernel *fragment* is VM-oriented (virtio, Hyper-V, Xilinx) with no
Rockchip entries — the Rockchip support comes from the **base** arm64 defconfig it layers onto.
That distinction is easy to get wrong.

In UEFI setup you would set:

```
Device Manager → Rockchip Platform Configuration
  ├─ ACPI / Device Tree  →  Device Tree
  └─ Device Tree         →  Mainline        (not Vendor)
```

## Why it was rejected

1. **UEFI would have to live on eMMC.** It can go on SD or eMMC — but SD boot doesn't work on this
   board (see README), so eMMC is the only option. That's irreversible, and with HAOS as a
   whole-disk image the two can't share one disk without hand-rebuilding HAOS's GPT.
2. **No USB-C power negotiation.** edk2 lists **FUSB302 as 🔴 not working**, so the firmware cannot
   negotiate USB-C PD. The supply must deliver 5 V at 3 A+ unnegotiated.
3. **Unvalidated end to end.** No published report of HAOS running on an R6S. Combining that with
   an irreversible eMMC write and maskrom-only recovery is a poor trade when Supervised on Armbian
   is known to work.

If you have a second boot device (e.g. a USB SSD), the calculus changes: UEFI on eMMC, HAOS on the
SSD, and you'd get real HAOS with OTA updates.

## Reference

- <https://github.com/edk2-porting/edk2-rk3588>
- <https://github.com/home-assistant/operating-system>
