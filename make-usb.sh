#!/usr/bin/env bash
# make-usb.sh - build a Clonezilla Live USB stick that installs Clonezilla
# onto a computer's hard drive (https://clonezilla.org/livehd.php, automated).
#
# Run on any Linux machine. The stick boots normal Clonezilla Live plus an
# extra first menu entry, "Install Clonezilla to this computer's HARD DRIVE",
# which runs czhd/install-to-hd.sh.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=czhd/menu-lib.sh
. "$HERE/czhd/menu-lib.sh"

CZ_SF_BASE=https://downloads.sourceforge.net/project/clonezilla/clonezilla_live_stable
CZ_SF_RSS="https://sourceforge.net/projects/clonezilla/rss?path=/clonezilla_live_stable"
CACHE=${CZHD_CACHE:-$HERE/cache}

TARGET=
CLONEZILLA=
AUTO=0
DEFAULT_ENTRY=clonezilla
BOOT_SIZE=2G
MENU_TIMEOUT=30
CZ_LOCALE=en_US.UTF-8
CZ_KEYMAP=us
ASSUME_YES=0
FORCE=0
IMAGE_SIZE=2G

log()  { printf '\e[1;32m[make-usb]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m[make-usb] WARNING:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[make-usb] ERROR:\e[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo $0 [options] TARGET

TARGET is the USB stick (e.g. /dev/sdb; ALL DATA ON IT IS ERASED), or a path
ending in .img to build a disk image you can write with Rufus/balenaEtcher/dd.

Stick options:
  --clonezilla VER|URL|ZIP  Clonezilla Live version (e.g. 3.3.3-37), zip URL or
                            local zip file (default: latest stable)
  --auto                    make the installer the default boot entry (5 s) and
                            skip its confirmation prompts: plug in, power on,
                            walk away. Only installs when the computer has
                            exactly one internal drive. USE WITH CARE.
  --yes                     don't ask before erasing TARGET
  --force                   allow a TARGET that doesn't look like a USB stick

Hard drive install options (stored on the stick):
  --boot-size SIZE          Clonezilla partition size (default $BOOT_SIZE); the rest
                            of the drive becomes the images partition
  --default clonezilla|lite-server
                            entry the hard drive boots by default (default $DEFAULT_ENTRY)
  --timeout SECS            boot menu timeout on the hard drive (default $MENU_TIMEOUT)
  --locale LOCALE           Clonezilla language, '' to ask every boot (default $CZ_LOCALE)
  --keymap MAP              Clonezilla keyboard, '' to ask every boot (default $CZ_KEYMAP)
  -h, --help
EOF
}

while (($#)); do
  case $1 in
    --clonezilla) CLONEZILLA=${2:?}; shift ;;
    --auto) AUTO=1 ;;
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --boot-size) BOOT_SIZE=${2:?}; shift ;;
    --default) DEFAULT_ENTRY=${2:?}; shift ;;
    --timeout) MENU_TIMEOUT=${2:?}; shift ;;
    --locale) CZ_LOCALE=${2?}; shift ;;
    --keymap) CZ_KEYMAP=${2?}; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [[ -z $TARGET ]] || die "only one TARGET allowed"; TARGET=$1 ;;
  esac
  shift
done

