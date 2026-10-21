#!/usr/bin/env bash
# lite-secureboot.sh - let UEFI clients with Secure Boot ON network-boot from
# Clonezilla Lite Server.
#
# Lite Server (DRBL) always copies a signed shim (shimx64.efi) and signed GRUB
# (grubx64.efi) into /tftpboot/nbi_img, but tells clients to load bootx64.efi,
# an unsigned GRUB it builds itself, which Secure Boot rejects. This puts the
# signed shim in place of bootx64.efi; shim then loads the signed grubx64.efi
# from the same server. Clients with Secure Boot off still boot fine.
#
# Started from the laptop's "Clonezilla Lite Server" boot entry through
# ocs_prerun, before Lite Server runs. It forks a watcher and returns, because
# Lite Server regenerates the boot files when it starts.
set -euo pipefail

NBI=/tftpboot/nbi_img
LOG=/tmp/czhd-secureboot.log

if [[ ${1-} != --watch ]]; then
  setsid nohup bash "$0" --watch >>"$LOG" 2>&1 </dev/null &
  echo "Secure Boot helper started (log: $LOG)"
  exit 0
fi

echo "$(date '+%F %T') watching $NBI"
while :; do
  if [[ -s $NBI/shimx64.efi && -s $NBI/grubx64.efi && -s $NBI/bootx64.efi ]] &&
    ! cmp -s "$NBI/shimx64.efi" "$NBI/bootx64.efi"; then
    cp -f "$NBI/bootx64.efi" "$NBI/bootx64-unsigned.efi"
    cp -f "$NBI/shimx64.efi" "$NBI/bootx64.efi"
    # MokManager, in case shim needs it; harmless otherwise.
    [[ -f /usr/lib/shim/mmx64.efi.signed ]] && cp -f /usr/lib/shim/mmx64.efi.signed "$NBI/mmx64.efi"
    chmod 644 "$NBI/bootx64.efi" "$NBI"/mmx64.efi 2>/dev/null || true
    echo "$(date '+%F %T') bootx64.efi is now the signed shim"
  fi
  sleep 2
done
