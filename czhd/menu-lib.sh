# shellcheck shell=bash
# Helpers for editing Clonezilla Live's boot menus (syslinux for BIOS, GRUB for
# UEFI). Sourced by make-usb.sh and install-to-hd.sh.
#
# Entries we add are wrapped in "# >>> czhd:ID" / "# <<< czhd:ID" markers so
# they can be found and removed again.

menu_files() {
  local root=$1 f
  for f in syslinux/syslinux.cfg syslinux/isolinux.cfg boot/grub/grub.cfg; do
    [[ -f $root/$f ]] && echo "$root/$f"
  done
  return 0
}

# Kernel parameters of Clonezilla's default entry, without the ocs_live_* ones.
base_params() {
  local root=$1 line
  line=$(grep -m1 -E '^[[:space:]]*append .*boot=live' "$root/syslinux/syslinux.cfg") ||
    { echo "no boot=live entry in $root/syslinux/syslinux.cfg" >&2; return 1; }
  sed -E -e 's/^[[:space:]]*append initrd=[^ ]+ //' \
    -e 's/ ocs_live_(run|extra_param|batch)="[^"]*"//g' <<<"$line"
}

# add_entry ROOT ID LABEL LIVEDIR SEARCH_FILE PARAMS
# Adds a boot entry at the top of every menu. PARAMS use syslinux quoting
# (plain double quotes); they are escaped for GRUB automatically.
add_entry() {
  local root=$1 id=$2 label=$3 livedir=$4 search=$5 params=$6 blk f
  blk=$(mktemp)
  for f in $(menu_files "$root"); do
    if [[ $f == *grub.cfg ]]; then
      cat >"$blk" <<EOF
# >>> czhd:$id
menuentry "$label" --id $id {
  search --set -f $search
  \$linux_cmd /$livedir/vmlinuz ${params//\"/\\\"}
  \$initrd_cmd /$livedir/initrd.img
}
# <<< czhd:$id

EOF
      awk 'FNR == NR { blk = blk $0 "\n"; next }
           !done && /^menuentry / { printf "%s", blk; done = 1 }
           { print }' "$blk" "$f" >"$f.new"
    else
      cat >"$blk" <<EOF

# >>> czhd:$id
label $id
  MENU LABEL $label
  kernel /$livedir/vmlinuz
  append initrd=/$livedir/initrd.img $params
# <<< czhd:$id
EOF
      awk 'FNR == NR { blk = blk $0 "\n"; next }
           { print }
           !done && /^MENU TITLE/ { printf "%s", blk; done = 1 }' "$blk" "$f" >"$f.new"
    fi
    cat "$f.new" >"$f"
    rm -f "$f.new"
  done
  rm -f "$blk"
}

remove_entries() {
  local root=$1 f
  for f in $(menu_files "$root"); do
    sed -i '/^# >>> czhd:/,/^# <<< czhd:/d' "$f"
  done
}

# set_default ROOT ID   (ID of an entry added with add_entry, or "clonezilla")
set_default() {
  local root=$1 id=$2 grub_id=$2 label=$2 f
  # Clonezilla's own first entry: GRUB id "live-default", syslinux label "Clonezilla live".
  if [[ $id == clonezilla ]]; then grub_id=live-default label="Clonezilla live"; fi
  for f in $(menu_files "$root"); do
    if [[ $f == *grub.cfg ]]; then
      sed -i -E "s/^set default=.*/set default=\"$grub_id\"/" "$f"
    else
      sed -i -E -e 's/^([[:space:]]*)MENU DEFAULT/\1# MENU DEFAULT/' \
        -e "/^label $label\$/a\\  MENU DEFAULT" "$f"
    fi
  done
}

set_timeout() {
  local root=$1 secs=$2 f
  for f in $(menu_files "$root"); do
    if [[ $f == *grub.cfg ]]; then
      sed -i -E "s/^set timeout=.*/set timeout=\"$secs\"/" "$f"
    else
      sed -i -E "s/^timeout [0-9]+/timeout $((secs * 10))/" "$f"
    fi
  done
}

# set_lang ROOT LOCALE KEYMAP: preselect Clonezilla's language/keyboard prompts.
set_lang() {
  local root=$1 locale=$2 keymap=$3 f
  for f in $(menu_files "$root"); do
    sed -i -E -e "/boot=live/s/ locales=[^ ]*/ locales=$locale/" \
      -e "/boot=live/s/ keyboard-layouts=[^ ]*/ keyboard-layouts=$keymap/" "$f"
  done
}
