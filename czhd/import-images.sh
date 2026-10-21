#!/usr/bin/env bash
# import-images.sh - copy premade Clonezilla images from a USB drive onto
# the CZIMAGES partition (/home/partimag), then check that they're restorable.
#
# Runs inside Clonezilla Live on the laptop: pick "Import images from a USB
# drive" in the boot menu, or from a Clonezilla shell run
#   sudo bash /run/live/medium/czhd/import-images.sh [/dev/sdXN]
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

IMAGES=/home/partimag
SRC_MNT=/tmp/czhd-import-src
LOG=/tmp/czhd-import.log

say()  { printf '\e[1;32m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mWARNING:\e[0m %s\n' "$*"; }
die()  { printf '\e[1;31mERROR:\e[0m %s\n' "$*"; cleanup; exit 1; }
cleanup() {
  if mountpoint -q "$SRC_MNT"; then umount "$SRC_MNT" 2>/dev/null || true; fi
}
trap cleanup EXIT
exec > >(tee -a "$LOG") 2>&1

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1} bytes"; }

# A Clonezilla image is a folder with a "disk" or "parts" file plus image data files.
is_image() {
  [[ -f $1/disk || -f $1/parts ]] && compgen -G "$1/*img*" >/dev/null
}

cat <<'EOF'
 ===========================================================
   Import Clonezilla images from a USB drive
 ===========================================================
EOF

# --- the images partition ------------------------------------------------------

if ! mountpoint -q "$IMAGES"; then
  mkdir -p "$IMAGES"
  mount LABEL=CZIMAGES "$IMAGES" || die "can't mount the CZIMAGES partition at $IMAGES"
fi
dst_disk=$(lsblk -p -n -o PKNAME "$(findmnt -n -o SOURCE "$IMAGES")" | head -n1)
boot_part=$(findmnt -n -o SOURCE /run/live/medium 2>/dev/null || true)

# --- choose the source partition ---------------------------------------------------

if [[ -n ${1-} ]]; then
  [[ -b $1 ]] || die "$1 is not a device"
  SRC_DEV=$1
