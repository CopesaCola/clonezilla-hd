#!/usr/bin/env bash
# lite-server-helper.sh - fix up the boot files Clonezilla Lite Server serves
# to PXE clients. Lite Server (DRBL) writes them to /tftpboot/nbi_img when it
# starts, so this runs in the background for the whole session and corrects
# them each time they are (re)generated.
#
# 1. Secure Boot: Lite Server copies a signed shim (shimx64.efi) and signed
#    GRUB (grubx64.efi) into nbi_img but tells UEFI clients to load
#    bootx64.efi, an unsigned GRUB it builds itself, which Secure Boot
#    rejects. Put the signed shim in place of bootx64.efi; shim then loads the
#    signed grubx64.efi from the same server. Clients with Secure Boot off
#    still boot fine.
# 2. Image repository: the client boot entry is copied from this laptop's own
#    boot menu, including ocs_repository="dev:///LABEL=CZIMAGES". On a client
#    that makes Clonezilla look for a CZIMAGES partition it doesn't have, so
#    strip it from the client menus.
# 3. Full-duplex multicast (see below).
#
# Started from the laptop's "Clonezilla Lite Server" boot entry through
# ocs_prerun, before Lite Server runs. It forks the watcher and returns.
set -euo pipefail

NBI=/tftpboot/nbi_img
LOG=/tmp/czhd-lite-server.log
DRBL_OCS_CONF=/etc/drbl/drbl-ocs.conf

if [[ ${1-} != --watch ]]; then
  # 3. Full-duplex multicast: udp-sender otherwise assumes a hub and pauses
  #    for every client's acknowledgements, which slows big batches. Same as
  #    the wizard's -x option; Lite Server reads this default when it starts,
  #    so set it now, before it runs.
  if [[ -w $DRBL_OCS_CONF ]] && ! grep -q '^udp_sender_extra_opt_default=.*--full-duplex' "$DRBL_OCS_CONF"; then
    if grep -q '^udp_sender_extra_opt_default=' "$DRBL_OCS_CONF"; then
      sed -i -E 's/^udp_sender_extra_opt_default="([^"]*)"/udp_sender_extra_opt_default="\1 --full-duplex"/' "$DRBL_OCS_CONF"
    else
      echo 'udp_sender_extra_opt_default="--full-duplex"' >>"$DRBL_OCS_CONF"
    fi
    echo "$(date '+%F %T') enabled full-duplex multicast in $DRBL_OCS_CONF" >>"$LOG"
  fi
  setsid nohup bash "$0" --watch >>"$LOG" 2>&1 </dev/null &
  echo "Lite Server helper started (log: $LOG)"
  exit 0
fi

log() { echo "$(date '+%F %T') $*"; }

log "watching $NBI"
while :; do
  if [[ -s $NBI/shimx64.efi && -s $NBI/grubx64.efi && -s $NBI/bootx64.efi ]] &&
    ! cmp -s "$NBI/shimx64.efi" "$NBI/bootx64.efi"; then
    cp -f "$NBI/bootx64.efi" "$NBI/bootx64-unsigned.efi"
    cp -f "$NBI/shimx64.efi" "$NBI/bootx64.efi"
    # MokManager, in case shim needs it; harmless otherwise.
    [[ -f /usr/lib/shim/mmx64.efi.signed ]] && cp -f /usr/lib/shim/mmx64.efi.signed "$NBI/mmx64.efi"
    chmod 644 "$NBI/bootx64.efi" "$NBI"/mmx64.efi 2>/dev/null || true
    log "bootx64.efi is now the signed shim"
  fi

  for f in "$NBI"/grub/grub.cfg* "$NBI"/pxelinux.cfg/*; do
    if [[ ! -f $f ]] || ! grep -q 'ocs_repository=' "$f"; then continue; fi
    # Handles both ocs_repository="..." and GRUB-escaped ocs_repository=\"...\".
    sed -i -E 's/[[:space:]]ocs_repository=(\\?"[^"\\]*\\?"|[^[:space:]]+)//g' "$f"
    log "removed ocs_repository from $f"
  done
  sleep 2
done
