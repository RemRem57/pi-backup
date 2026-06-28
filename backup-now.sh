#!/usr/bin/env bash
# backup-now — Backup HDD à la demande (voie B, déclenchement manuel).
# Usage : sudo backup-now
# Symlink recommandé : ln -s /appdata/pi-backup/backup-now.sh /usr/local/bin/backup-now
#
# Sécurités :
#   - Vérifie que le HDD est réellement monté avant que Borg écrive (invariant #1)
#   - Jamais umount -l ; retries avec backoff (invariant #2)
#   - sync avant umount (invariant #3)
#   - Slack vert UNIQUEMENT après démontage confirmé (invariant #4)
#   - flock pour éviter les exécutions parallèles (invariant #6)
#   - trap EXIT : umount d'urgence + Slack rouge si le script est interrompu
set -euo pipefail

MOUNT_POINT="/srv/dev-disk-by-uuid-686E-B978"
HDD_DEVICE="/dev/disk/by-uuid/686E-B978"
CONFIG="/appdata/pi-backup/config.yaml"
PI_BACKUP="/appdata/pi-backup/.venv/bin/pi-backup"
LOG="/var/log/pi-backup-triggered.log"
LOCK="/var/lock/pi-backup.lock"

# Positionné à 1 dès que le HDD est confirmé monté, remis à 0 dès que l'umount est géré.
# Le trap ne fait rien si 0 — évite les doubles notifications sur les exits normaux.
trap_active=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

slack_ok() {
    "$PI_BACKUP" notify --config "$CONFIG" --title "$1" --body "$2" \
        2>&1 | tee -a "$LOG" \
        || log "WARNING: Slack notification failed"
}

slack_err() {
    "$PI_BACKUP" notify --config "$CONFIG" --title "$1" --body "$2" --error \
        2>&1 | tee -a "$LOG" \
        || log "WARNING: Slack notification failed"
}

cleanup() {
    [[ $trap_active -eq 0 ]] && return
    log "INTERRUPTION détectée — tentative de démontage d'urgence de $MOUNT_POINT"
    sync 2>/dev/null || true
    if umount "$MOUNT_POINT" 2>&1 | tee -a "$LOG"; then
        slack_err "⚠️ Script interrompu — HDD démonté" \
            "backup-now a été interrompu (Ctrl-C ou signal). Le HDD a pu être démonté proprement."
    else
        slack_err "🚨 Script interrompu — NE PAS débrancher le HDD" \
            "backup-now a été interrompu et le HDD n'a PAS pu être démonté. Vérifier et démonter manuellement."
    fi
    log "=== backup-now interrompu ==="
}
trap cleanup EXIT

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo "backup-now doit être lancé en root : sudo backup-now" >&2
    exit 1
fi

# --- Flock (empêche les exécutions parallèles) ---
exec 200>"$LOCK"
if ! flock -n 200; then
    log "Une instance de backup-now est déjà en cours — abandon."
    exit 1
fi

log "=== backup-now démarré ==="

# --- 1. Vérifier la présence du HDD ---
# Si le disque n'est pas branché : sortie silencieuse (cas filet cron à 3h).
if ! [[ -b "$HDD_DEVICE" ]]; then
    log "HDD ($HDD_DEVICE) absent — backup ignoré."
    exit 0
fi

# --- 2. Monter si nécessaire ---
if mountpoint -q "$MOUNT_POINT"; then
    log "HDD déjà monté."
else
    log "Montage de $MOUNT_POINT..."
    if ! mount "$MOUNT_POINT" 2>&1 | tee -a "$LOG"; then
        log "ERREUR : échec du montage"
        slack_err "🚨 Backup annulé" \
            "Impossible de monter le HDD ($MOUNT_POINT). Vérifier le câble USB ou le fstab."
        exit 1
    fi
fi

# --- 3. Vérification de sécurité du mountpoint (invariant #1) ---
if ! mountpoint -q "$MOUNT_POINT"; then
    log "ERREUR : $MOUNT_POINT n'est pas un mountpoint actif"
    slack_err "🚨 Backup annulé" \
        "Vérification du mountpoint échouée après montage. Borg n'écrira PAS sur le HDD."
    exit 1
fi

# À partir d'ici le HDD est monté et sous notre responsabilité.
trap_active=1

# --- 4. Backups ---
backup_ok=0
nextcloud_ok=0

log "Lancement de pi-backup backup..."
if "$PI_BACKUP" backup --config "$CONFIG" 2>&1 | tee -a "$LOG"; then
    backup_ok=1
    log "OS backup : OK"
else
    log "ERREUR : OS backup échoué"
fi

log "Lancement de pi-backup nextcloud..."
if "$PI_BACKUP" nextcloud --config "$CONFIG" 2>&1 | tee -a "$LOG"; then
    nextcloud_ok=1
    log "Nextcloud backup : OK"
else
    log "ERREUR : Nextcloud backup échoué"
fi

# --- 5. Sync + démontage (toujours, même en cas d'échec backup) ---
log "Sync..."
sync

log "Démontage de $MOUNT_POINT..."
umount_ok=0
for delay in 3 6 10 15 20; do
    if umount "$MOUNT_POINT" 2>&1 | tee -a "$LOG"; then
        umount_ok=1
        trap_active=0  # umount réussi, le trap n'a plus rien à faire
        log "Démontage réussi."
        break
    fi
    log "Démontage échoué, nouvelle tentative dans ${delay}s..."
    sleep "$delay"
done

if [[ $umount_ok -eq 0 ]]; then
    trap_active=0  # on notifie nous-mêmes, le trap ne doit pas doubler
    log "ERREUR : impossible de démonter $MOUNT_POINT après 5 tentatives"
    slack_err "🚨 NE PAS débrancher le HDD" \
        "Démontage impossible après 5 tentatives. Le disque est encore monté — attendre et relancer : umount $MOUNT_POINT"
    exit 1
fi

# --- 6. Notification finale ---
if [[ $backup_ok -eq 1 && $nextcloud_ok -eq 1 ]]; then
    log "Tous les backups réussis."
    slack_ok "🔌 RETRAIT OK — tu peux débrancher" \
        "OS ✅  Nextcloud ✅  HDD démonté proprement."
    log "=== backup-now terminé avec succès ==="
    exit 0
else
    details=""
    [[ $backup_ok -eq 0 ]]    && details+="OS backup ❌  "
    [[ $nextcloud_ok -eq 0 ]] && details+="Nextcloud ❌  "
    details+="HDD démonté proprement."
    log "Un ou plusieurs backups ont échoué."
    slack_err "❌ Backup(s) échoué(s) — HDD démonté" "$details"
    log "=== backup-now terminé avec erreur(s) ==="
    exit 1
fi
