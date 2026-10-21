#!/usr/bin/env bash
# install-to-hd.sh - install Clonezilla Live onto this computer's internal drive.
#
# Runs inside Clonezilla Live booted from a USB stick made by make-usb.sh (the
# "Install Clonezilla to this computer's HARD DRIVE" boot entry starts it).
# It automates https://clonezilla.org/livehd.php:
#
#   partition 1  CZBOOT    FAT32 EFI system partition holding Clonezilla Live
#                          (in /live), bootable from UEFI and legacy BIOS
#   partition 2  CZIMAGES  ext4, the rest of the drive, for disk images
#
# If the drive already has that layout, only CZBOOT is rewritten and the
# images on CZIMAGES are kept (upgrade mode).
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$(dirname "$HERE")    # root of the USB stick
# shellcheck source-path=SCRIPTDIR source=menu-lib.sh
. "$HERE/menu-lib.sh"

# Defaults; make-usb.sh writes overrides to czhd.conf.
BOOT_SIZE=2G
AUTO=0
DEFAULT_ENTRY=clonezilla
MENU_TIMEOUT=30
CZ_LOCALE=en_US.UTF-8
CZ_KEYMAP=us
# shellcheck source=/dev/null
[[ -f $HERE/czhd.conf ]] && . "$HERE/czhd.conf"

TARGET_MNT=/tmp/czhd-target
LOG=/tmp/czhd-install.log

