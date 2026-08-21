# Recovery (maskrom)

On the NanoPi R6S an SD card **is not** a recovery path — see the warning in the README. If eMMC
ends up unbootable, maskrom over USB is the only way back.

**Build this kit before you write anything to eMMC.**

---

## What you need

| Item | Notes |
|---|---|
| **USB A-to-A cable** | The R6S enters maskrom over its **USB 3.0 Type-A** port, not USB-C. This cable is unusual — buy one in advance. |
| `rkdeveloptool` | Linux/macOS. Build instructions below. Windows users can use Rockchip's RKDevTool GUI instead. |
| `MiniLoaderAll.bin` | Rockchip loader pushed into SRAM. Magic bytes `4c 44 52 20` = `LDR `. |

Grab the loader from FriendlyELEC's tooling repo:

```sh
curl -LO https://raw.githubusercontent.com/friendlyarm/sd-fuse_rk3588/kernel-6.1.y/prebuilt/MiniLoaderAll.bin
curl -LO https://raw.githubusercontent.com/friendlyarm/sd-fuse_rk3588/kernel-6.1.y/prebuilt/idbloader.img
curl -LO https://raw.githubusercontent.com/friendlyarm/sd-fuse_rk3588/kernel-6.1.y/prebuilt/uboot.img

head -c 4 MiniLoaderAll.bin | xxd -p     # 4c445220  = "LDR "
head -c 4 idbloader.img     | xxd -p     # 524b4e53  = "RKNS"
```

`RKNS` is the Rockchip IDB signature written at **sector 64** of a bootable disk. Handy sanity
check for any card or image:

```sh
sudo dd if=/dev/rdiskN bs=512 skip=64 count=2 2>/dev/null | xxd | head -2
```

### If your computer only has USB-C

A plain "USB-C to USB-A" cable **will not work**. In maskrom the R6S is the USB *device* and its
device port is the full-size **Type-A** socket (its USB-C is power-only — PD input, no data). So the
board needs an A plug and your computer must present a USB-A **host** port. A standard C-to-A cable
is wired for the opposite roles (A plug into the host, C plug into a device); reversing it does not
work electrically.

Chain it instead:

```
computer USB-C -> [hub/dock with a USB-A socket] -> [A-to-A cable] -> R6S USB 3.0 Type-A
                   ^ provides the USB-A HOST port     ^ both ends full-size A male
```

Or skip the problem: any older laptop/desktop with a built-in USB-A port works, and on Windows you
can use Rockchip's RKDevTool GUI instead of building `rkdeveloptool`.

> ⚠️ **Buy a *passive* A-to-A cable.** Most two-A-plug products are "USB data transfer / bridge /
> link" cables with a chip inside for PC-to-PC file copying. Those are active devices, not a wire,
> and will not work.

The wiki doesn't say which of the two Type-A ports to use. Try **USB 3.0** first; if
`rkdeveloptool ld` reports `not found any devices!`, try the USB 2.0 port before assuming a fault.

---

## Building `rkdeveloptool` on macOS

Not in Homebrew. It builds fine with clang once you stub the autotools-generated header, so you
don't need `automake`:

```sh
brew install libusb            # if missing
git clone --depth 1 https://github.com/rockchip-linux/rkdeveloptool.git
cd rkdeveloptool
printf '#define PACKAGE_VERSION "1.32"\n#define VERSION "1.32"\n' > config.h
clang++ -std=c++11 -O2 -o rkdeveloptool *.cpp $(pkg-config --cflags --libs libusb-1.0)
./rkdeveloptool -v     # rkdeveloptool ver 1.32
```

On Linux the normal `autoreconf -i && ./configure && make` works.

---

## Entering maskrom

Per the FriendlyELEC wiki:

1. Disconnect power
2. Hold the **MASK** button
3. Connect power
4. Release after ~4 seconds (the wiki says "after the status LED has been on for at least 3 s")
5. Connect the USB A-to-A cable to your computer

MaskROM is boot code fused into the silicon — it cannot be erased or corrupted. Holding MASK makes
the SoC skip storage entirely and wait for a loader over USB, which is why it works even when eMMC
holds a broken bootloader.

Confirm detection:

```sh
./rkdeveloptool ld
# DevNo=1  Vid=0x2207,Pid=0x350b,LocationID=...  Mode=Maskrom
```

RKDevTool on Windows shows `Found One MASKROM Device`.

---

## Recovering

```sh
./rkdeveloptool db MiniLoaderAll.bin      # push loader into SRAM
./rkdeveloptool ef                        # erase flash  (or:)
./rkdeveloptool wl 0 system.img           # write an uncompressed image from LBA 0
./rkdeveloptool rd                        # reboot
```

`ef` alone is enough to un-brick: with no valid eMMC bootloader, the BootROM falls through to the
SD card, and you can then boot a normal FriendlyELEC image and reinstall.

---

## Restoring stock FriendlyWrt

Flash `rk3588-eflasher-friendlywrt-*.img.gz` from FriendlyELEC's
`01_Official images/02_SD-to-eMMC images/` to a card and boot it — eFlasher writes eMMC
automatically. Watch the LEDs: SYS fast-flashing = writing; SYS slow-flashing with both LAN LEDs
solid = done.

Note this only works once the eMMC bootloader is gone (e.g. after `rkdeveloptool ef`), for the
reasons in the README.