else
  echo "Plug in the USB drive with your images now, then press Enter."
  read -r _
  sleep 2
  udevadm settle || true
  cands=()
  while read -r line; do
    # line looks like: NAME="/dev/sda1" TYPE="part" PKNAME="/dev/sda"
    name=$(sed -E 's/.*NAME="([^"]*)" TYPE.*/\1/' <<<"$line")
    type=$(sed -E 's/.*TYPE="([^"]*)".*/\1/' <<<"$line")
    pk=$(sed -E 's/.*PKNAME="([^"]*)".*/\1/' <<<"$line")
    [[ $type == part && $pk != "$dst_disk" && $name != "$boot_part" ]] || continue
    fstype=$(blkid -s TYPE -o value "$name" 2>/dev/null || true)
    [[ -n $fstype && $fstype != swap ]] || continue
    cands+=("$name")
  done < <(lsblk -p -n -P -o NAME,TYPE,PKNAME)
  ((${#cands[@]})) || die "no USB drive partitions found (plugged in? try another port)"

  if ((${#cands[@]} == 1)); then
    SRC_DEV=${cands[0]}
  else
    echo "Partitions found:"
    for i in "${!cands[@]}"; do
      printf '  %d) %s\n' $((i + 1)) "$(lsblk -n -o NAME,SIZE,FSTYPE,LABEL "${cands[$i]}" | head -n1)"
    done
    read -rp "Which one holds your images? [1-${#cands[@]}] " n
    if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#cands[@]})); then die "invalid choice"; fi
    SRC_DEV=${cands[$((n - 1))]}
  fi
fi

# --- mount it read-only and find the images -------------------------------------------

say "Reading $SRC_DEV ($(lsblk -n -o SIZE,FSTYPE,LABEL "$SRC_DEV" | head -n1 | xargs))"
mkdir -p "$SRC_MNT"
if ! mount -o ro "$SRC_DEV" "$SRC_MNT"; then
  if [[ $(blkid -s TYPE -o value "$SRC_DEV") == ntfs ]]; then
    die "Windows left the NTFS drive marked in use. Plug it into Windows, use 'Safely Remove', then try again"
  fi
  die "can't mount $SRC_DEV"
fi

found=()
while IFS= read -r -d '' d; do
  is_image "$d" && found+=("$d")
done < <(find "$SRC_MNT" -mindepth 1 -maxdepth 3 -type d -print0 2>/dev/null | sort -z)
((${#found[@]})) || die "no Clonezilla images found on $SRC_DEV (looked 3 folders deep for folders with a 'disk' or 'parts' file)"

echo
printf '  %-3s %-40s %9s  %s\n' "#" IMAGE SIZE ""
sizes=()
for i in "${!found[@]}"; do
  d=${found[$i]}
  sizes[i]=$(du -sb "$d" | cut -f1)
  base=$(basename "$d")
  note=
  [[ -e $IMAGES/${base//[[:space:]]/_} ]] && note="(already on the laptop)"
  [[ $base == *[[:space:]]* ]] && note="$note (name has spaces: will be renamed)"
  printf '  %-3d %-40s %9s  %s\n' $((i + 1)) "${d#"$SRC_MNT"/}" "$(numfmt --to=iec "${sizes[$i]}" 2>/dev/null || echo "${sizes[$i]}")" "$note"
done
free=$(df -B1 --output=avail "$IMAGES" | tail -n1 | tr -d ' ')
echo
echo "  Free space on CZIMAGES: $(human "$free")"
echo
read -rp "Images to import (e.g. 1 3, or 'all') [all]: " pick
pick=${pick:-all}

sel=()
if [[ $pick == all ]]; then
  sel=("${!found[@]}")
else
  for n in $pick; do
    if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#found[@]})); then die "invalid choice: $n"; fi
    sel+=($((n - 1)))
  done
fi

# --- copy ------------------------------------------------------------------------------------

need=0
for i in "${sel[@]}"; do
  name=$(basename "${found[$i]}")
  name=${name//[[:space:]]/_}
  [[ -e $IMAGES/$name ]] || need=$((need + sizes[i]))
done
((need < free)) || die "not enough space: need $(human "$need"), $(human "$free") free"

imported=()
for i in "${sel[@]}"; do
  src=${found[$i]}
  name=$(basename "$src")
  name=${name//[[:space:]]/_}    # Clonezilla handles spaces in image names badly
  dst=$IMAGES/$name
  if [[ -e $dst ]]; then
    read -rp "'$name' is already on the laptop. Replace it? [y/N] " yn
    [[ $yn == [yY]* ]] || { say "Skipping $name"; continue; }
  fi
  say "Copying $name ($(human "${sizes[$i]}"))"
  tmp=$IMAGES/.importing-$name
  rm -rf "$tmp"
  # Copy to a hidden folder first so a half-finished copy never looks like an image.
  rsync -rt --info=progress2 "$src/" "$tmp/"
  sync
  rm -rf "$dst"
  mv "$tmp" "$dst"
  imported+=("$name")
done

umount "$SRC_MNT"
say "USB drive unmounted; you can unplug it."

# --- check ------------------------------------------------------------------------------------

((${#imported[@]})) || { echo "Nothing imported."; exit 0; }
echo
read -rp "Check the imported images are restorable now? Recommended, takes a few minutes per image. [Y/n] " yn
failed=()
if [[ $yn != [nN]* ]]; then
  for name in "${imported[@]}"; do
    say "Checking $name"
    if ocs-chkimg -b -nogui "$name"; then
      say "$name is restorable"
    else
      failed+=("$name")
    fi
  done
fi

echo
echo " ==========================================================="
echo "   Imported: ${imported[*]}"
if ((${#failed[@]})); then
  printf '\e[1;31m   FAILED the restorability check: %s\e[0m\n' "${failed[*]}"
  echo "   Copy those again, or re-create them, before deploying."
fi
echo "   Images on the laptop now:"
for d in "$IMAGES"/*/; do
  if is_image "$d"; then printf '     %-40s %s\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)"; fi
done
echo " ==========================================================="
echo "   Log: $LOG"
((${#failed[@]} == 0))
