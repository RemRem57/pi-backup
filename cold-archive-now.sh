#!/usr/bin/env bash
# cold-archive-now — archive froide trimestrielle Nextcloud → OVH Cold Archive
# Usage : sudo cold-archive-now [--dry-run]
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
APPDATA=/appdata/pi-backup
RCLONE_CONF=/appdata/rclone/rclone.conf
BUCKET=rzapp-nextcloud-cold
REMOTE="ovh-cold:${BUCKET}/nextcloud-archive"
RAID=/srv/dev-disk-by-uuid-c2939c2b-3899-4767-b3f0-b0505a98e397
DATA_DIR="${RAID}/nextcloud/data"
TMP="${RAID}/.cold-archive-tmp"        # sur le RAID, pas sur la SD
PIBACKUP="${APPDATA}/.venv/bin/pi-backup"
DB_CONTAINER=nextcloud-db
NC_CONTAINER=nextcloud
DB_NAME=nextcloud
DB_USER=nextcloud
DB_PW_FILE="${APPDATA}/.nextcloud-db-password"
LOG=/var/log/cold-archive-now.log
PUSHGW=http://localhost:9091

# ── Mode dry-run ──────────────────────────────────────────────────────────
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

RCLONE=(rclone --config "$RCLONE_CONF"
        --transfers 4 --checkers 8
        --stats 5m --stats-one-line -v)
[[ $DRY_RUN -eq 1 ]] && RCLONE+=(--dry-run)

# ── Garde-fous ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Lance-moi en root (sudo cold-archive-now)"; exit 1; }
exec 9>/var/lock/cold-archive-now.lock
flock -n 9 || { echo "Une archive froide est déjà en cours."; exit 1; }
exec > >(tee -a "$LOG") 2>&1
echo "═══ $(date -Is) — démarrage archive froide $([[ $DRY_RUN -eq 1 ]] && echo '[DRY-RUN]') ═══"

notify() {
  [[ $DRY_RUN -eq 1 ]] && { echo "[DRY-RUN] notify: $1 — $2"; return; }
  if [[ "${3:-}" == "--error" ]]; then
    "$PIBACKUP" notify --config "${APPDATA}/config.yaml" --title "$1" --body "$2" --error
  else
    "$PIBACKUP" notify --config "${APPDATA}/config.yaml" --title "$1" --body "$2"
  fi
}

on_error() {
  rm -rf "$TMP"
  notify "❄️🚨 Archive froide OVH échouée" "Voir ${LOG} sur le Pi." --error
}
trap on_error ERR

# ── 1. Dump SQL cohérent + config Nextcloud ──────────────────────────────
# En dry-run on fait quand même le dump réel (pour valider que la commande
# docker exec/cp fonctionne) mais on n'uploade rien — le dump reste dans $TMP
# pour inspection manuelle, il n'est pas supprimé en fin de script.
mkdir -p "$TMP"
echo "→ Dump MariaDB (single-transaction)…"
docker exec "$DB_CONTAINER" mariadb-dump --single-transaction \
  -u "$DB_USER" -p"$(cat "$DB_PW_FILE")" "$DB_NAME" > "${TMP}/nextcloud-db.sql"
echo "→ Copie config/ Nextcloud…"
docker cp "${NC_CONTAINER}:/var/www/html/config" "${TMP}/config"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "→ Dump OK. Vérifie manuellement : head -30 ${TMP}/nextcloud-db.sql"
  wc -l "${TMP}/nextcloud-db.sql"
  ls -la "${TMP}/config"
fi

# ── 2. Uploads (write-only : copy, jamais sync/delete) ───────────────────
# En dry-run, rclone --dry-run liste ce qu'il transférerait sans rien envoyer.
echo "→ Upload dump + config…"
"${RCLONE[@]}" copy "${TMP}/nextcloud-db.sql" "${REMOTE}/db/"
"${RCLONE[@]}" copy "${TMP}/config"           "${REMOTE}/config/"
echo "→ Upload datadir (incrémental — seul le delta est transféré)…"
"${RCLONE[@]}" copy "$DATA_DIR"               "${REMOTE}/data/"

# ── 3. Nettoyage + notifications ─────────────────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  echo "═══ $(date -Is) — DRY-RUN terminé, rien n'a été uploadé ═══"
  echo "Dump conservé dans ${TMP} pour inspection — à supprimer manuellement :"
  echo "  rm -rf ${TMP}"
  trap - ERR
  exit 0
fi

rm -rf "$TMP"
trap - ERR

SIZE=$("${RCLONE[@]}" size "$REMOTE" 2>/dev/null | tail -1 || echo "n/a")
notify "❄️ Archive froide OVH OK" "copy trimestriel terminé. Taille bucket : ${SIZE}"

# Métrique Prometheus (filet « trimestre oublié » côté Grafana)
echo "cold_archive_last_success $(date +%s)" | \
  curl -s --data-binary @- "${PUSHGW}/metrics/job/cold_archive" || true

echo "═══ $(date -Is) — terminé ═══"