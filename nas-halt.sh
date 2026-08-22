#!/usr/bin/env bash
# nas-halt — arrêt propre du NAS avant coupure physique de l'alimentation.
# Usage : sudo nas-halt [--check] [--force]
# Symlink recommandé : ln -s /appdata/pi-backup/nas-halt.sh /usr/local/bin/nas-halt
#
# Le HAT Penta SATA garde les SSD sous tension même Pi éteint : il n'existe pas
# de moyen logiciel de couper les disques. La coupure se fait donc en amont
# (prise Tapo), et ce script garantit qu'au moment où on coupe, plus rien de
# critique n'est en cours.
#
# Ce script n'arrête PAS Docker : systemd le fait déjà via docker.service, ce
# qui couvre automatiquement toute stack ajoutée plus tard. Seul réglage requis,
# une fois pour toutes, dans /etc/docker/daemon.json :
#     { "shutdown-timeout": 60 }
# (défaut 15 s, trop court pour MariaDB/PostgreSQL ; rester sous les 90 s du
#  TimeoutStopSec de docker.service)
#
# Sécurités :
#   - Prend le MÊME flock que backup-now (invariant : jamais de coupure pendant
#     un backup, y compris pendant la boucle de démontage où Borg ne tourne plus)
#   - Refuse de partir si un scrub ou une reconstruction RAID est en cours
#   - La notification Slack n'est jamais silencieuse : un échec est affiché
set -euo pipefail

CONFIG="/appdata/pi-backup/config.yaml"
PI_BACKUP="/appdata/pi-backup/.venv/bin/pi-backup"
LOCK="/var/lock/pi-backup.lock"

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
    echo "nas-halt doit être lancé en root : sudo nas-halt" >&2
    exit 1
fi

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; BLOCKED=1; }

slack_ok() {
    "$PI_BACKUP" notify --config "$CONFIG" --title "$1" --body "$2" \
        || echo "WARNING: notification Slack échouée" >&2
}

BLOCKED=0

# --- 1. Vérifications -------------------------------------------------------

echo "Vérifications avant arrêt"

# Verrou pi-backup : couvre backup-now du montage jusqu'au démontage confirmé.
# Couper le jus dans cette fenêtre laisse le dépôt Borg verrouillé, et la
# prochaine exécution refusera de démarrer tant que le lock n'est pas cassé.
exec 200>"$LOCK"
if flock -n 200; then
    ok "aucun backup en cours"
else
    die "un backup est en cours (verrou $LOCK détenu)"
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
    warn "le tableau RAID est dégradé — vérifier /proc/mdstat"
fi

if [[ $BLOCKED -eq 1 && $FORCE -eq 0 ]]; then
    echo
    echo "Arrêt annulé. Relancer quand c'est terminé, ou forcer avec --force." >&2
    exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo
    echo "Mode --check : rien n'a été arrêté."
    exit 0
fi

# --- 2. Arrêt ---------------------------------------------------------------

slack_ok "🔌 NAS — extinction" \
    "Arrêt propre demandé via nas-halt. Vérifications OK, extinction en cours."

sync

echo
echo "Extinction en cours."
echo
echo "  Attendre que la conso de la prise chute et se stabilise, PUIS couper."
echo "  Les LED bleues des SSD resteront allumées : c'est normal, le HAT reste"
echo "  alimenté. Ce n'est pas un signe que l'arrêt n'est pas terminé."
echo

sleep 2
systemctl poweroff