say()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWARNING:\e[0m %s\n' "$*"; }
die() {
  printf '\e[1;31mERROR:\e[0m %s\n' "$*"
  echo "Log: $LOG. Press Enter to get a shell."
  read -r _ || true
  exec bash -i
}
trap 'die "command failed (line $LINENO): $BASH_COMMAND"' ERR
exec > >(tee -a "$LOG") 2>&1

part() { if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi; }

[[ -f $SRC/live/vmlinuz && -f $SRC/live/filesystem.squashfs ]] ||
  die "can't find Clonezilla Live files in $SRC (run this from the make-usb.sh stick)"

clear || true
cat <<'EOF'
 ===========================================================
   Install Clonezilla Live to this computer's hard drive
 ===========================================================
EOF

# --- choose the target drive ---------------------------------------------------

src_part=$(findmnt -n -o SOURCE --target "$SRC" || true)
src_disk=
[[ -b $src_part ]] && src_disk=/dev/$(lsblk -n -o PKNAME "$src_part" | head -n1)

disks=()
while read -r name type tran; do
  [[ $type == disk && $name != "$src_disk" && $tran != usb ]] || continue
  [[ $name == /dev/zram* || $name == /dev/loop* ]] && continue
  [[ $(blockdev --getsize64 "$name" 2>/dev/null || echo 0) -gt $((8 * 1024 ** 3)) ]] || continue
  disks+=("$name")
done < <(lsblk -d -p -n -o NAME,TYPE,TRAN | awk '{print $1, $2, ($3 == "" ? "-" : $3)}')

[[ -n ${CZHD_DISK-} ]] || ((${#disks[@]})) || die "no internal drive (8 GB or larger, not USB) found"

if [[ -n ${CZHD_DISK-} ]]; then
  DISK=$CZHD_DISK    # override for testing / unusual hardware
elif ((${#disks[@]} == 1)); then
  DISK=${disks[0]}
else
  ((AUTO)) && die "more than one internal drive found (${disks[*]}); refusing to pick one automatically"
  echo "Internal drives:"
  for i in "${!disks[@]}"; do
    printf '  %d) %s\n' $((i + 1)) "$(lsblk -d -n -o NAME,SIZE,MODEL "${disks[$i]}")"
  done
  read -rp "Install to which drive? [1-${#disks[@]}] " n
  if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#disks[@]})); then die "invalid choice"; fi
  DISK=${disks[$((n - 1))]}
fi
P1=$(part "$DISK" 1)
P2=$(part "$DISK" 2)

# Upgrade mode: our layout is already there, keep the images partition.
UPGRADE=0
if [[ -b $P1 && -b $P2 && $(blkid -s LABEL -o value "$P1" 2>/dev/null) == CZBOOT &&
  $(blkid -s LABEL -o value "$P2" 2>/dev/null) == CZIMAGES ]]; then
  UPGRADE=1
fi

echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$DISK"
echo
if ((UPGRADE)); then
  say "$DISK already has Clonezilla installed: Clonezilla will be replaced, images on CZIMAGES are KEPT."
  if ((!AUTO)); then
    read -rp "Type UPGRADE to continue, or ERASE to wipe the whole drive instead: " answer
    case $answer in
      UPGRADE) ;;
      ERASE) UPGRADE=0 ;;
      *) die "aborted, nothing was changed" ;;
    esac
  fi
fi
if ((!UPGRADE && !AUTO)); then
  echo "EVERYTHING on $DISK will be erased."
  read -rp "Type YES to continue: " answer
  [[ $answer == YES ]] || die "aborted, nothing was changed"
fi

# --- partition + format ------------------------------------------------------------

for p in $(lsblk -n -p -o NAME "$DISK" | tail -n +2); do umount "$p" 2>/dev/null || true; done
swapoff -a 2>/dev/null || true

if ((!UPGRADE)); then
  say "Partitioning $DISK"
  wipefs -a -f "$DISK" >/dev/null
  sgdisk --zap-all "$DISK" >/dev/null
  # Attribute bit 2 = "legacy BIOS bootable", which gptmbr.bin looks for.
  sgdisk -n1:0:+"$BOOT_SIZE" -t1:ef00 -c1:CZBOOT -A1:set:2 \
    -n2:0:0 -t2:8300 -c2:CZIMAGES "$DISK" >/dev/null
  # Make sure the kernel uses the new table; the old partitions' device nodes
  # still exist, so their presence alone proves nothing.
  want=$(sgdisk -i 1 "$DISK" | awk '/^First sector:/ {print $3}')
  for _ in {1..10}; do
    partprobe "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || true
    udevadm settle
    [[ -b $P1 && -b $P2 && $(cat "/sys/class/block/${P1##*/}/start" 2>/dev/null) == "$want" ]] && break
    sleep 1
  done
  [[ $(cat "/sys/class/block/${P1##*/}/start" 2>/dev/null) == "$want" ]] ||
    die "the kernel is still using the old partition table; reboot from the USB stick and run the installer again"
  say "Formatting"
  wipefs -a -f "$P2" >/dev/null
  mkfs.ext4 -q -F -m 0 -L CZIMAGES "$P2"
fi
wipefs -a -f "$P1" >/dev/null
mkfs.vfat -F 32 -n CZBOOT "$P1" >/dev/null
udevadm settle

# --- copy Clonezilla Live ----------------------------------------------------------------

say "Copying Clonezilla Live to $P1"
mkdir -p "$TARGET_MNT"
modprobe -a -q vfat nls_cp437 nls_iso8859_1 nls_utf8 2>/dev/null || true
if ! mount -t vfat "$P1" "$TARGET_MNT" && ! mount -t vfat -o iocharset=iso8859-1 "$P1" "$TARGET_MNT"; then
  echo "--- kernel log ---"
  dmesg | tail -n 15
  blkid -p "$P1" || true
  die "could not mount the new FAT32 partition $P1 (details above)"
fi
rsync -rt --exclude=/czhd "$SRC/" "$TARGET_MNT/"
# The laptop gets the image import tool, not the installer.
mkdir -p "$TARGET_MNT/czhd"
cp "$HERE/import-images.sh" "$HERE/lite-server-helper.sh" "$TARGET_MNT/czhd/"
# Clonezilla stays in /live, not /live-hd as on clonezilla.org/livehd.php:
# Lite Server hard-codes <boot media>/live/ when it builds the client boot menu.

say "Writing boot menus"
remove_entries "$TARGET_MNT"
for f in $(menu_files "$TARGET_MNT"); do
  sed -i -E '/boot=live/s#boot=live #boot=live ocs_repository="dev:///LABEL=CZIMAGES" #' "$f"
done
params=$(base_params "$TARGET_MNT")
# add_entry puts each new entry at the top, so add them bottom-up.
add_entry "$TARGET_MNT" czhd-import "Import images from a USB drive" live /live/vmlinuz \
  "$params ocs_live_run=\"bash /run/live/medium/czhd/import-images.sh\" ocs_live_extra_param=\"\" ocs_live_batch=\"no\""
# lite-server-helper.sh makes Lite Server hand UEFI clients signed boot files
# (so Secure Boot can stay on) and keeps this laptop's settings off the clients.
add_entry "$TARGET_MNT" czhd-lite "Clonezilla Lite Server (PXE-boot other computers)" live /live/vmlinuz \
  "$params ocs_prerun=\"bash /run/live/medium/czhd/lite-server-helper.sh\" ocs_live_run=\"ocs-live-feed-img\" ocs_live_extra_param=\"\" ocs_live_batch=\"no\""
if [[ $DEFAULT_ENTRY == lite-server ]]; then set_default "$TARGET_MNT" czhd-lite; else set_default "$TARGET_MNT" clonezilla; fi
set_timeout "$TARGET_MNT" "$MENU_TIMEOUT"
set_lang "$TARGET_MNT" "$CZ_LOCALE" "$CZ_KEYMAP"
sync
umount "$TARGET_MNT"

# --- boot loaders ----------------------------------------------------------------------------

say "Installing the legacy BIOS boot loader"
dd if=/usr/lib/syslinux/mbr/gptmbr.bin of="$DISK" bs=440 count=1 conv=notrunc status=none
# The syslinux installer must match the .c32 modules shipped with this Clonezilla.
syslinux_bin=/tmp/czhd-syslinux
if ! cp "$SRC/utils/linux/x64/syslinux" "$syslinux_bin" 2>/dev/null || ! chmod 755 "$syslinux_bin"; then
  syslinux_bin=syslinux
else
  rc=0
  "$syslinux_bin" --version >/dev/null 2>&1 || rc=$?
  if ((rc >= 126)); then syslinux_bin=syslinux; fi    # bundled binary can't run here
fi
"$syslinux_bin" -d syslinux -f -i "$P1"

if [[ -d /sys/firmware/efi ]]; then
  say "Adding a UEFI boot entry"
  efibootmgr -q -c -d "$DISK" -p 1 -L "Clonezilla (hard drive)" -l '\EFI\boot\bootx64.efi' ||
    warn "could not add a UEFI boot entry; the drive still boots through the default EFI path"
fi
trap - ERR

cat <<EOF

 ===========================================================
   Done. Clonezilla Live is installed on $DISK.

   $P1  CZBOOT    Clonezilla Live ($(cat "$SRC/Clonezilla-Live-Version" 2>/dev/null | head -n1))
   $P2  CZIMAGES  image storage (auto-mounted as /home/partimag)

   Boot menu on the hard drive:
     - Clonezilla live: images are saved to/restored from CZIMAGES
     - Clonezilla Lite Server: PXE-boot other computers on the
       network (Secure Boot on or off) and deploy images to them
     - Import images from a USB drive: copy premade images
       onto CZIMAGES and check them
 ===========================================================

EOF
if [[ -n ${CZHD_NO_REBOOT-} ]]; then
  exit 0
elif ((AUTO)); then
  echo "Rebooting in 15 seconds. REMOVE THE USB STICK. (Ctrl+C to cancel)"
  sleep 15
else
  read -rp "Remove the USB stick, then press Enter to reboot. " _
fi
reboot