[[ -n $TARGET ]] || { usage >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must be run as root (sudo)"
[[ $DEFAULT_ENTRY == clonezilla || $DEFAULT_ENTRY == lite-server ]] || die "--default must be clonezilla or lite-server"
[[ $MENU_TIMEOUT =~ ^[0-9]+$ ]] || die "--timeout must be a number of seconds"
[[ $BOOT_SIZE =~ ^[0-9]+[MG]$ ]] || die "--boot-size must look like 2G or 1500M"
for cmd in curl unzip sfdisk mkfs.vfat wipefs lsblk losetup partprobe md5sum; do
  command -v "$cmd" >/dev/null || die "missing $cmd (Debian/Ubuntu: apt install curl unzip fdisk dosfstools util-linux parted)"
done

# --- get Clonezilla Live ------------------------------------------------------------

latest_version() {
  curl -fsSL --retry 3 "$CZ_SF_RSS" |
    grep -oE 'clonezilla_live_stable/[0-9][0-9.-]*/clonezilla-live-[0-9][0-9.-]*-amd64\.zip' |
    cut -d/ -f2 | sort -uV | tail -n1
}

get_zip() {
  local ver="" url file want got
  if [[ -f $CLONEZILLA ]]; then
    ZIP=$CLONEZILLA
    return
  elif [[ $CLONEZILLA == *://* ]]; then
    url=$CLONEZILLA
    file=${url%/download}
    file=${file##*/}
  else
    ver=${CLONEZILLA:-$(latest_version)}
    [[ -n $ver ]] || die "could not look up the latest Clonezilla version; pass --clonezilla VERSION"
    file=clonezilla-live-$ver-amd64.zip
    url=$CZ_SF_BASE/$ver/$file
  fi
  mkdir -p "$CACHE"
  ZIP=$CACHE/$file
  if [[ ! -s $ZIP ]]; then
    log "downloading $url"
    curl -fL --retry 3 --connect-timeout 30 -C - -o "$ZIP.part" "$url" || die "download failed (re-run to resume)"
    mv -f "$ZIP.part" "$ZIP"
  fi
  if [[ -n $ver ]]; then
    # SourceForge publishes an MD5 per file in its RSS feed.
    want=$(curl -fsSL --retry 3 "$CZ_SF_RSS/$ver" 2>/dev/null |
      grep -F "/$file/download" | grep -oE 'algo="md5">[0-9a-f]{32}' | head -n1 | cut -d'>' -f2 || true)
    if [[ -n $want ]]; then
      got=$(md5sum "$ZIP" | awk '{print $1}')
      [[ $got == "$want" ]] || { rm -f "$ZIP"; die "checksum mismatch for $file (deleted, re-run to retry)"; }
      log "checksum verified"
    else
      warn "no published checksum for $file; skipping verification"
    fi
  fi
}

get_zip
unzip -tqq "$ZIP" >/dev/null || die "$ZIP is not a valid zip"
unzip -l "$ZIP" live/filesystem.squashfs syslinux/syslinux.cfg boot/grub/grub.cfg >/dev/null ||
  die "$ZIP doesn't look like a Clonezilla Live zip"

# --- prepare the target ----------------------------------------------------------------

LOOP=
MNT=
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  set +e
  [[ -n $MNT ]] && { umount "$MNT" 2>/dev/null; rmdir "$MNT"; }
  [[ -n $LOOP ]] && losetup -d "$LOOP"
}
trap cleanup EXIT

if [[ $TARGET == *.img ]]; then
  log "creating image file $TARGET ($IMAGE_SIZE)"
  rm -f "$TARGET"
  truncate -s "$IMAGE_SIZE" "$TARGET"
  LOOP=$(losetup -f --show -P "$TARGET")
  DEV=$LOOP
else
  DEV=$TARGET
  [[ -b $DEV && $(lsblk -d -n -o TYPE "$DEV") == disk ]] || die "$DEV is not a whole disk (use /dev/sdX, not /dev/sdX1)"
  if ((!FORCE)); then
    [[ $(lsblk -d -n -o TRAN "$DEV") == usb || $(lsblk -d -n -o RM "$DEV" | tr -d ' ') == 1 ]] ||
      die "$DEV is not a USB/removable drive; pass --force if you are sure"
  fi
  echo
  lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL,MODEL,MOUNTPOINTS "$DEV"
  echo
  if ((!ASSUME_YES)); then
    read -rp "ALL DATA ON $DEV WILL BE ERASED. Type YES to continue: " answer
    [[ $answer == YES ]] || die "aborted"
  fi
  for p in $(lsblk -n -p -o NAME "$DEV" | tail -n +2); do umount "$p" 2>/dev/null || true; done
fi

part() { if [[ $DEV =~ [0-9]$ ]]; then echo "${DEV}p$1"; else echo "${DEV}$1"; fi; }

log "partitioning $DEV"
wipefs -a -f "$DEV" >/dev/null
printf 'label: dos\nstart=1MiB, type=c, bootable\n' | sfdisk -q "$DEV"
partprobe "$DEV" 2>/dev/null || true
command -v udevadm >/dev/null && udevadm settle
P1=$(part 1)
for _ in {1..10}; do [[ -b $P1 ]] && break; sleep 1; done
[[ -b $P1 ]] || die "partition $P1 did not appear"
mkfs.vfat -F 32 -n CZINSTALL "$P1" >/dev/null

log "copying Clonezilla Live"
MNT=$(mktemp -d)
mount "$P1" "$MNT"
unzip -qq "$ZIP" -d "$MNT"
mkdir -p "$MNT/czhd"
cp "$HERE/czhd/install-to-hd.sh" "$HERE/czhd/import-images.sh" "$HERE/czhd/menu-lib.sh" "$MNT/czhd/"
{
  echo "# Written by make-usb.sh; read by install-to-hd.sh."
  printf 'BOOT_SIZE=%q\nAUTO=%q\nDEFAULT_ENTRY=%q\nMENU_TIMEOUT=%q\nCZ_LOCALE=%q\nCZ_KEYMAP=%q\n' \
    "$BOOT_SIZE" "$AUTO" "$DEFAULT_ENTRY" "$MENU_TIMEOUT" "$CZ_LOCALE" "$CZ_KEYMAP"
} >"$MNT/czhd/czhd.conf"

log "adding the installer to the boot menus"
params=$(base_params "$MNT")
add_entry "$MNT" czhd-install "Install Clonezilla to this computer's HARD DRIVE" live /czhd/install-to-hd.sh \
  "$params ocs_live_run=\"bash /run/live/medium/czhd/install-to-hd.sh\" ocs_live_extra_param=\"\" ocs_live_batch=\"no\""
if ((AUTO)); then
  set_default "$MNT" czhd-install
  set_timeout "$MNT" 5
fi
set_lang "$MNT" "$CZ_LOCALE" "$CZ_KEYMAP"
version=$(head -n1 "$MNT/Clonezilla-Live-Version" 2>/dev/null || basename "$ZIP")

umount "$MNT"
rmdir "$MNT"
MNT=

log "installing the BIOS boot loader"
dd if=<(unzip -p "$ZIP" utils/mbr/mbr.bin) of="$DEV" bs=440 count=1 conv=notrunc status=none
syslinux_bin=$(mktemp)
unzip -p "$ZIP" utils/linux/x64/syslinux >"$syslinux_bin"
chmod 755 "$syslinux_bin"
"$syslinux_bin" -d syslinux -f -i "$P1" || die "syslinux failed; the stick will still boot on UEFI computers"
rm -f "$syslinux_bin"
sync

log "done"
cat <<EOF

  USB stick ready: $version
  Boot the laptop from it and pick
    "Install Clonezilla to this computer's HARD DRIVE"$( ((AUTO)) && echo " (starts automatically after 5 s)")
EOF
[[ -n $LOOP ]] && echo "  Image file: $TARGET (write it to a USB stick with Rufus, balenaEtcher or dd)"
exit 0
