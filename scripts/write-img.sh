#!/bin/bash
# Write a disk image (.img, .img.gz, .img.xz) to the SD card.
# Guarded: refuses unless exactly one external, removable disk of the expected size is present.
# Usage:  sudo bash write-img.sh /path/to/image.img.gz
set -eo pipefail    # not -u: bash 3.2 errors on ${#arr[@]} for an empty array

# Optional size guard. Set EXPECT_BYTES to your card's exact byte count (from `diskutil info`)
# to refuse writing to anything else. Unset = no size check (removability is still enforced).
EXPECT_BYTES="${EXPECT_BYTES:-}"
TOLERANCE="${TOLERANCE:-2000000000}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

IMG="$1"
[ -n "$IMG" ] || { red "Usage: sudo bash write-img.sh <image>"; exit 1; }
[ -f "$IMG" ] || { red "Image not found: $IMG"; exit 1; }

# pick decompressor by extension
case "$IMG" in
  *.xz)  DECOMP="xz -dc";   ;;
  *.gz)  DECOMP="gzip -dc"; ;;
  *.img) DECOMP="cat";      ;;
  *)     red "Unknown extension: $IMG (want .img, .gz or .xz)"; exit 1 ;;
esac

# verify archive integrity before touching the card
case "$IMG" in
  *.xz) echo "Testing xz integrity..."; xz -t "$IMG" || { red "Corrupt .xz"; exit 1; } ;;
  *.gz) echo "Testing gz integrity..."; gzip -t "$IMG" || { red "Corrupt .gz"; exit 1; } ;;
esac
grn "Archive OK"

# --- find the card ----------------------------------------------------------
disks=()
while IFS= read -r line; do
  [ -n "$line" ] && disks+=("$line")
done < <(diskutil list external physical 2>/dev/null | grep -oE '^/dev/disk[0-9]+' || true)

if [ "${#disks[@]}" -eq 0 ]; then
  red "No external disk found. Insert the SD card and re-run."; exit 1
fi
if [ "${#disks[@]}" -gt 1 ]; then
  red "More than one external disk attached — refusing to guess:"
  printf '  %s\n' "${disks[@]}"; exit 1
fi

DEV="${disks[0]}"; ID="${DEV#/dev/}"
info=$(diskutil info "$ID")
bytes=$(printf '%s' "$info" | sed -nE 's/.*\(([0-9]+) Bytes\).*/\1/p' | head -1)
removable=$(printf '%s' "$info" | awk -F': +' '/Removable Media/{print $2}' | head -1)
media=$(printf '%s' "$info" | awk -F': +' '/Device \/ Media Name/{print $2}' | head -1)

[ -n "$bytes" ] || { red "Could not read size of $DEV"; exit 1; }
case "$removable" in *Removable*) ;; *) red "$DEV not removable — refusing."; exit 1 ;; esac

if [ -n "$EXPECT_BYTES" ]; then
  diff=$(( bytes > EXPECT_BYTES ? bytes - EXPECT_BYTES : EXPECT_BYTES - bytes ))
  [ "$diff" -le "$TOLERANCE" ] || { red "Size mismatch on $DEV: $bytes bytes, expected ~$EXPECT_BYTES"; exit 1; }
fi

# --- confirm ----------------------------------------------------------------
echo
echo "  Target : $DEV  ($media, $(( bytes / 1000000000 )) GB, $removable)"
echo "  Source : $(basename "$IMG")"
echo
red "This ERASES everything on $DEV. This cannot be undone."
printf 'Type ERASE to proceed: '
read -r ans
[ "$ans" = "ERASE" ] || { echo "Aborted."; exit 1; }

# --- write ------------------------------------------------------------------
diskutil unmountDisk "$DEV"
echo "Writing (Ctrl-T for progress)..."
$DECOMP "$IMG" | dd of="/dev/r$ID" bs=4m
sync
diskutil eject "$DEV"
grn "Done. Card written and ejected."
