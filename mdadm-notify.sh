#!/bin/bash
# /appdata/pi-backup/mdadm-notify.sh
# Appelé par mdadm --monitor : $1=événement $2=device $3=composant (optionnel)
EVENT="$1"; DEVICE="$2"; COMPONENT="${3:-}"
PB=/appdata/pi-backup/.venv/bin/pi-backup
CFG=/appdata/pi-backup/config.yaml

case "$EVENT" in
  Fail|FailSpare|DegradedArray|DeviceDisappeared)
    "$PB" notify --config "$CFG" --error \
      --title "🔴 RAID — $EVENT" \
      --body "Device: $DEVICE $COMPONENT"
    ;;
  RebuildStarted|RebuildFinished|SpareActive|NewArray)
    "$PB" notify --config "$CFG" \
      --title "🔧 RAID — $EVENT" \
      --body "Device: $DEVICE $COMPONENT"
    ;;
  *) : ;;   # Rebuild20/40/60/80 : ignorés, trop bavards
esac
