#!/usr/bin/env bash
#
# nas-halt.sh — arrêt propre du NAS avant coupure physique de l'alimentation.
#
# Le HAT Penta SATA garde les SSD sous tension même Pi éteint : il n'existe pas
# de moyen logiciel de couper les disques. La coupure se fait donc en amont
# (prise Tapo), et ce script garantit qu'au moment où on coupe, plus rien de
# critique n'est en cours.
#
# Usage :
#   sudo nas-halt.sh              # vérifie, arrête, éteint
#   sudo nas-halt.sh --check      # vérifie seulement, n'éteint rien
#   sudo nas-halt.sh --force      # ignore les verrous (à utiliser en connaissance de cause)
#
set -euo pipefail

# ---------------------------------------------------------------- configuration

# Répertoires des stacks Docker, dans l'ordre d'arrêt souhaité.
# La supervision en dernier : elle continue d'observer les autres qui tombent.
COMPOSE_DIRS=(
  /docker-compose/nextcloud
  /docker-compose/exporters
  /docker-compose/monitoring
)

# Délai laissé à chaque conteneur pour s'arrêter de lui-même avant SIGKILL.
# Le défaut Docker est de 10 s : trop court pour MariaDB et PostgreSQL sous
# charge, et un SIGKILL sur une base = recovery au prochain démarrage.
STOP_TIMEOUT=60

# Point de montage du HDD de backup (présent seulement quand il est branché).
HDD_MOUNT=/srv/dev-disk-by-uuid-686E-B978

# Commande de notification Slack (laisser vide pour désactiver).
NOTIFY_CMD="pi-backup notify"

# ---------------------------------------------------------------------- helpers

CHECK_ONLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "argument inconnu : $arg" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit tourner en root (sudo)." >&2
  exit 1
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; BLOCKED=1; }

notify() {
  [[ -n "$NOTIFY_CMD" ]] || return 0
  $NOTIFY_CMD "$1" >/dev/null 2>&1 || true
}

BLOCKED=0

# ------------------------------------------------------------------ vérifications

echo "Vérifications avant arrêt"

# 1. Borg. Couper pendant une sauvegarde laisse le dépôt verrouillé, et la
#    prochaine exécution refusera de démarrer tant que le lock n'est pas cassé.
if pgrep -x borg >/dev/null 2>&1; then
  die "une sauvegarde Borg est en cours"
else
  ok "aucune sauvegarde Borg en cours"
fi

if systemctl is-active --quiet backup-hdd.service 2>/dev/null; then
  die "backup-hdd.service est actif"
else
  ok "backup-hdd.service inactif"
fi

# 2. RAID. Le bitmap d'intention d'écriture rend la coupure non destructive,
#    mais un scrub interrompu repart de zéro : autant attendre qu'il finisse.
for f in /sys/block/md*/md/sync_action; do
  [[ -e "$f" ]] || continue
  action=$(<"$f")
  dev=$(basename "$(dirname "$(dirname "$f")")")
  if [[ "$action" != "idle" ]]; then
    die "$dev est en '$action' (scrub ou reconstruction en cours)"
  else
    ok "$dev au repos"
  fi
done

# 3. État du tableau : si un disque manque déjà, mieux vaut le savoir avant
#    de couper que de le découvrir au redémarrage.
if grep -q '_' /proc/mdstat 2>/dev/null; then
  warn "le tableau RAID est dégradé — vérifie /proc/mdstat avant de couper"
fi

if [[ $BLOCKED -eq 1 && $FORCE -eq 0 ]]; then
  echo
  echo "Arrêt annulé. Relance quand les opérations ci-dessus sont terminées," >&2
  echo "ou force avec --force si tu sais ce que tu fais." >&2
  exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  echo "Mode --check : rien n'a été arrêté."
  exit 0
fi

# ------------------------------------------------------------------------ arrêt

echo
echo "Arrêt des services"

notify "NAS : arrêt propre demandé, extinction en cours"

for dir in "${COMPOSE_DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    echo "  → $dir"
    docker compose --project-directory "$dir" down --timeout "$STOP_TIMEOUT" || \
      warn "l'arrêt de $dir a retourné une erreur — on continue"
  else
    warn "$dir introuvable, ignoré"
  fi
done

# Démontage du HDD de backup s'il est encore branché.
if findmnt -rn "$HDD_MOUNT" >/dev/null 2>&1; then
  echo "  → démontage $HDD_MOUNT"
  umount "$HDD_MOUNT" || warn "démontage impossible — systemd s'en chargera"
fi

sync

echo
echo "Extinction. Le noyau vide les caches et met les disques en veille."
echo
echo "  Attends que la conso de la prise chute et se stabilise, PUIS coupe."
echo "  Les LED bleues des SSD resteront allumées : c'est normal, le HAT"
echo "  reste alimenté. Ce n'est pas un signe que l'arrêt n'est pas terminé."
echo

sleep 2
systemctl poweroff
