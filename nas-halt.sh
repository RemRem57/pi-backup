#!/usr/bin/env bash
#
# nas-halt.sh — arrêt propre du NAS avant coupure physique de l'alimentation.
#
# Le HAT Penta SATA garde les SSD sous tension même Pi éteint : il n'existe pas
# de moyen logiciel de couper les disques. La coupure se fait donc en amont
# (prise Tapo), et ce script garantit qu'au moment où on coupe, plus rien de
# critique n'est en cours.
#
# Ce script n'arrête PAS Docker : systemd le fait déjà en éteignant
# docker.service, ce qui couvre automatiquement toute stack ajoutée plus tard.
# Le seul réglage nécessaire est le délai laissé aux conteneurs, à mettre une
# fois pour toutes dans /etc/docker/daemon.json :
#
#     { "shutdown-timeout": 60 }
#
# (défaut : 15 s, trop court pour MariaDB/PostgreSQL — à garder sous les 90 s
#  du TimeoutStopSec de docker.service)
#
# Usage :
#   sudo nas-halt.sh              # vérifie puis éteint
#   sudo nas-halt.sh --check      # vérifie seulement
#   sudo nas-halt.sh --force      # ignore les verrous, en connaissance de cause
#
set -euo pipefail

NOTIFY_CMD="pi-backup notify"   # laisser vide pour désactiver

# ---------------------------------------------------------------------- setup

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

BLOCKED=0

# --------------------------------------------------------------- vérifications

echo "Vérifications avant arrêt"

# Borg : couper pendant une sauvegarde laisse le dépôt verrouillé, et la
# prochaine exécution refusera de démarrer tant que le lock n'est pas cassé.
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

# RAID : le bitmap d'intention d'écriture rend la coupure non destructive,
# mais un scrub interrompu repart de zéro — autant le laisser finir.
for f in /sys/block/md*/md/sync_action; do
  [[ -e "$f" ]] || continue
  action=$(<"$f")
  dev=$(basename "$(dirname "$(dirname "$f")")")
  if [[ "$action" != "idle" ]]; then
    die "$dev est en '$action'"
  else
    ok "$dev au repos"
  fi
done

# Tableau dégradé : mieux vaut le savoir maintenant qu'au redémarrage.
if grep -q '_' /proc/mdstat 2>/dev/null; then
  warn "le tableau RAID est dégradé — vérifie /proc/mdstat"
fi

if [[ $BLOCKED -eq 1 && $FORCE -eq 0 ]]; then
  echo
  echo "Arrêt annulé. Relance quand c'est terminé, ou --force." >&2
  exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
  echo
  echo "Mode --check : rien n'a été arrêté."
  exit 0
fi

# --------------------------------------------------------------------- arrêt

[[ -n "$NOTIFY_CMD" ]] && $NOTIFY_CMD "NAS : arrêt propre, extinction en cours" >/dev/null 2>&1 || true

sync

echo
echo "Extinction en cours."
echo
echo "  Attends que la conso de la prise chute et se stabilise, PUIS coupe."
echo "  Les LED bleues des SSD resteront allumées : c'est normal, le HAT"
echo "  reste alimenté. Ce n'est pas un signe que l'arrêt n'est pas fini."
echo

sleep 2
systemctl poweroff
